;;; pretty-view-gfm.el --- GFM parser  -*- lexical-binding: t -*-

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

;; A GitHub Flavored Markdown parser producing a plist AST.  Two phases:
;; a line-oriented block scanner, then an inline pass over the `:raw'
;; strings the block scanner leaves behind.  The parser never signals;
;; unrecognized syntax becomes paragraph text, which is Markdown's own
;; fallback.

;;; Code:

(require 'subr-x)
(require 'seq)

(defconst pretty-view-gfm--thematic-break-re
  "\\` \\{0,3\\}\\([-*_]\\)[ \t]*\\(?:\\1[ \t]*\\)\\{2,\\}\\'"
  "Match a thematic break line.")

(defconst pretty-view-gfm--atx-re
  "\\` \\{0,3\\}\\(#\\{1,6\\}\\)\\(?:[ \t]+\\(.*?\\)\\)?[ \t]*\\'"
  "Match an ATX heading line.  Group 1 is the hashes, group 2 the text.")

(defconst pretty-view-gfm--setext-re
  "\\` \\{0,3\\}\\(=+\\|-+\\)[ \t]*\\'"
  "Match a setext heading underline.")

(defun pretty-view-gfm--blank-p (line)
  "Return non-nil when LINE contains only whitespace."
  (string-match-p "\\`[ \t]*\\'" line))

(defun pretty-view-gfm--slug (string)
  "Return an anchor id derived from STRING.
Lowercases, drops punctuation, and joins words with hyphens."
  (let* ((s (downcase (string-trim string)))
         (s (replace-regexp-in-string "[^[:alnum:][:nonascii:] _-]" "" s))
         (s (replace-regexp-in-string "[ _]+" "-" s))
         (s (replace-regexp-in-string "-+" "-" s)))
    (string-trim s "-" "-")))

(defun pretty-view-gfm--strip-atx-closing (text)
  "Return TEXT without a trailing ATX closing sequence."
  (string-trim (replace-regexp-in-string "[ \t]+#+[ \t]*\\'" "" text)))

