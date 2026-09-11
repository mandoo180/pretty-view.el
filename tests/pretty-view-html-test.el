;;; pretty-view-html-test.el --- Tests for the document shell  -*- lexical-binding: t -*-

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
;; Shell assembly, table of contents, asset inlining, live-reload script.

;;; Code:

(require 'ert)
(require 'pretty-view-html)
(require 'pretty-view-themes)

(ert-deftest pretty-view-html-test-document-structure ()
  (let ((html (pretty-view-html-document "<p>x</p>\n" :title "T")))
    (should (string-prefix-p "<!DOCTYPE html>" html))
    (should (string-match-p "<html lang=" html))
    (should (string-match-p "<meta charset=\"utf-8\"" html))
    (should (string-match-p "name=\"viewport\"" html))
    (should (string-match-p "<title>T</title>" html))
    (should (string-match-p "<p>x</p>" html))
    (should (string-suffix-p "</html>\n" html))))

(ert-deftest pretty-view-html-test-title-is-escaped ()
  (should (string-match-p "<title>a &amp; b</title>"
                          (pretty-view-html-document "" :title "a & b"))))

(ert-deftest pretty-view-html-test-stylesheet-is-inlined ()
  (let ((pretty-view-theme 'github-light))
    (should (string-match-p "--pv-bg" (pretty-view-html-document "")))))

(ert-deftest pretty-view-html-test-head-functions-contribute ()
  (let ((pretty-view-head-functions
         (list (lambda () "<meta name=\"probe\" content=\"1\">")
               (lambda () nil))))
    (should (string-match-p "name=\"probe\""
                            (pretty-view-html-document "")))))

(ert-deftest pretty-view-html-test-body-filters-apply-in-order ()
  (let ((pretty-view-body-filter-functions
         (list (lambda (b) (concat b "<!--1-->"))
               (lambda (b) (concat b "<!--2-->")))))
    (should (string-match-p "<!--1--><!--2-->"
                            (pretty-view-html-document "x")))))

(ert-deftest pretty-view-html-test-toc-nil-by-default ()
  "Check for the nav element, not the string: the stylesheet also says pv-toc."
  (let ((pretty-view-toc nil))
    (should-not (string-match-p "class=\"pv-toc\""
                                (pretty-view-html-document
                                 "<h1 id=\"a\">A</h1><h2 id=\"b\">B</h2>")))))

(ert-deftest pretty-view-html-test-toc-when-enabled ()
  (let ((pretty-view-toc t))
    (let ((html (pretty-view-html-document
                 "<h1 id=\"a\">A</h1>\n<h2 id=\"b\">B &amp; C</h2>\n")))
      (should (string-match-p "class=\"pv-toc\"" html))
      (should (string-match-p "href=\"#a\"" html))
      (should (string-match-p "href=\"#b\"" html))
      (should (string-match-p "B &amp; C" html)))))

(ert-deftest pretty-view-html-test-toc-respects-depth ()
  "Headings deeper than the limit are omitted; the rest still make a TOC."
  (let ((html (pretty-view-html--toc
               "<h1 id=\"a\">A</h1>\n<h2 id=\"b\">B</h2>\n<h3 id=\"c\">C</h3>\n" 2)))
    (should (string-match-p "#a" html))
    (should (string-match-p "#b" html))
    (should-not (string-match-p "#c" html))))

(ert-deftest pretty-view-html-test-toc-needs-two-headings ()
  (should (null (pretty-view-html--toc "<h1 id=\"a\">A</h1>\n" 6))))

(ert-deftest pretty-view-html-test-toc-needs-two-headings-after-depth-filter ()
  "Depth filtering happens first: one surviving heading means no TOC."
  (should (null (pretty-view-html--toc
                 "<h1 id=\"a\">A</h1>\n<h3 id=\"c\">C</h3>\n" 2)))
  ;; ...and the same body with a deeper limit does produce one.
  (should (pretty-view-html--toc
           "<h1 id=\"a\">A</h1>\n<h3 id=\"c\">C</h3>\n" 6)))

(ert-deftest pretty-view-html-test-toc-skips-headings-without-id ()
  (should (null (pretty-view-html--toc "<h1>A</h1>\n<h2>B</h2>\n" 6))))

(ert-deftest pretty-view-html-test-inline-local-image ()
  (let* ((dir (make-temp-file "pv-assets" t))
         (png (expand-file-name "x.png" dir)))
    (unwind-protect
        (progn
          (with-temp-file png (set-buffer-multibyte nil) (insert "\211PNG\r\n"))
          (let ((html (pretty-view-html--inline-assets
                       "<img src=\"x.png\" alt=\"a\" />" dir)))
            (should (string-match-p "src=\"data:image/png;base64," html))
            (should-not (string-match-p "src=\"x.png\"" html))))
      (delete-directory dir t))))

(ert-deftest pretty-view-html-test-inline-skips-remote-urls ()
  (let ((html (pretty-view-html--inline-assets
               "<img src=\"https://e.com/x.png\" />" "/tmp")))
    (should (string-match-p "https://e.com/x.png" html))))

(ert-deftest pretty-view-html-test-inline-skips-missing-file ()
  (let ((html (pretty-view-html--inline-assets
               "<img src=\"nope.png\" />" "/tmp")))
    (should (string-match-p "nope.png" html))))

(ert-deftest pretty-view-html-test-inline-respects-size-ceiling ()
  (let* ((dir (make-temp-file "pv-assets" t))
         (png (expand-file-name "big.png" dir))
         (pretty-view-inline-image-max-bytes 8))
    (unwind-protect
        (progn
          (with-temp-file png (insert (make-string 100 ?a)))
          (let ((html (pretty-view-html--inline-assets
                       "<img src=\"big.png\" />" dir)))
            (should-not (string-match-p "base64" html))
            (should (string-match-p "file://" html))))
      (delete-directory dir t))))

(ert-deftest pretty-view-html-test-inline-can-be-disabled ()
  (let ((pretty-view-inline-images nil))
    (should (string-match-p "src=\"x.png\""
                            (pretty-view-html--inline-assets
                             "<img src=\"x.png\" />" "/tmp")))))

(ert-deftest pretty-view-html-test-live-script-present-only-when-asked ()
  (should-not (string-match-p "location.reload"
                              (pretty-view-html-document "x")))
  (should (string-match-p "location.reload"
                          (pretty-view-html-document "x" :live t))))

(ert-deftest pretty-view-html-test-live-script-honours-interval ()
  (let ((pretty-view-live-interval 3))
    (should (string-match-p "3000" (pretty-view-html-document "x" :live t)))))

(ert-deftest pretty-view-html-test-live-script-suppressed-by-nil-interval ()
  (let ((pretty-view-live-interval nil))
    (should-not (string-match-p "location.reload"
                                (pretty-view-html-document "x" :live t)))))

(provide 'pretty-view-html-test)
;;; pretty-view-html-test.el ends here
