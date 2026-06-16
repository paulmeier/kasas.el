;;; kasas.el --- Emacs interface to the kasas financial ledger -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Paul Meier

;; Author: Paul Meier <paulmartinmeier@gmail.com>
;; Maintainer: Paul Meier <paulmartinmeier@gmail.com>
;; Created: 2026
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, finance, convenience
;; URL: https://github.com/paulmeier/kasas.el
;; SPDX-License-Identifier: MIT

;; This file is NOT part of GNU Emacs.

;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction.  This program is free software and is
;; distributed under the terms of the MIT License; see the LICENSE file in the
;; project root for the full text.

;;; Commentary:

;; kasas.el is a client for kasas <https://github.com/paulmeier/kasas>, a
;; self-hosted financial ledger that exposes a REST API, an event stream, and an
;; MCP server over your transactions, accounts, labels, rules, and more.
;;
;; This file provides the foundation that every other module builds on:
;;
;;   * a small, dependency-free HTTP client over the built-in `url' library,
;;     with synchronous and asynchronous request helpers;
;;   * authentication via a configured token or `auth-source';
;;   * JSON decoding into plist-friendly shapes; and
;;   * typed accessors for the API DTOs (accounts, transactions, ...).
;;
;; Higher-level, user-facing features live in companion files that are loaded on
;; demand:
;;
;;   * `kasas-accounts'     -- browse accounts in a `tabulated-list' buffer;
;;   * `kasas-transactions' -- browse and search transactions;
;;   * `kasas-events'       -- follow the live event stream;
;;   * `kasas-plot'         -- realtime graphical displays via Org's gnuplot
;;                             integration (`org-plot');
;;   * `kasas-server'       -- download/install the kasas server binary and run
;;                             it from Emacs (`kasas-install', `kasas-server-start').
;;
;; Quick start:
;;
;;   (setq kasas-base-url "http://localhost:8080"
;;         kasas-token    "kasas_...")   ; or use auth-source, see `kasas-token'
;;   M-x kasas            ; the transaction-centric entry point
;;   M-x kasas-accounts   ; the account list
;;
;; See the README for a full tour.

;;; Code:

(require 'url)
(require 'url-http)
(require 'json)
(require 'auth-source)
(require 'cl-lib)
(require 'subr-x)
(require 'iso8601)

;; Buffer-local values set by url-http in the retrieval buffer.
(defvar url-http-response-status)
(defvar url-http-end-of-headers)

(declare-function kasas-transactions "kasas-transactions" ())

;;;; Customization

(defgroup kasas nil
  "Emacs interface to the kasas financial ledger."
  :group 'tools
  :prefix "kasas-"
  :link '(url-link :tag "Homepage" "https://github.com/paulmeier/kasas.el")
  :link '(url-link :tag "kasas" "https://github.com/paulmeier/kasas"))

(defcustom kasas-base-url "http://localhost:8080"
  "Base URL of the kasas server, with no trailing slash.

The REST API is served beneath \"/api/v1\" at this host."
  :type 'string
  :group 'kasas)

(defcustom kasas-token nil
  "Bearer token used to authenticate with kasas.

This may be the dashboard token or a scoped API key (see the kasas
Authentication docs).  When nil, `kasas' looks the token up via
`auth-source' (see `kasas-use-auth-source'); a kasas server with no token
configured accepts unauthenticated requests, in which case nil is fine.

Storing a secret directly in a variable is convenient but not secure; prefer
`auth-source' for anything but local experiments."
  :type '(choice (const :tag "None / look up via auth-source" nil)
                 (string :tag "Token"))
  :group 'kasas)

(defcustom kasas-use-auth-source t
  "When non-nil, fall back to `auth-source' to resolve the bearer token.

The host of `kasas-base-url' is used as the auth-source :host, so an entry such
as the following in ~/.authinfo.gpg supplies the token:

  machine localhost:8080 login kasas password kasas_XXXX

`kasas-token', when set, always takes precedence over auth-source."
  :type 'boolean
  :group 'kasas)

