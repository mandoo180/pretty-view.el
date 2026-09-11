;;; pretty-view-render.el --- AST to HTML for pretty-view  -*- lexical-binding: t -*-

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

;; Turns the AST produced by `pretty-view-gfm-parse' into HTML through a
;; user-replaceable table of per-node renderers, and provides the HTML
;; escaping used by every other module in the package.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup pretty-view nil
  "Render Org, Markdown, and text buffers to styled HTML."
  :group 'convenience
  :prefix "pretty-view-")

(defcustom pretty-view-code-mode-alist
  '(("elisp" . emacs-lisp-mode)
    ("emacs-lisp" . emacs-lisp-mode)
    ("el" . emacs-lisp-mode)
    ("sh" . sh-mode)
    ("shell" . sh-mode)
    ("bash" . sh-mode)
    ("zsh" . sh-mode)
    ("js" . javascript-mode)
    ("javascript" . javascript-mode)
    ("ts" . typescript-ts-mode)
    ("py" . python-mode)
    ("yml" . yaml-mode)
    ("rs" . rust-ts-mode)
    ("md" . markdown-mode)
    ("text" . fundamental-mode))
  "Map a fenced code block's info string to a major mode.
A language with no entry falls back to `LANG-ts-mode' (if its grammar is
installed), then `LANG-mode', then no highlighting."
  :type '(alist :key-type string :value-type symbol)
  :group 'pretty-view)

(defcustom pretty-view-face-class-alist
  '((font-lock-keyword-face       . "pv-keyword")
    (font-lock-string-face        . "pv-string")
    (font-lock-comment-face       . "pv-comment")
    (font-lock-comment-delimiter-face . "pv-comment")
    (font-lock-doc-face           . "pv-doc")
    (font-lock-function-name-face . "pv-function")
    (font-lock-variable-name-face . "pv-variable")
    (font-lock-type-face          . "pv-type")
    (font-lock-constant-face      . "pv-constant")
    (font-lock-builtin-face       . "pv-builtin")
    (font-lock-preprocessor-face  . "pv-preprocessor")
    (font-lock-negation-char-face . "pv-operator")
    (font-lock-operator-face      . "pv-operator")
    (font-lock-number-face        . "pv-constant")
    (font-lock-property-name-face . "pv-variable")
    (font-lock-property-use-face  . "pv-variable")
    (font-lock-function-call-face . "pv-function")
    (font-lock-variable-use-face  . "pv-variable")
    (font-lock-escape-face        . "pv-escape")
    (font-lock-warning-face       . "pv-warning"))
  "Map an Emacs face to the CSS class the theme styles.
A face with no entry produces no span, so its text is unstyled."
  :type '(alist :key-type symbol :value-type string)
  :group 'pretty-view)

(defun pretty-view-render--code-mode (lang)
  "Return the major mode for the info string LANG, or nil."
  (when (and lang (not (string-empty-p lang)))
    (let ((lang (downcase lang)))
      (or
       ;; Check alist first; validate -ts-mode entries for grammar availability
       (let ((mode (cdr (assoc lang pretty-view-code-mode-alist))))
         (and mode
              ;; If it's a -ts-mode, verify grammar is available
              (if (string-suffix-p "-ts-mode" (symbol-name mode))
                  (and (fboundp 'treesit-language-available-p)
                       (treesit-language-available-p
                        (intern (string-remove-suffix "-ts-mode" (symbol-name mode))))
                       mode)
                mode)))
       ;; Try LANG-ts-mode with grammar check
       (let ((ts (intern (concat lang "-ts-mode"))))
         (and (fboundp ts)
              (fboundp 'treesit-language-available-p)
              (treesit-language-available-p (intern lang))
              ts))
       ;; Fall back to LANG-mode
       (let ((plain (intern (concat lang "-mode"))))
         (and (fboundp plain) plain))))))

(defun pretty-view-render--face-class (face)
  "Return the CSS class for FACE, or nil.
FACE may be a symbol, a list of faces, or an anonymous face plist."
  (cond
   ((null face) nil)
   ((symbolp face) (cdr (assq face pretty-view-face-class-alist)))
   ((and (consp face) (keywordp (car face))) nil)
   ((consp face)
    (seq-some #'pretty-view-render--face-class face))
   (t nil)))

(defun pretty-view-render--fontify-buffer-html ()
  "Return the current buffer as HTML, spanning font-lock faces."
  (let ((out nil) (pos (point-min)))
    (while (< pos (point-max))
      (let* ((next (min (next-single-property-change pos 'face nil (point-max))
                        (next-single-property-change pos 'font-lock-face nil (point-max))))
             (face (or (get-text-property pos 'face)
                       (get-text-property pos 'font-lock-face)))
             (class (pretty-view-render--face-class face))
             (text (pretty-view-escape-html
                    (buffer-substring-no-properties pos next))))
        (push (if class
                  (format "<span class=\"%s\">%s</span>" class text)
                text)
              out)
        (setq pos next)))
    (apply #'concat (nreverse out))))

(defun pretty-view-render-fontified-code (code lang)
  "Return CODE as HTML, highlighted by the major mode for LANG.
Falls back to escaped plain text when LANG names no available mode or
when fontification fails."
  (let ((mode (pretty-view-render--code-mode lang)))
    (if (not mode)
        (pretty-view-escape-html code)
      (condition-case nil
          (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
                    ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
            (with-temp-buffer
              (insert code)
              (with-timeout (2 (pretty-view-escape-html code))
                (delay-mode-hooks (funcall mode))
                (font-lock-mode 1)
                (font-lock-ensure)
                (pretty-view-render--fontify-buffer-html))))
        (error (pretty-view-escape-html code))))))

(defun pretty-view-escape-html (string)
  "Return STRING with HTML special characters replaced by entities."
  (let ((s string))
    (setq s (replace-regexp-in-string "&" "&amp;" s t t))
    (setq s (replace-regexp-in-string "<" "&lt;" s t t))
    (setq s (replace-regexp-in-string ">" "&gt;" s t t))
    (setq s (replace-regexp-in-string "\"" "&quot;" s t t))
    (replace-regexp-in-string "'" "&#39;" s t t)))

(defun pretty-view-escape-attribute (string)
  "Return STRING escaped for use inside an HTML attribute value."
  (pretty-view-escape-html string))

(defcustom pretty-view-allow-raw-html t
  "When non-nil, emit raw HTML found in the source.
When nil, raw HTML is escaped and shown as text."
  :type 'boolean
  :group 'pretty-view)

(defun pretty-view-render--attr (name value)
  "Return ` NAME=\"VALUE\"' escaped, or an empty string when VALUE is nil."
  (if (and value (not (string-empty-p value)))
      (format " %s=\"%s\"" name (pretty-view-escape-attribute value))
    ""))

