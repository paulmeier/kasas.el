;;; kasas-gptel.el --- Expose the kasas ledger to gptel as LLM tools -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Paul Meier
;; SPDX-License-Identifier: MIT

;; Author: Paul Meier <paulmartinmeier@gmail.com>
;; URL: https://github.com/paulmeier/kasas.el

;; This file is part of kasas.el.  See kasas.el for the license.

;;; Commentary:

;; Integration with gptel <https://github.com/karthink/gptel>.  It registers a
;; set of read-only gptel *tools* that let an LLM query your kasas ledger
;; directly — search transactions, list accounts, inspect labels, check sync
;; status — so you can ask questions like "how much did I spend on groceries
;; last month?" and have the model fetch the real numbers via tool calls
;; instead of guessing.
;;
;; gptel is an optional dependency: this file degrades gracefully when gptel is
;; not installed.  Enable the integration with:
;;
;;   (require 'kasas-gptel)
;;   (kasas-gptel-setup)         ; registers the tools with gptel
;;
;; then turn tool use on in your gptel session (`gptel-use-tools').  Or just run
;; `M-x kasas-gptel-ask' for a one-shot question with the tools enabled.
;;
;; The tools are deliberately read-only: the model can inspect your finances but
;; never mutate them.

;;; Code:

(require 'kasas)

;; gptel is optional; load it if present and declare what we use so this file
;; byte-compiles cleanly without it.
(require 'gptel nil t)
(defvar gptel-tools)
(defvar gptel-use-tools)
(declare-function gptel-make-tool "gptel" (&rest args))
(declare-function gptel-request "gptel" (&optional prompt &rest args))

(require 'cl-lib)

(defvar kasas-gptel--tools nil
  "The list of gptel tool objects this package has registered.")

(defcustom kasas-gptel-result-limit 50
  "Maximum number of rows a kasas gptel tool returns to the model.
Keeps tool results small enough to fit comfortably in context."
  :type 'integer
  :group 'kasas)

(defun kasas-gptel--json (payload)
  "Encode PAYLOAD to a compact JSON string for a tool result."
  (condition-case err
      (kasas--json-encode payload)
    (error (format "kasas error: %s" (error-message-string err)))))

(defun kasas-gptel--guard (thunk)
  "Call THUNK, returning its value or a readable error string for the model."
  (condition-case err
      (funcall thunk)
    (kasas-error (format "kasas error: %s" (error-message-string err)))
    (error (format "error: %s" (error-message-string err)))))

;;;; Tool implementations

(defun kasas-gptel--tool-search (query &optional limit)
  "Tool: run kasas search QUERY (up to LIMIT results) and return JSON."
  (kasas-gptel--guard
   (lambda ()
     (let* ((n (min (or limit kasas-gptel-result-limit) kasas-gptel-result-limit))
            (result (kasas-search query :limit n)))
       (kasas-gptel--json
        (list :query (kasas-get result :query)
              :total (kasas-get result :total)
              :transactions (kasas-get result :transactions)))))))

(defun kasas-gptel--tool-accounts ()
  "Tool: list accounts as JSON."
  (kasas-gptel--guard (lambda () (kasas-gptel--json (kasas-accounts-list)))))

(defun kasas-gptel--tool-account-transactions (account-id &optional limit)
  "Tool: list transactions for ACCOUNT-ID (up to LIMIT) as JSON."
  (kasas-gptel--guard
   (lambda ()
     (let ((n (min (or limit kasas-gptel-result-limit) kasas-gptel-result-limit)))
       (kasas-gptel--json (kasas-account-transactions account-id :limit n))))))

(defun kasas-gptel--tool-labels ()
  "Tool: list the label vocabulary with counts as JSON."
  (kasas-gptel--guard (lambda () (kasas-gptel--json (kasas-labels)))))

(defun kasas-gptel--tool-sync-status ()
  "Tool: report the latest sync status as JSON."
  (kasas-gptel--guard (lambda () (kasas-gptel--json (kasas-sync-status)))))

;;;; Tool registration

(defun kasas-gptel--make-tools ()
  "Construct and return the list of kasas gptel tools.
Signals a `user-error' when gptel is not available."
  (unless (fboundp 'gptel-make-tool)
    (user-error "Kasas-gptel: gptel is not installed"))
  (list
   (gptel-make-tool
    :name "kasas_search_transactions"
    :function #'kasas-gptel--tool-search
    :description
    (concat "Search the user's financial transactions in kasas using its query "
            "language. Supports free text plus fields: amount:>50 amount:<0 "
            "amount:10..50, date:2024 date:2024-03 date:>=2024-01-01, "
            "payee:, description:, memo:, label:key=value (or key:value), "
            "pending:true, boolean AND/OR/NOT and ( ) grouping. Returns matching "
            "transactions with exact decimal amounts.")
    :args (list '(:name "query" :type string
                        :description "kasas search query, e.g. \"coffee amount:<0 date:2024\"")
                '(:name "limit" :type integer :optional t
                        :description "Max results to return"))
    :category "kasas")
   (gptel-make-tool
    :name "kasas_list_accounts"
    :function #'kasas-gptel--tool-accounts
    :description "List the user's financial accounts with balances and currencies."
    :args nil
    :category "kasas")
   (gptel-make-tool
    :name "kasas_account_transactions"
    :function #'kasas-gptel--tool-account-transactions
    :description "List recent transactions for a specific account id."
    :args (list '(:name "account_id" :type string :description "The account id")
                '(:name "limit" :type integer :optional t
                        :description "Max results to return"))
    :category "kasas")
   (gptel-make-tool
    :name "kasas_list_labels"
    :function #'kasas-gptel--tool-labels
    :description
    "List the label vocabulary (key/value pairs and how many transactions carry each)."
    :args nil
    :category "kasas")
   (gptel-make-tool
    :name "kasas_sync_status"
    :function #'kasas-gptel--tool-sync-status
    :description "Report the status of the most recent kasas data sync."
    :args nil
    :category "kasas")))

;;;###autoload
(defun kasas-gptel-setup ()
  "Register kasas tools with gptel, making them available to the model.
Idempotent: re-running replaces any previously registered kasas tools."
  (interactive)
  (unless (boundp 'gptel-tools)
    (user-error "Kasas-gptel: gptel is not installed"))
  ;; Drop any tool objects we registered on a previous run, then add the fresh
  ;; ones, so re-running stays idempotent.
  (setq gptel-tools (cl-remove-if (lambda (tool) (memq tool kasas-gptel--tools))
                                  gptel-tools))
  (setq kasas-gptel--tools (kasas-gptel--make-tools))
  (setq gptel-tools (append gptel-tools kasas-gptel--tools))
  (message "kasas-gptel: registered %d tools" (length kasas-gptel--tools))
  kasas-gptel--tools)

;;;###autoload
(defun kasas-gptel-ask (question)
  "Ask QUESTION about your finances with the kasas gptel tools enabled.
Requires gptel; the answer is inserted by gptel as usual."
  (interactive "skasas — ask about your finances: ")
  (unless (fboundp 'gptel-request)
    (user-error "Kasas-gptel: gptel is not installed"))
  (kasas-gptel-setup)
  (let ((gptel-use-tools t))
    (gptel-request question)
    (message "kasas-gptel: asked — %s" question)))

(provide 'kasas-gptel)

;;; kasas-gptel.el ends here
