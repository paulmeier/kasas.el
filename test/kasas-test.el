;;; kasas-test.el --- Tests for kasas.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Paul Meier
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; ERT tests covering the pure, server-independent helpers: URL and query
;; building, JSON round-tripping, money/time formatting, and the plot
;; aggregations.  Run with `make test' or `eldev test'.

;;; Code:

(require 'ert)
(require 'kasas)
(require 'kasas-plot)
(require 'kasas-server)

;;;; URL and query building

(ert-deftest kasas-test-build-query-skips-nil-and-empty ()
  (should (equal (kasas--build-query '(("a" . "1") ("b" . nil) ("c" . "")))
                 "?a=1"))
  (should (equal (kasas--build-query nil) ""))
  (should (equal (kasas--build-query '(("only" . nil))) "")))

(ert-deftest kasas-test-build-query-encodes ()
  (should (equal (kasas--build-query '(("q" . "a b&c")))
                 "?q=a%20b%26c")))

(ert-deftest kasas-test-build-query-coerces-numbers ()
  (should (equal (kasas--build-query '(("limit" . 100))) "?limit=100")))

(ert-deftest kasas-test-url-api-path ()
  (let ((kasas-base-url "http://localhost:8080"))
    (should (equal (kasas--url "accounts")
                   "http://localhost:8080/api/v1/accounts"))
    (should (equal (kasas--url "transactions" '(("limit" . 50)))
                   "http://localhost:8080/api/v1/transactions?limit=50"))))

(ert-deftest kasas-test-url-absolute-and-trailing-slash ()
  (let ((kasas-base-url "http://localhost:8080/"))
    (should (equal (kasas--url "/healthz") "http://localhost:8080/healthz"))
    (should (equal (kasas--url "/api/v1/auth") "http://localhost:8080/api/v1/auth"))))

(ert-deftest kasas-test-host ()
  (let ((kasas-base-url "http://example.com:9000"))
    (should (equal (kasas--host) "example.com:9000"))))

;;;; JSON

(ert-deftest kasas-test-json-roundtrip ()
  (let* ((obj '(:a 1 :b "two" :c :false))
         (decoded (kasas--json-read-string (kasas--json-encode obj))))
    (should (= (plist-get decoded :a) 1))
    (should (equal (plist-get decoded :b) "two"))))

(ert-deftest kasas-test-to-json-object ()
  (should (equal (kasas--to-json-object '(("category" . "food")))
                 '(:category "food")))
  (should (equal (kasas--to-json-object '(:category "food"))
                 '(:category "food")))
  (should (equal (kasas--to-json-object nil) nil)))

;;;; Accessors and formatting

(ert-deftest kasas-test-get-default ()
  (should (equal (kasas-get '(:a 1) :a) 1))
  (should (equal (kasas-get '(:a 1) :missing "d") "d"))
  (should (equal (kasas-get '(:a :null) :a "d") "d")))

(ert-deftest kasas-test-format-amount ()
  (let ((kasas-currency-symbol "$"))
    (should (equal (kasas-format-amount "12.34") "$12.34"))
    (should (equal (kasas-format-amount "-12.34") "-$12.34"))
    (should (equal (kasas-format-amount "0") "$0"))
    (should (equal (kasas-format-amount "12.34" "€") "€12.34"))))

(ert-deftest kasas-test-parse-amount ()
  (should (= (kasas-parse-amount "12.34") 12.34))
  (should (= (kasas-parse-amount "-5") -5.0))
  (should (= (kasas-parse-amount nil) 0.0))
  (should (= (kasas-parse-amount "not-a-number") 0.0)))

(ert-deftest kasas-test-labels-string ()
  (should (member (kasas-labels-string '(:category "food" :store "acme"))
                  '("category:food store:acme" "store:acme category:food")))
  (should (equal (kasas-labels-string nil) nil)))

(ert-deftest kasas-test-format-date ()
  (should (equal (kasas-format-date "") ""))
  (should (equal (kasas-format-date nil) ""))
  ;; A well-formed timestamp keeps its date component.
  (should (string-match-p "\\`2024-03-15" (kasas-format-date "2024-03-15T12:00:00Z"))))

;;;; Plot aggregations

(defconst kasas-test--transactions
  '((:date "2024-01-01T00:00:00Z" :amount "-10.00" :labels (:category "food"))
    (:date "2024-01-01T05:00:00Z" :amount "-5.00"  :labels (:category "food"))
    (:date "2024-01-02T00:00:00Z" :amount "100.00" :labels (:category "income"))
    (:date "2024-01-03T00:00:00Z" :amount "-20.00" :labels nil))
  "Synthetic transactions for aggregation tests.")

(ert-deftest kasas-test-plot-by-day ()
  (let ((agg (kasas-plot--by-day kasas-test--transactions)))
    (should (equal (mapcar #'car agg) '("2024-01-01" "2024-01-02" "2024-01-03")))
    (should (= (cdr (assoc "2024-01-01" agg)) -15.0))
    (should (= (cdr (assoc "2024-01-02" agg)) 100.0))))

(ert-deftest kasas-test-plot-cumulative ()
  (let* ((agg (kasas-plot--by-day kasas-test--transactions))
         (cum (kasas-plot--cumulative agg)))
    (should (= (cdr (nth 0 cum)) -15.0))
    (should (= (cdr (nth 1 cum)) 85.0))
    (should (= (cdr (nth 2 cum)) 65.0))))

(ert-deftest kasas-test-plot-by-label ()
  (let ((agg (kasas-plot--by-label kasas-test--transactions "category")))
    (should (= (cdr (assoc "food" agg)) 15.0))    ; abs outflow
    (should (= (cdr (assoc "income" agg)) 100.0))
    (should (= (cdr (assoc "(none)" agg)) 20.0))
    ;; sorted descending by total
    (should (>= (cdr (nth 0 agg)) (cdr (nth 1 agg))))))

;;;; Server install / configure helpers

(ert-deftest kasas-test-server-platform ()
  (should (equal (kasas-server--platform 'gnu/linux "x86_64-pc-linux-gnu")
                 '("linux" . "amd64")))
  (should (equal (kasas-server--platform 'darwin "aarch64-apple-darwin")
                 '("darwin" . "arm64")))
  (should (equal (kasas-server--platform 'darwin "x86_64-apple-darwin18.7.0")
                 '("darwin" . "amd64")))
  ;; Unsupported OS and architecture both signal.
  (should-error (kasas-server--platform 'windows-nt "x86_64-w64-mingw32"))
  (should-error (kasas-server--platform 'gnu/linux "i686-pc-linux-gnu")))

(ert-deftest kasas-test-server-setting-env-name ()
  (should (equal (kasas-server--setting-env-name "server.addr") "KASAS_SERVER_ADDR"))
  (should (equal (kasas-server--setting-env-name "plugins.net.timeout")
                 "KASAS_PLUGINS_NET_TIMEOUT")))

(ert-deftest kasas-test-server-env ()
  (let ((kasas-server-settings '(("server.addr" . ":9000")
                                 ("log.level" . "debug"))))
    (should (equal (kasas-server--env)
                   '("KASAS_SERVER_ADDR=:9000" "KASAS_LOG_LEVEL=debug"))))
  (let ((kasas-server-settings nil))
    (should (equal (kasas-server--env) nil))))

(ert-deftest kasas-test-server-asset-urls ()
  (let ((release
         '(:tag_name "v2.0.0"
           :assets [(:name "kasas_2.0.0_linux_amd64.tar.gz"
                     :browser_download_url "https://x/linux.tar.gz")
                    (:name "kasas_2.0.0_linux_amd64.tar.gz.sha256"
                     :browser_download_url "https://x/linux.tar.gz.sha256")
                    (:name "kasas_2.0.0_darwin_arm64.tar.gz"
                     :browser_download_url "https://x/darwin.tar.gz")])))
    (should (equal (kasas-server--asset-urls release "linux" "amd64")
                   '("https://x/linux.tar.gz" . "https://x/linux.tar.gz.sha256")))
    ;; A platform with a tarball but no checksum returns a nil cdr.
    (should (equal (kasas-server--asset-urls release "darwin" "arm64")
                   '("https://x/darwin.tar.gz" . nil)))
    ;; A platform with no tarball signals.
    (should-error (kasas-server--asset-urls release "windows" "amd64"))))

(ert-deftest kasas-test-server-configure ()
  (let ((kasas-server-settings nil))
    (kasas-server-configure "server.addr" ":9000")
    (should (equal (cdr (assoc "server.addr" kasas-server-settings)) ":9000"))
    ;; Re-setting replaces rather than duplicates.
    (kasas-server-configure "server.addr" ":7000")
    (should (equal kasas-server-settings '(("server.addr" . ":7000"))))
    ;; An empty value clears the override.
    (kasas-server-configure "server.addr" "")
    (should (equal kasas-server-settings nil))))

(provide 'kasas-test)

;;; kasas-test.el ends here
