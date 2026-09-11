;;; pretty-view-text.el --- Plain text converter  -*- lexical-binding: t -*-

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

;; Plain text is rendered as plain text: escaped, split into paragraphs
;; on blank lines, with line structure preserved inside each paragraph
;; and bare URLs linked.  Setting `pretty-view-text-as-markdown' routes
;; text through the GFM parser instead.

;;; Code:

(require 'pretty-view-render)
(require 'pretty-view-gfm)

(defcustom pretty-view-text-as-markdown nil
  "When non-nil, render plain text files through the Markdown parser."
  :type 'boolean
  :group 'pretty-view)

(defconst pretty-view-text--url-re "\\bhttps?://[^ \t\n<>\"]+"
  "Match a bare URL in plain text.")

(defun pretty-view-text--autolink (escaped)
  "Return ESCAPED, already HTML-escaped, with bare URLs turned into links."
  (replace-regexp-in-string
   pretty-view-text--url-re
   (lambda (url)
     ;; URL is escaped text, so it is safe in both the href and the body.
     (format "<a href=\"%s\">%s</a>" url url))
   escaped t t))

(defun pretty-view-text-body (text)
  "Return TEXT rendered as an HTML body."
  (if pretty-view-text-as-markdown
      (pretty-view-render-document (pretty-view-gfm-parse text))
    (let ((paragraphs (split-string (string-trim text) "\n[ \t]*\n+" t)))
      (mapconcat
       (lambda (para)
         (format "<p class=\"pv-text\">%s</p>\n"
                 (pretty-view-text--autolink
                  (pretty-view-escape-html (string-trim para)))))
       paragraphs ""))))

(provide 'pretty-view-text)
;;; pretty-view-text.el ends here
