;;; kasas-accounts.el --- Browse kasas accounts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Paul Meier
;; SPDX-License-Identifier: MIT

;; Author: Paul Meier <paulmartinmeier@gmail.com>
;; URL: https://github.com/paulmeier/kasas.el

;; This file is part of kasas.el.  See kasas.el for the license.

;;; Commentary:

;; A `tabulated-list-mode' buffer listing the accounts kasas tracks: name,
;; balance, currency, source, and last sync.  RET on a row opens that account's
;; transactions; `g' refreshes; `p' plots its balance history.

;;; Code:

(require 'kasas)
(require 'tabulated-list)

(declare-function kasas-transactions-for-account "kasas-transactions" (account))
(declare-function kasas-plot-account-balance "kasas-plot" (account-id))

(defvar-local kasas-accounts--org-id nil
  "Organization filter for the current accounts buffer, or nil for all.")

(defun kasas-accounts--row (account)
  "Return a `tabulated-list-entries' row (ID VECTOR) for ACCOUNT."
  (let ((id (kasas-get account :id)))
    (list id
          (vector
           (or (kasas-get account :name) "")
           ;; The currency has its own column, so keep the balance symbol-free.
           (kasas-format-amount (kasas-get account :balance "0") "")
           (or (kasas-get account :currency) "")
           (or (kasas-get account :source) "")
           (kasas-format-time (kasas-get account :synced_at))))))

(defun kasas-accounts--refresh ()
  "Fetch accounts and populate `tabulated-list-entries'."
  (let ((accounts (kasas-accounts-list :org-id kasas-accounts--org-id)))
    (setq tabulated-list-entries
          (mapcar #'kasas-accounts--row (append accounts nil)))))

(defun kasas-accounts-account-at-point ()
  "Return the account plist for the row at point, or signal an error."
  (let ((id (tabulated-list-get-id)))
    (unless id (user-error "No account on this line"))
    (kasas-account id)))

(defun kasas-accounts-visit ()
  "Open the transactions of the account at point."
  (interactive)
  (require 'kasas-transactions)
  (kasas-transactions-for-account (kasas-accounts-account-at-point)))

(defun kasas-accounts-plot ()
  "Plot the balance history of the account at point."
  (interactive)
  (require 'kasas-plot)
  (kasas-plot-account-balance (tabulated-list-get-id)))

(defun kasas-accounts-refresh ()
  "Re-fetch and redraw the accounts list."
  (interactive)
  (kasas-accounts--refresh)
  (tabulated-list-print t)
  (message "kasas: accounts refreshed"))

(defvar kasas-accounts-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'kasas-accounts-visit)
    (define-key map (kbd "p")   #'kasas-accounts-plot)
    (define-key map (kbd "g")   #'kasas-accounts-refresh)
    map)
  "Keymap for `kasas-accounts-mode'.")

(define-derived-mode kasas-accounts-mode tabulated-list-mode "kasas-Accounts"
  "Major mode listing kasas accounts.
\\{kasas-accounts-mode-map}"
  (setq tabulated-list-format
        [("Name" 30 t)
         ("Balance" 16 t)
         ("Cur" 5 t)
         ("Source" 12 t)
         ("Synced" 18 t)])
  (setq tabulated-list-sort-key '("Name" . nil))
  (tabulated-list-init-header)
  (add-hook 'tabulated-list-revert-hook #'kasas-accounts--refresh nil t))

;;;###autoload
(defun kasas-accounts (&optional org-id)
  "Show the list of kasas accounts in a dedicated buffer.
With a prefix argument, prompt for an ORG-ID to filter by."
  (interactive
   (list (when current-prefix-arg
           (read-string "Organization id (blank for all): " nil nil nil))))
  (let ((buffer (get-buffer-create "*kasas accounts*")))
    (with-current-buffer buffer
      (kasas-accounts-mode)
      (setq kasas-accounts--org-id (if (and org-id (string-empty-p org-id)) nil org-id))
      (kasas-accounts--refresh)
      (tabulated-list-print t))
    (pop-to-buffer buffer)))

(provide 'kasas-accounts)

;;; kasas-accounts.el ends here
