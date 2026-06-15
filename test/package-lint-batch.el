;;; package-lint-batch.el --- Install and run package-lint in batch -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Bootstrap `package-lint' from MELPA (if it is not already installed) and lint
;; the files passed on the command line.  Invoked by `make lint'.

;;; Code:

(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)
(unless (package-installed-p 'package-lint)
  (package-refresh-contents)
  (package-install 'package-lint))
(require 'package-lint)
;; Treat every file as part of the one multi-file package whose main file
;; carries the headers and Package-Requires.
(setq package-lint-main-file "kasas.el")
(package-lint-batch-and-exit)

;;; package-lint-batch.el ends here
