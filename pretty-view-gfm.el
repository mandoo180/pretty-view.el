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

(require 'cl-lib)
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

(defconst pretty-view-gfm--quote-re "\\` \\{0,3\\}> ?"
  "Match a block quote marker at the start of a line.")

(defconst pretty-view-gfm--list-item-re
  "\\`\\( \\{0,3\\}\\)\\([-*+]\\|\\([0-9]\\{1,9\\}\\)[.)]\\)\\(?:[ \t]+\\(.*\\)\\|[ \t]*\\'\\)"
  "Match a list item marker.
Group 1 is the indentation, group 2 the marker, group 3 the ordinal for
an ordered item, group 4 the first line of content.")

(defconst pretty-view-gfm--task-re "\\`\\[\\([ xX]\\)\\][ \t]+\\(.*\\)\\'"
  "Match a GFM task list marker at the start of item content.")

(defconst pretty-view-gfm--html-block-re
  "\\` \\{0,3\\}\\(?:<\\(?:script\\|pre\\|style\\)\\(?:[ \t>]\\|$\\)\\|<!--\\|<\\?\\|<!\\(?:[A-Z]\\|>\\)\\|<!\\[CDATA\\[\\|</?[a-zA-Z][a-zA-Z0-9-]*\\(?:[ \t].*\\)?[ \t]*>[ \t]*$\\)"
  "Match a line that opens an HTML block.")

(defconst pretty-view-gfm--link-def-re
  "\\` \\{0,3\\}\\[\\([^]^][^]]*\\|\\)\\][ \t]*:[ \t]*\\(\\S-+\\)\\(?:[ \t]+[\"'(]\\(.*?\\)[\"')]\\)?[ \t]*\\'"
  "Match a link reference definition.
Group 1 is the label, group 2 the destination, group 3 the title.")

(defconst pretty-view-gfm--footnote-def-re
  "\\` \\{0,3\\}\\[\\^\\([^]]+\\)\\][ \t]*:[ \t]*\\(.*\\)\\'"
  "Match a footnote definition.  Group 1 is the label, group 2 the text.")

(defvar pretty-view-gfm--link-refs nil
  "Hash table of link reference definitions for the document being parsed.
Maps a downcased label to a cons of href and title.  Bound by
`pretty-view-gfm-parse'.")

(defun pretty-view-gfm-link-ref (label)
  "Return the definition for LABEL as a cons of href and title, or nil."
  (and pretty-view-gfm--link-refs
       (gethash (downcase (string-trim label)) pretty-view-gfm--link-refs)))

(defun pretty-view-gfm--dedent (line width)
  "Return LINE with up to WIDTH columns of leading whitespace removed.
A tab counts as four columns, so an indentation written with tabs is
stripped the same as one written with spaces."
  (let ((i 0) (used 0))
    (while (and (< used width)
                (< i (length line))
                (memq (aref line i) '(?\s ?\t)))
      (setq used (+ used (if (eq (aref line i) ?\t) 4 1)))
      (setq i (1+ i)))
    (substring line i)))

(defun pretty-view-gfm--close-fence-p (line fence)
  "Return non-nil when LINE closes a block opened by FENCE."
  (let ((char (aref fence 0)))
    (string-match-p
     (format "\\` \\{0,3\\}%c\\{%d,\\}[ \t]*\\'"
             char (length fence))
     line)))

(defun pretty-view-gfm--take-blockquote (lines)
  "Consume a block quote from LINES.
Return a cons of the node and the remaining lines."
  (let ((body nil) (rest lines))
    (while (and rest
                (or (string-match-p pretty-view-gfm--quote-re (car rest))
                    ;; Lazy continuation: an unmarked, non-blank line that does
                    ;; not start a new block continues the quoted paragraph.
                    (and body (not (pretty-view-gfm--blank-p (car rest)))
                         (not (pretty-view-gfm--block-start-p (car rest))))))
      (push (replace-regexp-in-string pretty-view-gfm--quote-re "" (car rest))
            body)
      (setq rest (cdr rest)))
    (cons (list :type 'blockquote
                :children (pretty-view-gfm--parse-blocks (nreverse body)))
          rest)))

