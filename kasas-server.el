;;; kasas-server.el --- Install, configure, and run the kasas server -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Paul Meier
;; SPDX-License-Identifier: MIT

;; Author: Paul Meier <paulmartinmeier@gmail.com>
;; URL: https://github.com/paulmeier/kasas.el

;; This file is part of kasas.el.  See kasas.el for the license.

;;; Commentary:

;; Convenience commands for managing the kasas server itself from Emacs, for
;; people who run kasas on the same machine as their editor:
;;
;;   * `kasas-install'          -- download the latest release for this platform
;;                                 from GitHub, verify it against the published
;;                                 SHA-256 checksum, and install the binary;
;;   * `kasas-server-configure' -- set the configuration the server is started
;;                                 with (passed as KASAS_* environment vars);
;;   * `kasas-server-start' /
;;     `kasas-server-stop' /
;;     `kasas-server-restart'   -- run the server as an Emacs subprocess with
;;                                 that configuration applied.
;;
;; The download mirrors the server's own `kasas self-update': it picks the
;; release asset matching this OS/architecture, refuses to install one it cannot
;; verify against its checksum, and extracts the `kasas' binary.  Extraction
;; shells out to `tar', which the supported targets (GNU/Linux and macOS) always
;; have.

;;; Code:

(require 'kasas)
(require 'url)

(defcustom kasas-server-repository "paulmeier/kasas"
  "GitHub \"owner/name\" repository to download kasas releases from."
  :type 'string
  :group 'kasas)

(defcustom kasas-install-directory (locate-user-emacs-file "kasas/")
  "Directory the kasas server binary is installed into by `kasas-install'."
  :type 'directory
  :group 'kasas)

(defcustom kasas-server-executable nil
  "Path to the kasas server binary.
When nil, `kasas-server-start' looks for a binary under
`kasas-install-directory' and then on the executable search path."
  :type '(choice (const :tag "Auto-detect" nil)
                 (file :tag "Path"))
  :group 'kasas)

(defcustom kasas-server-config-file nil
  "TOML config file passed to the server with -config when set.
When nil, the server is configured purely through `kasas-server-settings' and
its own defaults."
  :type '(choice (const :tag "None" nil)
                 (file :tag "Config file"))
  :group 'kasas)

(defcustom kasas-server-settings nil
  "Settings applied when the kasas server is started.
An alist of (KEY . VALUE) string pairs, where KEY is a dotted setting name
such as \"server.addr\" or \"database.path\" (see the kasas configuration
documentation) and VALUE is its string value.  Each pair is passed to the
server as a KASAS_* environment variable: KEY is upcased and its dots become
underscores, so \"server.addr\" becomes KASAS_SERVER_ADDR.  Use
`kasas-server-configure' to edit this interactively."
  :type '(alist :key-type (string :tag "Key")
                :value-type (string :tag "Value"))
  :group 'kasas)

(defcustom kasas-server-buffer-name "*kasas server*"
  "Name of the buffer that captures the kasas server's output."
  :type 'string
  :group 'kasas)

(defconst kasas-server--setting-keys
  '("server.addr"
    "log.level" "log.format"
    "database.driver" "database.path" "database.dsn"
    "dashboard.enabled" "dashboard.token"
    "sync.enabled" "sync.interval" "sync.run_on_start" "sync.lookback_days"
    "simplefin.setup_token" "simplefin.access_url"
    "mcp.enabled"
    "events.enabled" "events.retention_days" "events.history_retention_days"
    "update.check" "update.allow_apply" "update.repository")
  "Common kasas configuration keys offered for completion.
A convenience subset for `kasas-server-configure'; any dotted key the server
understands may be entered.  See the kasas configuration documentation.")

;;;; Platform and release discovery

(defun kasas-server--platform (&optional type config)
  "Return (GOOS . GOARCH) for the running platform, in Go's naming.
TYPE defaults to `system-type' and CONFIG to `system-configuration'.  Signal
an error on a platform kasas publishes no binary for."
  (let* ((type (or type system-type))
         (config (or config system-configuration))
         (goos (pcase type
                 ('gnu/linux "linux")
                 ('darwin "darwin")
                 (_ (error "No released kasas binary for system type %s" type))))
         (arch (downcase (car (split-string config "-"))))
         (goarch (cond
                  ((member arch '("x86_64" "amd64")) "amd64")
                  ((member arch '("aarch64" "arm64")) "arm64")
                  (t (error "No released kasas binary for architecture %s" arch)))))
    (cons goos goarch)))

(defun kasas-server--github-get (url)
  "GET URL from the GitHub REST API and return the decoded JSON payload.
Signal `kasas-http-error' (or `kasas-auth-error') on a non-2xx response."
  (let* ((url-request-method "GET")
         (url-request-extra-headers
          '(("Accept" . "application/vnd.github+json")
            ("X-GitHub-Api-Version" . "2022-11-28")))
         (buffer (url-retrieve-synchronously url t t kasas-request-timeout)))
    (unless buffer
      (signal 'kasas-error (list (format "no response from %s" url))))
    (unwind-protect
        (pcase-let ((`(,status . ,payload) (kasas--parse-response buffer)))
          (if (<= 200 status 299)
              payload
            (kasas--signal-http status payload)))
      (kill-buffer buffer))))

(defun kasas-server--latest-release ()
  "Return the latest published kasas release as a decoded plist."
  (kasas-server--github-get
   (format "https://api.github.com/repos/%s/releases/latest"
           kasas-server-repository)))

(defun kasas-server--asset-urls (release goos goarch)
  "Return (TARBALL-URL . CHECKSUM-URL) from RELEASE for GOOS and GOARCH.
CHECKSUM-URL is nil when the release has no matching .sha256 asset.  Signal an
error when no tarball asset matches the platform."
  (let* ((suffix (format "_%s_%s.tar.gz" goos goarch))
         (sum-suffix (concat suffix ".sha256"))
         (tar-url nil)
         (sum-url nil))
    (dolist (a (append (kasas-get release :assets) nil))
      (let ((name (kasas-get a :name))
            (url (kasas-get a :browser_download_url)))
        (when name
          (cond
           ((string-suffix-p sum-suffix name) (setq sum-url url))
           ((string-suffix-p suffix name) (setq tar-url url))))))
    (unless tar-url
      (error "No kasas release asset for %s/%s in %s"
             goos goarch (kasas-get release :tag_name "the latest release")))
    (cons tar-url sum-url)))

;;;; Download, verify, extract

(defun kasas-server--sha256-file (path)
  "Return the hex SHA-256 digest of the file at PATH."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (secure-hash 'sha256 (current-buffer))))

(defun kasas-server--fetch-checksum (url)
  "Download the sha256sum file at URL and return its leading hex digest."
  (let ((buffer (url-retrieve-synchronously url t t kasas-request-timeout)))
    (unless buffer
      (signal 'kasas-error (list (format "no response from %s" url))))
    (unwind-protect
        (pcase-let ((`(,status . ,payload) (kasas--parse-response buffer)))
          (unless (<= 200 status 299)
            (kasas--signal-http status payload))
          (or (car (split-string (if (stringp payload) payload (format "%s" payload))))
              (error "Empty kasas checksum file at %s" url)))
      (kill-buffer buffer))))

(defun kasas-server--extract-binary (tarball dest)
  "Extract the `kasas' binary from TARBALL (a .tar.gz) to DEST.
Shells out to `tar'.  Signal an error when the archive contains no `kasas'
executable."
  (let ((tmpdir (make-temp-file "kasas-extract-" t)))
    (unwind-protect
        (progn
          (let ((status (call-process "tar" nil nil nil
                                      "-xzf" tarball "-C" tmpdir)))
            (unless (eq status 0)
              (error "Extracting kasas: tar exited with status %s" status)))
          (let ((binary (car (directory-files-recursively tmpdir "\\`kasas\\'"))))
            (unless binary
              (error "Release tarball did not contain a kasas binary"))
            (copy-file binary dest t)))
      (delete-directory tmpdir t))))

;;;###autoload
(defun kasas-install (&optional force)
  "Download and install the latest kasas server release for this platform.
Query GitHub for the newest release of `kasas-server-repository', download the
tarball matching this OS/architecture, verify it against the published SHA-256
checksum, and extract the `kasas' binary into `kasas-install-directory'.  With
a prefix argument, or non-nil FORCE, overwrite an existing binary without
asking.

This downloads tens of megabytes synchronously and blocks Emacs while it runs;
on success it reports the installed version and path.  Requires the `tar'
program on `PATH'."
  (interactive "P")
  (unless (executable-find "tar")
    (user-error "The `tar' program is required but was not found on PATH"))
  (pcase-let* ((`(,goos . ,goarch) (kasas-server--platform))
               (dest (expand-file-name "kasas" kasas-install-directory)))
    (when (and (file-exists-p dest) (not force)
               (not (yes-or-no-p
                     (format "Overwrite existing kasas binary at %s? " dest))))
      (user-error "Installation aborted"))
    (message "kasas: looking up the latest release of %s..." kasas-server-repository)
    (let* ((release (kasas-server--latest-release))
           (version (kasas-get release :tag_name "unknown"))
           (urls (kasas-server--asset-urls release goos goarch))
           (tar-url (car urls))
           (sum-url (cdr urls)))
      (unless sum-url
        (error "No checksum (.sha256) asset for %s/%s; refusing to install unverified"
               goos goarch))
      (let ((tmp (make-temp-file "kasas-" nil ".tar.gz")))
        (unwind-protect
            (progn
              (message "kasas: downloading %s (%s/%s)..." version goos goarch)
              (url-copy-file tar-url tmp t)
              (message "kasas: verifying checksum...")
              (let ((got (kasas-server--sha256-file tmp))
                    (want (kasas-server--fetch-checksum sum-url)))
                (unless (equal got want)
                  (error "Checksum mismatch (got %s, want %s)" got want)))
              (message "kasas: extracting...")
              (make-directory kasas-install-directory t)
              (kasas-server--extract-binary tmp dest)
              (set-file-modes dest #o755)
              (message "kasas: installed %s to %s (M-x kasas-server-start to run it)"
                       version dest))
          (when (file-exists-p tmp) (delete-file tmp))))
      dest)))

;;;; Configuration

;;;###autoload
(defun kasas-server-configure (key value &optional save)
  "Set the kasas server setting KEY to VALUE in `kasas-server-settings'.
KEY is a dotted setting name such as \"server.addr\"; completion offers the
common keys but any key the server understands is accepted.  VALUE is a string;
an empty VALUE removes the override.  With a prefix argument, or non-nil SAVE,
persist `kasas-server-settings' with `customize-save-variable' so the change
outlives this session.  Changes take effect the next time the server starts."
  (interactive
   (let* ((key (completing-read "kasas setting: " kasas-server--setting-keys))
          (current (cdr (assoc key kasas-server-settings)))
          (value (read-string (format "Value for %s: " key) current)))
     (list key value current-prefix-arg)))
  (setq kasas-server-settings
        (assoc-delete-all key (copy-alist kasas-server-settings)))
  (unless (string-empty-p value)
    (setq kasas-server-settings
          (append kasas-server-settings (list (cons key value)))))
  (when save
    (customize-save-variable 'kasas-server-settings kasas-server-settings))
  (message "kasas: %s %s%s"
           key
           (if (string-empty-p value) "cleared" (format "= %s" value))
           (if save " (saved)" ""))
  kasas-server-settings)

;;;; Running the server

(defvar kasas-server--process nil
  "The kasas server process started by `kasas-server-start', or nil.")

(defun kasas-server--binary ()
  "Return the path to the kasas server binary, or nil when none is found.
`kasas-server-executable' wins; otherwise look in `kasas-install-directory'
and then on the executable search path."
  (or (and kasas-server-executable
           (file-exists-p kasas-server-executable)
           kasas-server-executable)
      (let ((local (expand-file-name "kasas" kasas-install-directory)))
        (and (file-exists-p local) local))
      (executable-find "kasas")))

(defun kasas-server--setting-env-name (key)
  "Return the KASAS_* environment variable name for setting KEY.
KEY is a dotted name like \"server.addr\", yielding \"KASAS_SERVER_ADDR\"."
  (concat "KASAS_" (upcase (replace-regexp-in-string "\\." "_" key))))

(defun kasas-server--env ()
  "Return `kasas-server-settings' as a list of \"NAME=VALUE\" env entries."
  (mapcar (lambda (kv)
            (format "%s=%s"
                    (kasas-server--setting-env-name (car kv))
                    (cdr kv)))
          kasas-server-settings))

(defun kasas-server--sentinel (process event)
  "Report kasas server PROCESS status transitions described by EVENT."
  (unless (process-live-p process)
    (when (eq process kasas-server--process)
      (setq kasas-server--process nil)))
  (message "kasas server: %s" (string-trim event)))

;;;###autoload
(defun kasas-server-start ()
  "Start the kasas server as a subprocess, applying the configured settings.
The binary is resolved by `kasas-server--binary' (install it first with
`kasas-install').  `kasas-server-settings' are passed as KASAS_* environment
variables and `kasas-server-config-file', when set, as -config; output is
collected in `kasas-server-buffer-name'."
  (interactive)
  (when (process-live-p kasas-server--process)
    (user-error "A kasas server is already running; use `kasas-server-restart'"))
  (let ((binary (kasas-server--binary)))
    (unless binary
      (user-error "No kasas binary found; run `M-x kasas-install' first"))
    (let* ((process-environment (append (kasas-server--env) process-environment))
           (command (append (list binary "serve")
                            (when kasas-server-config-file
                              (list "-config"
                                    (expand-file-name kasas-server-config-file)))))
           (buffer (get-buffer-create kasas-server-buffer-name)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)))
      (setq kasas-server--process
            (make-process
             :name "kasas-server"
             :buffer buffer
             :command command
             :connection-type 'pipe
             :sentinel #'kasas-server--sentinel))
      (display-buffer buffer)
      (message "kasas: server started (%s)" (string-join command " "))
      kasas-server--process)))

;;;###autoload
(defun kasas-server-stop ()
  "Stop the kasas server started by `kasas-server-start'."
  (interactive)
  (if (process-live-p kasas-server--process)
      (progn
        (interrupt-process kasas-server--process)
        (message "kasas: stopping server"))
    (setq kasas-server--process nil)
    (message "kasas: no server is running")))

;;;###autoload
(defun kasas-server-restart ()
  "Restart the kasas server with the current configuration."
  (interactive)
  (when (process-live-p kasas-server--process)
    (interrupt-process kasas-server--process)
    (let ((tries 50))
      (while (and (> tries 0) (process-live-p kasas-server--process))
        (sleep-for 0.1)
        (setq tries (1- tries)))))
  (setq kasas-server--process nil)
  (kasas-server-start))

(provide 'kasas-server)

;;; kasas-server.el ends here
