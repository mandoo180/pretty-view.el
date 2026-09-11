;;; pretty-view-org-test.el --- Tests for the Org backend  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Kyeong Soo Choi

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;; Body export, transcoder overrides, and error capture.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'pretty-view-org)

(defun pv-org (text)
  "Export TEXT as an Org buffer body."
  (with-temp-buffer
    (insert text)
    (org-mode)
    (pretty-view-org-body)))

(ert-deftest pretty-view-org-test-heading ()
  (should (string-match-p "<h2[^>]*>Hi</h2>" (pv-org "* Hi\n"))))

(ert-deftest pretty-view-org-test-paragraph-and-emphasis ()
  (let ((html (pv-org "Some *bold* text.\n")))
    (should (string-match-p "<b>bold</b>\\|<strong>bold</strong>" html))))

(ert-deftest pretty-view-org-test-no-default-stylesheet ()
  "The theme supplies all CSS; ox-html must not inject its own."
  (let ((html (pv-org "* Hi\n")))
    (should-not (string-match-p "<style" html))
    (should-not (string-match-p "org-src-container" html))))

(ert-deftest pretty-view-org-test-body-only ()
  "Export must be a fragment; the shell supplies html and head."
  (should-not (string-match-p "<!DOCTYPE" (pv-org "* Hi\n"))))

(ert-deftest pretty-view-org-test-src-block-uses-font-lock ()
  (let ((html (pv-org "#+begin_src emacs-lisp\n(defun f ())\n#+end_src\n")))
    (should (string-match-p "pv-code" html))
    (should (string-match-p "pv-keyword" html))))

(ert-deftest pretty-view-org-test-src-block-escapes ()
  (let ((html (pv-org "#+begin_src text\na < b\n#+end_src\n")))
    (should (string-match-p "&lt;" html))))

(ert-deftest pretty-view-org-test-table ()
  (let ((html (pv-org "| a | b |\n|---+---|\n| 1 | 2 |\n")))
    (should (string-match-p "<table" html))))

(ert-deftest pretty-view-org-test-title ()
  (with-temp-buffer
    (insert "#+TITLE: My Doc\n* Hi\n")
    (org-mode)
    (should (equal (pretty-view-org-title) "My Doc")))
  (with-temp-buffer
    (insert "* Hi\n")
    (org-mode)
    (should (null (pretty-view-org-title)))))

(ert-deftest pretty-view-org-test-transcoder-override ()
  (let ((pretty-view-org-transcoders
         (cons '(horizontal-rule . (lambda (&rest _) "<hr class=\"probe\">"))
               pretty-view-org-transcoders)))
    (should (string-match-p "probe" (pv-org "-----\n")))))

(ert-deftest pretty-view-org-test-export-error-is-rendered-not-signalled ()
  (cl-letf (((symbol-function 'org-export-as)
             (lambda (&rest _) (error "synthetic failure"))))
    (let ((html (pv-org "* Hi\n")))
      (should (string-match-p "pv-error" html))
      (should (string-match-p "synthetic failure" html)))))

(ert-deftest pretty-view-org-test-error-message-is-escaped ()
  (cl-letf (((symbol-function 'org-export-as)
             (lambda (&rest _) (error "bad <tag>"))))
    (let ((html (pv-org "* Hi\n")))
      (should (string-match-p "&lt;tag&gt;" html))
      (should-not (string-match-p "bad <tag>" html)))))

(provide 'pretty-view-org-test)
;;; pretty-view-org-test.el ends here