(defcustom kasas-default-limit 100
  "Default page size for list endpoints (server max is 1000)."
  :type 'integer
  :group 'kasas)

(defcustom kasas-request-timeout 30
  "Seconds to wait for a synchronous request before giving up."
  :type 'number
  :group 'kasas)

(defcustom kasas-currency-symbol "$"
  "Symbol prepended when formatting money amounts for display.

kasas stores amounts as exact decimal strings and never as floats; this is
purely cosmetic and applied only at display time."
  :type 'string
  :group 'kasas)

;;;; Errors

(define-error 'kasas-error "kasas request failed")
(define-error 'kasas-http-error "kasas HTTP error" 'kasas-error)
(define-error 'kasas-auth-error "kasas authentication required" 'kasas-http-error)

;;;; Internals: URL and auth

(defun kasas--host ()
  "Return the host[:port] authority of `kasas-base-url'.
The port is kept when present, so it matches the auth-source convention in
the kasas docs (e.g. \"machine localhost:8080\")."
  (let* ((url (url-generic-parse-url kasas-base-url))
         (host (url-host url))
         (port (url-portspec url)))
    (if port (format "%s:%s" host port) host)))

(defun kasas--auth-token ()
  "Resolve the bearer token, or nil when none is available.
`kasas-token' wins; otherwise consult `auth-source' when enabled."
  (or kasas-token
      (and kasas-use-auth-source
           (let* ((host (kasas--host))
                  (found (car (auth-source-search :host host :max 1
                                                  :require '(:secret)))))
             (when found
               (let ((secret (plist-get found :secret)))
                 (if (functionp secret) (funcall secret) secret)))))))

(defun kasas--build-query (params)
  "Encode PARAMS, an alist of (KEY . VALUE), into a query string.
Entries whose VALUE is nil are skipped.  KEY may be a string or symbol;
VALUE is coerced to a string.  Returns the empty string for no params."
  (let ((pairs
         (delq nil
               (mapcar
                (lambda (kv)
                  (let ((k (car kv)) (v (cdr kv)))
                    (when (and v (not (equal v "")))
                      (concat (url-hexify-string (format "%s" k))
                              "="
                              (url-hexify-string (format "%s" v))))))
                params))))
    (if pairs (concat "?" (string-join pairs "&")) "")))

(defun kasas--url (path &optional params)
  "Build a full request URL for PATH under the API root, plus PARAMS.
PATH is appended to \"<base>/api/v1\"; a path beginning with \"/\" is treated
as absolute under the base host (so probes like \"/healthz\" work too)."
  (let* ((base (string-trim-right kasas-base-url "/+"))
         (root (if (string-prefix-p "/api" path)
                   (concat base path)
                 (if (string-prefix-p "/" path)
                     (concat base path)
                   (concat base "/api/v1/" path)))))
    (concat root (kasas--build-query params))))

;;;; Internals: JSON

(defun kasas--json-read-string (string)
  "Parse JSON STRING into Lisp using plists, vectors, and keyword keys.
Prefers the native `json-parse-string' when available."
  (if (fboundp 'json-parse-string)
      (json-parse-string string
                         :object-type 'plist
                         :array-type 'array
                         :null-object nil
                         :false-object :false)
    (let ((json-object-type 'plist)
          (json-array-type 'vector)
          (json-key-type 'keyword)
          (json-false :false))
      (json-read-from-string string))))

(defun kasas--json-encode (object)
  "Encode OBJECT to a JSON string."
  (if (fboundp 'json-serialize)
      (json-serialize object :null-object nil :false-object :false)
    (let ((json-false :false))
      (json-encode object))))

;;;; Internals: HTTP

(defun kasas--headers (has-body)
  "Return request headers; include a JSON content type when HAS-BODY."
  (let ((token (kasas--auth-token))
        (headers nil))
    (when token
      (push (cons "Authorization" (concat "Bearer " token)) headers))
    (when has-body
      (push (cons "Content-Type" "application/json") headers))
    headers))

(defun kasas--parse-response (buffer)
  "Parse the `url' response in BUFFER into (STATUS . PAYLOAD).
PAYLOAD is decoded JSON, or the raw body string when it is not JSON, or nil
for an empty body.  Signals on a transport-level failure."
  (with-current-buffer buffer
    (let ((status url-http-response-status))
      (unless status
        (signal 'kasas-error '("no HTTP response from kasas")))
      ;; `url-http' marks the end of the headers; fall back to a blank line.
      (goto-char (point-min))
      (let* ((body-start (cond ((and (boundp 'url-http-end-of-headers)
                                     url-http-end-of-headers)
                                (marker-position url-http-end-of-headers))
                               ((re-search-forward "^\r?$" nil t) (point))
                               (t (point-max))))
             (body (string-trim
                    (decode-coding-string
                     (buffer-substring-no-properties body-start (point-max))
                     'utf-8))))
        (cons status
              (when (and body (not (string-empty-p body)))
                (condition-case nil
                    (kasas--json-read-string body)
                  (error body))))))))

(defun kasas--signal-http (status payload)
  "Signal an appropriate kasas error for STATUS and decoded PAYLOAD."
  (let ((msg (or (and (listp payload) (plist-get payload :error))
                 (and (listp payload) (plist-get payload :message))
                 (and (stringp payload) payload)
                 "request failed")))
    (cond
     ((memq status '(401 403))
      (signal 'kasas-auth-error (list (format "%s (HTTP %d)" msg status))))
     (t
      (signal 'kasas-http-error (list (format "%s (HTTP %d)" msg status)))))))

(cl-defun kasas-request (method path &key params data)
  "Perform a synchronous METHOD request to PATH and return decoded JSON.

METHOD is a string such as \"GET\" or \"POST\".  PATH is relative to the API
root (see `kasas--url').  PARAMS is an alist of query parameters; DATA, when
non-nil, is a Lisp object serialized to a JSON request body.

Return the decoded payload on a 2xx response and signal `kasas-http-error'
\(or `kasas-auth-error') otherwise."
  (let* ((url-request-method method)
         (url-request-extra-headers (kasas--headers (and data t)))
         (url-request-data (when data
                             (encode-coding-string (kasas--json-encode data) 'utf-8)))
         (url (kasas--url path params))
         (buffer (url-retrieve-synchronously url t t kasas-request-timeout)))
    (unless buffer
      (signal 'kasas-error (list (format "no response from %s" url))))
    (unwind-protect
        (pcase-let ((`(,status . ,payload) (kasas--parse-response buffer)))
          (if (<= 200 status 299)
              payload
            (kasas--signal-http status payload)))
      (kill-buffer buffer))))

(cl-defun kasas-request-async (method path callback &key params data error-callback)
  "Like `kasas-request' but asynchronous.

METHOD, PATH, PARAMS, and DATA are as in `kasas-request'.  On a 2xx response
CALLBACK is called with the decoded payload.  On failure ERROR-CALLBACK, when
supplied, is called with an error object; otherwise the error is reported with
`message'."
  (let* ((url-request-method method)
         (url-request-extra-headers (kasas--headers (and data t)))
         (url-request-data (when data
                             (encode-coding-string (kasas--json-encode data) 'utf-8)))
         (url (kasas--url path params)))
    (url-retrieve
     url
     (lambda (event-status)
       (let ((buffer (current-buffer)))
         (unwind-protect
             (if-let* ((err (plist-get event-status :error)))
                 (if error-callback (funcall error-callback err)
                   (message "kasas: %S" err))
               (condition-case err
                   (pcase-let ((`(,status . ,payload) (kasas--parse-response buffer)))
                     (if (<= 200 status 299)
                         (funcall callback payload)
                       (kasas--signal-http status payload)))
                 (kasas-error
                  (if error-callback (funcall error-callback err)
                    (message "kasas: %s" (error-message-string err))))))
           (kill-buffer buffer))))
     nil t t)))

;;;; API: typed endpoints

;; The functions below mirror the kasas REST surface.  Each returns the decoded
;; payload (a plist for objects, a vector for arrays) and signals on error.

(defun kasas-auth-status ()
  "Return the open `{auth_required, authenticated}' probe as a plist."
  (kasas-request "GET" "auth"))

(defun kasas-healthy-p ()
  "Return non-nil when the server's liveness probe succeeds."
  (ignore-errors (kasas-request "GET" "/healthz") t))

(defun kasas-organizations ()
  "Return the vector of organizations."
  (kasas-request "GET" "organizations"))

(cl-defun kasas-accounts-list (&key org-id)
  "Return the vector of accounts, optionally filtered by ORG-ID."
  (kasas-request "GET" "accounts" :params `(("org_id" . ,org-id))))

(defun kasas-account (id)
  "Return the account with ID."
  (kasas-request "GET" (format "accounts/%s" id)))

(cl-defun kasas-account-transactions (id &key since until (limit kasas-default-limit) offset)
  "Return transactions for account ID, with optional filters.
SINCE and UNTIL accept a YYYY-MM-DD date, an RFC3339 timestamp, or unix
seconds.  LIMIT and OFFSET paginate."
  (kasas-request "GET" (format "accounts/%s/transactions" id)
                 :params `(("since" . ,since) ("until" . ,until)
                           ("limit" . ,limit) ("offset" . ,offset))))

(cl-defun kasas-transactions-list (&key label-key label-value since until
                                        (limit kasas-default-limit) offset)
  "Return a vector of transactions.
LABEL-KEY with optional LABEL-VALUE drills down by label; SINCE/UNTIL filter by
time; LIMIT/OFFSET paginate."
  (kasas-request "GET" "transactions"
                 :params `(("label_key" . ,label-key)
                           ("label_value" . ,label-value)
                           ("since" . ,since) ("until" . ,until)
                           ("limit" . ,limit) ("offset" . ,offset))))

(cl-defun kasas-search (query &key (limit kasas-default-limit) offset)
  "Run the kasas search QUERY and return the `{query,total,transactions}' plist.
LIMIT and OFFSET paginate the results.  See the kasas search grammar for the
query language."
  (kasas-request "GET" "transactions/search"
                 :params `(("q" . ,query) ("limit" . ,limit) ("offset" . ,offset))))

(defun kasas-transaction (id)
  "Return the transaction with ID."
  (kasas-request "GET" (format "transactions/%s" id)))

(defun kasas-transaction-history (id)
  "Return the version history of transaction ID."
  (kasas-request "GET" (format "transactions/%s/history" id)))

(defun kasas-transaction-relationships (id)
  "Return the relationship edges of transaction ID."
  (kasas-request "GET" (format "transactions/%s/relationships" id)))

(defun kasas-labels ()
  "Return the label vocabulary with per-pair transaction counts."
  (kasas-request "GET" "labels"))

(defun kasas-set-transaction-labels (id labels)
  "Replace the labels of transaction ID with LABELS, an alist or plist.
LABELS is serialized as the JSON object body \"{\\\"labels\\\": {...}}\"."
  (kasas-request "PUT" (format "transactions/%s/labels" id)
                 :data (list :labels (kasas--to-json-object labels))))

(cl-defun kasas-events (&key after type entity-type entity-id (limit kasas-default-limit) newest)
  "Read the event stream forward from a cursor.
Return the `{events, next}' plist.  AFTER is a sequence cursor; TYPE,
ENTITY-TYPE, ENTITY-ID filter; LIMIT bounds the page; NEWEST (non-nil) returns
the most recent events instead."
  (kasas-request "GET" "events"
                 :params `(("after" . ,after) ("type" . ,type)
                           ("entity_type" . ,entity-type) ("entity_id" . ,entity-id)
                           ("limit" . ,limit)
                           ,@(when newest '(("newest" . "true"))))))

(cl-defun kasas-sync-status ()
  "Return the latest sync status."
  (kasas-request "GET" "sync"))

(cl-defun kasas-sync-history (&key (limit kasas-default-limit))
  "Return up to LIMIT of the most recent sync-run records."
  (kasas-request "GET" "sync/history" :params `(("limit" . ,limit))))

(defun kasas-trigger-sync ()
  "Trigger a sync (async on the server; return the 202 payload)."
  (kasas-request "POST" "sync"))

(defun kasas--to-json-object (alist-or-plist)
  "Coerce ALIST-OR-PLIST into a plist suitable for `kasas--json-encode'."
  (cond
   ((null alist-or-plist) nil)
   ((keywordp (car alist-or-plist)) alist-or-plist) ; already a plist
   ((consp (car alist-or-plist))                    ; alist
    (cl-loop for (k . v) in alist-or-plist
             append (list (intern (concat ":" (format "%s" k))) v)))
   (t alist-or-plist)))

;;;; DTO accessors and formatting helpers

(defun kasas-get (object key &optional default)
  "Read KEY from OBJECT, a decoded JSON plist, returning DEFAULT when missing.
KEY is a keyword such as :id; a missing or `:null' value yields DEFAULT."
  (let ((v (plist-get object key)))
    (if (or (null v) (eq v :null)) default v)))

(defun kasas-format-amount (amount &optional currency)
  "Format AMOUNT (an exact decimal string) for display, prefixed by CURRENCY.
Negative amounts keep their sign before the currency symbol."
  (let* ((sym (or currency kasas-currency-symbol))
         (s (if (stringp amount) amount (format "%s" amount))))
    (if (string-prefix-p "-" s)
        (concat "-" sym (substring s 1))
      (concat sym s))))

(defun kasas-parse-amount (amount)
  "Return AMOUNT (an exact decimal string) as a float for plotting/aggregation.
Returns 0.0 for nil or unparsable input.  Display always uses the exact
string via `kasas-format-amount'; this is for math only."
  (cond
   ((numberp amount) (float amount))
   ((and (stringp amount) (string-match-p "\\`[-+]?[0-9.]+\\'" amount))
    (string-to-number amount))
   (t 0.0)))

(defun kasas-format-time (iso)
  "Format an RFC3339/ISO timestamp ISO as a local YYYY-MM-DD HH:MM string."
  (if (and iso (stringp iso) (not (string-empty-p iso)))
      (condition-case nil
          (format-time-string "%Y-%m-%d %H:%M" (encode-time (iso8601-parse iso)))
        (error iso))
    ""))

(defun kasas-format-date (iso)
  "Format an RFC3339/ISO timestamp ISO as a local YYYY-MM-DD string."
  (if (and iso (stringp iso) (not (string-empty-p iso)))
      (condition-case nil
          (format-time-string "%Y-%m-%d" (encode-time (iso8601-parse iso)))
        (error iso))
    ""))

(defun kasas-labels-string (labels)
  "Render LABELS (a plist of key->value) as a compact \"k:v k:v\" string."
  (when labels
    (string-join
     (cl-loop for (k v) on labels by #'cddr
              collect (format "%s:%s" (substring (symbol-name k) 1) v))
     " ")))

;;;; Entry point

;;;###autoload
(defun kasas ()
  "Open the kasas transaction browser, the main entry point.
Loads `kasas-transactions' on demand."
  (interactive)
  (require 'kasas-transactions)
  (call-interactively #'kasas-transactions))

(provide 'kasas)

;;; kasas.el ends here