(defun pretty-view-render--align-style (align)
  "Return a `style' attribute for ALIGN, or an empty string."
  (if align (format " style=\"text-align:%s\"" align) ""))

(defun pretty-view-render-heading (node render)
  "Render heading NODE using RENDER for its children."
  (let ((level (plist-get node :level)))
    (format "<h%d%s>%s</h%d>\n" level
            (pretty-view-render--attr "id" (plist-get node :id))
            (funcall render (plist-get node :children))
            level)))

(defun pretty-view-render-paragraph (node render)
  "Render paragraph NODE using RENDER for its children."
  (format "<p>%s</p>\n" (funcall render (plist-get node :children))))

(defun pretty-view-render-code-block (node _render)
  "Render code block NODE."
  (let ((lang (plist-get node :lang)))
    (format "<pre class=\"pv-code\"><code%s>%s</code></pre>\n"
            (if lang (format " class=\"language-%s\""
                             (pretty-view-escape-attribute lang)) "")
            (pretty-view-render-fontified-code (plist-get node :code) lang))))

(defun pretty-view-render-list (node render)
  "Render list NODE using RENDER for its items."
  (let ((ordered (plist-get node :ordered))
        (start (plist-get node :start)))
    (format "<%s%s>\n%s</%s>\n"
            (if ordered "ol" "ul")
            (if (and ordered start (/= start 1))
                (format " start=\"%d\"" start) "")
            (funcall render (plist-get node :children))
            (if ordered "ol" "ul"))))

