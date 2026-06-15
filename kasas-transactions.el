;;; kasas-transactions.el --- Browse and search kasas transactions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Paul Meier
;; SPDX-License-Identifier: MIT

;; Author: Paul Meier <paulmartinmeier@gmail.com>
;; URL: https://github.com/paulmeier/kasas.el

;; This file is part of kasas.el.  See kasas.el for the license.

;;; Commentary:

;; A `tabulated-list-mode' buffer over kasas transactions, backed either by a
;; plain list (optionally scoped to one account) or by the kasas search query
;; language.  Press `s' to enter a query, `l' to drill down by label, RET to
;; inspect a transaction, and `p' to plot the current set.

;;; Code:

(require 'kasas)
(require 'tabulated-list)

(declare-function kasas-plot-transactions "kasas-plot" (transactions title))

(defvar-local kasas-transactions--source nil
  "How the current buffer is populated.
One of: (all), (account ID NAME), (search QUERY), or (label KEY VALUE).")

(defvar kasas-transactions-query-history nil
  "Minibuffer history of kasas search queries.")

(defun kasas-transactions--row (txn)
  "Return a `tabulated-list-entries' row (ID VECTOR) for TXN."
  (let* ((id (kasas-get txn :id))
         (amount (kasas-get txn :amount "0"))
         (pending (eq (kasas-get txn :pending) t))
         (desc (or (kasas-get txn :description)
                   (kasas-get txn :payee) "")))
    (list id
          (vector
           (kasas-format-date (kasas-get txn :date))
           (propertize (kasas-format-amount amount)
                       'face (if (string-prefix-p "-" (format "%s" amount))
                                 'kasas-amount-negative-face
                               'kasas-amount-positive-face))
           (if pending (propertize desc 'face 'kasas-pending-face) desc)
           (or (kasas-get txn :payee) "")
           (or (kasas-labels-string (kasas-get txn :labels)) "")))))

