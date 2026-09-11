;;; pretty-view-org.el --- Org export through a derived ox-html backend  -*- lexical-binding: t -*-

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

;; Exports an Org buffer to an HTML body through a backend derived from
;; `ox-html'.  The translate alist is assembled at export time from
;; `pretty-view-org-transcoders', so a user override takes effect
;; without redefining the backend.  Source blocks go through
;; `pretty-view-render-fontified-code', the same path Markdown uses, so
;; code looks identical in both formats.

;;; Code:

(require 'ox-html)
(require 'pretty-view-render)

(defun pretty-view-org-src-block (src-block _contents info)
  "Transcode SRC-BLOCK to HTML using the package's own highlighter.
INFO is the export communication channel."
  (let ((lang (org-element-property :language src-block))
        (code (org-export-format-code-default src-block info)))
    (format "<pre class=\"pv-code\"><code%s>%s</code></pre>\n"
            (if lang
                (format " class=\"language-%s\""
                        (pretty-view-escape-attribute lang))
              "")
            (pretty-view-render-fontified-code code lang))))

(defun pretty-view-org-example-block (example-block _contents info)
  "Transcode EXAMPLE-BLOCK to a plain code block.
INFO is the export communication channel."
  (format "<pre class=\"pv-code\"><code>%s</code></pre>\n"
          (pretty-view-escape-html
           (org-export-format-code-default example-block info))))

(defcustom pretty-view-org-transcoders
  '((src-block . pretty-view-org-src-block)
    (example-block . pretty-view-org-example-block))
  "Org element types mapped to the functions that transcode them.
Each function takes the `ox' transcoder arguments
\(ELEMENT CONTENTS INFO) and returns an HTML string.  Entries here are
merged over the inherited `html' backend at export time."
  :type '(alist :key-type symbol :value-type function)
  :group 'pretty-view)

(defun pretty-view-org--backend ()
  "Return an export backend derived from `html' with the user's transcoders."
  (org-export-create-backend
   :parent 'html
   :transcoders pretty-view-org-transcoders))

(defun pretty-view-org--plain-text (data)
  "Return the plain text content of DATA, an Org secondary string or object.
Post-blank spaces and subscript/superscript syntax are preserved."
  (cond
   ((stringp data) data)
   ((and (consp data) (symbolp (car data)))
    (let ((obj-type (car data))
          (contents (nthcdr 2 data)))
      (let ((text (if contents
                      (mapconcat #'pretty-view-org--plain-text contents "")
                    (or (org-element-property :raw-value data) ""))))
        ;; Reconstruct subscript/superscript syntax from the parse tree
        (let ((text (cond
                     ((eq obj-type 'subscript)
                      (concat "_" (if (org-element-property :use-brackets-p data)
                                      (concat "{" text "}")
                                    text)))
                     ((eq obj-type 'superscript)
                      (concat "^" (if (org-element-property :use-brackets-p data)
                                      (concat "{" text "}")
                                    text)))
                     (t text))))
          ;; Append post-blank spaces
          (concat text (make-string (or (org-element-property :post-blank data) 0) 32))))))
   ((listp data) (mapconcat #'pretty-view-org--plain-text data ""))
   (t "")))

(defun pretty-view-org-title ()
  "Return the `#+TITLE:' of the current Org buffer, or nil.
Subscripts, superscripts, and other markup are reconstructed as Org syntax."
  (let ((keywords (org-collect-keywords (list "title"))))
    (when keywords
      (let ((raw-title (cadr (assoc "TITLE" keywords))))
        (when raw-title
          ;; Parse the secondary string as-is; subscripts/superscripts will
          ;; be reconstructed from the parse tree by pretty-view-org--plain-text
          (let ((title-list (org-element-parse-secondary-string
                             raw-title
                             (org-element-restriction 'paragraph))))
            ;; Extract plain text (preserving post-blank spaces and subscript syntax)
            (let ((text (pretty-view-org--plain-text title-list)))
              (unless (string-empty-p (string-trim text))
                (substring-no-properties (string-trim text))))))))))

(defun pretty-view-org-body ()
  "Return the current Org buffer exported to an HTML body."
  (condition-case err
      (let ((org-html-head-include-default-style nil)
            (org-html-head-include-scripts nil)
            (org-html-htmlize-output-type nil)
            (org-export-with-smart-quotes t)
            ;; A single broken link must not abort the whole export (and
            ;; thus replace the entire document with a `.pv-error' box in
            ;; live mode); mark it in place and keep exporting instead.
            (org-export-with-broken-links 'mark))
        (org-export-as (pretty-view-org--backend) nil nil t nil))
    (error
     (format "<div class=\"pv-error\"><strong>Org export failed:</strong> %s</div>\n"
             (pretty-view-escape-html (error-message-string err))))))

(provide 'pretty-view-org)
;;; pretty-view-org.el ends here
