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
A language with no entry falls back to `LANG-ts-mode', then
`LANG-mode', then no highlighting."
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
      (let* ((next (next-single-property-change pos 'face nil (point-max)))
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

(provide 'pretty-view-render)
;;; pretty-view-render.el ends here
