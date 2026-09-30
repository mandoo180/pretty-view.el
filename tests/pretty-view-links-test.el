;;; pretty-view-links-test.el --- Tests for linked documents  -*- lexical-binding: t -*-

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
;; Link rewriting, and the background queue that renders linked
;; documents.  The queue is driven by calling its tick function
;; directly; no test waits on a real timer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'pretty-view-links)

(defmacro pv-links-with-tree (dir files &rest body)
  "Bind DIR to a fresh directory holding FILES, run BODY, delete it.
FILES are names relative to DIR; each is created with placeholder
contents, along with any directory it needs."
  (declare (indent 2))
  `(let ((,dir (file-name-as-directory (make-temp-file "pv-links" t))))
     (unwind-protect
         (progn
           (dolist (f ,files)
             (let ((path (expand-file-name f ,dir)))
               (make-directory (file-name-directory path) t)
               (with-temp-file path (insert "x"))))
           ,@body)
       (delete-directory ,dir t))))

(defmacro pv-links-with-urls (&rest body)
  "Run BODY with file URLs stubbed to \"URL:\" plus the file name."
  `(cl-letf (((symbol-function 'pretty-view-browser-file-url)
              (lambda (f) (concat "URL:" f))))
     ,@body))

(defun pv-links-accept-all (file)
  "Accept FILE, linking it to a fake output named after its base name."
  (concat "/out/" (file-name-base file) "-h.html"))

(defun pv-links-href (html)
  "Return the first href value in HTML."
  (and (string-match "href=\"\\([^\"]*\\)\"" html) (match-string 1 html)))

;;; Rewriting

(ert-deftest pretty-view-links-test-document-link-points-at-its-page ()
  (pv-links-with-tree dir '("sub/doc.md")
    (should (equal (pretty-view-links-rewrite
                    "<a href=\"sub/doc.md\">d</a>" dir #'pv-links-accept-all)
                   "<a href=\"doc-h.html\">d</a>"))))

(ert-deftest pretty-view-links-test-accept-gets-the-absolute-file ()
  (pv-links-with-tree dir '("sub/doc.md")
    (pv-links-with-urls
     (let (seen)
       (pretty-view-links-rewrite "<a href=\"sub/doc.md\">d</a>" dir
                                  (lambda (f) (push f seen) nil))
       (should (equal seen (list (expand-file-name "sub/doc.md" dir))))))))

(ert-deftest pretty-view-links-test-fragment-is-kept ()
  (pv-links-with-tree dir '("doc.md")
    (should (equal (pv-links-href
                    (pretty-view-links-rewrite
                     "<a href=\"doc.md#part-two\">d</a>" dir
                     #'pv-links-accept-all))
                   "doc-h.html#part-two"))))

(ert-deftest pretty-view-links-test-korean-names-raw-and-percent-encoded ()
  (pv-links-with-tree dir '("설명.md")
    (dolist (href '("설명.md" "%EC%84%A4%EB%AA%85.md"))
      (should (equal (pv-links-href
                      (pretty-view-links-rewrite
                       (format "<a href=\"%s\">d</a>" href) dir
                       #'pv-links-accept-all))
                     "%EC%84%A4%EB%AA%85-h.html")))))

(ert-deftest pretty-view-links-test-entities-are-decoded ()
  (pv-links-with-tree dir '("a&b.txt")
    (should (equal (pv-links-href
                    (pretty-view-links-rewrite
                     "<a href=\"a&amp;b.txt\">d</a>" dir
                     #'pv-links-accept-all))
                   "a%26b-h.html"))))

(ert-deftest pretty-view-links-test-spaces-and-upper-case-extension ()
  "Review focus: `Release Notes.MD' is a document, linked encoded."
  (pv-links-with-tree dir '("Release Notes.MD")
    (let (seen)
      (should (equal (pv-links-href
                      (pretty-view-links-rewrite
                       "<a href=\"Release%20Notes.MD\">n</a>" dir
                       (lambda (f) (push f seen) (pv-links-accept-all f))))
                     "Release%20Notes-h.html"))
      (should (equal seen
                     (list (expand-file-name "Release Notes.MD" dir)))))))

(ert-deftest pretty-view-links-test-other-links-are-untouched ()
  (pv-links-with-tree dir '("sub/doc.md")
    (pv-links-with-urls
     (dolist (html '("<a href=\"#top\">t</a>"
                     "<a href=\"\">e</a>"
                     "<a href=\"https://e.com/sub/doc.md\">r</a>"
                     "<a href=\"mailto:a@b.c\">m</a>"
                     "<a href=\"//cdn.example/sub/doc.md\">n</a>"
                     "<a href=\"missing.md\">x</a>"
                     "<a href=\"sub\">dir</a>"
                     "<a data-href=\"sub/doc.md\">no href</a>"))
       (should (equal (pretty-view-links-rewrite
                       html dir #'pv-links-accept-all)
                      html))))))

(ert-deftest pretty-view-links-test-other-files-open-in-a-new-tab ()
  (pv-links-with-tree dir '("data.json")
    (pv-links-with-urls
     (should (equal (pretty-view-links-rewrite
                     "<a href=\"data.json\">j</a>" dir #'pv-links-accept-all)
                    (format (concat "<a href=\"URL:%sdata.json\""
                                    " target=\"_blank\" rel=\"noopener\">j</a>")
                            dir))))))

(ert-deftest pretty-view-links-test-other-file-keeps-fragment-drops-query ()
  "Review focus: a query and an escaped `&' do not break the link."
  (pv-links-with-tree dir '("data.json" "manual.pdf")
    (pv-links-with-urls
     (should (equal (pv-links-href
                     (pretty-view-links-rewrite
                      "<a href=\"data.json?x=1&amp;y=2#k\">j</a>" dir nil))
                    (concat "URL:" dir "data.json#k")))
     (should (equal (pv-links-href
                     (pretty-view-links-rewrite
                      "<a href=\"manual.pdf#page=3\">p</a>" dir nil))
                    (concat "URL:" dir "manual.pdf#page=3"))))))

(ert-deftest pretty-view-links-test-existing-target-is-kept ()
  (pv-links-with-tree dir '("data.json")
    (pv-links-with-urls
     (let ((html (pretty-view-links-rewrite
                  "<a href=\"data.json\" target=\"_self\">j</a>" dir nil)))
       (should (string-match-p "target=\"_self\"" html))
       (should-not (string-match-p "_blank" html))))))

(ert-deftest pretty-view-links-test-declined-document-opens-the-file ()
  (pv-links-with-tree dir '("doc.md")
    (pv-links-with-urls
     (dolist (accept (list nil #'ignore))
       (should (equal (pretty-view-links-rewrite
                       "<a href=\"doc.md\">d</a>" dir accept)
                      (format (concat "<a href=\"URL:%sdoc.md\""
                                      " target=\"_blank\""
                                      " rel=\"noopener\">d</a>")
                              dir)))))))

(ert-deftest pretty-view-links-test-extensions-option ()
  (pv-links-with-tree dir '("notes.txt")
    (pv-links-with-urls
     (let ((pretty-view-follow-links-extensions '("md")))
       (should (string-prefix-p
                "URL:"
                (pv-links-href (pretty-view-links-rewrite
                                "<a href=\"notes.txt\">n</a>" dir
                                #'pv-links-accept-all))))))))

(ert-deftest pretty-view-links-test-file-url-href ()
  (pv-links-with-tree dir '("doc.md")
    (should (equal (pv-links-href
                    (pretty-view-links-rewrite
                     (format "<a href=\"file://%sdoc.md\">d</a>" dir) dir
                     #'pv-links-accept-all))
                   "doc-h.html"))))

(ert-deftest pretty-view-links-test-other-attributes-survive ()
  (pv-links-with-tree dir '("doc.md")
    (should (equal (pretty-view-links-rewrite
                    "<a class=\"c\" href=\"doc.md\" title=\"t\">d</a>" dir
                    #'pv-links-accept-all)
                   "<a class=\"c\" href=\"doc-h.html\" title=\"t\">d</a>"))))

(ert-deftest pretty-view-links-test-every-link-is-rewritten ()
  "Review focus: one document linked twice, amid other text."
  (pv-links-with-tree dir '("doc.md")
    (should (equal (pretty-view-links-rewrite
                    (concat "<p><a href=\"doc.md\">1</a> and "
                            "<a href=\"doc.md#b\">2</a></p>")
                    dir #'pv-links-accept-all)
                   (concat "<p><a href=\"doc-h.html\">1</a> and "
                           "<a href=\"doc-h.html#b\">2</a></p>")))))

(ert-deftest pretty-view-links-test-remote-base-is-left-alone ()
  (let ((html "<a href=\"doc.md\">d</a>"))
    (should (equal (pretty-view-links-rewrite
                    html "/ssh:host:/x/" #'pv-links-accept-all)
                   html))))

(provide 'pretty-view-links-test)
;;; pretty-view-links-test.el ends here