(defun pretty-view-render--item-body (node render)
  "Render the children of list item NODE using RENDER.
A single paragraph is unwrapped so tight lists read as one line."
  (let ((kids (plist-get node :children)))
    (if (and (= (length kids) 1)
             (eq (plist-get (car kids) :type) 'paragraph))
        (funcall render (plist-get (car kids) :children))
      (concat "\n" (funcall render kids)))))

(defun pretty-view-render-list-item (node render)
  "Render list item NODE using RENDER for its children."
  (format "<li>%s</li>\n" (pretty-view-render--item-body node render)))

(defun pretty-view-render-task-item (node render)
  "Render task list item NODE using RENDER for its children."
  (format "<li class=\"pv-task\"><input type=\"checkbox\" disabled%s /> %s</li>\n"
          (if (plist-get node :checked) " checked" "")
          (pretty-view-render--item-body node render)))

(defun pretty-view-render-blockquote (node render)
  "Render block quote NODE using RENDER for its children."
  (format "<blockquote>\n%s</blockquote>\n"
          (funcall render (plist-get node :children))))

(defun pretty-view-render-table (node render)
  "Render table NODE using RENDER for its rows."
  (let* ((rows (plist-get node :children))
         (head (seq-filter (lambda (r) (plist-get r :header)) rows))
         (body (seq-remove (lambda (r) (plist-get r :header)) rows)))
    (format "<table class=\"pv-table\">\n%s%s</table>\n"
            (if head (format "<thead>\n%s</thead>\n" (funcall render head)) "")
            (if body (format "<tbody>\n%s</tbody>\n" (funcall render body)) ""))))

(defun pretty-view-render-table-row (node render)
  "Render table row NODE using RENDER for its cells."
  (format "<tr>%s</tr>\n" (funcall render (plist-get node :children))))

(defun pretty-view-render-table-cell (node render)
  "Render table cell NODE using RENDER for its children."
  (let ((tag (if (plist-get node :header) "th" "td")))
    (format "<%s%s>%s</%s>" tag
            (pretty-view-render--align-style (plist-get node :align))
            (funcall render (plist-get node :children))
            tag)))

(defun pretty-view-render-link (node render)
  "Render link NODE using RENDER for its children."
  (format "<a href=\"%s\"%s>%s</a>"
          (pretty-view-escape-attribute (plist-get node :href))
          (pretty-view-render--attr "title" (plist-get node :title))
          (funcall render (plist-get node :children))))

(defun pretty-view-render-image (node _render)
  "Render image NODE."
  (format "<img src=\"%s\" alt=\"%s\"%s />"
          (pretty-view-escape-attribute (plist-get node :src))
          (pretty-view-escape-attribute (or (plist-get node :alt) ""))
          (pretty-view-render--attr "title" (plist-get node :title))))

(defun pretty-view-render-footnote-reference (node _render)
  "Render footnote reference NODE."
  (let ((label (pretty-view-escape-attribute (plist-get node :label))))
    (format
     "<sup class=\"pv-fnref\" id=\"fnref-%s\"><a href=\"#fn-%s\">%s</a></sup>"
     label label (pretty-view-escape-html (plist-get node :label)))))

(defun pretty-view-render-footnote-definition (node render)
  "Render footnote definition NODE using RENDER for its children."
  (let ((label (pretty-view-escape-attribute (plist-get node :label))))
    (format
     "<div class=\"pv-footnote\" id=\"fn-%s\"><sup>%s</sup> %s<a class=\"pv-fnback\" href=\"#fnref-%s\">↩</a></div>\n"
     label (pretty-view-escape-html (plist-get node :label))
     (funcall render (plist-get node :children)) label)))

(defun pretty-view-render-raw-html (node _render)
  "Render raw HTML NODE, honouring `pretty-view-allow-raw-html'."
  (let ((html (or (plist-get node :html) "")))
    (if pretty-view-allow-raw-html
        html
      (pretty-view-escape-html html))))

(defun pretty-view-render-container (node render)
  "Render NODE by rendering its children with RENDER and nothing else."
  (funcall render (plist-get node :children)))

(defun pretty-view-render-text (node _render)
  "Render text NODE as escaped HTML."
  (pretty-view-escape-html (plist-get node :value)))

(defun pretty-view-render-emphasis (node render)
  "Render emphasis NODE using RENDER for its children."
  (format "<em>%s</em>" (funcall render (plist-get node :children))))

(defun pretty-view-render-strong (node render)
  "Render strong NODE using RENDER for its children."
  (format "<strong>%s</strong>" (funcall render (plist-get node :children))))

(defun pretty-view-render-strikethrough (node render)
  "Render strikethrough NODE using RENDER for its children."
  (format "<del>%s</del>" (funcall render (plist-get node :children))))

(defun pretty-view-render-code-span (node _render)
  "Render inline code NODE."
  (format "<code>%s</code>"
          (pretty-view-escape-html (plist-get node :code))))

(defun pretty-view-render-thematic-break (_node _render)
  "Render a thematic break."
  "<hr />\n")

(defun pretty-view-render-line-break (_node _render)
  "Render a hard line break."
  "<br />\n")

(defun pretty-view-render-soft-break (_node _render)
  "Render a soft line break as a newline in the source."
  "\n")

(defcustom pretty-view-renderers
  '((document    . pretty-view-render-container)
    (heading     . pretty-view-render-heading)
    (paragraph   . pretty-view-render-paragraph)
    (code-block  . pretty-view-render-code-block)
    (blockquote  . pretty-view-render-blockquote)
    (list        . pretty-view-render-list)
    (list-item   . pretty-view-render-list-item)
    (task-item   . pretty-view-render-task-item)
    (table       . pretty-view-render-table)
    (table-row   . pretty-view-render-table-row)
    (table-cell  . pretty-view-render-table-cell)
    (thematic-break . pretty-view-render-thematic-break)
    (html-block  . pretty-view-render-raw-html)
    (html-inline . pretty-view-render-raw-html)
    (footnote-definition . pretty-view-render-footnote-definition)
    (footnote-reference  . pretty-view-render-footnote-reference)
    (text        . pretty-view-render-text)
    (emphasis    . pretty-view-render-emphasis)
    (strong      . pretty-view-render-strong)
    (strikethrough . pretty-view-render-strikethrough)
    (code-span   . pretty-view-render-code-span)
    (link        . pretty-view-render-link)
    (autolink    . pretty-view-render-link)
    (image       . pretty-view-render-image)
    (line-break  . pretty-view-render-line-break)
    (soft-break  . pretty-view-render-soft-break))
  "Map an AST node type to the function that renders it.
Each function is called as (FN NODE RENDER), where RENDER takes a list
of nodes and returns their concatenated HTML, and returns an HTML
string.  A function that signals falls back to the built-in renderer
for that node type and logs a warning."
  :type '(alist :key-type symbol :value-type function)
  :group 'pretty-view)

(defvar pretty-view-render--builtin-renderers
  (copy-alist pretty-view-renderers)
  "The renderer table as shipped, used as the fallback for a broken override.")

(defun pretty-view-render-nodes (nodes)
  "Return the concatenated HTML of NODES."
  (mapconcat #'pretty-view-render-node nodes ""))

(defun pretty-view-render-node (node)
  "Return the HTML for NODE, dispatching through `pretty-view-renderers'."
  (let* ((type (plist-get node :type))
         (fn (cdr (assq type pretty-view-renderers))))
    (cond
     ((null fn)
      ;; An unknown type still renders its children, so a user-added node
      ;; type degrades to its content rather than vanishing.
      (pretty-view-render-nodes (plist-get node :children)))
     (t
      (condition-case err
          (funcall fn node #'pretty-view-render-nodes)
        (error
         (display-warning
          'pretty-view
          (format "renderer for `%s' signalled: %s; using the built-in"
                  type (error-message-string err))
          :warning)
         (let ((builtin (cdr (assq type pretty-view-render--builtin-renderers))))
           (if builtin
               (funcall builtin node #'pretty-view-render-nodes)
             (pretty-view-render-nodes (plist-get node :children))))))))))

(defun pretty-view-render-document (node)
  "Return the HTML body for document NODE."
  (pretty-view-render-node node))

(provide 'pretty-view-render)
;;; pretty-view-render.el ends here