(defun pretty-view-gfm--list-ordered-p (line)
  "Return non-nil when LINE opens an ordered list item."
  (and (string-match pretty-view-gfm--list-item-re line)
       (match-string 3 line)
       t))

(defun pretty-view-gfm--item-node (body)
  "Build a list-item or task-item node from BODY, a list of lines."
  (let ((first (or (car body) "")))
    (if (string-match pretty-view-gfm--task-re first)
        (list :type 'task-item
              :checked (not (equal (match-string 1 first) " "))
              :children (pretty-view-gfm--parse-blocks
                         (cons (match-string 2 first) (cdr body))))
      (list :type 'list-item
            :children (pretty-view-gfm--parse-blocks body)))))

(defun pretty-view-gfm--take-list (lines)
  "Consume one list from LINES.
Return a cons of the node and the remaining lines.  A list ends at the
first line that is neither a sibling marker, an indented continuation,
nor a blank line followed by more of the same list."
  (let* ((ordered (pretty-view-gfm--list-ordered-p (car lines)))
         (start (if ordered (string-to-number (match-string 3 (car lines))) 1))
         (first-indent (length (match-string 1 (car lines))))
         (items nil) (body nil) (rest lines) (tight t) (pending-blank nil)
         (done nil))
    (while (and rest (not done))
      (let ((line (car rest)))
        (cond
         ((pretty-view-gfm--blank-p line)
          (setq pending-blank t)
          (setq rest (cdr rest)))
         ;; A sibling marker at the same nesting level starts a new item.
         ((and (string-match pretty-view-gfm--list-item-re line)
               (= (length (match-string 1 line)) first-indent)
               (eq (and (match-string 3 line) t) (and ordered t)))
          (let ((content (or (match-string 4 line) "")))
            (when body
              (push (pretty-view-gfm--item-node (nreverse body)) items)
              (when pending-blank (setq tight nil)))
            (setq body (list content)))
          (setq pending-blank nil)
          (setq rest (cdr rest)))
         ;; An indented line continues the current item.
         ((and body (string-match-p "\\`\\(  \\| \\{4\\}\\|\t\\)" line))
          (when pending-blank
            (setq tight nil)
            (push "" body)
            (setq pending-blank nil))
          (push (pretty-view-gfm--dedent line 2) body)
          (setq rest (cdr rest)))
         ;; Lazy continuation of the item's paragraph.
         ((and body (not pending-blank) (not (pretty-view-gfm--block-start-p line)))
          (push line body)
          (setq rest (cdr rest)))
         (t (setq done t)))))
    (when body
      (push (pretty-view-gfm--item-node (nreverse body)) items))
    (cons (list :type 'list :ordered ordered :start start :tight tight
                :children (nreverse items))
          ;; A blank line that ended the list is not part of it.
          rest)))

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

(defconst pretty-view-gfm--table-delimiter-re
  "\\` \\{0,3\\}|?[ \t]*:?-+:?[ \t]*\\(|[ \t]*:?-+:?[ \t]*\\)*|?[ \t]*\\'"
  "Match a GFM table delimiter row.")

