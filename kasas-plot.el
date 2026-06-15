;;; kasas-plot.el --- Realtime graphical displays of kasas data via org-plot -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Paul Meier
;; SPDX-License-Identifier: MIT

;; Author: Paul Meier <paulmartinmeier@gmail.com>
;; URL: https://github.com/paulmeier/kasas.el

;; This file is part of kasas.el.  See kasas.el for the license.

;;; Commentary:

;; Turn kasas data into charts using Org's gnuplot integration (`org-plot',
;; which ships with Org).  Each command aggregates transactions into an Org
;; table, annotates it with a `#+PLOT:' directive, and renders it with
;; `org-plot/gnuplot' -- so the plot is a real, re-runnable Org document you can
;; tweak by hand.
;;
;; "Realtime" comes from `kasas-plot-auto-refresh-mode': a buffer-local timer
;; (and, when available, the `kasas-events' stream) that re-fetches the
;; underlying data and re-renders the chart on an interval, so a dashboard left
;; open tracks your ledger as it changes.
;;
;; Requires a working `gnuplot' binary on PATH; `org-plot/gnuplot' shells out to
;; it.  Install gnuplot from your package manager.

;;; Code:

(require 'kasas)
(require 'org)
(require 'org-plot)
(require 'cl-lib)

(declare-function kasas-events-follow "kasas-events")
(defvar kasas-events-hook)

(defcustom kasas-plot-refresh-interval 30
  "Seconds between automatic refreshes in `kasas-plot-auto-refresh-mode'."
  :type 'number
  :group 'kasas)

(defcustom kasas-plot-buffer-name "*kasas plot*"
  "Name of the buffer Org plots are rendered from."
  :type 'string
  :group 'kasas)

;; Each plot buffer remembers how to rebuild itself, so a refresh can re-run the
;; same aggregation against fresh data.
(defvar-local kasas-plot--builder nil
  "Zero-argument closure that rebuilds the Org table + `#+PLOT:' directive.")

(defvar-local kasas-plot--timer nil
  "Repeating refresh timer for this plot buffer.")

;;;; Aggregation helpers

(defun kasas-plot--by-day (transactions)
  "Aggregate TRANSACTIONS into an alist of (DAY . NET-AMOUNT), sorted ascending."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (txn transactions)
      (let ((day (kasas-format-date (kasas-get txn :date)))
            (amt (kasas-parse-amount (kasas-get txn :amount))))
        (unless (string-empty-p day)
          (puthash day (+ amt (gethash day table 0.0)) table))))
    (sort (let (rows) (maphash (lambda (k v) (push (cons k v) rows)) table) rows)
          (lambda (a b) (string< (car a) (car b))))))

(defun kasas-plot--cumulative (day-alist)
  "Turn DAY-ALIST of (DAY . AMOUNT) into (DAY . RUNNING-SUM)."
  (let ((sum 0.0))
    (mapcar (lambda (cell)
              (setq sum (+ sum (cdr cell)))
              (cons (car cell) sum))
            day-alist)))

(defun kasas-plot--by-label (transactions key)
  "Aggregate outflow magnitude in TRANSACTIONS by the value of label KEY.
Transactions lacking the label are grouped under \"(none)\".  Returns an alist
of (VALUE . TOTAL) sorted by descending total."
  (let ((kw (intern (concat ":" key)))
        (table (make-hash-table :test 'equal)))
    (dolist (txn transactions)
      (let* ((labels (kasas-get txn :labels))
             (value (or (and labels (kasas-get labels kw)) "(none)"))
             (amt (abs (kasas-parse-amount (kasas-get txn :amount)))))
        (puthash value (+ amt (gethash value table 0.0)) table)))
    (sort (let (rows) (maphash (lambda (k v) (push (cons k v) rows)) table) rows)
          (lambda (a b) (> (cdr a) (cdr b))))))

;;;; Org table + directive rendering

(defun kasas-plot--render (title plot-directive header rows)
  "Render an Org plot into the plot buffer and display it.

TITLE names the chart.  PLOT-DIRECTIVE is the `#+PLOT:' option string.  HEADER
is a list of column-name strings; ROWS is a list of row lists whose cells are
coerced to strings.  Records a builder so the buffer can refresh itself."
  (let ((buffer (get-buffer-create kasas-plot-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'org-mode) (org-mode))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "#+TITLE: kasas — %s\n\n" title))
        (insert (format "* %s\n" title))
        (insert (format "Updated %s\n\n" (format-time-string "%Y-%m-%d %H:%M:%S")))
        (insert (format "#+PLOT: %s\n" plot-directive))
        (insert "| " (string-join header " | ") " |\n")
        (insert "|-\n")
        (if rows
            (dolist (row rows)
              (insert "| " (mapconcat (lambda (c) (format "%s" c)) row " | ") " |\n"))
          (insert "| (no data) | 0 |\n"))
        (forward-line -1)
        (org-table-align)
        ;; Point must sit on the table for `org-plot/gnuplot' to find it.
        (re-search-backward "^|" nil t)
        (condition-case err
            (org-plot/gnuplot)
          (error (message "kasas-plot: gnuplot failed (%s); table is in %s"
                          (error-message-string err) (buffer-name))))))
    (pop-to-buffer buffer)
    buffer))

(defun kasas-plot--set-builder (builder)
  "Store BUILDER as the refresh closure in the plot buffer."
  (with-current-buffer (get-buffer kasas-plot-buffer-name)
    (setq kasas-plot--builder builder)))

;;;; Public plotting commands

;;;###autoload
(defun kasas-plot-transactions (transactions title)
  "Plot TRANSACTIONS as a net-amount-per-day time series titled TITLE."
  (let ((builder
         (lambda ()
           (let ((rows (mapcar (lambda (c) (list (car c) (format "%.2f" (cdr c))))
                               (kasas-plot--by-day transactions))))
             (kasas-plot--render
              (format "%s — net per day" title)
              "ind:1 deps:(2) type:2d with:boxes set:\"xdata time\" set:\"timefmt '%Y-%m-%d'\" set:\"format x '%m-%d'\""
              '("Date" "Net") rows)))))
    (funcall builder)
    (kasas-plot--set-builder builder)))

;;;###autoload
(defun kasas-plot-account-balance (account-id)
  "Plot the cumulative net flow over time for ACCOUNT-ID.

This is the running sum of transaction amounts ordered by date — a faithful
shape of how the account moved, without needing per-day balance snapshots."
  (interactive (list (read-string "Account id: ")))
  (let ((builder
         (lambda ()
           (let* ((txns (append (kasas-account-transactions account-id :limit 1000) nil))
                  (cum (kasas-plot--cumulative (kasas-plot--by-day txns)))
                  (rows (mapcar (lambda (c) (list (car c) (format "%.2f" (cdr c)))) cum)))
             (kasas-plot--render
              "Account — cumulative net flow"
              "ind:1 deps:(2) type:2d with:lines set:\"xdata time\" set:\"timefmt '%Y-%m-%d'\" set:\"format x '%m-%d'\""
              '("Date" "Cumulative") rows)))))
    (funcall builder)
    (kasas-plot--set-builder builder)))

;;;###autoload
(defun kasas-plot-spending-by-label (key &optional query)
  "Plot a bar chart of spending grouped by the values of label KEY.

With QUERY (a kasas search string, prompted for with a prefix argument) the
chart is scoped to matching transactions; otherwise all transactions are used."
  (interactive
   (let* ((labels (append (kasas-labels) nil))
          (keys (delete-dups (mapcar (lambda (l) (kasas-get l :key)) labels))))
     (list (completing-read "Group spending by label key: " keys nil nil)
           (when current-prefix-arg (read-string "Limit to search (blank = all): ")))))
  (let ((builder
         (lambda ()
           (let* ((txns (if (and query (not (string-empty-p query)))
                            (append (kasas-get (kasas-search query :limit 1000) :transactions) nil)
                          (append (kasas-transactions-list :limit 1000) nil)))
                  (agg (kasas-plot--by-label txns key))
                  (rows (mapcar (lambda (c) (list (car c) (format "%.2f" (cdr c)))) agg)))
             (kasas-plot--render
              (format "Spending by %s" key)
              "ind:1 deps:(2) type:2d with:histograms set:\"style fill solid 0.6\""
              (list key "Spending") rows)))))
    (funcall builder)
    (kasas-plot--set-builder builder)))

;;;; Realtime auto-refresh

(defun kasas-plot--refresh ()
  "Re-run the current plot buffer's builder against fresh data."
  (when-let* ((buffer (get-buffer kasas-plot-buffer-name)))
    (with-current-buffer buffer
      (when (functionp kasas-plot--builder)
        (funcall kasas-plot--builder)))))

(defun kasas-plot--on-event (_event)
  "Refresh the plot in response to a kasas event."
  (kasas-plot--refresh))

;;;###autoload
(define-minor-mode kasas-plot-auto-refresh-mode
  "Periodically re-render the current kasas plot from fresh data.

While enabled, a buffer-local timer re-fetches and re-plots every
`kasas-plot-refresh-interval' seconds.  If `kasas-events' is following the
stream, the plot also refreshes immediately on each new event."
  :lighter " kasas-live"
  :group 'kasas
  (if kasas-plot-auto-refresh-mode
      (progn
        (setq kasas-plot--timer
              (run-at-time kasas-plot-refresh-interval kasas-plot-refresh-interval
                           #'kasas-plot--refresh))
        (add-hook 'kasas-events-hook #'kasas-plot--on-event)
        (add-hook 'kill-buffer-hook #'kasas-plot-auto-refresh-mode-disable nil t))
    (when (timerp kasas-plot--timer)
      (cancel-timer kasas-plot--timer))
    (setq kasas-plot--timer nil)
    (remove-hook 'kasas-events-hook #'kasas-plot--on-event)))

(defun kasas-plot-auto-refresh-mode-disable ()
  "Disable `kasas-plot-auto-refresh-mode' (used as a `kill-buffer-hook')."
  (when kasas-plot-auto-refresh-mode
    (kasas-plot-auto-refresh-mode -1)))

(provide 'kasas-plot)

;;; kasas-plot.el ends here
