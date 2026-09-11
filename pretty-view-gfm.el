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

(defun pretty-view-gfm--paragraph-end (lines)
  "Return the number of leading LINES belonging to one paragraph.
Stops before a blank line or a construct that interrupts a paragraph."
  (let ((n 0) (stop nil))
    (while (and (not stop) (< n (length lines)))
      (let ((line (nth n lines)))
        (if (and (> n 0)
                 (or (pretty-view-gfm--blank-p line)
                     (string-match-p pretty-view-gfm--thematic-break-re line)
                     (string-match-p pretty-view-gfm--atx-re line)))
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
