;;; pretty-view-browser-test.el --- Tests for platform handling  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Kyeong Soo Choi

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;; Platform detection, output paths, and browser command construction.
;; Nothing here launches a program: `pretty-view-browser-command' is a
;; pure function returning an argument list.
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'pretty-view-browser)

(defmacro pv-with-wsl (wsl &rest body)
  "Run BODY with WSL detection forced to WSL."
  `(cl-letf (((symbol-function 'pretty-view-browser-wsl-p) (lambda () ,wsl)))
     ,@body))

(ert-deftest pretty-view-browser-test-wsl-detection-from-kernel ()
  (let ((pretty-view-browser--uname "6.6.0-microsoft-standard-WSL2"))
    (should (pretty-view-browser-wsl-p)))
  (cl-letf (((symbol-function 'getenv) (lambda (&rest _) nil)))
    (let ((pretty-view-browser--uname "6.6.0-generic"))
      (should-not (pretty-view-browser-wsl-p)))))

(ert-deftest pretty-view-browser-test-wsl-detection-from-env ()
  "Test WSL detection using environment variable alone, without kernel string."
  (cl-letf (((symbol-function 'getenv)
             (lambda (name &rest _) (when (equal name "WSL_DISTRO_NAME") "Ubuntu"))))
    (let ((pretty-view-browser--uname "6.6.0-generic"))
      (should (pretty-view-browser-wsl-p)))))

(ert-deftest pretty-view-browser-test-command-uses-explicit-program ()
  (let ((pretty-view-browser "firefox"))
    (should (equal (pretty-view-browser-command "/tmp/a.html")
                   '("firefox" "file:///tmp/a.html")))))

(ert-deftest pretty-view-browser-test-command-default-is-nil-off-wsl ()
  (pv-with-wsl nil
    (let ((pretty-view-browser 'default))
      (should (null (pretty-view-browser-command "/tmp/a.html"))))))

(ert-deftest pretty-view-browser-test-command-prefers-wslview ()
  (pv-with-wsl t
    (cl-letf (((symbol-function 'executable-find)
               (lambda (p &rest _) (when (equal p "wslview") "/usr/bin/wslview"))))
      (let ((pretty-view-browser 'default))
        (should (equal (pretty-view-browser-command "/tmp/a.html")
                       '("/usr/bin/wslview" "/tmp/a.html")))))))

(ert-deftest pretty-view-browser-test-command-falls-back-to-explorer ()
  (pv-with-wsl t
    (cl-letf (((symbol-function 'executable-find)
               (lambda (p &rest _)
                 (when (equal p "explorer.exe") "/mnt/c/WINDOWS/explorer.exe")))
              ((symbol-function 'pretty-view-browser--windows-path)
               (lambda (_f) "C:\\tmp\\a.html")))
      (let ((pretty-view-browser 'default))
        (should (equal (pretty-view-browser-command "/tmp/a.html")
                       '("/mnt/c/WINDOWS/explorer.exe" "C:\\tmp\\a.html")))))))

(ert-deftest pretty-view-browser-test-command-nil-when-nothing-found ()
  (pv-with-wsl t
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
      (let ((pretty-view-browser 'default))
        (should (null (pretty-view-browser-command "/tmp/a.html")))))))

(ert-deftest pretty-view-browser-test-function-browser-is-called ()
  (let* ((called nil)
         (pretty-view-browser (lambda (f) (setq called f))))
    (pretty-view-browser-open "/tmp/a.html")
    (should (equal called "/tmp/a.html"))))

(ert-deftest pretty-view-browser-test-output-file-is-stable ()
  (let ((pretty-view-output-directory "/tmp/pv/"))
    (should (equal (pretty-view-browser-output-file "/a/b/notes.md")
                   (pretty-view-browser-output-file "/a/b/notes.md")))))

(ert-deftest pretty-view-browser-test-output-file-disambiguates-paths ()
  (let ((pretty-view-output-directory "/tmp/pv/"))
    (should-not (equal (pretty-view-browser-output-file "/a/notes.md")
                       (pretty-view-browser-output-file "/b/notes.md")))))

(ert-deftest pretty-view-browser-test-output-file-keeps-base-name ()
  (let ((pretty-view-output-directory "/tmp/pv/"))
    (should (string-match-p "/notes-[0-9a-f]\\{10\\}\\.html\\'"
                            (pretty-view-browser-output-file "/a/notes.md")))))

(ert-deftest pretty-view-browser-test-output-file-sanitizes-base-name ()
  (let ((pretty-view-output-directory "/tmp/pv/"))
    (should (string-match-p "/a-b-[0-9a-f]\\{10\\}\\.html\\'"
                            (pretty-view-browser-output-file "/x/a b.md")))))

(ert-deftest pretty-view-browser-test-default-output-directory-off-wsl ()
  (pv-with-wsl nil
    (should (equal (pretty-view-browser-default-output-directory)
                   (expand-file-name "pretty-view" temporary-file-directory)))))

(ert-deftest pretty-view-browser-test-default-output-directory-on-wsl ()
  (pv-with-wsl t
    (cl-letf (((symbol-function 'pretty-view-browser--windows-temp)
               (lambda () "/mnt/c/Users/u/AppData/Local/Temp")))
      (should (string-prefix-p "/mnt/c/"
                               (pretty-view-browser-default-output-directory))))))

(ert-deftest pretty-view-browser-test-wsl-falls-back-when-temp-unresolved ()
  (pv-with-wsl t
    (cl-letf (((symbol-function 'pretty-view-browser--windows-temp)
               (lambda () nil)))
      (should (equal (pretty-view-browser-default-output-directory)
                     (expand-file-name "pretty-view" temporary-file-directory))))))

(ert-deftest pretty-view-browser-test-windows-temp-is-cached ()
  "The Windows TEMP lookup runs a subprocess at most once."
  (let ((calls 0)
        (pretty-view-browser--windows-temp-cache 'unset))
    (cl-letf (((symbol-function 'pretty-view-browser-wsl-p) (lambda () t))
              ((symbol-function 'shell-command-to-string)
               (lambda (&rest _) (setq calls (1+ calls)) "C:\\Temp\r\n")))
      (pretty-view-browser--windows-temp)
      (pretty-view-browser--windows-temp)
      (should (= calls 1)))))

(ert-deftest pretty-view-browser-test-windows-temp-nil-off-wsl ()
  "Off WSL the lookup runs nothing and returns nil."
  (let ((pretty-view-browser--windows-temp-cache 'unset)
        (ran nil))
    (cl-letf (((symbol-function 'pretty-view-browser-wsl-p) (lambda () nil))
              ((symbol-function 'shell-command-to-string)
               (lambda (&rest _) (setq ran t) "")))
      (should (null (pretty-view-browser--windows-temp)))
      (should-not ran))))

(ert-deftest pretty-view-browser-test-windows-temp-rejects-garbage ()
  (let ((pretty-view-browser--windows-temp-cache 'unset))
    (cl-letf (((symbol-function 'pretty-view-browser-wsl-p) (lambda () t))
              ((symbol-function 'shell-command-to-string) (lambda (&rest _) "")))
      (should (null (pretty-view-browser--windows-temp))))))

(ert-deftest pretty-view-browser-test-open-falls-back-to-browse-url ()
  "When no platform command applies, browse-url is used with a file URL."
  (let ((called nil))
    (cl-letf (((symbol-function 'pretty-view-browser-command) (lambda (_f) nil))
              ((symbol-function 'browse-url) (lambda (url) (setq called url))))
      (let ((pretty-view-browser 'default))
        (should (pretty-view-browser-open "/tmp/a.html"))
        (should (equal called "file:///tmp/a.html"))))))

(ert-deftest pretty-view-browser-test-open-survives-a-signalling-function ()
  "A user browser function that signals must not escape."
  (let ((pretty-view-browser (lambda (_f) (error "boom")))
        (reported nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (setq reported (apply #'format fmt args)))))
      (should (null (pretty-view-browser-open "/tmp/a.html")))
      (should (string-match-p "/tmp/a.html" reported)))))

(ert-deftest pretty-view-browser-test-windows-temp-caches-a-nil-result ()
  "A failed lookup must not re-run the subprocess on every call."
  (let ((calls 0))
    (pretty-view-browser--reset-caches)
    (cl-letf (((symbol-function 'pretty-view-browser-wsl-p) (lambda () t))
              ((symbol-function 'shell-command-to-string)
               (lambda (&rest _) (setq calls (1+ calls)) "")))
      (should (null (pretty-view-browser--windows-temp)))
      (should (null (pretty-view-browser--windows-temp)))
      (should (= calls 1)))))

(ert-deftest pretty-view-browser-test-output-name-is-never-empty-or-hidden ()
  (let ((pretty-view-output-directory "/tmp/pv/"))
    (dolist (src '("/x/--.md" "/x/...md" "/x/.md" "/x/___.md"))
      (let ((name (file-name-nondirectory
                   (pretty-view-browser-output-file src))))
        (should-not (string-prefix-p "." name))
        (should-not (string-prefix-p "-" name))
        (should (string-match-p "\\`[[:alnum:]]" name))))))

(provide 'pretty-view-browser-test)
;;; pretty-view-browser-test.el ends here
