;;; checkdoc-batch.el --- Batch checkdoc runner for CI -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Run checkdoc over every file passed on the command line, printing any style
;; complaints and exiting non-zero when at least one file has them.  Invoked by
;; `make checkdoc'.

;;; Code:

(require 'checkdoc)

(let ((checkdoc-force-docstrings-flag t))
  ;; `checkdoc-file' reports via `display-warning', which collects into the
  ;; *Warnings* buffer; a non-empty buffer afterwards means something failed.
  (dolist (file command-line-args-left)
    (checkdoc-file file))
  (let ((warnings (get-buffer "*Warnings*")))
    (if (and warnings (> (buffer-size warnings) 0))
        (progn
          (princ (with-current-buffer warnings (buffer-string)))
          (kill-emacs 1))
      (princ "checkdoc: no issues\n")
      (kill-emacs 0))))

;;; checkdoc-batch.el ends here
