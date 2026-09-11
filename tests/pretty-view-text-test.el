;;; pretty-view-text-test.el --- Tests for the plain text converter  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Kyeong Soo Choi
;;
;; This file is part of pretty-view.el.
;;
;; pretty-view.el is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the Free
;; Software Foundation, either version 3 of the License, or (at your option)
;; any later version.
;;
;; pretty-view.el is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
;; more details.
;;
;; You should have received a copy of the GNU General Public License along with
;; this program. If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;; Paragraph splitting, escaping, autolinking, and the markdown opt-in.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'pretty-view-text)

(ert-deftest pretty-view-text-test-paragraphs ()
  (let ((html (pretty-view-text-body "one\n\ntwo")))
    (should (string-match-p "<p class=\"pv-text\">one</p>" html))
    (should (string-match-p "<p class=\"pv-text\">two</p>" html))))

(ert-deftest pretty-view-text-test-keeps-internal-newlines ()
  "Line structure inside a paragraph is meaningful in a text file."
  (should (string-match-p "a\nb" (pretty-view-text-body "a\nb"))))

(ert-deftest pretty-view-text-test-escapes ()
  (should (string-match-p "&lt;b&gt;" (pretty-view-text-body "<b>")))
  (should-not (string-match-p "<b>" (pretty-view-text-body "<b>"))))

(ert-deftest pretty-view-text-test-autolinks ()
  (let ((html (pretty-view-text-body "see https://example.com now")))
    (should (string-match-p "<a href=\"https://example.com\"" html))))

(ert-deftest pretty-view-text-test-autolink-does-not-break-escaping ()
  (let ((html (pretty-view-text-body "https://e.com/?a=1&b=2")))
    (should (string-match-p "&amp;b=2" html))))

(ert-deftest pretty-view-text-test-collapses-blank-run ()
  (let ((html (pretty-view-text-body "a\n\n\n\nb")))
    (should (= 2 (cl-count-if (lambda (_) t)
                              (split-string html "<p class=\"pv-text\">" t))))))

(ert-deftest pretty-view-text-test-markdown-opt-in ()
  (let ((pretty-view-text-as-markdown t))
    (should (string-match-p "<h1" (pretty-view-text-body "# Head")))))

(ert-deftest pretty-view-text-test-markdown-off-by-default ()
  (let ((pretty-view-text-as-markdown nil))
    (should-not (string-match-p "<h1" (pretty-view-text-body "# Head")))))

(ert-deftest pretty-view-text-test-empty-input ()
  (should (equal (pretty-view-text-body "") "")))

(provide 'pretty-view-text-test)
;;; pretty-view-text-test.el ends here
