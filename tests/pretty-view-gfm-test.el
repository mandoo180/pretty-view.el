;;; pretty-view-gfm-test.el --- Tests for the GFM parser  -*- lexical-binding: t -*-

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
;; Block and inline parsing.  Assertions read specific fields; plist key
;; order is not part of the contract.
;;; Code:

(require 'ert)
(require 'pretty-view-gfm)
(require 'pretty-view-test-helper)

(ert-deftest pretty-view-gfm-test-atx-heading ()
  (let ((node (pv-test-block "## Hello world")))
    (should (eq (pv-test-type node) 'heading))
    (should (= (plist-get node :level) 2))
    (should (equal (pv-test-text node) "Hello world"))
    (should (equal (plist-get node :id) "hello-world"))))

(ert-deftest pretty-view-gfm-test-atx-heading-levels ()
  (should (= (plist-get (pv-test-block "# a") :level) 1))
  (should (= (plist-get (pv-test-block "###### a") :level) 6)))

(ert-deftest pretty-view-gfm-test-seven-hashes-is-a-paragraph ()
  "Seven hashes is not a heading in CommonMark."
  (should (eq (pv-test-type (pv-test-block "####### a")) 'paragraph)))

(ert-deftest pretty-view-gfm-test-hash-without-space-is-a-paragraph ()
  (should (eq (pv-test-type (pv-test-block "#hashtag")) 'paragraph)))

(ert-deftest pretty-view-gfm-test-closing-sequence-stripped ()
  (should (equal (pv-test-text (pv-test-block "## Hello ##")) "Hello")))

(ert-deftest pretty-view-gfm-test-setext-heading ()
  (let ((node (pv-test-block "Title\n=====")))
    (should (eq (pv-test-type node) 'heading))
    (should (= (plist-get node :level) 1))
    (should (equal (pv-test-text node) "Title")))
  (should (= (plist-get (pv-test-block "Title\n-----") :level) 2)))

(ert-deftest pretty-view-gfm-test-paragraph-joins-lines ()
  (let ((node (pv-test-block "one\ntwo")))
    (should (eq (pv-test-type node) 'paragraph))
    (should (equal (pv-test-text node) "one\ntwo"))))

(ert-deftest pretty-view-gfm-test-blank-line-separates-paragraphs ()
  (let ((blocks (pv-test-blocks "one\n\ntwo")))
    (should (= (length blocks) 2))
    (should (equal (pv-test-text (nth 1 blocks)) "two"))))

(ert-deftest pretty-view-gfm-test-thematic-break ()
  (dolist (s '("---" "***" "___" " - - -" "_____________"))
    (should (eq (pv-test-type (pv-test-block s)) 'thematic-break))))

(ert-deftest pretty-view-gfm-test-thematic-break-interrupts-paragraph ()
  (let ((blocks (pv-test-blocks "text\n---\nmore")))
    ;; `text' followed by `---' is a setext level-2 heading, not a break.
    (should (eq (pv-test-type (nth 0 blocks)) 'heading))
    (should (= (plist-get (nth 0 blocks) :level) 2))))

(ert-deftest pretty-view-gfm-test-slug ()
  (should (equal (pretty-view-gfm--slug "Hello, World!") "hello-world"))
  (should (equal (pretty-view-gfm--slug "  spaced  out  ") "spaced-out"))
  (should (equal (pretty-view-gfm--slug "한글 제목") "한글-제목")))

(ert-deftest pretty-view-gfm-test-parse-returns-document ()
  (let ((doc (pretty-view-gfm-parse "hi")))
    (should (eq (plist-get doc :type) 'document))
    (should (= (length (plist-get doc :children)) 1))))

(ert-deftest pretty-view-gfm-test-empty-input ()
  (should (equal (plist-get (pretty-view-gfm-parse "") :children) nil)))

(ert-deftest pretty-view-gfm-test-fenced-code ()
  (let ((node (pv-test-block "```elisp\n(+ 1 2)\n```")))
    (should (eq (pv-test-type node) 'code-block))
    (should (equal (plist-get node :lang) "elisp"))
    (should (equal (plist-get node :code) "(+ 1 2)\n"))))

(ert-deftest pretty-view-gfm-test-fenced-code-no-lang ()
  (let ((node (pv-test-block "```\nplain\n```")))
    (should (eq (pv-test-type node) 'code-block))
    (should (null (plist-get node :lang)))))

(ert-deftest pretty-view-gfm-test-fenced-code-tilde ()
  (let ((node (pv-test-block "~~~python\nx = 1\n~~~")))
    (should (eq (pv-test-type node) 'code-block))
    (should (equal (plist-get node :lang) "python"))))

(ert-deftest pretty-view-gfm-test-fenced-code-info-string-first-word ()
  (let ((node (pv-test-block "```js title=\"a.js\"\nx\n```")))
    (should (equal (plist-get node :lang) "js"))))

(ert-deftest pretty-view-gfm-test-fenced-code-keeps-markdown-literal ()
  "Markdown inside a fence is content, not syntax."
  (let ((node (pv-test-block "```\n# not a heading\n```")))
    (should (equal (plist-get node :code) "# not a heading\n"))))

(ert-deftest pretty-view-gfm-test-fenced-code-unterminated-runs-to-end ()
  (let ((node (pv-test-block "```\na\nb")))
    (should (eq (pv-test-type node) 'code-block))
    (should (equal (plist-get node :code) "a\nb\n"))))

(ert-deftest pretty-view-gfm-test-fenced-code-longer-fence-closes ()
  "A closing fence must be at least as long as the opening fence."
  (let ((node (pv-test-block "````\n```\nstill code\n````")))
    (should (equal (plist-get node :code) "```\nstill code\n"))))

(ert-deftest pretty-view-gfm-test-fenced-code-strips-indent ()
  "Content is dedented by the opening fence's indentation."
  (let ((node (pv-test-block "  ```\n  a\n   b\n  ```")))
    (should (equal (plist-get node :code) "a\n b\n"))))

(ert-deftest pretty-view-gfm-test-indented-code ()
  (let ((node (pv-test-block "    indented\n    lines")))
    (should (eq (pv-test-type node) 'code-block))
    (should (null (plist-get node :lang)))
    (should (equal (plist-get node :code) "indented\nlines\n"))))

(ert-deftest pretty-view-gfm-test-indented-code-not-after-paragraph ()
  "An indented line continuing a paragraph is paragraph text."
  (let ((blocks (pv-test-blocks "text\n    continued")))
    (should (= (length blocks) 1))
    (should (eq (pv-test-type (car blocks)) 'paragraph))))

(ert-deftest pretty-view-gfm-test-blockquote ()
  (let ((node (pv-test-block "> quoted")))
    (should (eq (pv-test-type node) 'blockquote))
    (should (eq (pv-test-type (car (plist-get node :children))) 'paragraph))
    (should (equal (pv-test-text (car (plist-get node :children))) "quoted"))))

(ert-deftest pretty-view-gfm-test-blockquote-nested ()
  (let* ((outer (pv-test-block "> > deep"))
         (inner (car (plist-get outer :children))))
    (should (eq (pv-test-type inner) 'blockquote))))

(ert-deftest pretty-view-gfm-test-blockquote-holds-blocks ()
  (let ((node (pv-test-block "> # head\n> body")))
    (should (eq (pv-test-type (nth 0 (plist-get node :children))) 'heading))
    (should (eq (pv-test-type (nth 1 (plist-get node :children))) 'paragraph))))

(ert-deftest pretty-view-gfm-test-blockquote-not-interrupted-by-plain-text ()
  "Lazy continuation is for paragraph text, and must keep working."
  (let ((node (pv-test-block "> a\nlazy text")))
    (should (eq (pv-test-type node) 'blockquote))
    (should (equal (pv-test-text (car (plist-get node :children)))
                   "a\nlazy text"))))

(ert-deftest pretty-view-gfm-test-blockquote-interrupted-by-heading ()
  (let ((blocks (pv-test-blocks "> a\n# heading")))
    (should (= (length blocks) 2))
    (should (eq (pv-test-type (nth 0 blocks)) 'blockquote))
    (should (eq (pv-test-type (nth 1 blocks)) 'heading))))

(ert-deftest pretty-view-gfm-test-blockquote-interrupted-by-list ()
  (let ((blocks (pv-test-blocks "> a\n- item")))
    (should (= (length blocks) 2))
    (should (eq (pv-test-type (nth 1 blocks)) 'list))))

(ert-deftest pretty-view-gfm-test-blockquote-interrupted-by-thematic-break ()
  (let ((blocks (pv-test-blocks "> a\n---")))
    (should (= (length blocks) 2))
    (should (eq (pv-test-type (nth 0 blocks)) 'blockquote))
    (should (eq (pv-test-type (nth 1 blocks)) 'thematic-break))))

(ert-deftest pretty-view-gfm-test-bullet-list ()
  (let ((node (pv-test-block "- one\n- two")))
    (should (eq (pv-test-type node) 'list))
    (should (null (plist-get node :ordered)))
    (should (= (length (plist-get node :children)) 2))
    (should (eq (pv-test-type (car (plist-get node :children))) 'list-item))))

(ert-deftest pretty-view-gfm-test-bullet-list-markers ()
  (dolist (m '("-" "*" "+"))
    (should (eq (pv-test-type (pv-test-block (concat m " x"))) 'list))))

(ert-deftest pretty-view-gfm-test-ordered-list ()
  (let ((node (pv-test-block "1. one\n2. two")))
    (should (eq (pv-test-type node) 'list))
    (should (plist-get node :ordered))
    (should (= (plist-get node :start) 1))))

(ert-deftest pretty-view-gfm-test-ordered-list-start ()
  (should (= (plist-get (pv-test-block "5. five") :start) 5)))

(ert-deftest pretty-view-gfm-test-nested-list ()
  (let* ((outer (pv-test-block "- a\n  - b"))
         (item (car (plist-get outer :children)))
         (inner (nth 1 (plist-get item :children))))
    (should (eq (pv-test-type inner) 'list))))

(ert-deftest pretty-view-gfm-test-tight-and-loose-lists ()
  (should (plist-get (pv-test-block "- a\n- b") :tight))
  (should-not (plist-get (pv-test-block "- a\n\n- b") :tight)))

(ert-deftest pretty-view-gfm-test-task-list-item ()
  (let* ((node (pv-test-block "- [ ] todo\n- [x] done"))
         (items (plist-get node :children)))
    (should (eq (pv-test-type (nth 0 items)) 'task-item))
    (should-not (plist-get (nth 0 items) :checked))
    (should (plist-get (nth 1 items) :checked))
    (should (equal (pv-test-text (car (plist-get (nth 0 items) :children)))
                   "todo"))))

(ert-deftest pretty-view-gfm-test-task-list-uppercase-x ()
  (let ((item (car (plist-get (pv-test-block "- [X] done") :children))))
    (should (plist-get item :checked))))

(ert-deftest pretty-view-gfm-test-list-does-not-swallow-following-paragraph ()
  (let ((blocks (pv-test-blocks "- a\n\nafter")))
    (should (= (length blocks) 2))
    (should (eq (pv-test-type (nth 1 blocks)) 'paragraph))))

(ert-deftest pretty-view-gfm-test-table ()
  (let* ((node (pv-test-block "| a | b |\n|---|---|\n| 1 | 2 |"))
         (rows (plist-get node :children)))
    (should (eq (pv-test-type node) 'table))
    (should (= (length rows) 2))
    (should (plist-get (nth 0 rows) :header))
    (should-not (plist-get (nth 1 rows) :header))
    (should (equal (pv-test-text (nth 0 (plist-get (nth 0 rows) :children)))
                   "a"))))

(ert-deftest pretty-view-gfm-test-table-alignment ()
  (let ((node (pv-test-block "| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |")))
    (should (equal (plist-get node :align) '(left center right)))))

(ert-deftest pretty-view-gfm-test-table-default-alignment-is-nil ()
  (let ((node (pv-test-block "| a |\n|---|\n| 1 |")))
    (should (equal (plist-get node :align) '(nil)))))

(ert-deftest pretty-view-gfm-test-table-without-outer-pipes ()
  (let ((node (pv-test-block "a | b\n--- | ---\n1 | 2")))
    (should (eq (pv-test-type node) 'table))
    (should (= (length (plist-get (nth 0 (plist-get node :children)) :children))
               2))))

(ert-deftest pretty-view-gfm-test-table-needs-delimiter-row ()
  "A pipe row with no delimiter row underneath is a paragraph."
  (should (eq (pv-test-type (pv-test-block "| a | b |\n| 1 | 2 |")) 'paragraph)))

(ert-deftest pretty-view-gfm-test-table-escaped-pipe-stays-in-cell ()
  (let* ((node (pv-test-block "| a |\n|---|\n| x \\| y |"))
         (cell (car (plist-get (nth 1 (plist-get node :children)) :children))))
    (should (equal (pv-test-text cell) "x | y"))))

(ert-deftest pretty-view-gfm-test-table-ends-at-blank-line ()
  (let ((blocks (pv-test-blocks "| a |\n|---|\n| 1 |\n\nafter")))
    (should (= (length blocks) 2))
    (should (eq (pv-test-type (nth 1 blocks)) 'paragraph))))

(ert-deftest pretty-view-gfm-test-table-interrupts-paragraph ()
  "A table directly after a paragraph line starts its own block."
  (let ((blocks (pv-test-blocks "text\n| a | b |\n|---|---|\n| 1 | 2 |")))
    (should (= (length blocks) 2))
    (should (eq (pv-test-type (nth 0 blocks)) 'paragraph))
    (should (equal (pv-test-text (nth 0 blocks)) "text"))
    (should (eq (pv-test-type (nth 1 blocks)) 'table))))

(ert-deftest pretty-view-gfm-test-html-block ()
  (let ((node (pv-test-block "<div class=\"x\">\n  <p>hi</p>\n</div>")))
    (should (eq (pv-test-type node) 'html-block))
    (should (string-match-p "<div" (plist-get node :html)))
    (should (string-match-p "</div>" (plist-get node :html)))))

(ert-deftest pretty-view-gfm-test-html-block-ends-at-blank-line ()
  (let ((blocks (pv-test-blocks "<div>\n</div>\n\nafter")))
    (should (= (length blocks) 2))
    (should (eq (pv-test-type (nth 1 blocks)) 'paragraph))))

(ert-deftest pretty-view-gfm-test-html-comment-is-a-block ()
  (should (eq (pv-test-type (pv-test-block "<!-- note -->")) 'html-block)))

(ert-deftest pretty-view-gfm-test-link-reference-definition-produces-no-node ()
  (let ((blocks (pv-test-blocks "[ref]: https://example.com\n\ntext")))
    (should (= (length blocks) 1))
    (should (eq (pv-test-type (car blocks)) 'paragraph))))

(ert-deftest pretty-view-gfm-test-link-reference-is-recorded ()
  (pretty-view-gfm-parse "[Ref]: https://example.com \"T\"")
  (should (equal (pretty-view-gfm-link-ref "ref")
                 '("https://example.com" . "T"))))

(ert-deftest pretty-view-gfm-test-link-reference-label-is-case-insensitive ()
  (pretty-view-gfm-parse "[MiXeD]: https://example.com")
  (should (pretty-view-gfm-link-ref "mixed"))
  (should (pretty-view-gfm-link-ref "MIXED")))

(ert-deftest pretty-view-gfm-test-footnote-definition ()
  (let ((node (pv-test-block "[^a]: the note")))
    (should (eq (pv-test-type node) 'footnote-definition))
    (should (equal (plist-get node :label) "a"))
    (should (equal (pv-test-text (car (plist-get node :children)))
                   "the note"))))

(ert-deftest pretty-view-gfm-test-footnote-definition-continuation ()
  (let* ((node (pv-test-block "[^a]: first\n    second"))
         (para (car (plist-get node :children))))
    (should (equal (pv-test-text para) "first\nsecond"))))

(ert-deftest pretty-view-gfm-test-footnote-is-not-a-link-reference ()
  (should (eq (pv-test-type (pv-test-block "[^a]: x")) 'footnote-definition)))

(ert-deftest pretty-view-gfm-test-footnote-definition-interrupts-paragraph ()
  (let ((blocks (pv-test-blocks "text\n[^a]: note")))
    (should (= (length blocks) 2))
    (should (eq (pv-test-type (nth 0 blocks)) 'paragraph))
    (should (eq (pv-test-type (nth 1 blocks)) 'footnote-definition))))

(ert-deftest pretty-view-gfm-test-html-block-interrupts-paragraph ()
  (let ((blocks (pv-test-blocks "text\n<div>\n</div>")))
    (should (= (length blocks) 2))
    (should (eq (pv-test-type (nth 0 blocks)) 'paragraph))
    (should (eq (pv-test-type (nth 1 blocks)) 'html-block))))

(ert-deftest pretty-view-gfm-test-setext-does-not-promote-a-block-start ()
  "A setext underline promotes a paragraph, not a line that starts a block."
  (let ((blocks (pv-test-blocks "<div>\n---\n</div>")))
    (should (= (length blocks) 1))
    (should (eq (pv-test-type (car blocks)) 'html-block)))
  (let ((blocks (pv-test-blocks "- a\n---")))
    (should (eq (pv-test-type (nth 0 blocks)) 'list))
    (should (eq (pv-test-type (nth 1 blocks)) 'thematic-break))))

(ert-deftest pretty-view-gfm-test-setext-still-promotes-a-paragraph ()
  (should (eq (pv-test-type (pv-test-block "Title\n---")) 'heading))
  (should (= (plist-get (pv-test-block "Title\n===") :level) 1)))

(ert-deftest pretty-view-gfm-test-footnote-tab-continuation ()
  (let* ((node (pv-test-block "[^a]: first\n\tsecond"))
         (para (car (plist-get node :children))))
    (should (equal (pv-test-text para) "first\nsecond"))))

(ert-deftest pretty-view-gfm-test-inline-plain-text ()
  (let ((kids (plist-get (pv-test-block "hello") :children)))
    (should (equal (pv-test-type (car kids)) 'text))
    (should (equal (plist-get (car kids) :value) "hello"))
    (should (null (plist-get (pv-test-block "hello") :raw)))))

(ert-deftest pretty-view-gfm-test-code-span ()
  (let* ((kids (plist-get (pv-test-block "a `code` b") :children))
         (span (nth 1 kids)))
    (should (eq (pv-test-type span) 'code-span))
    (should (equal (plist-get span :code) "code"))))

(ert-deftest pretty-view-gfm-test-code-span-double-backtick ()
  (let ((span (nth 0 (plist-get (pv-test-block "``a ` b``") :children))))
    (should (eq (pv-test-type span) 'code-span))
    (should (equal (plist-get span :code) "a ` b"))))

(ert-deftest pretty-view-gfm-test-code-span-strips-one-space-each-side ()
  (let ((span (nth 0 (plist-get (pv-test-block "`` ` ``") :children))))
    (should (equal (plist-get span :code) "`"))))

(ert-deftest pretty-view-gfm-test-unmatched-backtick-is-literal ()
  (should (equal (pv-test-text (pv-test-block "a ` b")) "a ` b")))

(ert-deftest pretty-view-gfm-test-backslash-escape ()
  (should (equal (pv-test-text (pv-test-block "\\*not em\\*")) "*not em*")))

(ert-deftest pretty-view-gfm-test-backslash-before-ordinary-char-is-literal ()
  (should (equal (pv-test-text (pv-test-block "a\\b")) "a\\b")))

(ert-deftest pretty-view-gfm-test-hard-break-two-spaces ()
  (let ((kids (plist-get (pv-test-block "a  \nb") :children)))
    (should (seq-find (lambda (n) (eq (pv-test-type n) 'line-break)) kids))))

(ert-deftest pretty-view-gfm-test-hard-break-backslash ()
  (let ((kids (plist-get (pv-test-block "a\\\nb") :children)))
    (should (seq-find (lambda (n) (eq (pv-test-type n) 'line-break)) kids))))

(ert-deftest pretty-view-gfm-test-soft-break ()
  (let ((kids (plist-get (pv-test-block "a\nb") :children)))
    (should (seq-find (lambda (n) (eq (pv-test-type n) 'soft-break)) kids))))

(ert-deftest pretty-view-gfm-test-inline-runs-inside-table-cells ()
  (let* ((node (pv-test-block "| `x` |\n|---|\n| y |"))
         (cell (car (plist-get (nth 0 (plist-get node :children)) :children))))
    (should (eq (pv-test-type (car (plist-get cell :children))) 'code-span))))

(ert-deftest pretty-view-gfm-test-code-block-is-not-inline-parsed ()
  (let ((node (pv-test-block "```\n`x`\n```")))
    (should (equal (plist-get node :code) "`x`\n"))
    (should (null (plist-get node :children)))))

(defun pv-test-inline (markdown &optional n)
  "Return inline node N (default 0) of the first block of MARKDOWN."
  (nth (or n 0) (plist-get (pv-test-block markdown) :children)))

(ert-deftest pretty-view-gfm-test-inline-link ()
  (let ((node (pv-test-inline "[text](https://example.com)")))
    (should (eq (pv-test-type node) 'link))
    (should (equal (plist-get node :href) "https://example.com"))
    (should (equal (pv-test-text node) "text"))))

(ert-deftest pretty-view-gfm-test-inline-link-with-title ()
  (let ((node (pv-test-inline "[t](https://e.com \"Title\")")))
    (should (equal (plist-get node :title) "Title"))))

(ert-deftest pretty-view-gfm-test-inline-link-angle-destination ()
  (let ((node (pv-test-inline "[t](<https://e.com/a b>)")))
    (should (equal (plist-get node :href) "https://e.com/a b"))))

(ert-deftest pretty-view-gfm-test-image ()
  (let ((node (pv-test-inline "![alt](img.png)")))
    (should (eq (pv-test-type node) 'image))
    (should (equal (plist-get node :src) "img.png"))
    (should (equal (plist-get node :alt) "alt"))))

(ert-deftest pretty-view-gfm-test-reference-link ()
  (let* ((doc (pretty-view-gfm-parse "[t][ref]\n\n[ref]: https://e.com \"T\""))
         (node (car (plist-get (car (plist-get doc :children)) :children))))
    (should (eq (pv-test-type node) 'link))
    (should (equal (plist-get node :href) "https://e.com"))
    (should (equal (plist-get node :title) "T"))))

(ert-deftest pretty-view-gfm-test-collapsed-reference-link ()
  (let* ((doc (pretty-view-gfm-parse "[ref][]\n\n[ref]: https://e.com"))
         (node (car (plist-get (car (plist-get doc :children)) :children))))
    (should (equal (plist-get node :href) "https://e.com"))))

(ert-deftest pretty-view-gfm-test-shortcut-reference-link ()
  (let* ((doc (pretty-view-gfm-parse "[ref]\n\n[ref]: https://e.com"))
         (node (car (plist-get (car (plist-get doc :children)) :children))))
    (should (equal (plist-get node :href) "https://e.com"))))

(ert-deftest pretty-view-gfm-test-undefined-reference-stays-literal ()
  (should (equal (pv-test-text (pv-test-block "[nope]")) "[nope]")))

(ert-deftest pretty-view-gfm-test-angle-autolink ()
  (let ((node (pv-test-inline "<https://example.com>")))
    (should (eq (pv-test-type node) 'autolink))
    (should (equal (plist-get node :href) "https://example.com"))))

(ert-deftest pretty-view-gfm-test-bare-url-autolink ()
  (let ((node (pv-test-inline "see https://example.com now" 1)))
    (should (eq (pv-test-type node) 'autolink))
    (should (equal (plist-get node :href) "https://example.com"))))

(ert-deftest pretty-view-gfm-test-bare-url-drops-trailing-punctuation ()
  (let ((node (pv-test-inline "see https://example.com." 1)))
    (should (equal (plist-get node :href) "https://example.com"))))

(ert-deftest pretty-view-gfm-test-bare-url-keeps-balanced-parens ()
  "A closing paren that balances an opening one belongs to the URL."
  (let ((node (pv-test-inline "see https://e.com/a_(b) end" 1)))
    (should (eq (pv-test-type node) 'autolink))
    (should (equal (plist-get node :href) "https://e.com/a_(b)"))))

(ert-deftest pretty-view-gfm-test-bare-url-drops-unbalanced-paren ()
  "A closing paren with no opener is sentence punctuation."
  (let* ((nodes (plist-get (pv-test-block "(see https://e.com) end") :children))
         (node (seq-find (lambda (n) (eq (plist-get n :type) 'autolink)) nodes)))
    (should (equal (plist-get node :href) "https://e.com"))))

(ert-deftest pretty-view-gfm-test-bare-url-drops-trailing-sentence-punctuation ()
  (should (equal (plist-get (pv-test-inline "see https://e.com." 1) :href)
                 "https://e.com"))
  (should (equal (plist-get (pv-test-inline "see https://e.com?!" 1) :href)
                 "https://e.com")))

(ert-deftest pretty-view-gfm-test-footnote-reference ()
  (let ((node (pv-test-inline "text[^a]" 1)))
    (should (eq (pv-test-type node) 'footnote-reference))
    (should (equal (plist-get node :label) "a"))))

(ert-deftest pretty-view-gfm-test-inline-html ()
  (let ((node (pv-test-inline "<span>x</span>")))
    (should (eq (pv-test-type node) 'html-inline))
    (should (equal (plist-get node :html) "<span>"))))

(ert-deftest pretty-view-gfm-test-link-text-is-inline-parsed ()
  (let ((node (pv-test-inline "[a `b` c](x)")))
    (should (eq (pv-test-type (nth 1 (plist-get node :children))) 'code-span))))

(provide 'pretty-view-gfm-test)
;;; pretty-view-gfm-test.el ends here