(defun pretty-view-gfm--split-row (line)
  "Split LINE into raw cell strings on unescaped pipes."
  (let ((cells nil) (cur "") (i 0) (n (length line)))
    (while (< i n)
      (let ((c (aref line i)))
        (cond
         ((and (eq c ?\\) (< (1+ i) n) (eq (aref line (1+ i)) ?|))
          (setq cur (concat cur "|"))
          (setq i (+ i 2)))
         ((eq c ?|)
          (push cur cells)
          (setq cur "")
          (setq i (1+ i)))
         (t (setq cur (concat cur (string c)))
            (setq i (1+ i))))))
    (push cur cells)
    (setq cells (mapcar #'string-trim (nreverse cells)))
    ;; Drop the empty strings produced by leading and trailing pipes.
    (when (and cells (string-empty-p (car cells)))
      (setq cells (cdr cells)))
    (when (and cells (string-empty-p (car (last cells))))
      (setq cells (butlast cells)))
    cells))

(defun pretty-view-gfm--table-align (delimiter-line)
  "Return the alignment list encoded in DELIMITER-LINE."
  (mapcar (lambda (spec)
            (let ((l (string-prefix-p ":" spec))
                  (r (string-suffix-p ":" spec)))
              (cond ((and l r) 'center) (l 'left) (r 'right) (t nil))))
          (pretty-view-gfm--split-row delimiter-line)))

(defun pretty-view-gfm--table-row (line align header)
  "Build a table-row node from LINE using ALIGN.
HEADER is non-nil for the header row."
  (let ((cells (pretty-view-gfm--split-row line)) (i -1))
    (list :type 'table-row :header header
          :children (mapcar (lambda (raw)
                              (setq i (1+ i))
                              (list :type 'table-cell :header header
                                    :align (nth i align) :raw raw))
                            cells))))

(defun pretty-view-gfm--table-start-p (lines)
  "Return non-nil when LINES opens a GFM pipe table."
  (and (cdr lines)
       (string-match-p "|" (car lines))
       (string-match-p pretty-view-gfm--table-delimiter-re (nth 1 lines))))

(defun pretty-view-gfm--take-table (lines)
  "Consume a table from LINES.
Return a cons of the node and the remaining lines."
  (let* ((align (pretty-view-gfm--table-align (nth 1 lines)))
         (rows (list (pretty-view-gfm--table-row (car lines) align t)))
         (rest (nthcdr 2 lines)))
    (while (and rest
                (not (pretty-view-gfm--blank-p (car rest)))
                (string-match-p "|" (car rest)))
      (push (pretty-view-gfm--table-row (car rest) align nil) rows)
      (setq rest (cdr rest)))
    (cons (list :type 'table :align align :children (nreverse rows))
          rest)))

(defun pretty-view-gfm--take-html-block (lines)
  "Consume an HTML block from LINES.
Return a cons of the node and the remaining lines."
  (let ((body nil) (rest lines))
    (while (and rest (not (pretty-view-gfm--blank-p (car rest))))
      (push (car rest) body)
      (setq rest (cdr rest)))
    (cons (list :type 'html-block :html (string-join (nreverse body) "\n"))
          rest)))

(defun pretty-view-gfm--take-footnote (lines)
  "Consume a footnote definition from LINES.
Return a cons of the node and the remaining lines."
  (string-match pretty-view-gfm--footnote-def-re (car lines))
  (let ((label (match-string 1 (car lines)))
        (body (list (match-string 2 (car lines))))
        (rest (cdr lines)))
    ;; Indented lines continue the note.
    (while (and rest (string-match-p "\\`\\(    \\|\t\\)" (car rest)))
      (push (pretty-view-gfm--dedent (car rest) 4) body)
      (setq rest (cdr rest)))
    (cons (list :type 'footnote-definition :label label
                :children (pretty-view-gfm--parse-blocks (nreverse body)))
          rest)))

(defun pretty-view-gfm--block-start-p (line)
  "Return non-nil when LINE begins a new block.
A line starts a block if it matches thematic break, ATX heading,
fence, list item, block quote, HTML block, footnote definition, or
link reference definition patterns."
  (or (string-match-p pretty-view-gfm--thematic-break-re line)
      (string-match-p pretty-view-gfm--atx-re line)
      (string-match-p pretty-view-gfm--fence-re line)
      (string-match-p pretty-view-gfm--list-item-re line)
      (string-match-p pretty-view-gfm--quote-re line)
      (string-match-p pretty-view-gfm--footnote-def-re line)
      (string-match-p pretty-view-gfm--link-def-re line)
      (string-match-p pretty-view-gfm--html-block-re line)))

(defun pretty-view-gfm--paragraph-end (lines)
  "Return the number of leading LINES belonging to one paragraph.
Stops before a blank line or a construct that interrupts a paragraph."
  (let ((n 0) (stop nil))
    (while (and (not stop) (< n (length lines)))
      (let ((line (nth n lines)))
        (if (and (> n 0)
                 (or (pretty-view-gfm--blank-p line)
                     (pretty-view-gfm--block-start-p line)
                     (pretty-view-gfm--table-start-p (nthcdr n lines))))
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
         ;; Block quote.
         ((string-match-p pretty-view-gfm--quote-re line)
          (let ((result (pretty-view-gfm--take-blockquote lines)))
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
               (not (pretty-view-gfm--blank-p line))
               (not (pretty-view-gfm--block-start-p line)))
          (push (pretty-view-gfm--heading
                 (if (string-prefix-p "=" (string-trim (nth 1 lines))) 1 2)
                 (string-trim line))
                nodes)
          (setq lines (nthcdr 2 lines)))
         ;; List.
         ((and (string-match-p pretty-view-gfm--list-item-re line)
               (not (string-match-p pretty-view-gfm--thematic-break-re line)))
          (let ((result (pretty-view-gfm--take-list lines)))
            (push (car result) nodes)
            (setq lines (cdr result))))
         ;; Indented code block.  Only when not continuing a paragraph,
         ;; which the paragraph clause has already consumed.
         ((string-prefix-p "    " line)
          (let ((result (pretty-view-gfm--take-indented lines)))
            (push (car result) nodes)
            (setq lines (cdr result))))
         ;; GFM pipe table.
         ((pretty-view-gfm--table-start-p lines)
          (let ((result (pretty-view-gfm--take-table lines)))
            (push (car result) nodes)
            (setq lines (cdr result))))
         ;; Footnote definition.
         ((string-match-p pretty-view-gfm--footnote-def-re line)
          (let ((result (pretty-view-gfm--take-footnote lines)))
            (push (car result) nodes)
            (setq lines (cdr result))))
         ;; Link reference definition: recorded, never rendered.
         ((string-match pretty-view-gfm--link-def-re line)
          (when pretty-view-gfm--link-refs
            (puthash (downcase (match-string 1 line))
                     (cons (match-string 2 line) (match-string 3 line))
                     pretty-view-gfm--link-refs))
          (setq lines (cdr lines)))
         ;; HTML block.
         ((string-match-p pretty-view-gfm--html-block-re line)
          (let ((result (pretty-view-gfm--take-html-block lines)))
            (push (car result) nodes)
            (setq lines (cdr result))))
         ;; Paragraph.
         (t
          (let* ((n (pretty-view-gfm--paragraph-end lines))
                 (text (string-join (seq-take lines n) "\n")))
            (push (list :type 'paragraph :raw (string-trim text)) nodes)
            (setq lines (nthcdr n lines)))))))
    (nreverse nodes)))

(defconst pretty-view-gfm--escapable "[]!\"#$%&'()*+,./:;<=>?@\\^_`{|}~-"
  "Characters a backslash may escape.")

(defun pretty-view-gfm--text (value)
  "Return a text node holding VALUE, or nil when VALUE is empty."
  (unless (string-empty-p value)
    (list :type 'text :value value)))

(defun pretty-view-gfm--code-span-at (string pos)
  "Try to read a code span in STRING starting at POS.
Return a cons of the node and the position after it, or nil."
  (let* ((n (length string))
         (open pos))
    (while (and (< open n) (eq (aref string open) ?`))
      (setq open (1+ open)))
    (let* ((width (- open pos))
           (fence (make-string width ?`))
           (close (string-search fence string open)))
      ;; The closing run must be exactly as long as the opening one.
      (while (and close
                  (< (+ close width) n)
                  (eq (aref string (+ close width)) ?`))
        (setq close (string-search fence string (1+ close))))
      (when close
        (let ((code (substring string open close)))
          ;; Strip one leading and trailing space when both are present
          ;; and the content is not all spaces.
          (when (and (> (length code) 1)
                     (string-prefix-p " " code)
                     (string-suffix-p " " code)
                     (not (string-match-p "\\`[ ]+\\'" code)))
            (setq code (substring code 1 -1)))
          (cons (list :type 'code-span :code code) (+ close width)))))))

(defconst pretty-view-gfm--autolink-re
  "\\`<\\([a-zA-Z][a-zA-Z0-9+.-]\\{1,31\\}:[^<> \t]*\\)>"
  "Match an angle-bracket autolink.")

(defconst pretty-view-gfm--bare-url-re
  "\\`\\(https?://[^ \t\n<>\"]+\\)"
  "Match a bare URL for GFM autolinking.")

(defconst pretty-view-gfm--html-inline-re
  "\\`\\(</?[a-zA-Z][a-zA-Z0-9-]*\\(?:[ \t][^<>]*\\)?/?>\\|<!--.*?-->\\)"
  "Match an inline HTML tag or comment.")

(defun pretty-view-gfm--matching-bracket (string start)
  "Return the index of the `]' closing the `[' at START in STRING, or nil."
  (let ((depth 0) (i start) (n (length string)) (found nil))
    (while (and (< i n) (not found))
      (let ((c (aref string i)))
        (cond
         ((eq c ?\\) (setq i (1+ i)))
         ((eq c ?\[) (setq depth (1+ depth)))
         ((eq c ?\]) (setq depth (1- depth))
          (when (zerop depth) (setq found i)))))
      (setq i (1+ i)))
    found))

(defun pretty-view-gfm--read-destination (string start)
  "Read a link destination and title from STRING at START.
START must point at the opening parenthesis.  Return a list of href,
title, and the position after the closing parenthesis, or nil."
  (when (and (< start (length string)) (eq (aref string start) ?\())
    (let ((sub (substring string start)))
      (when (string-match
             "\\`(\\([ \t]*\\)\\(?:<\\([^>]*\\)>\\|\\([^ \t)]*\\)\\)\\(?:[ \t]+[\"']\\(.*?\\)[\"']\\)?[ \t]*)"
             sub)
        (list (or (match-string 2 sub) (match-string 3 sub) "")
              (match-string 4 sub)
              (+ start (match-end 0)))))))

(defun pretty-view-gfm--read-label (string start)
  "Read a reference label from STRING at START.
START must point at `['.  Return a cons of the label text and the
position after `]', or nil."
  (when (and (< start (length string)) (eq (aref string start) ?\[))
    (when-let* ((close (pretty-view-gfm--matching-bracket string start)))
      (cons (substring string (1+ start) close) (1+ close)))))

(defun pretty-view-gfm--link-at (string pos image)
  "Try to read a link, or an image when IMAGE is non-nil, at POS in STRING.
Return a cons of the node and the position after it, or nil."
  (let* ((open (if image (1+ pos) pos))
         (close (pretty-view-gfm--matching-bracket string open)))
    (when close
      (let* ((text (substring string (1+ open) close))
             (after (1+ close))
             (inline (pretty-view-gfm--read-destination string after))
             (href nil) (title nil) (end nil))
        (cond
         (inline
          (setq href (nth 0 inline) title (nth 1 inline) end (nth 2 inline)))
         ;; Full or collapsed reference: [text][label] or [text][].
         ((when-let* ((lab (pretty-view-gfm--read-label string after)))
            (let* ((label (if (string-empty-p (car lab)) text (car lab)))
                   (def (pretty-view-gfm-link-ref label)))
              (when def
                (setq href (car def) title (cdr def) end (cdr lab))
                t))))
         ;; Shortcut reference: [label].
         ((when-let* ((def (pretty-view-gfm-link-ref text)))
            (setq href (car def) title (cdr def) end after)
            t)))
        (when href
          (cons (if image
                    (list :type 'image :src href :title title
                          :alt (pretty-view-gfm--plain-text text))
                  (list :type 'link :href href :title title
                        :children (pretty-view-gfm--parse-inlines text)))
                end))))))

(defun pretty-view-gfm--plain-text (string)
  "Return STRING with inline markup removed, for use as image alt text."
  (replace-regexp-in-string "[][*_`~]" "" string))

(defun pretty-view-gfm--trim-url-punctuation (url)
  "Trim trailing punctuation from URL per GFM autolink rules.
Strip trailing .,:;!? unconditionally.
Then drop trailing ) only while ) count exceeds ( count."
  ;; First, strip trailing run of sentence punctuation (no parens).
  (let ((trimmed (replace-regexp-in-string "[.,:;!?]+\\'" "" url)))
    ;; Then, drop trailing ) only when unbalanced.
    (while (and (string-suffix-p ")" trimmed)
                (> (seq-count (lambda (c) (eq c ?\))) trimmed)
                   (seq-count (lambda (c) (eq c ?\()) trimmed)))
      (setq trimmed (substring trimmed 0 -1)))
    trimmed))

(defun pretty-view-gfm--flanking (string start end)
  "Classify the delimiter run in STRING between START and END.
Return a cons of left-flanking and right-flanking booleans."
  (let* ((before (if (> start 0) (aref string (1- start)) ?\s))
         (after (if (< end (length string)) (aref string end) ?\s))
         (before-ws (memq before '(?\s ?\t ?\n)))
         (after-ws (memq after '(?\s ?\t ?\n)))
         (before-punct (and (not before-ws)
                            (string-match-p "[[:punct:]]" (string before))))
         (after-punct (and (not after-ws)
                           (string-match-p "[[:punct:]]" (string after)))))
    (cons
     ;; Left-flanking: not followed by whitespace, and either not
     ;; followed by punctuation or preceded by whitespace/punctuation.
     (and (not after-ws)
          (or (not after-punct) before-ws before-punct))
     ;; Right-flanking: the mirror image.
     (and (not before-ws)
          (or (not before-punct) after-ws after-punct)))))

(defun pretty-view-gfm--delimiter-at (string pos)
  "Read a delimiter run at POS in STRING.
Return a plist node of type `delimiter', or nil when POS holds none."
  (let ((c (aref string pos)))
    (when (memq c '(?* ?_ ?~))
      (let ((end pos))
        (while (and (< end (length string)) (eq (aref string end) c))
          (setq end (1+ end)))
        (let* ((count (- end pos))
               (flank (pretty-view-gfm--flanking string pos end))
               ;; Underscores do not open or close inside a word.
               (intraword (and (eq c ?_)
                               (car flank) (cdr flank))))
          (list :type 'delimiter :char c :count count
                :can-open (and (car flank) (not intraword))
                :can-close (and (cdr flank) (not intraword))
                :value (make-string count c)
                :end end))))))

(defun pretty-view-gfm--consume-delimiter (nodes index count)
  "Remove COUNT characters from the delimiter at INDEX in NODES.
Clears the slot when nothing is left."
  (let* ((node (aref nodes index))
         (left (- (plist-get node :count) count)))
    (if (<= left 0)
        (aset nodes index nil)
      (aset nodes index
            (plist-put (plist-put (copy-sequence node) :count left)
                       :value (make-string left (plist-get node :char)))))))

(defun pretty-view-gfm--match-delimiters (nodes)
  "Pair delimiter nodes in NODES into emphasis, strong, and strikethrough.
Unmatched delimiter nodes degrade to text."
  (let ((nodes (vconcat nodes)))
    (let ((closer 0))
      (while (< closer (length nodes))
        (let ((node (aref nodes closer)))
          (when (and node
                     (eq (plist-get node :type) 'delimiter)
                     (plist-get node :can-close))
            (let ((opener (1- closer)) (found nil))
              (while (and (>= opener 0) (not found))
                (let ((cand (aref nodes opener)))
                  (when (and cand
                             (eq (plist-get cand :type) 'delimiter)
                             (plist-get cand :can-open)
                             (eq (plist-get cand :char) (plist-get node :char)))
                    (setq found opener)))
                (setq opener (1- opener)))
              (when found
                (let* ((char (plist-get node :char))
                       (closer-count (plist-get node :count))
                       (opener-count (plist-get (aref nodes found) :count))
                       (use (cond
                             ;; Strikethrough: must have at least 2 from each
                             ((eq char ?~)
                              (if (and (>= closer-count 2) (>= opener-count 2)) 2 0))
                             ;; Emphasis/strong: match only if counts align
                             ;; Strong: both must have >= 2
                             ;; Emphasis: both must have == 1
                             ((and (>= closer-count 2) (>= opener-count 2))
                              2)
                             ((and (= closer-count 1) (= opener-count 1))
                              1)
                             (t 0))))
                  (when (> use 0)
                    (let ((type (cond ((eq char ?~) 'strikethrough)
                                      ((= use 2) 'strong)
                                      (t 'emphasis)))
                          (inner nil)
                          (opener-fully-consumed nil))
                      (let ((k (1+ found)))
                        (while (< k closer)
                          (when (aref nodes k) (push (aref nodes k) inner))
                          (aset nodes k nil)
                          (setq k (1+ k))))
                      ;; Check if opener will be fully consumed.
                      (let ((opener-count (plist-get (aref nodes found) :count)))
                        (setq opener-fully-consumed (= opener-count use)))
                      (pretty-view-gfm--consume-delimiter nodes found use)
                      (pretty-view-gfm--consume-delimiter nodes closer use)
                      ;; Place the emphasis node:
                      ;; - If opener was fully consumed, put it at found
                      ;; - If opener has a remainder, put it at found+1
                      ;;   (the leftover delimiter stays at found and can match again)
                      (let ((target-slot (if opener-fully-consumed found (1+ found))))
                        (aset nodes target-slot
                              (list :type type :children (nreverse inner))))
                      ;; Re-examine this position: a partly consumed
                      ;; closer may still close another opener.
                      (setq closer (1- closer)))))))))
        (setq closer (1+ closer))))
    ;; Whatever delimiters remain become literal text.
    (seq-filter
     #'identity
     (mapcar (lambda (node)
               (if (and node (eq (plist-get node :type) 'delimiter))
                   (pretty-view-gfm--text (plist-get node :value))
                 node))
             (append nodes nil)))))

(defun pretty-view-gfm--parse-inlines (string)
  "Parse STRING into a list of inline nodes."
  (let ((nodes nil) (buf "") (i 0) (n (length string)))
    (cl-flet ((flush ()
                (when-let* ((node (pretty-view-gfm--text buf)))
                  (push node nodes))
                (setq buf "")))
      (while (< i n)
        (let ((c (aref string i)))
          (cond
           ;; Backslash escape, or a hard break at end of line.
           ((eq c ?\\)
            (cond
             ((and (< (1+ i) n) (eq (aref string (1+ i)) ?\n))
              (flush)
              (push (list :type 'line-break) nodes)
              (setq i (+ i 2)))
             ((and (< (1+ i) n)
                   (string-search (string (aref string (1+ i)))
                                  pretty-view-gfm--escapable))
              (setq buf (concat buf (string (aref string (1+ i)))))
              (setq i (+ i 2)))
             (t (setq buf (concat buf "\\"))
                (setq i (1+ i)))))
           ;; Code span.
           ((eq c ?`)
            (let ((result (pretty-view-gfm--code-span-at string i)))
              (if result
                  (progn (flush)
                         (push (car result) nodes)
                         (setq i (cdr result)))
                (setq buf (concat buf "`"))
                (setq i (1+ i)))))
           ;; Image.
           ((and (eq c ?!) (< (1+ i) n) (eq (aref string (1+ i)) ?\[)
                 (pretty-view-gfm--link-at string i t))
            (let ((result (pretty-view-gfm--link-at string i t)))
              (flush)
              (push (car result) nodes)
              (setq i (cdr result))))
           ;; Footnote reference.
           ((and (eq c ?\[) (< (1+ i) n) (eq (aref string (1+ i)) ?^)
                 (string-match "\\`\\[\\^\\([^]]+\\)\\]" (substring string i)))
            (let ((sub (substring string i)))
              (string-match "\\`\\[\\^\\([^]]+\\)\\]" sub)
              (flush)
              (push (list :type 'footnote-reference
                          :label (match-string 1 sub))
                    nodes)
              (setq i (+ i (match-end 0)))))
           ;; Link, inline or reference.
           ((and (eq c ?\[) (pretty-view-gfm--link-at string i nil))
            (let ((result (pretty-view-gfm--link-at string i nil)))
              (flush)
              (push (car result) nodes)
              (setq i (cdr result))))
           ;; Angle autolink, then inline HTML.
           ((eq c ?<)
            (let ((sub (substring string i)))
              (cond
               ((string-match pretty-view-gfm--autolink-re sub)
                (flush)
                (push (list :type 'autolink :href (match-string 1 sub)
                            :children (list (list :type 'text
                                                  :value (match-string 1 sub))))
                      nodes)
                (setq i (+ i (match-end 0))))
               ((string-match pretty-view-gfm--html-inline-re sub)
                (flush)
                (push (list :type 'html-inline :html (match-string 1 sub))
                      nodes)
                (setq i (+ i (match-end 0))))
               (t (setq buf (concat buf "<"))
                  (setq i (1+ i))))))
           ;; Bare URL autolink.
           ((and (memq c '(?h))
                 (string-match pretty-view-gfm--bare-url-re
                               (substring string i)))
            (let* ((sub (substring string i))
                   (url (progn (string-match pretty-view-gfm--bare-url-re sub)
                               (match-string 1 sub)))
                   (url (pretty-view-gfm--trim-url-punctuation url)))
              (flush)
              (push (list :type 'autolink :href url
                          :children (list (list :type 'text :value url)))
                    nodes)
              (setq i (+ i (length url)))))
           ;; Emphasis, strong, strikethrough delimiter run.
           ((and (memq c '(?* ?_ ?~))
                 (pretty-view-gfm--delimiter-at string i))
            (let ((node (pretty-view-gfm--delimiter-at string i)))
              (flush)
              (push node nodes)
              (setq i (plist-get node :end))))
           ;; Hard break: two or more trailing spaces before a newline.
           ((and (eq c ?\s)
                 (string-match "\\` \\{2,\\}\n" (substring string i)))
            (flush)
            (push (list :type 'line-break) nodes)
            (setq i (+ i (match-end 0))))
           ;; Soft break.
           ((eq c ?\n)
            (flush)
            (push (list :type 'soft-break) nodes)
            (setq i (1+ i)))
           (t (setq buf (concat buf (string c)))
              (setq i (1+ i))))))
      (flush))
    (pretty-view-gfm--match-delimiters (nreverse nodes))))

(defun pretty-view-gfm--resolve-inlines (nodes)
  "Return NODES with every `:raw' string replaced by parsed `:children'."
  (mapcar
   (lambda (node)
     (let ((node (copy-sequence node)))
       (when-let* ((raw (plist-get node :raw)))
         (setq node (plist-put node :children
                               (pretty-view-gfm--parse-inlines raw)))
         (setq node (plist-put node :raw nil)))
       (when-let* ((kids (plist-get node :children)))
         ;; Inline nodes produced just above have no `:raw' and recurse
         ;; harmlessly; block children are walked here.
         (setq node (plist-put node :children
                               (pretty-view-gfm--resolve-inlines kids))))
       node))
   nodes))

(defun pretty-view-gfm-parse (string)
  "Parse STRING as GitHub Flavored Markdown and return a document node."
  (setq pretty-view-gfm--link-refs (make-hash-table :test #'equal))
  (let* ((lines (split-string (string-trim-right string "\n") "\n"))
         (blocks (if (equal lines '(""))
                     nil
                   (pretty-view-gfm--parse-blocks lines))))
    (list :type 'document
          :children (pretty-view-gfm--resolve-inlines blocks))))

(provide 'pretty-view-gfm)
;;; pretty-view-gfm.el ends here