(defconst pretty-view-gfm--fence-re
  "\\`\\( \\{0,3\\}\\)\\(`\\{3,\\}\\|~\\{3,\\}\\)[ \t]*\\(.*?\\)[ \t]*\\'"
  "Match an opening code fence.
Group 1 is the indentation, group 2 the fence, group 3 the info string.")

(defun pretty-view-gfm--dedent (line width)
  "Return LINE with up to WIDTH leading spaces removed."
  (let ((i 0))
    (while (and (< i width)
                (< i (length line))
                (eq (aref line i) ?\s))
      (setq i (1+ i)))
    (substring line i)))

(defun pretty-view-gfm--close-fence-p (line fence)
  "Return non-nil when LINE closes a block opened by FENCE."
  (let ((char (aref fence 0)))
    (string-match-p
     (format "\\` \\{0,3\\}%c\\{%d,\\}[ \t]*\\'"
             char (length fence))
     line)))

(defun pretty-view-gfm--take-fenced (lines)
  "Consume a fenced code block from LINES.
Return a cons of the node and the remaining lines."
  (string-match pretty-view-gfm--fence-re (car lines))
  (let* ((indent (length (match-string 1 (car lines))))
         (fence (match-string 2 (car lines)))
         (info (match-string 3 (car lines)))
         (lang (when (and info (not (string-empty-p info)))
                 (car (split-string info "[ \t]+" t))))
         (rest (cdr lines))
         (body nil))
    (while (and rest (not (pretty-view-gfm--close-fence-p (car rest) fence)))
      (push (pretty-view-gfm--dedent (car rest) indent) body)
      (setq rest (cdr rest)))
    (cons (list :type 'code-block :lang lang
                :code (if body
                          (concat (string-join (nreverse body) "\n") "\n")
                        ""))
          ;; Drop the closing fence when there is one.
          (if rest (cdr rest) nil))))

(defun pretty-view-gfm--take-indented (lines)
  "Consume an indented code block from LINES.
Return a cons of the node and the remaining lines."
  (let ((body nil) (rest lines) (pending nil))
    (while (and rest
                (or (string-prefix-p "    " (car rest))
                    (pretty-view-gfm--blank-p (car rest))))
      (if (pretty-view-gfm--blank-p (car rest))
          ;; Blank lines belong to the block only when code follows.
          (push "" pending)
        (setq body (append pending body))
        (setq pending nil)
        (push (substring (car rest) 4) body))
      (setq rest (cdr rest)))
    (cons (list :type 'code-block :lang nil
                :code (concat (string-join (nreverse body) "\n") "\n"))
          ;; Trailing blank lines go back to the caller.
          (nthcdr (- (length lines) (length rest) (length pending)) lines))))

(defun pretty-view-gfm--paragraph-end (lines)
  "Return the number of leading LINES belonging to one paragraph.
Stops before a blank line or a construct that interrupts a paragraph."
  (let ((n 0) (stop nil))
    (while (and (not stop) (< n (length lines)))
      (let ((line (nth n lines)))
        (if (and (> n 0)
                 (or (pretty-view-gfm--blank-p line)
                     (string-match-p pretty-view-gfm--thematic-break-re line)
                     (string-match-p pretty-view-gfm--atx-re line)
                     (string-match-p pretty-view-gfm--fence-re line)))
            (setq stop t)
          (if (pretty-view-gfm--blank-p line)
              (setq stop t)
            (setq n (1+ n))))))
    (max n 1)))

(defun pretty-view-gfm--heading (level text)
  "Return a heading node of LEVEL holding TEXT."
  (list :type 'heading :level level :raw text
        :id (pretty-view-gfm--slug text)))

(defun pretty-view-gfm--parse-blocks (lines)
  "Parse LINES, a list of strings, into a list of block nodes."
  (let ((nodes nil))
    (while lines
      (let ((line (car lines)))
        (cond
         ;; Blank lines separate blocks and carry no content.
         ((pretty-view-gfm--blank-p line)
          (setq lines (cdr lines)))
         ;; Fenced code block.
         ((string-match-p pretty-view-gfm--fence-re line)
          (let ((result (pretty-view-gfm--take-fenced lines)))
            (push (car result) nodes)
            (setq lines (cdr result))))
         ;; Thematic break.
         ((string-match-p pretty-view-gfm--thematic-break-re line)
          (push (list :type 'thematic-break) nodes)
          (setq lines (cdr lines)))
         ;; ATX heading.
         ((string-match pretty-view-gfm--atx-re line)
          (let ((level (length (match-string 1 line)))
                (text (or (match-string 2 line) "")))
            (push (pretty-view-gfm--heading
                   level (pretty-view-gfm--strip-atx-closing text))
                  nodes))
          (setq lines (cdr lines)))
         ;; Setext heading: a paragraph followed by = or - underline.
         ((and (cdr lines)
               (string-match pretty-view-gfm--setext-re (nth 1 lines))
               (not (pretty-view-gfm--blank-p line)))
          (push (pretty-view-gfm--heading
                 (if (string-prefix-p "=" (string-trim (nth 1 lines))) 1 2)
                 (string-trim line))
                nodes)
          (setq lines (nthcdr 2 lines)))
         ;; Indented code block.  Only when not continuing a paragraph,
         ;; which the paragraph clause has already consumed.
         ((string-prefix-p "    " line)
          (let ((result (pretty-view-gfm--take-indented lines)))
            (push (car result) nodes)
            (setq lines (cdr result))))
         ;; Paragraph.
         (t
          (let* ((n (pretty-view-gfm--paragraph-end lines))
                 (text (string-join (seq-take lines n) "\n")))
            (push (list :type 'paragraph :raw (string-trim text)) nodes)
            (setq lines (nthcdr n lines)))))))
    (nreverse nodes)))

(defun pretty-view-gfm-parse (string)
  "Parse STRING as GitHub Flavored Markdown and return a document node."
  (let ((lines (split-string (string-trim-right string "\n") "\n")))
    (list :type 'document
          :children (if (equal lines '(""))
                        nil
                      (pretty-view-gfm--parse-blocks lines)))))

(provide 'pretty-view-gfm)
;;; pretty-view-gfm.el ends here