(defface kasas-amount-negative-face
  '((t :inherit error))
  "Face for negative (outflow) transaction amounts."
  :group 'kasas)

(defface kasas-amount-positive-face
  '((t :inherit success))
  "Face for positive (inflow) transaction amounts."
  :group 'kasas)

(defface kasas-pending-face
  '((t :inherit shadow :slant italic))
  "Face for pending transactions."
  :group 'kasas)

(defun kasas-transactions--fetch ()
  "Fetch the transactions for the current buffer's source as a list."
  (pcase kasas-transactions--source
    (`(account ,id . ,_) (append (kasas-account-transactions id) nil))
    (`(search ,query)
     (append (kasas-get (kasas-search query) :transactions) nil))
    (`(label ,key ,value)
     (append (kasas-transactions-list :label-key key :label-value value) nil))
    (_ (append (kasas-transactions-list) nil))))

(defun kasas-transactions--describe-source ()
  "Return a short human-readable description of the current source."
  (pcase kasas-transactions--source
    (`(account ,_ ,name) (format "account: %s" name))
    (`(search ,query) (format "search: %s" query))
    (`(label ,key ,value) (format "label: %s%s" key (if value (concat "=" value) "")))
    (_ "all transactions")))

(defun kasas-transactions--refresh ()
  "Fetch transactions and populate `tabulated-list-entries'."
  (let ((txns (kasas-transactions--fetch)))
    (setq tabulated-list-entries (mapcar #'kasas-transactions--row txns))
    (setq mode-line-process
          (format " [%s · %d]" (kasas-transactions--describe-source) (length txns)))))

(defun kasas-transactions-refresh ()
  "Re-fetch and redraw the transaction list."
  (interactive)
  (kasas-transactions--refresh)
  (tabulated-list-print t)
  (message "kasas: %s" (kasas-transactions--describe-source)))

(defun kasas-transactions-search (query)
  "Replace the buffer contents with the results of search QUERY."
  (interactive (list (read-string "kasas search: " nil 'kasas-transactions-query-history)))
  (setq kasas-transactions--source (list 'search query))
  (kasas-transactions-refresh))

(defun kasas-transactions-by-label (key value)
  "Drill into transactions carrying label KEY (and optional VALUE)."
  (interactive
   (let* ((labels (append (kasas-labels) nil))
          (keys (delete-dups (mapcar (lambda (l) (kasas-get l :key)) labels)))
          (k (completing-read "Label key: " keys nil nil))
          (vals (delq nil (mapcar (lambda (l)
                                    (when (equal (kasas-get l :key) k)
                                      (kasas-get l :value)))
                                  labels)))
          (v (completing-read (format "Value for %s (blank = any): " k) vals nil nil)))
     (list k (if (string-empty-p v) nil v))))
  (setq kasas-transactions--source (list 'label key value))
  (kasas-transactions-refresh))

(defun kasas-transactions-show ()
  "Show full details of the transaction at point in a help buffer."
  (interactive)
  (let* ((id (tabulated-list-get-id))
         (_ (unless id (user-error "No transaction on this line")))
         (txn (kasas-transaction id)))
    (help-setup-xref (list #'kasas-transactions-show) (called-interactively-p 'interactive))
    (with-help-window "*kasas transaction*"
      (with-current-buffer standard-output
        (insert (kasas-transactions--detail-string txn))))))

(defun kasas-transactions--detail-string (txn)
  "Render the details of TXN as a string for display."
  (let ((rows
         `(("ID"          . ,(kasas-get txn :id))
           ("Account"     . ,(kasas-get txn :account_id))
           ("Date"        . ,(kasas-format-date (kasas-get txn :date)))
           ("Amount"      . ,(kasas-format-amount (kasas-get txn :amount "0")))
           ("Pending"     . ,(if (eq (kasas-get txn :pending) t) "yes" "no"))
           ("Description" . ,(kasas-get txn :description ""))
           ("Payee"       . ,(kasas-get txn :payee ""))
           ("Memo"        . ,(kasas-get txn :memo ""))
           ("Source"      . ,(kasas-get txn :source ""))
           ("Synced"      . ,(kasas-format-time (kasas-get txn :synced_at)))
           ("Labels"      . ,(or (kasas-labels-string (kasas-get txn :labels)) "")))))
    (mapconcat
     (lambda (row)
       (format "%-13s %s" (concat (car row) ":") (cdr row)))
     rows "\n")))

(defun kasas-transactions-plot ()
  "Plot the transactions currently shown in this buffer."
  (interactive)
  (require 'kasas-plot)
  (kasas-plot-transactions (kasas-transactions--fetch)
                           (kasas-transactions--describe-source)))

(defvar kasas-transactions-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'kasas-transactions-show)
    (define-key map (kbd "s")   #'kasas-transactions-search)
    (define-key map (kbd "l")   #'kasas-transactions-by-label)
    (define-key map (kbd "p")   #'kasas-transactions-plot)
    (define-key map (kbd "g")   #'kasas-transactions-refresh)
    map)
  "Keymap for `kasas-transactions-mode'.")

(define-derived-mode kasas-transactions-mode tabulated-list-mode "kasas-Txns"
  "Major mode listing kasas transactions.
\\{kasas-transactions-mode-map}"
  (setq tabulated-list-format
        [("Date" 12 t)
         ("Amount" 14 t)
         ("Description" 36 t)
         ("Payee" 20 t)
         ("Labels" 24 nil)])
  (setq tabulated-list-sort-key '("Date" . t))
  (tabulated-list-init-header)
  (add-hook 'tabulated-list-revert-hook #'kasas-transactions--refresh nil t))

(defun kasas-transactions--display (source)
  "Open the transactions buffer populated according to SOURCE."
  (let ((buffer (get-buffer-create "*kasas transactions*")))
    (with-current-buffer buffer
      (kasas-transactions-mode)
      (setq kasas-transactions--source source)
      (kasas-transactions--refresh)
      (tabulated-list-print t))
    (pop-to-buffer buffer)))

;;;###autoload
(defun kasas-transactions ()
  "Browse all kasas transactions."
  (interactive)
  (kasas-transactions--display '(all)))

;;;###autoload
(defun kasas-transactions-for-account (account)
  "Browse the transactions of ACCOUNT, a decoded account plist."
  (kasas-transactions--display
   (list 'account (kasas-get account :id) (kasas-get account :name))))

(provide 'kasas-transactions)

;;; kasas-transactions.el ends here
