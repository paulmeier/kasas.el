;;; kasas-events.el --- Follow the kasas event stream -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Paul Meier
;; SPDX-License-Identifier: MIT

;; Author: Paul Meier <paulmartinmeier@gmail.com>
;; URL: https://github.com/paulmeier/kasas.el

;; This file is part of kasas.el.  See kasas.el for the license.

;;; Commentary:

;; A live view of the kasas event stream.  Following the same approach the
;; built-in dashboard uses, this polls `GET /api/v1/events?after=<cursor>'
;; forward on a timer and appends new events to a buffer, deduping on the
;; monotonic `sequence' cursor.  It is the substrate other realtime features
;; (notably `kasas-plot' auto-refresh) hook into.

;;; Code:

(require 'kasas)

(defcustom kasas-events-poll-interval 5
  "Seconds between polls of the kasas event stream."
  :type 'number
  :group 'kasas)

(defcustom kasas-events-buffer-name "*kasas events*"
  "Name of the buffer used to follow the event stream."
  :type 'string
  :group 'kasas)

(defvar-local kasas-events--cursor nil
  "Last `sequence' seen in this events buffer, the poll cursor.")

(defvar-local kasas-events--timer nil
  "Repeating timer driving the poll loop in this events buffer.")

(defvar kasas-events-hook nil
  "Abnormal hook run with each new event plist as it arrives.
Other features (for example realtime plots) can subscribe here to react to
ledger changes without running their own poll loop.")

(defun kasas-events--type-face (type)
  "Return a face appropriate for event TYPE."
  (cond
   ((string-suffix-p ".created" type) 'success)
   ((string-suffix-p ".deleted" type) 'error)
   ((string-suffix-p ".removed" type) 'error)
   (t 'default)))

(defun kasas-events--insert (event)
  "Append EVENT, a decoded event plist, to the current buffer."
  (let ((inhibit-read-only t)
        (type (or (kasas-get event :type) "?")))
    (save-excursion
      (goto-char (point-max))
      (insert
       (format "%-6s  %-19s  %s  %s\n"
               (or (kasas-get event :sequence) "")
               (kasas-format-time (kasas-get event :occurred_at))
               (propertize (format "%-20s" type) 'face (kasas-events--type-face type))
               (or (kasas-get event :entity_id) ""))))))

(defun kasas-events--poll (buffer)
  "Poll for events newer than BUFFER's cursor and append them."
  (when (buffer-live-p buffer)
    (kasas-request-async
     "GET" "events"
     (lambda (payload)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (let ((events (append (kasas-get payload :events) nil))
                 (at-end (eobp)))
             (dolist (event events)
               (kasas-events--insert event)
               (run-hook-with-args 'kasas-events-hook event))
             (when-let* ((next (kasas-get payload :next)))
               (setq kasas-events--cursor next))
             (when (and events at-end)
               (goto-char (point-max)))))))
     :params (let ((cursor (with-current-buffer buffer kasas-events--cursor)))
               (if cursor `(("after" . ,cursor) ("limit" . 200))
                 '(("newest" . "true") ("limit" . 50))))
     :error-callback
     (lambda (err) (message "kasas events: %s" (error-message-string err))))))

(defun kasas-events--start-timer ()
  "Begin polling in the current events buffer."
  (kasas-events--stop-timer)
  (let ((buffer (current-buffer)))
    (setq kasas-events--timer
          (run-at-time 0 kasas-events-poll-interval
                       #'kasas-events--poll buffer))))

(defun kasas-events--stop-timer ()
  "Stop polling in the current events buffer."
  (when (timerp kasas-events--timer)
    (cancel-timer kasas-events--timer))
  (setq kasas-events--timer nil))

(defun kasas-events-toggle-follow ()
  "Toggle live following (polling) of the event stream."
  (interactive)
  (if kasas-events--timer
      (progn (kasas-events--stop-timer) (message "kasas events: paused"))
    (kasas-events--start-timer)
    (message "kasas events: following")))

(defun kasas-events-refresh ()
  "Poll once for new events now."
  (interactive)
  (kasas-events--poll (current-buffer)))

(defvar kasas-events-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'kasas-events-refresh)
    (define-key map (kbd "f") #'kasas-events-toggle-follow)
    map)
  "Keymap for `kasas-events-mode'.")

(define-derived-mode kasas-events-mode special-mode "kasas-Events"
  "Major mode following the kasas event stream.
\\{kasas-events-mode-map}"
  (setq-local truncate-lines t)
  (add-hook 'kill-buffer-hook #'kasas-events--stop-timer nil t))

;;;###autoload
(defun kasas-events-follow ()
  "Open the kasas event stream and follow it live."
  (interactive)
  (let ((buffer (get-buffer-create kasas-events-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'kasas-events-mode)
        (kasas-events-mode))
      (let ((inhibit-read-only t))
        (when (= (point-min) (point-max))
          (insert (propertize
                   (format "%-6s  %-19s  %-20s  %s\n" "SEQ" "WHEN" "TYPE" "ENTITY")
                   'face 'bold))))
      (kasas-events--start-timer))
    (pop-to-buffer buffer)))

(provide 'kasas-events)

;;; kasas-events.el ends here
