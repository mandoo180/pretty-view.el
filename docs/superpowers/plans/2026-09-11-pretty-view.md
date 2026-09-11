# pretty-view.el Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an Emacs package that renders the current Org, Markdown, or plain-text buffer to a styled, self-contained HTML file and opens it in the operating system's browser.

**Architecture:** Three source formats converge on a common HTML body — Org through a backend derived from `ox-html`, Markdown through a GFM parser written for this package, plain text through a minimal converter. A theme layer turns a palette plist into CSS custom properties, a document shell wraps the body, and a platform-aware launcher opens the result. The shell, theme, and launcher never learn which format produced the body.

**Tech Stack:** Emacs Lisp only. Built-ins `org`/`ox-html`, `cl-lib`, `seq`. ERT for tests. No external programs, no network access, no third-party packages.

**Spec:** `docs/superpowers/specs/2026-09-11-pretty-view-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- Emacs requirement: **29.1**. Do not use functions introduced after 29.1.
- Dependencies: **none beyond built-ins** (`org`, `cl-lib`, `seq`). Never add a `Package-Requires` entry for a third-party package. Never call `htmlize-*`.
- No external programs and no network access at render time. The one exception is the browser launcher in Task 17, which runs `wslview`, `explorer.exe`, or `wslpath`.
- Public prefix `pretty-view-`; internals `pretty-view--`.
- License: **GPL-3.0-or-later**. Every source file carries the standard GPL header and a `;;; Commentary:` section.
- Every file starts with `;;; -*- lexical-binding: t -*-` and ends with a `;;; FILE ends here` line.
- Byte-compilation must be **warning-free**; CI treats warnings as errors.
- The parser never signals. Unrecognized syntax degrades to paragraph text.
- Repository: `mandoo180/pretty-view.el`, public.

---

### Task 1: Project skeleton, escaping, and the test harness

Sets up the repository layout and the two things every later task needs: `pretty-view-escape-html` and a way to run tests.

**Files:**
- Create: `pretty-view-render.el`
- Create: `tests/pretty-view-test-helper.el`
- Create: `tests/pretty-view-render-test.el`
- Create: `Makefile`
- Create: `.gitignore`
- Create: `LICENSE` (GPL-3.0 text)

**Interfaces:**
- Consumes: nothing
- Produces:
  - `(pretty-view-escape-html STRING)` → string, escaping `& < > " '`
  - `(pretty-view-escape-attribute STRING)` → string, same escaping (separate entry point so the two can diverge later)
  - Test helpers `pv-test-blocks`, `pv-test-block`, `pv-test-type`, `pv-test-text`

- [ ] **Step 1: Write the failing test**

Create `tests/pretty-view-render-test.el`:

```elisp
;;; pretty-view-render-test.el --- Tests for pretty-view-render  -*- lexical-binding: t -*-
;;; Commentary:
;; Tests for HTML escaping and the renderer table.
;;; Code:

(require 'ert)
(require 'pretty-view-render)

(ert-deftest pretty-view-render-test-escape-ampersand-first ()
  "Ampersands must be escaped before the entities we introduce."
  (should (equal (pretty-view-escape-html "a & b") "a &amp; b"))
  (should (equal (pretty-view-escape-html "<b>") "&lt;b&gt;"))
  (should (equal (pretty-view-escape-html "\"q\"") "&quot;q&quot;"))
  (should (equal (pretty-view-escape-html "it's") "it&#39;s")))

(ert-deftest pretty-view-render-test-escape-does-not-double-escape-its-own-output ()
  "Escaping `&lt;' must not turn into `&amp;lt;' for a single pass."
  (should (equal (pretty-view-escape-html "<&>") "&lt;&amp;&gt;")))

(ert-deftest pretty-view-render-test-escape-attribute ()
  (should (equal (pretty-view-escape-attribute "a\"b") "a&quot;b")))

(provide 'pretty-view-render-test)
;;; pretty-view-render-test.el ends here
```

- [ ] **Step 2: Run test to verify it fails**

```bash
emacs -Q --batch -L . -L tests -l ert -l tests/pretty-view-render-test.el \
  -f ert-run-tests-batch-and-exit
```

Expected: FAIL — `Cannot open load file: pretty-view-render`.

- [ ] **Step 3: Write the minimal implementation**

Create `pretty-view-render.el`:

```elisp
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
```

- [ ] **Step 4: Run test to verify it passes**

```bash
emacs -Q --batch -L . -L tests -l ert -l tests/pretty-view-render-test.el \
  -f ert-run-tests-batch-and-exit
```

Expected: PASS, 3 tests.

- [ ] **Step 5: Add the test helper**

Create `tests/pretty-view-test-helper.el`:

```elisp
;;; pretty-view-test-helper.el --- Shared test helpers  -*- lexical-binding: t -*-
;;; Commentary:
;; Accessors that keep AST assertions readable.  Tests compare specific
;; fields rather than whole plists, because plist key order is not part
;; of the contract.
;;; Code:

(defun pv-test-blocks (markdown)
  "Parse MARKDOWN and return the top-level block nodes."
  (plist-get (pretty-view-gfm-parse markdown) :children))

(defun pv-test-block (markdown &optional n)
  "Parse MARKDOWN and return block N (default 0)."
  (nth (or n 0) (pv-test-blocks markdown)))

(defun pv-test-type (node)
  "Return the `:type' of NODE."
  (plist-get node :type))

(defun pv-test-text (node)
  "Return every `:value' string under NODE concatenated, depth first."
  (cond
   ((null node) "")
   ((and (listp node) (keywordp (car node)))
    (concat (or (plist-get node :value) "")
            (pv-test-text (plist-get node :children))))
   ((listp node) (mapconcat #'pv-test-text node ""))
   (t "")))

(provide 'pretty-view-test-helper)
;;; pretty-view-test-helper.el ends here
```

- [ ] **Step 6: Add the Makefile**

Create `Makefile`:

```make
EMACS ?= emacs
LOAD  := -L . -L tests
SRC   := $(wildcard pretty-view*.el)
TESTS := $(wildcard tests/*-test.el)

.PHONY: test compile checkdoc clean all

all: compile test

test:
	$(EMACS) -Q --batch $(LOAD) -l ert $(addprefix -l ,$(TESTS)) \
	  -f ert-run-tests-batch-and-exit

compile: clean
	$(EMACS) -Q --batch $(LOAD) \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SRC)

checkdoc:
	$(EMACS) -Q --batch $(LOAD) \
	  --eval '(dolist (f (file-expand-wildcards "pretty-view*.el")) (checkdoc-file f))'

clean:
	rm -f *.elc tests/*.elc
```

Note: Makefile recipe lines must begin with a TAB, not spaces.

- [ ] **Step 7: Add .gitignore and LICENSE**

Create `.gitignore`:

```
*.elc
/dist/
```

Fetch the GPL-3.0 text into `LICENSE`:

```bash
cp /usr/share/common-licenses/GPL-3 LICENSE 2>/dev/null || \
  curl -fsSL https://www.gnu.org/licenses/gpl-3.0.txt -o LICENSE
```

- [ ] **Step 8: Run the full suite**

```bash
make test
```

Expected: PASS, 3 tests, 0 unexpected.

- [ ] **Step 9: Commit**

```bash
git add Makefile .gitignore LICENSE pretty-view-render.el tests/
git commit -m "feat: project skeleton, HTML escaping, and test harness"
```

---

### Task 2: GFM block parser — headings, paragraphs, thematic breaks

The block scanner's spine: split a document into lines and dispatch on the first line of each block. Later tasks extend the dispatch table; this task establishes it.

**Files:**
- Create: `pretty-view-gfm.el`
- Create: `tests/pretty-view-gfm-test.el`

**Interfaces:**
- Consumes: `pv-test-block`, `pv-test-type`, `pv-test-text` from Task 1
- Produces:
  - `(pretty-view-gfm-parse STRING)` → `(:type document :children NODES)`
  - `(pretty-view-gfm--slug STRING)` → an anchor id string
  - `pretty-view-gfm--parse-blocks (LINES)` → node list. LINES is a list of strings with no trailing newline. Later tasks add clauses to its `cond`.
  - Block nodes carry `:raw` (a string awaiting inline parsing); Task 7 replaces `:raw` with `:children`.

- [ ] **Step 1: Write the failing tests**

Create `tests/pretty-view-gfm-test.el`:

```elisp
;;; pretty-view-gfm-test.el --- Tests for the GFM parser  -*- lexical-binding: t -*-
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
    (should (equal (plist-get node :raw) "Hello world"))
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
  (should (equal (plist-get (pv-test-block "## Hello ##") :raw) "Hello")))

(ert-deftest pretty-view-gfm-test-setext-heading ()
  (let ((node (pv-test-block "Title\n=====")))
    (should (eq (pv-test-type node) 'heading))
    (should (= (plist-get node :level) 1))
    (should (equal (plist-get node :raw) "Title")))
  (should (= (plist-get (pv-test-block "Title\n-----") :level) 2)))

(ert-deftest pretty-view-gfm-test-paragraph-joins-lines ()
  (let ((node (pv-test-block "one\ntwo")))
    (should (eq (pv-test-type node) 'paragraph))
    (should (equal (plist-get node :raw) "one\ntwo"))))

(ert-deftest pretty-view-gfm-test-blank-line-separates-paragraphs ()
  (let ((blocks (pv-test-blocks "one\n\ntwo")))
    (should (= (length blocks) 2))
    (should (equal (plist-get (nth 1 blocks) :raw) "two"))))

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

(provide 'pretty-view-gfm-test)
;;; pretty-view-gfm-test.el ends here
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
emacs -Q --batch -L . -L tests -l ert -l tests/pretty-view-gfm-test.el \
  -f ert-run-tests-batch-and-exit
```

Expected: FAIL — `Cannot open load file: pretty-view-gfm`.

- [ ] **Step 3: Write the implementation**

Create `pretty-view-gfm.el` with the standard GPL header (copy the block from Task 1's `pretty-view-render.el`, changing the summary line), this Commentary, and this code:

```elisp
;;; Commentary:

;; A GitHub Flavored Markdown parser producing a plist AST.  Two phases:
;; a line-oriented block scanner, then an inline pass over the `:raw'
;; strings the block scanner leaves behind.  The parser never signals;
;; unrecognized syntax becomes paragraph text, which is Markdown's own
;; fallback.

;;; Code:

(require 'subr-x)

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
```

Note the setext clause sits *after* the thematic-break clause but tests a
*following* line, so `text\n---` becomes a level-2 heading while a bare
`---` becomes a break. That ordering is what
`pretty-view-gfm-test-thematic-break-interrupts-paragraph` pins.

Do **not** add a `(not (string-match-p pretty-view-gfm--thematic-break-re
(nth 1 lines)))` guard to this clause. A run of three or more dashes matches
both patterns, so such a guard would make every dash-underlined setext
heading impossible and break
`pretty-view-gfm-test-setext-heading`. Clause order already does the
separating work: a bare `---` reaches the thematic-break clause as the
*current* line and never gets to this one.

`pretty-view-gfm--parse-blocks` must `require 'seq` transitively; add
`(require 'seq)` next to `(require 'subr-x)`.

- [ ] **Step 4: Run tests to verify they pass**

```bash
make test
```

Expected: PASS, 16 tests, 0 unexpected.

- [ ] **Step 5: Commit**

```bash
git add pretty-view-gfm.el tests/pretty-view-gfm-test.el
git commit -m "feat(gfm): parse headings, paragraphs, and thematic breaks"
```

---

### Task 3: GFM block parser — code blocks

Fenced code blocks with an info string, and indented code blocks. Code block content is never inline-parsed, so these nodes carry `:code`, not `:raw`.

**Files:**
- Modify: `pretty-view-gfm.el` — add two clauses to `pretty-view-gfm--parse-blocks`
- Modify: `tests/pretty-view-gfm-test.el`

**Interfaces:**
- Consumes: `pretty-view-gfm--parse-blocks` from Task 2
- Produces: `(:type code-block :lang STRING-OR-NIL :code STRING)`. `:code` keeps its trailing newline per line but has no trailing blank line. `:lang` is the first word of the info string, or nil.

- [ ] **Step 1: Write the failing tests**

Append to `tests/pretty-view-gfm-test.el`, before the `provide`:

```elisp
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
make test
```

Expected: FAIL — the fenced-code tests report `paragraph` where `code-block` was expected.

- [ ] **Step 3: Implement fenced code**

Add to `pretty-view-gfm.el`, above `pretty-view-gfm--parse-blocks`:

```elisp
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
```

Add this clause to `pretty-view-gfm--parse-blocks`, immediately after the
blank-line clause and before the thematic-break clause — a fence made of
`~~~` would otherwise be read as a thematic break:

```elisp
         ;; Fenced code block.
         ((string-match-p pretty-view-gfm--fence-re line)
          (let ((result (pretty-view-gfm--take-fenced lines)))
            (push (car result) nodes)
            (setq lines (cdr result))))
```

- [ ] **Step 4: Run tests to verify fenced code passes**

```bash
make test
```

Expected: the nine fenced-code tests PASS; the two indented-code tests still FAIL.

- [ ] **Step 5: Implement indented code**

Add above `pretty-view-gfm--parse-blocks`:

```elisp
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
```

Add this clause to `pretty-view-gfm--parse-blocks` immediately before the
paragraph fallback. The `nodes` guard is what makes
`pretty-view-gfm-test-indented-code-not-after-paragraph` pass: an indented
line cannot start a code block when it continues a paragraph, and the
paragraph clause has already consumed those lines.

```elisp
         ;; Indented code block.  Only when not continuing a paragraph,
         ;; which the paragraph clause has already consumed.
         ((string-prefix-p "    " line)
          (let ((result (pretty-view-gfm--take-indented lines)))
            (push (car result) nodes)
            (setq lines (cdr result))))
```

Also extend `pretty-view-gfm--paragraph-end` to stop at a fence, so a
fenced block directly after a paragraph is not swallowed. Add
`(string-match-p pretty-view-gfm--fence-re line)` to the `or` in its
interrupt test.

- [ ] **Step 6: Run tests to verify they pass**

```bash
make test
```

Expected: PASS, 26 tests, 0 unexpected.

- [ ] **Step 7: Commit**

```bash
git add pretty-view-gfm.el tests/pretty-view-gfm-test.el
git commit -m "feat(gfm): parse fenced and indented code blocks"
```

---

### Task 4: GFM block parser — block quotes, lists, task list items

Block quotes and lists both hold blocks, so both recurse into `pretty-view-gfm--parse-blocks`.

**Files:**
- Modify: `pretty-view-gfm.el`
- Modify: `tests/pretty-view-gfm-test.el`

**Interfaces:**
- Consumes: `pretty-view-gfm--parse-blocks`, `pretty-view-gfm--blank-p` from Tasks 2–3
- Produces:
  - `(:type blockquote :children NODES)`
  - `(:type list :ordered BOOL :start INT :tight BOOL :children ITEMS)`
  - `(:type list-item :children NODES)`
  - `(:type task-item :checked BOOL :children NODES)`

- [ ] **Step 1: Write the failing tests**

Append to `tests/pretty-view-gfm-test.el`:

```elisp
(ert-deftest pretty-view-gfm-test-blockquote ()
  (let ((node (pv-test-block "> quoted")))
    (should (eq (pv-test-type node) 'blockquote))
    (should (eq (pv-test-type (car (plist-get node :children))) 'paragraph))
    (should (equal (plist-get (car (plist-get node :children)) :raw) "quoted"))))

(ert-deftest pretty-view-gfm-test-blockquote-nested ()
  (let* ((outer (pv-test-block "> > deep"))
         (inner (car (plist-get outer :children))))
    (should (eq (pv-test-type inner) 'blockquote))))

(ert-deftest pretty-view-gfm-test-blockquote-holds-blocks ()
  (let ((node (pv-test-block "> # head\n> body")))
    (should (eq (pv-test-type (nth 0 (plist-get node :children))) 'heading))
    (should (eq (pv-test-type (nth 1 (plist-get node :children))) 'paragraph))))

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
    (should (equal (plist-get (car (plist-get (nth 0 items) :children)) :raw)
                   "todo"))))

(ert-deftest pretty-view-gfm-test-task-list-uppercase-x ()
  (let ((item (car (plist-get (pv-test-block "- [X] done") :children))))
    (should (plist-get item :checked))))

(ert-deftest pretty-view-gfm-test-list-does-not-swallow-following-paragraph ()
  (let ((blocks (pv-test-blocks "- a\n\nafter")))
    (should (= (length blocks) 2))
    (should (eq (pv-test-type (nth 1 blocks)) 'paragraph))))
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
make test
```

Expected: FAIL on all twelve new tests.

- [ ] **Step 3: Implement block quotes**

Add to `pretty-view-gfm.el`:

```elisp
(defconst pretty-view-gfm--quote-re "\\` \\{0,3\\}> ?"
  "Match a block quote marker at the start of a line.")

(defun pretty-view-gfm--take-blockquote (lines)
  "Consume a block quote from LINES.
Return a cons of the node and the remaining lines."
  (let ((body nil) (rest lines))
    (while (and rest
                (or (string-match-p pretty-view-gfm--quote-re (car rest))
                    ;; Lazy continuation: an unmarked, non-blank line
                    ;; continues the quoted paragraph.
                    (and body (not (pretty-view-gfm--blank-p (car rest))))))
      (push (replace-regexp-in-string pretty-view-gfm--quote-re "" (car rest))
            body)
      (setq rest (cdr rest)))
    (cons (list :type 'blockquote
                :children (pretty-view-gfm--parse-blocks (nreverse body)))
          rest)))
```

Add the clause to `pretty-view-gfm--parse-blocks`, after the fenced-code
clause:

```elisp
         ;; Block quote.
         ((string-match-p pretty-view-gfm--quote-re line)
          (let ((result (pretty-view-gfm--take-blockquote lines)))
            (push (car result) nodes)
            (setq lines (cdr result))))
```

- [ ] **Step 4: Run tests to verify block quotes pass**

```bash
make test
```

Expected: the three blockquote tests PASS; the list tests still FAIL.

- [ ] **Step 5: Implement lists**

Add to `pretty-view-gfm.el`:

```elisp
(defconst pretty-view-gfm--list-item-re
  "\\`\\( \\{0,3\\}\\)\\([-*+]\\|\\([0-9]\\{1,9\\}\\)[.)]\\)\\(?:[ \t]+\\(.*\\)\\|[ \t]*\\'\\)"
  "Match a list item marker.
Group 1 is the indentation, group 2 the marker, group 3 the ordinal for
an ordered item, group 4 the first line of content.")

(defconst pretty-view-gfm--task-re "\\`\\[\\([ xX]\\)\\][ \t]+\\(.*\\)\\'"
  "Match a GFM task list marker at the start of item content.")

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
  (string-match pretty-view-gfm--list-item-re (car lines))
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
          ;; Read the content out of the match BEFORE building the previous
          ;; item: --item-node calls --parse-blocks, which runs its own
          ;; regexps and clobbers the match data this line still needs.
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
         ((and body (not pending-blank))
          (push line body)
          (setq rest (cdr rest)))
         (t (setq done t)))))
    (when body
      (push (pretty-view-gfm--item-node (nreverse body)) items))
    (cons (list :type 'list :ordered ordered :start start :tight tight
                :children (nreverse items))
          ;; A blank line that ended the list is not part of it.
          rest)))
```

Add the clause to `pretty-view-gfm--parse-blocks`, after the block-quote
clause and before the indented-code clause:

```elisp
         ;; List.
         ((and (string-match-p pretty-view-gfm--list-item-re line)
               (not (string-match-p pretty-view-gfm--thematic-break-re line)))
          (let ((result (pretty-view-gfm--take-list lines)))
            (push (car result) nodes)
            (setq lines (cdr result))))
```

The thematic-break guard matters because `- - -` matches both patterns and
must stay a break; the earlier thematic-break clause already handles it,
and this guard documents the intent.

Two details in `pretty-view-gfm--take-list` are load-bearing, and both were
wrong in an earlier draft of this plan:

- The sibling test compares the marker's indentation against
  `first-indent`, the indentation of the list's own first marker — **not**
  against a fixed `< 4`. With a fixed bound, `"- a\n  - b"` reads the
  indented marker as a sibling and nesting never happens, which fails
  `pretty-view-gfm-test-nested-list`.
- The new item's content is read out of the match data **before**
  `pretty-view-gfm--item-node` runs. That function calls
  `pretty-view-gfm--parse-blocks`, whose own regexps overwrite the match
  data, so a later `(match-string 4 line)` would return text from an
  unrelated match. Every item after the first would take the wrong string.

Also add `(string-match-p pretty-view-gfm--list-item-re line)` and
`(string-match-p pretty-view-gfm--quote-re line)` to the interrupt test in
`pretty-view-gfm--paragraph-end`, so a list or quote directly after a
paragraph starts its own block.

- [ ] **Step 6: Run tests to verify they pass**

```bash
make test
```

Expected: PASS, 38 tests, 0 unexpected.

- [ ] **Step 7: Commit**

```bash
git add pretty-view-gfm.el tests/pretty-view-gfm-test.el
git commit -m "feat(gfm): parse block quotes, lists, and task list items"
```

---

### Task 5: GFM block parser — pipe tables

A GFM table is a header row, a delimiter row that sets alignment, and body rows. Cells carry `:raw` for later inline parsing.

**Files:**
- Modify: `pretty-view-gfm.el`
- Modify: `tests/pretty-view-gfm-test.el`

**Interfaces:**
- Consumes: `pretty-view-gfm--parse-blocks` from Task 2
- Produces:
  - `(:type table :align (SYM...) :children ROWS)` where each SYM is `left`, `center`, `right`, or nil
  - `(:type table-row :header BOOL :children CELLS)`
  - `(:type table-cell :align SYM :header BOOL :raw STRING)`

- [ ] **Step 1: Write the failing tests**

Append to `tests/pretty-view-gfm-test.el`:

```elisp
(ert-deftest pretty-view-gfm-test-table ()
  (let* ((node (pv-test-block "| a | b |\n|---|---|\n| 1 | 2 |"))
         (rows (plist-get node :children)))
    (should (eq (pv-test-type node) 'table))
    (should (= (length rows) 2))
    (should (plist-get (nth 0 rows) :header))
    (should-not (plist-get (nth 1 rows) :header))
    (should (equal (plist-get (nth 0 (plist-get (nth 0 rows) :children)) :raw)
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
    (should (equal (plist-get cell :raw) "x | y"))))

(ert-deftest pretty-view-gfm-test-table-ends-at-blank-line ()
  (let ((blocks (pv-test-blocks "| a |\n|---|\n| 1 |\n\nafter")))
    (should (= (length blocks) 2))
    (should (eq (pv-test-type (nth 1 blocks)) 'paragraph))))
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
make test
```

Expected: FAIL on all seven — `paragraph` where `table` was expected.

- [ ] **Step 3: Write the implementation**

Add to `pretty-view-gfm.el`:

```elisp
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
```

Add the clause to `pretty-view-gfm--parse-blocks`, before the paragraph
fallback:

```elisp
         ;; GFM pipe table.
         ((pretty-view-gfm--table-start-p lines)
          (let ((result (pretty-view-gfm--take-table lines)))
            (push (car result) nodes)
            (setq lines (cdr result))))
```

`pretty-view-gfm--table-start-p` reads the *next* line, so it must be
checked before the paragraph clause consumes both.

- [ ] **Step 4: Run tests to verify they pass**

```bash
make test
```

Expected: PASS, 45 tests, 0 unexpected.

- [ ] **Step 5: Commit**

```bash
git add pretty-view-gfm.el tests/pretty-view-gfm-test.el
git commit -m "feat(gfm): parse pipe tables with alignment"
```

---

### Task 6: GFM block parser — HTML blocks, link reference definitions, footnote definitions

The three remaining block constructs. Link reference definitions and footnote definitions produce no output of their own; they populate tables that Task 8 consults.

**Files:**
- Modify: `pretty-view-gfm.el`
- Modify: `tests/pretty-view-gfm-test.el`

**Interfaces:**
- Consumes: `pretty-view-gfm--parse-blocks` from Task 2
- Produces:
  - `(:type html-block :html STRING)`
  - `(:type footnote-definition :label STRING :children NODES)`
  - `pretty-view-gfm--link-refs` — a dynamically bound hash table, `test` `equal`, mapping a downcased label to `(HREF . TITLE)`. Bound by `pretty-view-gfm-parse`, read by Task 8.
  - `(pretty-view-gfm-link-ref LABEL)` → `(HREF . TITLE)` or nil

- [ ] **Step 1: Write the failing tests**

Append to `tests/pretty-view-gfm-test.el`:

```elisp
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
    (should (equal (plist-get (car (plist-get node :children)) :raw)
                   "the note"))))

(ert-deftest pretty-view-gfm-test-footnote-definition-continuation ()
  (let* ((node (pv-test-block "[^a]: first\n    second"))
         (para (car (plist-get node :children))))
    (should (equal (plist-get para :raw) "first\nsecond"))))

(ert-deftest pretty-view-gfm-test-footnote-is-not-a-link-reference ()
  (should (eq (pv-test-type (pv-test-block "[^a]: x")) 'footnote-definition)))
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
make test
```

Expected: FAIL on all nine — `paragraph` where `html-block`, `footnote-definition`, or nothing was expected, plus `void-function pretty-view-gfm-link-ref`.

- [ ] **Step 3: Write the implementation**

Add to `pretty-view-gfm.el`, near the top:

```elisp
(defvar pretty-view-gfm--link-refs nil
  "Hash table of link reference definitions for the document being parsed.
Maps a downcased label to a cons of href and title.  Bound by
`pretty-view-gfm-parse'.")

(defun pretty-view-gfm-link-ref (label)
  "Return the definition for LABEL as a cons of href and title, or nil."
  (and pretty-view-gfm--link-refs
       (gethash (downcase (string-trim label)) pretty-view-gfm--link-refs)))
```

Add the three constructs:

```elisp
(defconst pretty-view-gfm--html-block-re "\\` \\{0,3\\}<\\(?:[a-zA-Z/!?]\\)"
  "Match a line that opens an HTML block.")

(defconst pretty-view-gfm--link-def-re
  "\\` \\{0,3\\}\\[\\([^]^][^]]*\\|\\)\\][ \t]*:[ \t]*\\(\\S-+\\)\\(?:[ \t]+[\"'(]\\(.*?\\)[\"')]\\)?[ \t]*\\'"
  "Match a link reference definition.
Group 1 is the label, group 2 the destination, group 3 the title.")

(defconst pretty-view-gfm--footnote-def-re
  "\\` \\{0,3\\}\\[\\^\\([^]]+\\)\\][ \t]*:[ \t]*\\(.*\\)\\'"
  "Match a footnote definition.  Group 1 is the label, group 2 the text.")

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
```

Add these clauses to `pretty-view-gfm--parse-blocks`. The footnote clause
must precede the link-definition clause, because `[^a]: x` matches neither
pattern ambiguously only once the footnote form is tried first. Place both
before the paragraph fallback, and the HTML clause after the table clause:

```elisp
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
```

Bind the table in `pretty-view-gfm-parse`:

```elisp
(defun pretty-view-gfm-parse (string)
  "Parse STRING as GitHub Flavored Markdown and return a document node."
  (setq pretty-view-gfm--link-refs (make-hash-table :test #'equal))
  (let ((lines (split-string (string-trim-right string "\n") "\n")))
    (list :type 'document
          :children (if (equal lines '(""))
                        nil
                      (pretty-view-gfm--parse-blocks lines)))))
```

Note `setq`, not `let`: Task 8 resolves references during the inline pass,
which `pretty-view-gfm-parse` will call after the block pass, and the
tests read the table after parsing returns.

Finally, add the footnote, link-definition, and HTML patterns to the
interrupt test in `pretty-view-gfm--paragraph-end`.

- [ ] **Step 4: Run tests to verify they pass**

```bash
make test
```

Expected: PASS, 54 tests, 0 unexpected.

- [ ] **Step 5: Commit**

```bash
git add pretty-view-gfm.el tests/pretty-view-gfm-test.el
git commit -m "feat(gfm): parse HTML blocks, link references, and footnote definitions"
```

---

### Task 7: GFM inline parser — escapes, code spans, breaks, entities

The inline pass walks the block tree and replaces every `:raw` string with `:children`. This task builds the walker and the first tier of inline constructs; Tasks 8 and 9 extend the same scanner.

**Files:**
- Modify: `pretty-view-gfm.el`
- Modify: `tests/pretty-view-gfm-test.el`

**Interfaces:**
- Consumes: every block node with `:raw` from Tasks 2–6
- Produces:
  - `(pretty-view-gfm--resolve-inlines NODES)` → NODES with each `:raw` replaced by `:children`
  - `(pretty-view-gfm--parse-inlines STRING)` → node list
  - `(:type text :value STRING)`, `(:type code-span :code STRING)`, `(:type line-break)`, `(:type soft-break)`

- [ ] **Step 1: Write the failing tests**

Append to `tests/pretty-view-gfm-test.el`:

```elisp
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
make test
```

Expected: FAIL on all twelve — blocks still carry `:raw` and no `:children`.

- [ ] **Step 3: Write the implementation**

Add to `pretty-view-gfm.el`:

```elisp
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
    (nreverse nodes)))

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
```

Add `(require 'cl-lib)` to the top of the file for `cl-flet`.

Wire the pass into `pretty-view-gfm-parse`:

```elisp
(defun pretty-view-gfm-parse (string)
  "Parse STRING as GitHub Flavored Markdown and return a document node."
  (setq pretty-view-gfm--link-refs (make-hash-table :test #'equal))
  (let* ((lines (split-string (string-trim-right string "\n") "\n"))
         (blocks (if (equal lines '(""))
                     nil
                   (pretty-view-gfm--parse-blocks lines))))
    (list :type 'document
          :children (pretty-view-gfm--resolve-inlines blocks))))
```

`plist-put` with a nil value leaves the `:raw` key present holding nil,
which is why `pretty-view-gfm-test-inline-plain-text` asserts
`(null (plist-get ... :raw))` rather than the key's absence.

- [ ] **Step 4: Run tests to verify they pass**

```bash
make test
```

Expected: PASS, 66 tests, 0 unexpected.

- [ ] **Step 5: Commit**

```bash
git add pretty-view-gfm.el tests/pretty-view-gfm-test.el
git commit -m "feat(gfm): parse inline escapes, code spans, and breaks"
```

---

### Task 8: GFM inline parser — links, images, autolinks, footnote references

**Files:**
- Modify: `pretty-view-gfm.el`
- Modify: `tests/pretty-view-gfm-test.el`

**Interfaces:**
- Consumes: `pretty-view-gfm--parse-inlines` from Task 7, `pretty-view-gfm-link-ref` from Task 6
- Produces:
  - `(:type link :href STRING :title STRING-OR-NIL :children NODES)`
  - `(:type image :src STRING :alt STRING :title STRING-OR-NIL)`
  - `(:type autolink :href STRING :children NODES)`
  - `(:type footnote-reference :label STRING)`
  - `(:type html-inline :html STRING)`

- [ ] **Step 1: Write the failing tests**

Append to `tests/pretty-view-gfm-test.el`:

```elisp
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
make test
```

Expected: FAIL on all fourteen.

- [ ] **Step 3: Write the implementation**

Add to `pretty-view-gfm.el`:

```elisp
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
```

Add these clauses to the `cond` in `pretty-view-gfm--parse-inlines`, after
the code-span clause and before the fallback:

```elisp
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
                   ;; Trailing punctuation is sentence punctuation, not URL.
                   (url (replace-regexp-in-string "[.,:;!?)]+\\'" "" url)))
              (flush)
              (push (list :type 'autolink :href url
                          :children (list (list :type 'text :value url)))
                    nodes)
              (setq i (+ i (length url)))))
```

`pretty-view-gfm--link-at` runs twice per match — once in the guard, once
in the body. That is deliberate: it keeps the `cond` readable, and the
function is cheap and free of side effects.

- [ ] **Step 4: Run tests to verify they pass**

```bash
make test
```

Expected: PASS, 80 tests, 0 unexpected.

- [ ] **Step 5: Commit**

```bash
git add pretty-view-gfm.el tests/pretty-view-gfm-test.el
git commit -m "feat(gfm): parse links, images, autolinks, and footnote references"
```

---

### Task 9: GFM inline parser — emphasis, strong, strikethrough

The delimiter-run algorithm. Runs of `*`, `_`, and `~` are collected as they are scanned, then matched into pairs in a second pass over the node list.

**Files:**
- Modify: `pretty-view-gfm.el`
- Modify: `tests/pretty-view-gfm-test.el`

**Interfaces:**
- Consumes: `pretty-view-gfm--parse-inlines` from Tasks 7–8
- Produces: `(:type emphasis :children NODES)`, `(:type strong :children NODES)`, `(:type strikethrough :children NODES)`

- [ ] **Step 1: Write the failing tests**

Append to `tests/pretty-view-gfm-test.el`:

```elisp
(ert-deftest pretty-view-gfm-test-emphasis-asterisk ()
  (let ((node (pv-test-inline "*em*")))
    (should (eq (pv-test-type node) 'emphasis))
    (should (equal (pv-test-text node) "em"))))

(ert-deftest pretty-view-gfm-test-emphasis-underscore ()
  (should (eq (pv-test-type (pv-test-inline "_em_")) 'emphasis)))

(ert-deftest pretty-view-gfm-test-strong ()
  (let ((node (pv-test-inline "**strong**")))
    (should (eq (pv-test-type node) 'strong))
    (should (equal (pv-test-text node) "strong"))))

(ert-deftest pretty-view-gfm-test-strong-underscore ()
  (should (eq (pv-test-type (pv-test-inline "__strong__")) 'strong)))

(ert-deftest pretty-view-gfm-test-strikethrough ()
  (let ((node (pv-test-inline "~~gone~~")))
    (should (eq (pv-test-type node) 'strikethrough))
    (should (equal (pv-test-text node) "gone"))))

(ert-deftest pretty-view-gfm-test-nested-emphasis-in-strong ()
  (let* ((strong (pv-test-inline "**a *b* c**"))
         (inner (nth 1 (plist-get strong :children))))
    (should (eq (pv-test-type strong) 'strong))
    (should (eq (pv-test-type inner) 'emphasis))))

(ert-deftest pretty-view-gfm-test-intraword-underscore-is-literal ()
  "GFM does not emphasize inside a word with underscores."
  (should (equal (pv-test-text (pv-test-block "snake_case_name"))
                 "snake_case_name")))

(ert-deftest pretty-view-gfm-test-intraword-asterisk-emphasizes ()
  (let ((node (pv-test-inline "a*b*c" 1)))
    (should (eq (pv-test-type node) 'emphasis))))

(ert-deftest pretty-view-gfm-test-unmatched-delimiter-is-literal ()
  (should (equal (pv-test-text (pv-test-block "*unclosed")) "*unclosed"))
  (should (equal (pv-test-text (pv-test-block "a ** b")) "a ** b")))

(ert-deftest pretty-view-gfm-test-emphasis-not-across-blocks ()
  (let ((blocks (pv-test-blocks "*a\n\nb*")))
    (should (equal (pv-test-text (nth 0 blocks)) "*a"))))

(ert-deftest pretty-view-gfm-test-escaped-delimiter-is-not-a-delimiter ()
  (should (equal (pv-test-text (pv-test-block "\\*a\\*")) "*a*")))

(ert-deftest pretty-view-gfm-test-delimiter-inside-code-span-is-literal ()
  (let ((span (pv-test-inline "`*x*`")))
    (should (eq (pv-test-type span) 'code-span))
    (should (equal (plist-get span :code) "*x*"))))
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
make test
```

Expected: FAIL on the emphasis, strong, strikethrough, and nesting tests. The literal-text tests already pass, which is the point of including them — they guard against a regression when emphasis lands.

- [ ] **Step 3: Write the implementation**

Add to `pretty-view-gfm.el`:

```elisp
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
                       (avail (min (plist-get node :count)
                                   (plist-get (aref nodes found) :count)))
                       (use (cond ((eq char ?~) (if (>= avail 2) 2 0))
                                  ((>= avail 2) 2)
                                  (t 1))))
                  (when (> use 0)
                    (let ((type (cond ((eq char ?~) 'strikethrough)
                                      ((= use 2) 'strong)
                                      (t 'emphasis)))
                          (inner nil))
                      (let ((k (1+ found)))
                        (while (< k closer)
                          (when (aref nodes k) (push (aref nodes k) inner))
                          (aset nodes k nil)
                          (setq k (1+ k))))
                      (pretty-view-gfm--consume-delimiter nodes found use)
                      (pretty-view-gfm--consume-delimiter nodes closer use)
                      (aset nodes found
                            (list :type type :children (nreverse inner)))
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
```

Add this clause to the `cond` in `pretty-view-gfm--parse-inlines`, after
the bare-URL clause and before the fallback:

```elisp
           ;; Emphasis, strong, strikethrough delimiter run.
           ((and (memq c '(?* ?_ ?~))
                 (pretty-view-gfm--delimiter-at string i))
            (let ((node (pretty-view-gfm--delimiter-at string i)))
              (flush)
              (push node nodes)
              (setq i (plist-get node :end))))
```

And run the matcher on the way out. Replace the final `(nreverse nodes)`
of `pretty-view-gfm--parse-inlines` with:

```elisp
    (pretty-view-gfm--match-delimiters (nreverse nodes))
```

Emphasis cannot cross a block boundary because each block's `:raw` string
is parsed on its own, which is what
`pretty-view-gfm-test-emphasis-not-across-blocks` checks.

- [ ] **Step 4: Run tests to verify they pass**

```bash
make test
```

Expected: PASS, 92 tests, 0 unexpected.

- [ ] **Step 5: Commit**

```bash
git add pretty-view-gfm.el tests/pretty-view-gfm-test.el
git commit -m "feat(gfm): parse emphasis, strong, and strikethrough"
```

---

### Task 10: Code highlighting through font-lock

Renders code by activating the real major mode in a temporary buffer, running `font-lock-ensure`, and walking the text properties. This is what replaces `htmlize` and what gives Org and Markdown identical code blocks.

**Files:**
- Modify: `pretty-view-render.el`
- Modify: `tests/pretty-view-render-test.el`

**Interfaces:**
- Consumes: `pretty-view-escape-html` from Task 1
- Produces:
  - `(pretty-view-render-fontified-code CODE LANG)` → HTML string, the inner content of a `<code>` element
  - `pretty-view-code-mode-alist` — alist of info string → major mode symbol
  - `pretty-view-face-class-alist` — alist of face symbol → CSS class string

- [ ] **Step 1: Write the failing tests**

Append to `tests/pretty-view-render-test.el`:

```elisp
(ert-deftest pretty-view-render-test-fontified-code-emits-spans ()
  (let ((html (pretty-view-render-fontified-code "(defun foo ())" "elisp")))
    (should (string-match-p "<span class=\"pv-keyword\">defun</span>" html))
    (should (string-match-p "foo" html))))

(ert-deftest pretty-view-render-test-fontified-code-escapes ()
  (let ((html (pretty-view-render-fontified-code "a < b & c" nil)))
    (should (string-match-p "&lt;" html))
    (should (string-match-p "&amp;" html))
    (should-not (string-match-p "[^&]< " html))))

(ert-deftest pretty-view-render-test-fontified-code-unknown-language ()
  "An unknown language yields escaped plain text, not an error."
  (let ((html (pretty-view-render-fontified-code "x < y" "no-such-lang")))
    (should (equal html "x &lt; y"))))

(ert-deftest pretty-view-render-test-fontified-code-nil-language ()
  (should (equal (pretty-view-render-fontified-code "plain" nil) "plain")))

(ert-deftest pretty-view-render-test-code-mode-alist-alias ()
  (let ((pretty-view-code-mode-alist '(("elisp" . emacs-lisp-mode))))
    (should (eq (pretty-view-render--code-mode "elisp") 'emacs-lisp-mode))))

(ert-deftest pretty-view-render-test-code-mode-suffix-fallback ()
  "A language with no alist entry falls back to LANG-mode."
  (let ((pretty-view-code-mode-alist nil))
    (should (eq (pretty-view-render--code-mode "emacs-lisp") 'emacs-lisp-mode))
    (should (null (pretty-view-render--code-mode "definitely-not-a-mode")))))

(ert-deftest pretty-view-render-test-face-normalization ()
  "A face property may be a symbol, a list, or an anonymous plist."
  (should (equal (pretty-view-render--face-class 'font-lock-keyword-face)
                 "pv-keyword"))
  (should (equal (pretty-view-render--face-class
                  '(font-lock-keyword-face default))
                 "pv-keyword"))
  (should (null (pretty-view-render--face-class '(:foreground "red"))))
  (should (null (pretty-view-render--face-class nil))))

(ert-deftest pretty-view-render-test-fontified-code-preserves-newlines ()
  (let ((html (pretty-view-render-fontified-code "a\nb\n" nil)))
    (should (equal html "a\nb\n"))))
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
make test
```

Expected: FAIL — `void-function pretty-view-render-fontified-code`.

- [ ] **Step 3: Write the implementation**

Add to `pretty-view-render.el`:

```elisp
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
      (or (cdr (assoc lang pretty-view-code-mode-alist))
          (let ((ts (intern (concat lang "-ts-mode"))))
            (and (fboundp ts) ts))
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
          (with-temp-buffer
            (insert code)
            (with-timeout (2 (pretty-view-escape-html code))
              (delay-mode-hooks (funcall mode))
              (font-lock-mode 1)
              (font-lock-ensure)
              (pretty-view-render--fontify-buffer-html)))
        (error (pretty-view-escape-html code))))))
```

Add `(require 'seq)` to the top of `pretty-view-render.el`, and declare
the customization group once, above the first `defcustom`:

```elisp
(defgroup pretty-view nil
  "Render Org, Markdown, and text buffers to styled HTML."
  :group 'convenience
  :prefix "pretty-view-")
```

`delay-mode-hooks` keeps a user's mode hooks — which may start LSP
servers or load large libraries — from running for a code block.
`with-timeout` bounds a pathological mode.

- [ ] **Step 4: Run tests to verify they pass**

```bash
make test
```

Expected: PASS, 100 tests, 0 unexpected.

- [ ] **Step 5: Commit**

```bash
git add pretty-view-render.el tests/pretty-view-render-test.el
git commit -m "feat(render): highlight code through font-lock without htmlize"
```

---

### Task 11: Renderer table and built-in renderers

Turns the AST into HTML through `pretty-view-renderers`, the package's central customization point.

**Files:**
- Modify: `pretty-view-render.el`
- Modify: `tests/pretty-view-render-test.el`

**Interfaces:**
- Consumes: every node type from Tasks 2–9; `pretty-view-render-fontified-code` from Task 10
- Produces:
  - `(pretty-view-render-document NODE)` → HTML string for a document node
  - `(pretty-view-render-nodes NODES)` → concatenated HTML; this is the `RENDER` argument handed to renderers
  - `(pretty-view-render-node NODE)` → HTML for one node, dispatching through `pretty-view-renderers`
  - `pretty-view-renderers` — alist of node type → `(lambda (NODE RENDER) ...)`
  - `pretty-view-allow-raw-html` — boolean defcustom

- [ ] **Step 1: Write the failing tests**

Append to `tests/pretty-view-render-test.el`, and add `(require 'pretty-view-gfm)` to its top:

```elisp
(defun pv-render (markdown)
  "Parse MARKDOWN and render it to HTML."
  (pretty-view-render-document (pretty-view-gfm-parse markdown)))

(ert-deftest pretty-view-render-test-heading ()
  (should (equal (pv-render "# Hi") "<h1 id=\"hi\">Hi</h1>\n")))

(ert-deftest pretty-view-render-test-paragraph ()
  (should (equal (pv-render "text") "<p>text</p>\n")))

(ert-deftest pretty-view-render-test-emphasis-and-strong ()
  (should (equal (pv-render "*a* **b**")
                 "<p><em>a</em> <strong>b</strong></p>\n")))

(ert-deftest pretty-view-render-test-strikethrough ()
  (should (equal (pv-render "~~x~~") "<p><del>x</del></p>\n")))

(ert-deftest pretty-view-render-test-code-span-escapes ()
  (should (equal (pv-render "`<b>`") "<p><code>&lt;b&gt;</code></p>\n")))

(ert-deftest pretty-view-render-test-code-block-has-language-class ()
  (let ((html (pv-render "```elisp\n(foo)\n```")))
    (should (string-match-p "<pre class=\"pv-code\"" html))
    (should (string-match-p "language-elisp" html))))

(ert-deftest pretty-view-render-test-link ()
  (should (equal (pv-render "[t](https://e.com)")
                 "<p><a href=\"https://e.com\">t</a></p>\n")))

(ert-deftest pretty-view-render-test-link-title-and-escaping ()
  (should (string-match-p "title=\"A &amp; B\""
                          (pv-render "[t](https://e.com \"A & B\")"))))

(ert-deftest pretty-view-render-test-image ()
  (should (equal (pv-render "![a](i.png)")
                 "<p><img src=\"i.png\" alt=\"a\" /></p>\n")))

(ert-deftest pretty-view-render-test-bullet-list ()
  (should (equal (pv-render "- a\n- b")
                 "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n")))

(ert-deftest pretty-view-render-test-ordered-list-start ()
  (should (string-match-p "<ol start=\"3\">" (pv-render "3. a"))))

(ert-deftest pretty-view-render-test-task-item ()
  (let ((html (pv-render "- [x] done")))
    (should (string-match-p "class=\"pv-task\"" html))
    (should (string-match-p "checked" html))
    (should (string-match-p "disabled" html))))

(ert-deftest pretty-view-render-test-blockquote ()
  (should (equal (pv-render "> q")
                 "<blockquote>\n<p>q</p>\n</blockquote>\n")))

(ert-deftest pretty-view-render-test-thematic-break ()
  (should (equal (pv-render "---") "<hr />\n")))

(ert-deftest pretty-view-render-test-table ()
  (let ((html (pv-render "| a |\n|:--|\n| 1 |")))
    (should (string-match-p "<table" html))
    (should (string-match-p "<th style=\"text-align:left\">a</th>" html))
    (should (string-match-p "<td style=\"text-align:left\">1</td>" html))))

(ert-deftest pretty-view-render-test-raw-html-passthrough ()
  (let ((pretty-view-allow-raw-html t))
    (should (string-match-p "<div>" (pv-render "<div>\n</div>")))))

(ert-deftest pretty-view-render-test-raw-html-escaped-when-disallowed ()
  (let ((pretty-view-allow-raw-html nil))
    (should (string-match-p "&lt;div&gt;" (pv-render "<div>\n</div>")))))

(ert-deftest pretty-view-render-test-user-renderer-override ()
  (let ((pretty-view-renderers
         (cons '(thematic-break . (lambda (_node _render) "<hr class=\"x\">"))
               pretty-view-renderers)))
    (should (equal (pv-render "---") "<hr class=\"x\">"))))

(ert-deftest pretty-view-render-test-signalling-renderer-falls-back ()
  "A broken override must not lose the document."
  (let* ((warned nil)
         (pretty-view-renderers
          (cons '(thematic-break . (lambda (_n _r) (error "boom")))
                pretty-view-renderers)))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (&rest _) (setq warned t))))
      (should (equal (pv-render "---") "<hr />\n"))
      (should warned))))

(ert-deftest pretty-view-render-test-unknown-node-type-renders-children ()
  (should (equal (pretty-view-render-node
                  '(:type no-such-type
                    :children ((:type text :value "x"))))
                 "x")))

(ert-deftest pretty-view-render-test-soft-break-becomes-newline ()
  (should (equal (pv-render "a\nb") "<p>a\nb</p>\n")))

(ert-deftest pretty-view-render-test-hard-break ()
  (should (equal (pv-render "a  \nb") "<p>a<br />\nb</p>\n")))

(ert-deftest pretty-view-render-test-footnotes ()
  (let ((html (pv-render "text[^a]\n\n[^a]: note")))
    (should (string-match-p "id=\"fnref-a\"" html))
    (should (string-match-p "href=\"#fn-a\"" html))
    (should (string-match-p "id=\"fn-a\"" html))))
```

Add `(require 'cl-lib)` to the test file for `cl-letf`.

- [ ] **Step 2: Run tests to verify they fail**

```bash
make test
```

Expected: FAIL — `void-function pretty-view-render-document`.

- [ ] **Step 3: Write the implementation**

Add to `pretty-view-render.el`:

```elisp
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

Every built-in renderer is a named function rather than an inline
lambda: a lambda inside a quoted `defcustom` value stays interpreted,
which costs a function call through the evaluator for every text node in
every document.  Named functions are byte-compiled, and they also give a
user overriding one entry something to call.

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
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
make test
```

Expected: PASS, 122 tests, 0 unexpected.

- [ ] **Step 5: Commit**

```bash
git add pretty-view-render.el tests/pretty-view-render-test.el
git commit -m "feat(render): AST to HTML through a replaceable renderer table"
```

---

### Task 12: Golden-file corpus

Pins the whole Markdown path — parse plus render — against realistic documents rather than one construct at a time. This is the regression net for every later change.

**Files:**
- Create: `tests/corpus/basic.md`, `tests/corpus/basic.html`
- Create: `tests/corpus/lists.md`, `tests/corpus/lists.html`
- Create: `tests/corpus/table-and-code.md`, `tests/corpus/table-and-code.html`
- Create: `tests/pretty-view-corpus-test.el`
- Create: `tools/regenerate-corpus.sh`

**Interfaces:**
- Consumes: `pretty-view-gfm-parse`, `pretty-view-render-document`
- Produces: a corpus test that fails loudly when rendering changes

- [ ] **Step 1: Write the corpus sources**

`tests/corpus/basic.md`:

```markdown
# Title

A paragraph with *emphasis*, **strong**, ~~struck~~, and `code`.

A [link](https://example.com "Home") and an ![image](pic.png).

> A quote.
>
> With two paragraphs.

---

Text with a footnote[^note].

[^note]: The note body.
```

`tests/corpus/lists.md`:

```markdown
## Lists

- first
- second
  - nested
- third

1. one
2. two

- [ ] open
- [x] closed
```

`tests/corpus/table-and-code.md`:

````markdown
## Data

| Name | Count | Note |
|:-----|------:|:----:|
| a    |     1 | x    |
| b    |     2 | y    |

```elisp
(defun greet (name)
  "Say hello to NAME."
  (message "hello %s" name))
```

    indented code
    second line
````

- [ ] **Step 2: Write the failing test**

Create `tests/pretty-view-corpus-test.el`:

```elisp
;;; pretty-view-corpus-test.el --- Golden-file tests  -*- lexical-binding: t -*-
;;; Commentary:
;; Renders each tests/corpus/NAME.md and compares it against NAME.html.
;; Regenerate with tools/regenerate-corpus.sh after an intentional change,
;; then read the diff before committing.
;;; Code:

(require 'ert)
(require 'pretty-view-gfm)
(require 'pretty-view-render)

(defconst pretty-view-corpus-directory
  (expand-file-name "corpus"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Directory holding the golden-file corpus.")

(defun pretty-view-corpus-render (name)
  "Render corpus document NAME and return its HTML."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name (concat name ".md") pretty-view-corpus-directory))
    (pretty-view-render-document
     (pretty-view-gfm-parse (buffer-string)))))

(defun pretty-view-corpus-expected (name)
  "Return the recorded HTML for corpus document NAME."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name (concat name ".html") pretty-view-corpus-directory))
    (buffer-string)))

(defmacro pretty-view-corpus-deftest (name)
  "Define an ERT test comparing corpus document NAME against its golden file."
  `(ert-deftest ,(intern (format "pretty-view-corpus-test-%s" name)) ()
     (should (equal (pretty-view-corpus-render ,name)
                    (pretty-view-corpus-expected ,name)))))

(pretty-view-corpus-deftest "basic")
(pretty-view-corpus-deftest "lists")
(pretty-view-corpus-deftest "table-and-code")

(provide 'pretty-view-corpus-test)
;;; pretty-view-corpus-test.el ends here
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
make test
```

Expected: FAIL — the `.html` files do not exist yet.

- [ ] **Step 4: Write the regeneration script**

Create `tools/regenerate-corpus.sh`:

```bash
#!/usr/bin/env bash
# Regenerate the golden HTML for every tests/corpus/*.md.
# Run this only after an intentional rendering change, then read the diff.
set -euo pipefail
cd "$(dirname "$0")/.."
for md in tests/corpus/*.md; do
  emacs -Q --batch -L . \
    --eval "(progn
              (require 'pretty-view-gfm)
              (require 'pretty-view-render)
              (with-temp-buffer
                (insert-file-contents \"$md\")
                (let ((html (pretty-view-render-document
                             (pretty-view-gfm-parse (buffer-string)))))
                  (with-temp-file \"${md%.md}.html\"
                    (insert html)))))"
  echo "wrote ${md%.md}.html"
done
```

Make it executable and run it:

```bash
chmod +x tools/regenerate-corpus.sh
./tools/regenerate-corpus.sh
```

- [ ] **Step 5: Read the generated HTML before trusting it**

```bash
cat tests/corpus/basic.html tests/corpus/lists.html tests/corpus/table-and-code.html
```

Check by eye: headings carry ids, the nested list is inside the parent
`<li>`, table cells carry the alignment from the delimiter row, the elisp
block has `pv-keyword` spans, the footnote pair links both ways. Fix the
renderer and regenerate if any of it is wrong — a golden file recording a
bug is worse than no golden file.

- [ ] **Step 6: Run the test to verify it passes**

```bash
make test
```

Expected: PASS, 125 tests, 0 unexpected.

- [ ] **Step 7: Commit**

```bash
git add tests/corpus tests/pretty-view-corpus-test.el tools/regenerate-corpus.sh
git commit -m "test: pin the markdown path with a golden-file corpus"
```

---

### Task 13: Theme registry and CSS generation

The mechanism, with no themes in it yet. A palette plist becomes a block of CSS custom properties; a missing slot inherits the default palette; an unknown slot is an error at definition time.

**Files:**
- Create: `pretty-view-theme.el`
- Create: `tests/pretty-view-theme-test.el`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `(pretty-view-define-theme NAME &rest PALETTE)` → registers and returns NAME
  - `(pretty-view-theme-palette NAME)` → the palette merged over the defaults, or nil when NAME is unknown
  - `(pretty-view-theme-css NAME)` → the complete stylesheet as a string
  - `(pretty-view-theme-names)` → a list of registered theme symbols
  - `pretty-view-theme-default-palette` — the plist of slot defaults
  - `pretty-view-theme` and `pretty-view-default-light-theme` — defcustoms

- [ ] **Step 1: Write the failing tests**

Create `tests/pretty-view-theme-test.el`:

```elisp
;;; pretty-view-theme-test.el --- Tests for the theme layer  -*- lexical-binding: t -*-
;;; Commentary:
;; Palette merging, CSS generation, and automatic dark mode.
;;; Code:

(require 'ert)
(require 'pretty-view-theme)

(defmacro pv-with-clean-themes (&rest body)
  "Run BODY with an empty theme registry."
  `(let ((pretty-view-theme--registry (make-hash-table :test #'eq)))
     ,@body))

(ert-deftest pretty-view-theme-test-define-and-lookup ()
  (pv-with-clean-themes
   (pretty-view-define-theme 'demo :bg "#000" :fg "#fff")
   (should (memq 'demo (pretty-view-theme-names)))
   (should (equal (plist-get (pretty-view-theme-palette 'demo) :bg) "#000"))))

(ert-deftest pretty-view-theme-test-missing-slot-inherits-default ()
  (pv-with-clean-themes
   (pretty-view-define-theme 'demo :bg "#000")
   (should (equal (plist-get (pretty-view-theme-palette 'demo) :accent)
                  (plist-get pretty-view-theme-default-palette :accent)))))

(ert-deftest pretty-view-theme-test-unknown-slot-signals ()
  (pv-with-clean-themes
   (should-error (pretty-view-define-theme 'demo :bgg "#000"))))

(ert-deftest pretty-view-theme-test-unknown-theme-returns-nil ()
  (pv-with-clean-themes
   (should (null (pretty-view-theme-palette 'nope)))))

(ert-deftest pretty-view-theme-test-css-emits-custom-properties ()
  (pv-with-clean-themes
   (pretty-view-define-theme 'demo :bg "#123456")
   (let ((css (pretty-view-theme-css 'demo)))
     (should (string-match-p ":root" css))
     (should (string-match-p "--pv-bg: *#123456" css)))))

(ert-deftest pretty-view-theme-test-css-includes-base-stylesheet ()
  (pv-with-clean-themes
   (pretty-view-define-theme 'demo :bg "#000")
   (should (string-match-p "var(--pv-bg)" (pretty-view-theme-css 'demo)))))

(ert-deftest pretty-view-theme-test-extra-css-is-appended-last ()
  (pv-with-clean-themes
   (pretty-view-define-theme 'demo :bg "#000" :extra-css ".marker{}")
   (let ((css (pretty-view-theme-css 'demo)))
     (should (string-match-p "\\.marker{}" css))
     (should (> (string-match "\\.marker{}" css)
                (string-match "var(--pv-bg)" css))))))

(ert-deftest pretty-view-theme-test-auto-emits-both-palettes ()
  (pv-with-clean-themes
   (pretty-view-define-theme 'dark-demo :bg "#111111")
   (pretty-view-define-theme 'light-demo :bg "#eeeeee" :dark-variant 'dark-demo)
   (let* ((pretty-view-default-light-theme 'light-demo)
          (css (pretty-view-theme-css 'auto)))
     (should (string-match-p "#eeeeee" css))
     (should (string-match-p "#111111" css))
     (should (string-match-p "prefers-color-scheme: *dark" css)))))

(ert-deftest pretty-view-theme-test-auto-without-dark-variant ()
  "A light theme with no dark variant still produces valid CSS."
  (pv-with-clean-themes
   (pretty-view-define-theme 'solo :bg "#eeeeee")
   (let* ((pretty-view-default-light-theme 'solo)
          (css (pretty-view-theme-css 'auto)))
     (should (string-match-p "#eeeeee" css))
     (should-not (string-match-p "prefers-color-scheme" css)))))

(ert-deftest pretty-view-theme-test-unknown-theme-css-falls-back ()
  "An unknown theme name must still produce a usable stylesheet."
  (pv-with-clean-themes
   (let ((css (pretty-view-theme-css 'nope)))
     (should (string-match-p "var(--pv-bg)" css))
     (should (string-match-p "--pv-bg" css)))))

(provide 'pretty-view-theme-test)
;;; pretty-view-theme-test.el ends here
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
make test
```

Expected: FAIL — `Cannot open load file: pretty-view-theme`.

- [ ] **Step 3: Write the implementation**

Create `pretty-view-theme.el` with the standard GPL header and:

```elisp
;;; Commentary:

;; Themes are palette plists.  Every theme fills the same slots, so
;; coverage is uniform; a slot a theme omits inherits the default
;; palette, and an unknown slot is an error at definition time so a typo
;; cannot silently do nothing.  A palette becomes a block of CSS custom
;; properties that the one static stylesheet reads.  Themes never
;; restate layout.

;;; Code:

(require 'seq)
(require 'subr-x)                       ; hash-table-keys is not preloaded

(defvar pretty-view-theme--registry (make-hash-table :test #'eq)
  "Registered themes, mapping a theme symbol to its palette plist.")

(defconst pretty-view-theme-default-palette
  '(:bg "#ffffff" :fg "#1f2328" :muted "#59636e"
    :accent "#0969da" :accent-muted "#ddf4ff"
    :border "#d1d9e0" :rule "#d1d9e0"
    :code-bg "#f6f8fa" :code-fg "#1f2328" :code-border "#d1d9e0"
    :quote-border "#d1d9e0" :quote-fg "#59636e"
    :table-stripe "#f6f8fa"
    :mark-bg "#fff8c5"
    :keyword "#cf222e" :string "#0a3069" :comment "#59636e"
    :doc "#0a3069" :function "#8250df" :variable "#1f2328"
    :type "#953800" :constant "#0550ae" :builtin "#0550ae"
    :preprocessor "#8250df" :operator "#1f2328"
    :escape "#0550ae" :warning "#9a6700"
    :body-font "-apple-system, BlinkMacSystemFont, \"Segoe UI\", \"Noto Sans KR\", \"Apple SD Gothic Neo\", \"Malgun Gothic\", Helvetica, Arial, sans-serif"
    :mono-font "\"D2CodingLigature NF\", \"D2Coding\", ui-monospace, SFMono-Regular, \"SF Mono\", Menlo, Consolas, monospace"
    :measure "46rem" :radius "6px" :line-height "1.65"
    :dark-variant nil :extra-css nil)
  "Default value for every palette slot.
A theme that omits a slot inherits the value here.  The set of keys in
this plist is the complete set of legal slots.")

(defun pretty-view-theme--slots ()
  "Return the list of legal palette slot keywords."
  (seq-filter #'keywordp pretty-view-theme-default-palette))

(defun pretty-view-define-theme (name &rest palette)
  "Register theme NAME with PALETTE, a plist of slot keywords and values.
Slots omitted from PALETTE inherit `pretty-view-theme-default-palette'.
Signals when PALETTE names a slot that does not exist."
  (let ((legal (pretty-view-theme--slots))
        (keys (seq-filter #'keywordp palette)))
    (dolist (key keys)
      (unless (memq key legal)
        (error "pretty-view: unknown theme slot `%s' in theme `%s'" key name))))
  (puthash name palette pretty-view-theme--registry)
  name)

(defun pretty-view-theme-names ()
  "Return the list of registered theme symbols."
  (hash-table-keys pretty-view-theme--registry))

(defun pretty-view-theme-palette (name)
  "Return the palette for theme NAME merged over the defaults, or nil."
  (let ((palette (gethash name pretty-view-theme--registry)))
    (when palette
      (let ((merged (copy-sequence pretty-view-theme-default-palette)))
        (dolist (key (seq-filter #'keywordp palette))
          (setq merged (plist-put merged key (plist-get palette key))))
        merged))))

(defconst pretty-view-theme--css-slots
  '((:bg . "bg") (:fg . "fg") (:muted . "muted")
    (:accent . "accent") (:accent-muted . "accent-muted")
    (:border . "border") (:rule . "rule")
    (:code-bg . "code-bg") (:code-fg . "code-fg")
    (:code-border . "code-border")
    (:quote-border . "quote-border") (:quote-fg . "quote-fg")
    (:table-stripe . "table-stripe") (:mark-bg . "mark-bg")
    (:keyword . "keyword") (:string . "string") (:comment . "comment")
    (:doc . "doc") (:function . "function") (:variable . "variable")
    (:type . "type") (:constant . "constant") (:builtin . "builtin")
    (:preprocessor . "preprocessor") (:operator . "operator")
    (:escape . "escape") (:warning . "warning")
    (:body-font . "body-font") (:mono-font . "mono-font")
    (:measure . "measure") (:radius . "radius")
    (:line-height . "line-height"))
  "Map a palette slot to the CSS custom property name it fills.
Slots absent from this list carry no colour or metric, such as
`:dark-variant' and `:extra-css'.")

(defun pretty-view-theme--properties (palette)
  "Return PALETTE as CSS custom property declarations."
  (mapconcat
   (lambda (pair)
     (let ((value (plist-get palette (car pair))))
       (if value (format "  --pv-%s: %s;\n" (cdr pair) value) "")))
   pretty-view-theme--css-slots ""))

(defun pretty-view-theme--variables (palette selector)
  "Return a SELECTOR rule holding PALETTE's custom properties."
  (format "%s {\n%s}\n" selector (pretty-view-theme--properties palette)))

(defun pretty-view-theme-css (name)
  "Return the complete stylesheet for theme NAME.
NAME may be `auto', in which case `pretty-view-default-light-theme' and
its `:dark-variant' are both emitted, the dark one inside a
`prefers-color-scheme' query.  An unknown NAME falls back to the
default palette so the page is always styled."
  (if (eq name 'auto)
      (let* ((light-name pretty-view-default-light-theme)
             (light (or (pretty-view-theme-palette light-name)
                        pretty-view-theme-default-palette))
             (dark-name (plist-get light :dark-variant))
             (dark (and dark-name (pretty-view-theme-palette dark-name))))
        (concat
         (pretty-view-theme--variables light ":root")
         (when dark
           (format "@media (prefers-color-scheme: dark) {\n%s}\n"
                   (pretty-view-theme--variables dark ":root")))
         pretty-view-theme--base-stylesheet
         (or (plist-get light :extra-css) "")))
    (let ((palette (or (pretty-view-theme-palette name)
                       pretty-view-theme-default-palette)))
      (concat
       (pretty-view-theme--variables palette ":root")
       pretty-view-theme--base-stylesheet
       (or (plist-get palette :extra-css) "")))))

(provide 'pretty-view-theme)
;;; pretty-view-theme.el ends here
```

Also add the two defcustoms, above `pretty-view-theme-css`:

```elisp
(defcustom pretty-view-theme 'github-light
  "Theme used to style rendered documents.
A theme symbol registered with `pretty-view-define-theme', or `auto' to
follow the operating system's light and dark setting."
  :type 'symbol
  :group 'pretty-view)

(defcustom pretty-view-default-light-theme 'github-light
  "Light half of the pair used when `pretty-view-theme' is `auto'.
Its `:dark-variant' supplies the dark half."
  :type 'symbol
  :group 'pretty-view)
```

`pretty-view-theme.el` references `pretty-view--group` indirectly through
`:group 'pretty-view'`; add a `(defgroup pretty-view ...)` guard so the
file loads standalone:

```elisp
(defgroup pretty-view nil
  "Render Org, Markdown, and text buffers to styled HTML."
  :group 'convenience
  :prefix "pretty-view-")
```

Defining the same group in two files is harmless; `defgroup` is
idempotent.

`pretty-view-theme--base-stylesheet` is defined in Task 14. To keep this
task's tests green, add a placeholder at the top of the file that Task 14
replaces:

```elisp
(defconst pretty-view-theme--base-stylesheet
  "body { background: var(--pv-bg); color: var(--pv-fg); }\n"
  "The static stylesheet, written against the CSS custom properties.")
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
make test
```

Expected: PASS, 135 tests, 0 unexpected.

- [ ] **Step 5: Commit**

```bash
git add pretty-view-theme.el tests/pretty-view-theme-test.el
git commit -m "feat(theme): palette registry and CSS custom property generation"
```

---

### Task 14: The static stylesheet and the five bundled themes

The one place layout and typography are decided, plus the palettes that colour it.

**Files:**
- Modify: `pretty-view-theme.el` — replace the placeholder stylesheet
- Create: `pretty-view-themes.el`
- Modify: `tests/pretty-view-theme-test.el`

**Interfaces:**
- Consumes: `pretty-view-define-theme` from Task 13
- Produces: themes `github-light`, `github-dark`, `sepia`, `nord`, `cyberpunk`, registered on load of `pretty-view-themes.el`

**Design note:** this is the task where the package acquires a look. Before writing the stylesheet, invoke the `frontend-design` skill for guidance on typography and visual direction, so the result reads as a deliberate document design rather than as browser defaults with colours applied.

- [ ] **Step 1: Write the failing tests**

Append to `tests/pretty-view-theme-test.el`, and add `(require 'pretty-view-themes)` to its top:

```elisp
(ert-deftest pretty-view-themes-test-all-five-registered ()
  (dolist (name '(github-light github-dark sepia nord cyberpunk))
    (should (pretty-view-theme-palette name))))

(ert-deftest pretty-view-themes-test-every-theme-fills-every-colour-slot ()
  "A theme missing a colour would inherit a light default and break in dark."
  (dolist (name '(github-light github-dark sepia nord cyberpunk))
    (let ((palette (pretty-view-theme-palette name)))
      (dolist (slot '(:bg :fg :muted :accent :border :code-bg :code-fg
                      :quote-border :quote-fg :table-stripe
                      :keyword :string :comment :function :variable
                      :type :constant :builtin))
        (should (plist-get palette slot))))))

(ert-deftest pretty-view-themes-test-light-themes-declare-a-dark-variant ()
  (should (eq (plist-get (pretty-view-theme-palette 'github-light)
                         :dark-variant)
              'github-dark))
  (should (plist-get (pretty-view-theme-palette 'sepia) :dark-variant)))

(ert-deftest pretty-view-themes-test-css-is-generated-for-each ()
  (dolist (name '(github-light github-dark sepia nord cyberpunk))
    (let ((css (pretty-view-theme-css name)))
      (should (> (length css) 500))
      (should (string-match-p "--pv-bg" css)))))

(ert-deftest pretty-view-theme-test-base-stylesheet-styles-every-class ()
  "Every class the renderers emit must be styled."
  (let ((css pretty-view-theme--base-stylesheet))
    (dolist (class '("pv-code" "pv-table" "pv-task" "pv-footnote" "pv-fnref"
                     "pv-keyword" "pv-string" "pv-comment" "pv-function"
                     "pv-variable" "pv-type" "pv-constant" "pv-builtin"
                     "pv-toc"))
      (should (string-match-p (regexp-quote class) css)))))
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
make test
```

Expected: FAIL — `Cannot open load file: pretty-view-themes`, and the base-stylesheet test fails against the placeholder.

- [ ] **Step 3: Write the static stylesheet**

Replace the placeholder `pretty-view-theme--base-stylesheet` in
`pretty-view-theme.el` with the real one. It is written against the
custom properties only — no literal colours anywhere, so every theme
gets identical layout.

```elisp
(defconst pretty-view-theme--base-stylesheet "
*, *::before, *::after { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body {
  margin: 0;
  padding-block: 3rem;
  padding-inline: max(1rem, calc((100% - var(--pv-measure)) / 2));
  background: var(--pv-bg);
  color: var(--pv-fg);
  font-family: var(--pv-body-font);
  font-size: 1rem;
  line-height: var(--pv-line-height);
  overflow-wrap: break-word;
}
.pv-doc > *:first-child { margin-top: 0; }

h1, h2, h3, h4, h5, h6 {
  margin: 2.2em 0 0.7em;
  line-height: 1.25;
  font-weight: 650;
  letter-spacing: -0.01em;
}
h1 { font-size: 2em; }
h2 { font-size: 1.5em; }
h3 { font-size: 1.22em; }
h4 { font-size: 1.05em; }
h5, h6 { font-size: 1em; color: var(--pv-muted); }
h1, h2 { padding-bottom: 0.3em; border-bottom: 1px solid var(--pv-rule); }

p { margin: 0 0 1.1em; }
a { color: var(--pv-accent); text-decoration: none; }
a:hover { text-decoration: underline; }
strong { font-weight: 650; }
mark { background: var(--pv-mark-bg); color: inherit; }
small { color: var(--pv-muted); }

ul, ol { margin: 0 0 1.1em; padding-left: 1.6em; }
li { margin: 0.25em 0; }
li > ul, li > ol { margin-bottom: 0.2em; }
li.pv-task { list-style: none; margin-left: -1.4em; }
li.pv-task input { margin-right: 0.45em; vertical-align: middle; }

blockquote {
  margin: 0 0 1.1em;
  padding: 0.1em 1em;
  border-left: 0.25em solid var(--pv-quote-border);
  color: var(--pv-quote-fg);
}
blockquote > *:last-child { margin-bottom: 0; }

hr { height: 1px; margin: 2em 0; border: 0; background: var(--pv-rule); }

img { max-width: 100%; height: auto; border-radius: var(--pv-radius); }

code, kbd, samp {
  font-family: var(--pv-mono-font);
  font-size: 0.88em;
}
:not(pre) > code {
  padding: 0.15em 0.36em;
  background: var(--pv-code-bg);
  border-radius: var(--pv-radius);
}
pre.pv-code {
  margin: 0 0 1.2em;
  padding: 0.9em 1em;
  max-width: 100%;
  overflow-x: auto;
  background: var(--pv-code-bg);
  color: var(--pv-code-fg);
  border: 1px solid var(--pv-code-border);
  border-radius: var(--pv-radius);
  line-height: 1.5;
}
pre.pv-code code { padding: 0; background: none; }

table.pv-table {
  display: block;
  max-width: 100%;
  overflow-x: auto;
  margin: 0 0 1.3em;
  border-collapse: collapse;
  font-variant-numeric: tabular-nums;
}
table.pv-table th, table.pv-table td {
  padding: 0.45em 0.85em;
  border: 1px solid var(--pv-border);
}
table.pv-table th { background: var(--pv-table-stripe); font-weight: 650; }
table.pv-table tbody tr:nth-child(even) { background: var(--pv-table-stripe); }

nav.pv-toc {
  margin: 0 0 2.5em;
  padding: 0.9em 1.1em;
  background: var(--pv-code-bg);
  border: 1px solid var(--pv-border);
  border-radius: var(--pv-radius);
  font-size: 0.94em;
}
nav.pv-toc ul { margin: 0; padding: 0; list-style: none; }
nav.pv-toc li { margin: 0.15em 0; }
nav.pv-toc .pv-toc-2 { padding-left: 1em; }
nav.pv-toc .pv-toc-3 { padding-left: 2em; }
nav.pv-toc .pv-toc-4, nav.pv-toc .pv-toc-5, nav.pv-toc .pv-toc-6 {
  padding-left: 3em;
  color: var(--pv-muted);
}

sup.pv-fnref { font-size: 0.75em; }
sup.pv-fnref a { padding: 0 0.15em; }
.pv-footnote {
  margin: 0.4em 0;
  padding-left: 0.2em;
  font-size: 0.92em;
  color: var(--pv-muted);
}
.pv-footnote > p { display: inline; margin: 0; }
.pv-fnback { margin-left: 0.4em; }

p.pv-text { white-space: pre-wrap; }

.pv-error {
  margin: 1em 0;
  padding: 0.8em 1em;
  border: 1px solid var(--pv-warning);
  border-left-width: 0.25em;
  border-radius: var(--pv-radius);
  background: var(--pv-code-bg);
}

.pv-keyword      { color: var(--pv-keyword); }
.pv-string       { color: var(--pv-string); }
.pv-comment      { color: var(--pv-comment); font-style: italic; }
.pv-doc          { color: var(--pv-doc); font-style: italic; }
.pv-function     { color: var(--pv-function); }
.pv-variable     { color: var(--pv-variable); }
.pv-type         { color: var(--pv-type); }
.pv-constant     { color: var(--pv-constant); }
.pv-builtin      { color: var(--pv-builtin); }
.pv-preprocessor { color: var(--pv-preprocessor); }
.pv-operator     { color: var(--pv-operator); }
.pv-escape       { color: var(--pv-escape); }
.pv-warning      { color: var(--pv-warning); }

@media (max-width: 34rem) {
  body { padding-block: 1.6rem; font-size: 0.97rem; }
  h1 { font-size: 1.7em; }
  h2 { font-size: 1.35em; }
}

@media print {
  body { padding: 0; color: #000; background: #fff; }
  nav.pv-toc { display: none; }
  pre.pv-code { white-space: pre-wrap; overflow-x: visible; }
  a { color: inherit; text-decoration: underline; }
}
"
  "The static stylesheet, written against the CSS custom properties.
Themes supply colours and metrics; layout is decided once, here.")
```

Three properties of this stylesheet the tests and the spec depend on, so
do not lose them while editing: the side gutter comes from a single
`padding-inline` on `body` using `max()`, so the page keeps at least 1rem
of margin at 400px; `pre.pv-code` and `table.pv-table` each scroll
sideways on their own, so the body never does; and there is no `@import`
and no external URL anywhere, because the package renders offline.

- [ ] **Step 4: Write the themes**

Create `pretty-view-themes.el` with the standard GPL header, this
Commentary, and these five definitions. The file is data: no logic
belongs here.

```elisp
;;; Commentary:

;; The bundled palettes.  This file is data; the machinery lives in
;; `pretty-view-theme.el'.  Every theme fills every colour slot, because
;; a slot left out inherits the light default and would be invisible on
;; a dark background.

;;; Code:

(require 'pretty-view-theme)

(defconst pretty-view-themes--serif-font
  "Charter, \"Iowan Old Style\", \"Source Serif 4\", \"Noto Serif KR\", Georgia, serif"
  "Serif stack used by the reading themes.")

(pretty-view-define-theme 'github-light
  :bg "#ffffff" :fg "#1f2328" :muted "#59636e"
  :accent "#0969da" :accent-muted "#ddf4ff"
  :border "#d1d9e0" :rule "#d1d9e0"
  :code-bg "#f6f8fa" :code-fg "#1f2328" :code-border "#d1d9e0"
  :quote-border "#d1d9e0" :quote-fg "#59636e"
  :table-stripe "#f6f8fa" :mark-bg "#fff8c5"
  :keyword "#cf222e" :string "#0a3069" :comment "#59636e"
  :doc "#0a3069" :function "#8250df" :variable "#1f2328"
  :type "#953800" :constant "#0550ae" :builtin "#0550ae"
  :preprocessor "#8250df" :operator "#1f2328"
  :escape "#0550ae" :warning "#9a6700"
  :dark-variant 'github-dark)

(pretty-view-define-theme 'github-dark
  :bg "#0d1117" :fg "#e6edf3" :muted "#8b949e"
  :accent "#4493f8" :accent-muted "#121d2f"
  :border "#30363d" :rule "#30363d"
  :code-bg "#161b22" :code-fg "#e6edf3" :code-border "#30363d"
  :quote-border "#30363d" :quote-fg "#8b949e"
  :table-stripe "#161b22" :mark-bg "#4a3f13"
  :keyword "#ff7b72" :string "#a5d6ff" :comment "#8b949e"
  :doc "#a5d6ff" :function "#d2a8ff" :variable "#e6edf3"
  :type "#ffa657" :constant "#79c0ff" :builtin "#79c0ff"
  :preprocessor "#d2a8ff" :operator "#ff7b72"
  :escape "#79c0ff" :warning "#d29922"
  :dark-variant 'github-dark)

(pretty-view-define-theme 'sepia
  :bg "#fbf3e4" :fg "#433422" :muted "#7d6a4f"
  :accent "#9a5b24" :accent-muted "#f0e2c8"
  :border "#ddcdae" :rule "#e2d4b7"
  :code-bg "#f3e8d2" :code-fg "#433422" :code-border "#ddcdae"
  :quote-border "#c9b189" :quote-fg "#6d5a3e"
  :table-stripe "#f3e8d2" :mark-bg "#f5e0a3"
  :keyword "#9a2f2f" :string "#4b6b2f" :comment "#8a7a5c"
  :doc "#4b6b2f" :function "#7a4b9a" :variable "#433422"
  :type "#96591a" :constant "#2f5d7c" :builtin "#2f5d7c"
  :preprocessor "#7a4b9a" :operator "#5c4a2e"
  :escape "#2f5d7c" :warning "#9a6b1a"
  :body-font pretty-view-themes--serif-font
  :measure "40rem" :line-height "1.75"
  :dark-variant 'nord)

(pretty-view-define-theme 'nord
  :bg "#2e3440" :fg "#d8dee9" :muted "#7b88a1"
  :accent "#88c0d0" :accent-muted "#3b4252"
  :border "#434c5e" :rule "#434c5e"
  :code-bg "#3b4252" :code-fg "#e5e9f0" :code-border "#4c566a"
  :quote-border "#4c566a" :quote-fg "#a9b3c6"
  :table-stripe "#353c4a" :mark-bg "#4c4322"
  :keyword "#81a1c1" :string "#a3be8c" :comment "#616e88"
  :doc "#a3be8c" :function "#88c0d0" :variable "#d8dee9"
  :type "#8fbcbb" :constant "#b48ead" :builtin "#81a1c1"
  :preprocessor "#b48ead" :operator "#81a1c1"
  :escape "#ebcb8b" :warning "#ebcb8b"
  :dark-variant 'nord)

(pretty-view-define-theme 'cyberpunk
  :bg "#0b0b12" :fg "#e8e6f0" :muted "#8b86a8"
  :accent "#ff2e88" :accent-muted "#2a0f1e"
  :border "#2b2740" :rule "#2b2740"
  :code-bg "#14121f" :code-fg "#e8e6f0" :code-border "#332e4d"
  :quote-border "#ff2e88" :quote-fg "#b7b1cf"
  :table-stripe "#14121f" :mark-bg "#3d2f10"
  :keyword "#ff2e88" :string "#9cf06b" :comment "#6b6590"
  :doc "#9cf06b" :function "#4de2ff" :variable "#e8e6f0"
  :type "#ffd866" :constant "#c792ea" :builtin "#4de2ff"
  :preprocessor "#c792ea" :operator "#ff9f4a"
  :escape "#ffd866" :warning "#ffd866"
  :dark-variant 'cyberpunk)

(provide 'pretty-view-themes)
;;; pretty-view-themes.el ends here
```

`github-dark`, `nord`, and `cyberpunk` name themselves as their own
`:dark-variant`, so `pretty-view-theme` set to one of them and then to
`auto` still produces valid CSS rather than falling back to the light
default.

- [ ] **Step 5: Run tests to verify they pass**

```bash
make test
```

Expected: PASS, 140 tests, 0 unexpected.

- [ ] **Step 6: Look at the output before trusting it**

```bash
emacs -Q --batch -L . --eval '(progn
  (require (quote pretty-view-gfm)) (require (quote pretty-view-render))
  (require (quote pretty-view-themes))
  (dolist (theme (list (quote github-light) (quote github-dark)
                       (quote sepia) (quote nord) (quote cyberpunk)))
    (with-temp-file (format "/tmp/pv-%s.html" theme)
      (insert "<!doctype html><meta charset=utf-8><style>"
              (pretty-view-theme-css theme) "</style>")
      (insert-file-contents "tests/corpus/table-and-code.html")
      (goto-char (point-max))
      (insert-file-contents "tests/corpus/basic.html"))))'
```

Open each file and check the five themes for readable contrast, a sane
measure, and code colours that do not vanish into the background. Fix the
palettes rather than the stylesheet when something reads badly.

- [ ] **Step 7: Commit**

```bash
git add pretty-view-theme.el pretty-view-themes.el tests/pretty-view-theme-test.el
git commit -m "feat(theme): static stylesheet and five bundled themes"
```

---

### Task 15: Document shell — head, table of contents, asset inlining, live script

Wraps a body in a complete HTML document. Format-agnostic by construction: the TOC is extracted from rendered headings, so it works identically for Org and Markdown.

**Files:**
- Create: `pretty-view-html.el`
- Create: `tests/pretty-view-html-test.el`

**Interfaces:**
- Consumes: `pretty-view-theme-css` from Task 13, `pretty-view-escape-html` from Task 1
- Produces:
  - `(pretty-view-html-document BODY &key title base-directory live)` → complete HTML string
  - `(pretty-view-html--toc BODY MAX-DEPTH)` → TOC HTML, or nil when fewer than two headings
  - `(pretty-view-html--inline-assets HTML BASE-DIRECTORY)` → HTML with local images as data URIs
  - `pretty-view-toc`, `pretty-view-inline-images`, `pretty-view-inline-image-max-bytes`, `pretty-view-live-interval`, `pretty-view-head-functions`, `pretty-view-body-filter-functions` — defcustoms

- [ ] **Step 1: Write the failing tests**

Create `tests/pretty-view-html-test.el`:

```elisp
;;; pretty-view-html-test.el --- Tests for the document shell  -*- lexical-binding: t -*-
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
  (let ((html (pretty-view-html--toc
               "<h1 id=\"a\">A</h1>\n<h3 id=\"c\">C</h3>\n" 2)))
    (should (string-match-p "#a" html))
    (should-not (string-match-p "#c" html))))

(ert-deftest pretty-view-html-test-toc-needs-two-headings ()
  (should (null (pretty-view-html--toc "<h1 id=\"a\">A</h1>\n" 6))))

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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
make test
```

Expected: FAIL — `Cannot open load file: pretty-view-html`.

- [ ] **Step 3: Write the implementation**

Create `pretty-view-html.el` with the standard GPL header, requiring
`cl-lib`, `pretty-view-theme`, and `pretty-view-render`, and:

```elisp
(defcustom pretty-view-toc nil
  "Whether to emit a table of contents.
Nil for none, t for all heading levels, or an integer maximum depth.
Org documents defer to their own `#+OPTIONS: toc:' instead."
  :type '(choice (const :tag "None" nil)
                 (const :tag "All levels" t)
                 (integer :tag "Maximum depth"))
  :group 'pretty-view)

(defcustom pretty-view-inline-images t
  "When non-nil, embed local images in the output as data URIs.
This is what makes the output a single self-contained file."
  :type 'boolean
  :group 'pretty-view)

(defcustom pretty-view-inline-image-max-bytes 2000000
  "Largest image, in bytes, that is embedded as a data URI.
Larger files are linked with a `file://' URL instead."
  :type 'integer
  :group 'pretty-view)

(defcustom pretty-view-live-interval 1.5
  "Seconds between browser reloads in `pretty-view-live-mode'.
Nil omits the reload script.

On `file://' the page cannot ask whether its source changed, so the
reload is unconditional and happens even while the document is idle."
  :type '(choice (const :tag "No automatic reload" nil) number)
  :group 'pretty-view)

(defcustom pretty-view-head-functions nil
  "Functions contributing markup to the document\\='s `<head>'.
Each is called with no arguments in the source buffer and returns a
string or nil.  This is where to add a KaTeX or Mermaid script tag."
  :type 'hook
  :group 'pretty-view)

(defcustom pretty-view-body-filter-functions nil
  "Functions filtering the rendered body.
Each is called with the body string in the source buffer and returns
the replacement, applied in order."
  :type 'hook
  :group 'pretty-view)
```

The table of contents, extracted from the rendered HTML so Org and
Markdown share one implementation:

```elisp
(defconst pretty-view-html--heading-re
  "<h\\([1-6]\\)[^>]*\\bid=\"\\([^\"]+\\)\"[^>]*>\\(.*?\\)</h\\1>"
  "Match a rendered heading carrying an id.
Group 1 is the level, group 2 the id, group 3 the inner HTML.")

(defun pretty-view-html--strip-tags (html)
  "Return HTML with element tags removed, keeping text and entities."
  (replace-regexp-in-string "<[^>]*>" "" html))

(defun pretty-view-html--headings (body max-depth)
  "Return (LEVEL ID TEXT) for each heading in BODY up to MAX-DEPTH."
  (let ((result nil) (start 0))
    (while (string-match pretty-view-html--heading-re body start)
      (let ((level (string-to-number (match-string 1 body))))
        (when (<= level max-depth)
          (push (list level (match-string 2 body)
                      (pretty-view-html--strip-tags (match-string 3 body)))
                result)))
      (setq start (match-end 0)))
    (nreverse result)))

(defun pretty-view-html--toc (body max-depth)
  "Return a table of contents for BODY up to MAX-DEPTH, or nil.
Returns nil when BODY holds fewer than two headings with ids, because a
one-entry contents list is noise."
  (let ((headings (pretty-view-html--headings body max-depth)))
    (when (> (length headings) 1)
      (format "<nav class=\"pv-toc\"><ul>\n%s</ul></nav>\n"
              (mapconcat
               (lambda (h)
                 (format "<li class=\"pv-toc-%d\"><a href=\"#%s\">%s</a></li>\n"
                         (nth 0 h)
                         (pretty-view-escape-attribute (nth 1 h))
                         (nth 2 h)))
               headings "")))))
```

Asset inlining:

```elisp
(defconst pretty-view-html--image-mime-alist
  '(("png" . "image/png") ("jpg" . "image/jpeg") ("jpeg" . "image/jpeg")
    ("gif" . "image/gif") ("svg" . "image/svg+xml")
    ("webp" . "image/webp") ("avif" . "image/avif")
    ("bmp" . "image/bmp") ("ico" . "image/x-icon"))
  "Map an image file extension to its MIME type.")

(defun pretty-view-html--data-uri (file)
  "Return FILE as a data URI, or nil when it cannot be embedded."
  (let ((mime (cdr (assoc (downcase (or (file-name-extension file) ""))
                          pretty-view-html--image-mime-alist))))
    (when (and mime
               (file-readable-p file)
               (<= (file-attribute-size (file-attributes file))
                   pretty-view-inline-image-max-bytes))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file)
        (format "data:%s;base64,%s"
                mime (base64-encode-string (buffer-string) t))))))

(defun pretty-view-html--inline-assets (html base-directory)
  "Return HTML with local image sources under BASE-DIRECTORY embedded.
Remote URLs, unreadable files, and files over
`pretty-view-inline-image-max-bytes' are left as links."
  (if (not pretty-view-inline-images)
      html
    (replace-regexp-in-string
     "\\(<img[^>]*\\bsrc=\"\\)\\([^\"]+\\)\\(\"\\)"
     (lambda (match)
       (let ((src (match-string 2 match)))
         (if (string-match-p "\\`\\(?:[a-z][a-z0-9+.-]*:\\|//\\)" src)
             match
           (let* ((file (expand-file-name src base-directory))
                  (uri (pretty-view-html--data-uri file)))
             (concat (match-string 1 match)
                     (cond (uri uri)
                           ((file-readable-p file) (concat "file://" file))
                           (t src))
                     (match-string 3 match))))))
     html t)))
```

The live-reload script and the shell:

```elisp
(defun pretty-view-html--live-script ()
  "Return the reload script, or an empty string when reloading is off."
  (if (not pretty-view-live-interval)
      ""
    (format "<script>
(function () {
  var key = 'pv-scroll:' + location.pathname;
  try {
    var y = sessionStorage.getItem(key);
    if (y !== null) window.scrollTo(0, parseInt(y, 10));
  } catch (e) {}
  window.addEventListener('beforeunload', function () {
    try { sessionStorage.setItem(key, String(window.scrollY)); } catch (e) {}
  });
  setInterval(function () {
    if (document.visibilityState !== 'hidden') location.reload();
  }, %d);
})();
</script>\n" (truncate (* 1000 pretty-view-live-interval)))))

(cl-defun pretty-view-html-document (body &key title base-directory live)
  "Wrap BODY in a complete HTML document and return it.
TITLE names the document, BASE-DIRECTORY resolves relative image paths,
and LIVE non-nil embeds the reload script."
  (let* ((body (seq-reduce (lambda (acc fn) (funcall fn acc))
                           pretty-view-body-filter-functions body))
         (body (pretty-view-html--inline-assets
                body (or base-directory default-directory)))
         (depth (cond ((integerp pretty-view-toc) pretty-view-toc)
                      (pretty-view-toc 6)
                      (t nil)))
         (toc (and depth (pretty-view-html--toc body depth)))
         (head (mapconcat (lambda (fn) (or (funcall fn) ""))
                          pretty-view-head-functions "\n")))
    (concat
     "<!DOCTYPE html>\n<html lang=\"" (or (bound-and-true-p pretty-view-html-lang) "en") "\">\n<head>\n"
     "<meta charset=\"utf-8\" />\n"
     "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />\n"
     "<title>" (pretty-view-escape-html (or title "Document")) "</title>\n"
     "<style>\n" (pretty-view-theme-css pretty-view-theme) "</style>\n"
     (if (string-empty-p head) "" (concat head "\n"))
     "</head>\n<body>\n<main class=\"pv-doc\">\n"
     (or toc "")
     body
     "</main>\n"
     (if live (pretty-view-html--live-script) "")
     "</body>\n</html>\n")))
```

Add a `pretty-view-html-lang` defcustom defaulting to `"en"` rather than
relying on `bound-and-true-p`:

```elisp
(defcustom pretty-view-html-lang "en"
  "Value of the `lang' attribute on the generated `html' element."
  :type 'string
  :group 'pretty-view)
```

and use it directly in `pretty-view-html-document`.

- [ ] **Step 4: Run tests to verify they pass**

```bash
make test
```

Expected: PASS, 157 tests, 0 unexpected.

- [ ] **Step 5: Commit**

```bash
git add pretty-view-html.el tests/pretty-view-html-test.el
git commit -m "feat(html): document shell with TOC, asset inlining, and live reload"
```

---

### Task 16: Org export backend

A backend derived from `ox-html`, with the translate alist assembled at export time so user overrides take effect without redefining the backend.

**Files:**
- Create: `pretty-view-org.el`
- Create: `tests/pretty-view-org-test.el`

**Interfaces:**
- Consumes: `pretty-view-render-fontified-code` from Task 10, `pretty-view-escape-html` from Task 1
- Produces:
  - `(pretty-view-org-body)` → HTML body string for the current Org buffer
  - `(pretty-view-org-title)` → the `#+TITLE:` value, or nil
  - `pretty-view-org-transcoders` — alist of Org element type → transcoder

- [ ] **Step 1: Write the failing tests**

Create `tests/pretty-view-org-test.el`:

```elisp
;;; pretty-view-org-test.el --- Tests for the Org backend  -*- lexical-binding: t -*-
;;; Commentary:
;; Body export, transcoder overrides, and error capture.
;;; Code:

(require 'ert)
(require 'pretty-view-org)

(defun pv-org (text)
  "Export TEXT as an Org buffer body."
  (with-temp-buffer
    (insert text)
    (org-mode)
    (pretty-view-org-body)))

(ert-deftest pretty-view-org-test-heading ()
  (should (string-match-p "<h2[^>]*>Hi</h2>" (pv-org "* Hi\n"))))

(ert-deftest pretty-view-org-test-paragraph-and-emphasis ()
  (let ((html (pv-org "Some *bold* text.\n")))
    (should (string-match-p "<b>bold</b>\\|<strong>bold</strong>" html))))

(ert-deftest pretty-view-org-test-no-default-stylesheet ()
  "The theme supplies all CSS; ox-html must not inject its own."
  (let ((html (pv-org "* Hi\n")))
    (should-not (string-match-p "<style" html))
    (should-not (string-match-p "org-src-container" html))))

(ert-deftest pretty-view-org-test-body-only ()
  "Export must be a fragment; the shell supplies html and head."
  (should-not (string-match-p "<!DOCTYPE" (pv-org "* Hi\n"))))

(ert-deftest pretty-view-org-test-src-block-uses-font-lock ()
  (let ((html (pv-org "#+begin_src emacs-lisp\n(defun f ())\n#+end_src\n")))
    (should (string-match-p "pv-code" html))
    (should (string-match-p "pv-keyword" html))))

(ert-deftest pretty-view-org-test-src-block-escapes ()
  (let ((html (pv-org "#+begin_src text\na < b\n#+end_src\n")))
    (should (string-match-p "&lt;" html))))

(ert-deftest pretty-view-org-test-table ()
  (let ((html (pv-org "| a | b |\n|---+---|\n| 1 | 2 |\n")))
    (should (string-match-p "<table" html))))

(ert-deftest pretty-view-org-test-title ()
  (with-temp-buffer
    (insert "#+TITLE: My Doc\n* Hi\n")
    (org-mode)
    (should (equal (pretty-view-org-title) "My Doc")))
  (with-temp-buffer
    (insert "* Hi\n")
    (org-mode)
    (should (null (pretty-view-org-title)))))

(ert-deftest pretty-view-org-test-transcoder-override ()
  (let ((pretty-view-org-transcoders
         (cons '(horizontal-rule . (lambda (&rest _) "<hr class=\"probe\">"))
               pretty-view-org-transcoders)))
    (should (string-match-p "probe" (pv-org "-----\n")))))

(ert-deftest pretty-view-org-test-export-error-is-rendered-not-signalled ()
  (cl-letf (((symbol-function 'org-export-as)
             (lambda (&rest _) (error "synthetic failure"))))
    (let ((html (pv-org "* Hi\n")))
      (should (string-match-p "pv-error" html))
      (should (string-match-p "synthetic failure" html)))))

(ert-deftest pretty-view-org-test-error-message-is-escaped ()
  (cl-letf (((symbol-function 'org-export-as)
             (lambda (&rest _) (error "bad <tag>"))))
    (let ((html (pv-org "* Hi\n")))
      (should (string-match-p "&lt;tag&gt;" html))
      (should-not (string-match-p "bad <tag>" html)))))

(provide 'pretty-view-org-test)
;;; pretty-view-org-test.el ends here
```

Add `(require 'cl-lib)` to the test file.

- [ ] **Step 2: Run tests to verify they fail**

```bash
make test
```

Expected: FAIL — `Cannot open load file: pretty-view-org`.

- [ ] **Step 3: Write the implementation**

Create `pretty-view-org.el` with the standard GPL header and:

```elisp
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

(defun pretty-view-org-title ()
  "Return the `#+TITLE:' of the current Org buffer, or nil."
  (let ((title (cadr (assq :title (org-export-get-environment)))))
    (when title
      (let ((text (if (stringp title)
                      title
                    (substring-no-properties
                     (org-element-interpret-data title)))))
        (unless (string-empty-p (string-trim text))
          (string-trim text))))))

(defun pretty-view-org-body ()
  "Return the current Org buffer exported to an HTML body.
An export failure is rendered into the body rather than signalled, so a
broken document still opens in the browser with the reason visible."
  (condition-case err
      (let ((org-html-head-include-default-style nil)
            (org-html-head-include-scripts nil)
            (org-html-htmlize-output-type nil)
            (org-export-with-smart-quotes t))
        (org-export-as (pretty-view-org--backend) nil nil t nil))
    (error
     (format "<div class=\"pv-error\"><strong>Org export failed:</strong> %s</div>\n"
             (pretty-view-escape-html (error-message-string err))))))

(provide 'pretty-view-org)
;;; pretty-view-org.el ends here
```

The `t` in the `org-export-as` call is `body-only`. `org-html-htmlize-output-type`
is set to nil so that any `ox-html` path still reaching htmlize emits plain
text rather than loading the library.

Add a `.pv-error` rule to `pretty-view-theme--base-stylesheet`: a bordered
block using `--pv-warning` for its accent. Add `"pv-error"` to the class
list in `pretty-view-theme-test-base-stylesheet-styles-every-class`.

- [ ] **Step 4: Run tests to verify they pass**

```bash
make test
```

Expected: PASS, 168 tests, 0 unexpected.

- [ ] **Step 5: Commit**

```bash
git add pretty-view-org.el pretty-view-theme.el tests/
git commit -m "feat(org): export Org through a derived ox-html backend"
```

---

### Task 17: Plain text converter

**Files:**
- Create: `pretty-view-text.el`
- Create: `tests/pretty-view-text-test.el`

**Interfaces:**
- Consumes: `pretty-view-escape-html` from Task 1, `pretty-view-gfm-parse` and `pretty-view-render-document` from Tasks 2–11
- Produces:
  - `(pretty-view-text-body TEXT)` → HTML body string
  - `pretty-view-text-as-markdown` — boolean defcustom

- [ ] **Step 1: Write the failing tests**

Create `tests/pretty-view-text-test.el`:

```elisp
;;; pretty-view-text-test.el --- Tests for the plain text converter  -*- lexical-binding: t -*-
;;; Commentary:
;; Paragraph splitting, escaping, autolinking, and the markdown opt-in.
;;; Code:

(require 'ert)
(require 'pretty-view-text)

(ert-deftest pretty-view-text-test-paragraphs ()
  (let ((html (pretty-view-text-body "one\n\ntwo")))
    (should (string-match-p "<p class=\"pv-text\">one</p>" html))
    (should (string-match-p "<p class=\"pv-text\">two</p>" html))))

(ert-deftest pretty-view-text-test-keeps-internal-newlines ()
  "Line structure inside a paragraph is meaningful in a text file."
  (should (string-match-p "a\nb" (pretty-view-text-body "a\nb"))))

(ert-deftest pretty-view-text-test-escapes ()
  (should (string-match-p "&lt;b&gt;" (pretty-view-text-body "<b>")))
  (should-not (string-match-p "<b>" (pretty-view-text-body "<b>"))))

(ert-deftest pretty-view-text-test-autolinks ()
  (let ((html (pretty-view-text-body "see https://example.com now")))
    (should (string-match-p "<a href=\"https://example.com\"" html))))

(ert-deftest pretty-view-text-test-autolink-does-not-break-escaping ()
  (let ((html (pretty-view-text-body "https://e.com/?a=1&b=2")))
    (should (string-match-p "&amp;b=2" html))))

(ert-deftest pretty-view-text-test-collapses-blank-run ()
  (let ((html (pretty-view-text-body "a\n\n\n\nb")))
    (should (= 2 (cl-count-if (lambda (_) t)
                              (split-string html "<p class=\"pv-text\">" t))))))

(ert-deftest pretty-view-text-test-markdown-opt-in ()
  (let ((pretty-view-text-as-markdown t))
    (should (string-match-p "<h1" (pretty-view-text-body "# Head")))))

(ert-deftest pretty-view-text-test-markdown-off-by-default ()
  (let ((pretty-view-text-as-markdown nil))
    (should-not (string-match-p "<h1" (pretty-view-text-body "# Head")))))

(ert-deftest pretty-view-text-test-empty-input ()
  (should (equal (pretty-view-text-body "") "")))

(provide 'pretty-view-text-test)
;;; pretty-view-text-test.el ends here
```

Add `(require 'cl-lib)` to the test file.

- [ ] **Step 2: Run tests to verify they fail**

```bash
make test
```

Expected: FAIL — `Cannot open load file: pretty-view-text`.

- [ ] **Step 3: Write the implementation**

Create `pretty-view-text.el` with the standard GPL header and:

```elisp
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
```

Autolinking runs *after* escaping, so `&` inside a URL is already
`&amp;` in both the `href` and the link text — which is correct HTML and
what `pretty-view-text-test-autolink-does-not-break-escaping` pins.

Add a `.pv-text` rule to `pretty-view-theme--base-stylesheet` setting
`white-space: pre-wrap`, which is what preserves the newlines inside a
paragraph. Add `"pv-text"` to the class list in
`pretty-view-theme-test-base-stylesheet-styles-every-class`.

- [ ] **Step 4: Run tests to verify they pass**

```bash
make test
```

Expected: PASS, 177 tests, 0 unexpected.

- [ ] **Step 5: Commit**

```bash
git add pretty-view-text.el pretty-view-theme.el tests/
git commit -m "feat(text): render plain text with preserved line structure"
```

---

### Task 18: Browser launch, platform detection, and output location

Every platform decision in the package lives in this file. The command construction is a pure function so it can be tested without launching anything.

**Files:**
- Create: `pretty-view-browser.el`
- Create: `tests/pretty-view-browser-test.el`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `(pretty-view-browser-wsl-p)` → boolean
  - `(pretty-view-browser-default-output-directory)` → a directory name
  - `(pretty-view-browser-command FILE)` → a list of strings, or nil meaning "use `browse-url'"
  - `(pretty-view-browser-open FILE)` → opens FILE, returning non-nil on success
  - `(pretty-view-browser-output-file SOURCE)` → the output path for SOURCE
  - `pretty-view-browser`, `pretty-view-output-directory` — defcustoms

- [ ] **Step 1: Write the failing tests**

Create `tests/pretty-view-browser-test.el`:

```elisp
;;; pretty-view-browser-test.el --- Tests for platform handling  -*- lexical-binding: t -*-
;;; Commentary:
;; Platform detection, output paths, and browser command construction.
;; Nothing here launches a program: `pretty-view-browser-command' is a
;; pure function returning an argument list.
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'pretty-view-browser)

(defmacro pv-with-wsl (wsl &rest body)
  "Run BODY with WSL detection forced to WSL."
  `(cl-letf (((symbol-function 'pretty-view-browser-wsl-p) (lambda () ,wsl)))
     ,@body))

(ert-deftest pretty-view-browser-test-wsl-detection-from-kernel ()
  (cl-letf (((symbol-function 'system-name) (lambda () "host")))
    (let ((pretty-view-browser--uname "6.6.0-microsoft-standard-WSL2"))
      (should (pretty-view-browser-wsl-p)))
    (let ((pretty-view-browser--uname "6.6.0-generic"))
      (should-not (pretty-view-browser-wsl-p)))))

(ert-deftest pretty-view-browser-test-command-uses-explicit-program ()
  (let ((pretty-view-browser "firefox"))
    (should (equal (pretty-view-browser-command "/tmp/a.html")
                   '("firefox" "file:///tmp/a.html")))))

(ert-deftest pretty-view-browser-test-command-default-is-nil-off-wsl ()
  (pv-with-wsl nil
    (let ((pretty-view-browser 'default))
      (should (null (pretty-view-browser-command "/tmp/a.html"))))))

(ert-deftest pretty-view-browser-test-command-prefers-wslview ()
  (pv-with-wsl t
    (cl-letf (((symbol-function 'executable-find)
               (lambda (p &rest _) (when (equal p "wslview") "/usr/bin/wslview"))))
      (let ((pretty-view-browser 'default))
        (should (equal (pretty-view-browser-command "/tmp/a.html")
                       '("/usr/bin/wslview" "/tmp/a.html")))))))

(ert-deftest pretty-view-browser-test-command-falls-back-to-explorer ()
  (pv-with-wsl t
    (cl-letf (((symbol-function 'executable-find)
               (lambda (p &rest _)
                 (when (equal p "explorer.exe") "/mnt/c/WINDOWS/explorer.exe")))
              ((symbol-function 'pretty-view-browser--windows-path)
               (lambda (_f) "C:\\tmp\\a.html")))
      (let ((pretty-view-browser 'default))
        (should (equal (pretty-view-browser-command "/tmp/a.html")
                       '("/mnt/c/WINDOWS/explorer.exe" "C:\\tmp\\a.html")))))))

(ert-deftest pretty-view-browser-test-command-nil-when-nothing-found ()
  (pv-with-wsl t
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
      (let ((pretty-view-browser 'default))
        (should (null (pretty-view-browser-command "/tmp/a.html")))))))

(ert-deftest pretty-view-browser-test-function-browser-is-called ()
  (let* ((called nil)
         (pretty-view-browser (lambda (f) (setq called f))))
    (pretty-view-browser-open "/tmp/a.html")
    (should (equal called "/tmp/a.html"))))

(ert-deftest pretty-view-browser-test-output-file-is-stable ()
  (let ((pretty-view-output-directory "/tmp/pv/"))
    (should (equal (pretty-view-browser-output-file "/a/b/notes.md")
                   (pretty-view-browser-output-file "/a/b/notes.md")))))

(ert-deftest pretty-view-browser-test-output-file-disambiguates-paths ()
  (let ((pretty-view-output-directory "/tmp/pv/"))
    (should-not (equal (pretty-view-browser-output-file "/a/notes.md")
                       (pretty-view-browser-output-file "/b/notes.md")))))

(ert-deftest pretty-view-browser-test-output-file-keeps-base-name ()
  (let ((pretty-view-output-directory "/tmp/pv/"))
    (should (string-match-p "/notes-[0-9a-f]\\{10\\}\\.html\\'"
                            (pretty-view-browser-output-file "/a/notes.md")))))

(ert-deftest pretty-view-browser-test-output-file-sanitizes-base-name ()
  (let ((pretty-view-output-directory "/tmp/pv/"))
    (should (string-match-p "/a-b-[0-9a-f]\\{10\\}\\.html\\'"
                            (pretty-view-browser-output-file "/x/a b.md")))))

(ert-deftest pretty-view-browser-test-default-output-directory-off-wsl ()
  (pv-with-wsl nil
    (should (equal (pretty-view-browser-default-output-directory)
                   (expand-file-name "pretty-view" temporary-file-directory)))))

(ert-deftest pretty-view-browser-test-default-output-directory-on-wsl ()
  (pv-with-wsl t
    (cl-letf (((symbol-function 'pretty-view-browser--windows-temp)
               (lambda () "/mnt/c/Users/u/AppData/Local/Temp")))
      (should (string-prefix-p "/mnt/c/"
                               (pretty-view-browser-default-output-directory))))))

(ert-deftest pretty-view-browser-test-wsl-falls-back-when-temp-unresolved ()
  (pv-with-wsl t
    (cl-letf (((symbol-function 'pretty-view-browser--windows-temp)
               (lambda () nil)))
      (should (equal (pretty-view-browser-default-output-directory)
                     (expand-file-name "pretty-view" temporary-file-directory))))))

(provide 'pretty-view-browser-test)
;;; pretty-view-browser-test.el ends here
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
make test
```

Expected: FAIL — `Cannot open load file: pretty-view-browser`.

- [ ] **Step 3: Write the implementation**

Create `pretty-view-browser.el` with the standard GPL header and:

```elisp
;;; Commentary:

;; Every platform decision in the package lives here.  WSL is the reason
;; the file exists: it is Linux with a Windows browser behind it, so the
;; output goes to the Windows temporary directory and the file is handed
;; over as a Windows path.  Writing to `/mnt/c' avoids
;; `\\\\wsl.localhost' UNC paths entirely.
;;
;; `pretty-view-browser-command' returns an argument list and launches
;; nothing, which is what makes the platform logic testable.

;;; Code:

(require 'browse-url)

(defvar pretty-view-browser--uname
  (or (car (split-string (shell-command-to-string "uname -r") "\n" t)) "")
  "Kernel release string, read once at load time.
A variable rather than a call so tests can rebind it.")

(defun pretty-view-browser-wsl-p ()
  "Return non-nil when running under the Windows Subsystem for Linux."
  (and (eq system-type 'gnu/linux)
       (or (string-match-p "[Mm]icrosoft" pretty-view-browser--uname)
           (and (getenv "WSL_DISTRO_NAME") t))
       t))

(defun pretty-view-browser--windows-temp ()
  "Return the Windows temporary directory as a Linux path, or nil."
  (let ((user (or (getenv "WSLUSER") (getenv "USER"))))
    (seq-find
     #'file-directory-p
     (delq nil
           (list (getenv "TEMP_LINUX")
                 (when user
                   (format "/mnt/c/Users/%s/AppData/Local/Temp" user)))))))

(defun pretty-view-browser--windows-path (file)
  "Return FILE as a Windows path, or nil when conversion fails."
  (when (executable-find "wslpath")
    (let ((out (string-trim
                (shell-command-to-string
                 (format "wslpath -w %s" (shell-quote-argument file))))))
      (unless (string-empty-p out) out))))

(defcustom pretty-view-output-directory nil
  "Directory that rendered HTML is written to.
Nil means `pretty-view-browser-default-output-directory', which is the
system temporary directory, or the Windows one under WSL."
  :type '(choice (const :tag "Automatic" nil) directory)
  :group 'pretty-view)

(defcustom pretty-view-browser 'default
  "How to open the rendered file.
`default' uses `browse-url', after adjusting for WSL.  A string names a
program, invoked with the file URL.  A function is called with the
output file path."
  :type '(choice (const :tag "System default" default)
                 (string :tag "Program")
                 (function :tag "Function"))
  :group 'pretty-view)

(defun pretty-view-browser-default-output-directory ()
  "Return the directory rendered HTML should be written to."
  (let ((wsl-temp (and (pretty-view-browser-wsl-p)
                       (pretty-view-browser--windows-temp))))
    (expand-file-name "pretty-view" (or wsl-temp temporary-file-directory))))

(defun pretty-view-browser-output-file (source)
  "Return the output path for SOURCE, a file name or a buffer name.
The name combines a sanitized base name with a hash of SOURCE, so two
documents never collide and one document always reuses its path."
  (let* ((dir (or pretty-view-output-directory
                  (pretty-view-browser-default-output-directory)))
         (base (file-name-base source))
         (base (replace-regexp-in-string "[^[:alnum:]_-]+" "-" base))
         (base (string-trim (if (string-empty-p base) "document" base) "-" "-"))
         (hash (substring (secure-hash 'sha1 source) 0 10)))
    (expand-file-name (format "%s-%s.html" base hash) dir)))

(defun pretty-view-browser-command (file)
  "Return the argument list that opens FILE, or nil to use `browse-url'.
FILE is an absolute path."
  (cond
   ((stringp pretty-view-browser)
    (list pretty-view-browser (concat "file://" file)))
   ((pretty-view-browser-wsl-p)
    (let ((wslview (executable-find "wslview")))
      (if wslview
          (list wslview file)
        (let ((explorer (executable-find "explorer.exe"))
              (win (pretty-view-browser--windows-path file)))
          (when (and explorer win) (list explorer win))))))
   (t nil)))

(defun pretty-view-browser-open (file)
  "Open FILE in a browser.
Reports the path and returns nil when no browser could be launched, so
the file can be opened by hand."
  (cond
   ((functionp pretty-view-browser)
    (funcall pretty-view-browser file)
    t)
   (t
    (let ((command (pretty-view-browser-command file)))
      (condition-case err
          (progn
            (if command
                (apply #'start-process "pretty-view" nil command)
              (browse-url (concat "file://" file)))
            t)
        (error
         (message "pretty-view: could not open a browser (%s); the file is at %s"
                  (error-message-string err) file)
         nil))))))

(provide 'pretty-view-browser)
;;; pretty-view-browser.el ends here
```

Add `(require 'seq)` for `seq-find`.

`explorer.exe` returns a non-zero exit status even on success, which is
why `start-process` is used and its status ignored.

- [ ] **Step 4: Run tests to verify they pass**

```bash
make test
```

Expected: PASS, 191 tests, 0 unexpected.

- [ ] **Step 5: Verify WSL behaviour by hand**

On the development machine, which is WSL:

```bash
emacs -Q --batch -L . --eval '(progn
  (require (quote pretty-view-browser))
  (message "wsl=%s" (pretty-view-browser-wsl-p))
  (message "outdir=%s" (pretty-view-browser-default-output-directory))
  (message "cmd=%S" (pretty-view-browser-command "/tmp/a.html")))'
```

Expected: `wsl=t`, an output directory under `/mnt/c/`, and a command
list naming `wslview` or `explorer.exe`. If the output directory falls
back to `/tmp`, check `pretty-view-browser--windows-temp` against the
actual Windows user name before moving on.

- [ ] **Step 6: Commit**

```bash
git add pretty-view-browser.el tests/pretty-view-browser-test.el
git commit -m "feat(browser): platform-aware output location and browser launch"
```

---

### Task 19: Commands, dispatch, and live mode

The user-facing layer, and the only file that knows the whole pipeline.

**Files:**
- Create: `pretty-view.el`
- Create: `tests/pretty-view-test.el`

**Interfaces:**
- Consumes: every module from Tasks 10–18
- Produces:
  - `pretty-view`, `pretty-view-file`, `pretty-view-export`, `pretty-view-select-theme` — interactive commands
  - `pretty-view-live-mode` — a buffer-local minor mode
  - `(pretty-view-body)` → the HTML body for the current buffer, via `pretty-view-source-functions`
  - `(pretty-view-render-buffer-to-file FILE &optional LIVE)` → writes FILE
  - `pretty-view-source-functions` — alist of major mode → body function

- [ ] **Step 1: Write the failing tests**

Create `tests/pretty-view-test.el`:

```elisp
;;; pretty-view-test.el --- Tests for commands and dispatch  -*- lexical-binding: t -*-
;;; Commentary:
;; Source dispatch, file writing, live mode, and theme selection.
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'pretty-view)

(defmacro pv-in-mode (mode text &rest body)
  "Run BODY in a temp buffer holding TEXT in MODE."
  (declare (indent 2))
  `(with-temp-buffer
     (insert ,text)
     (,mode)
     ,@body))

(ert-deftest pretty-view-test-dispatch-markdown ()
  (pv-in-mode markdown-mode "# Hi"
    (should (string-match-p "<h1" (pretty-view-body)))))

(ert-deftest pretty-view-test-dispatch-org ()
  (pv-in-mode org-mode "* Hi\n"
    (should (string-match-p "<h2" (pretty-view-body)))))

(ert-deftest pretty-view-test-dispatch-text ()
  (pv-in-mode text-mode "plain words"
    (should (string-match-p "pv-text" (pretty-view-body)))))

(ert-deftest pretty-view-test-dispatch-unknown-mode-uses-text ()
  (pv-in-mode fundamental-mode "words"
    (should (string-match-p "pv-text" (pretty-view-body)))))

(ert-deftest pretty-view-test-dispatch-honours-derived-modes ()
  "gfm-mode derives from markdown-mode and must take the markdown path."
  (pv-in-mode gfm-mode "# Hi"
    (should (string-match-p "<h1" (pretty-view-body)))))

(ert-deftest pretty-view-test-source-functions-override ()
  (let ((pretty-view-source-functions
         (cons '(text-mode . (lambda () "<p>probe</p>"))
               pretty-view-source-functions)))
    (pv-in-mode text-mode "x"
      (should (equal (pretty-view-body) "<p>probe</p>")))))

(ert-deftest pretty-view-test-render-writes-a-complete-document ()
  (let ((out (make-temp-file "pv" nil ".html")))
    (unwind-protect
        (progn
          (pv-in-mode markdown-mode "# Title"
            (pretty-view-render-buffer-to-file out))
          (with-temp-buffer
            (insert-file-contents out)
            (let ((html (buffer-string)))
              (should (string-prefix-p "<!DOCTYPE html>" html))
              (should (string-match-p "<h1" html))
              (should (string-match-p "--pv-bg" html)))))
      (delete-file out))))

(ert-deftest pretty-view-test-render-creates-missing-directory ()
  (let* ((dir (expand-file-name "pv-nested" (make-temp-file "pv-out" t)))
         (out (expand-file-name "a.html" dir)))
    (unwind-protect
        (progn
          (pv-in-mode text-mode "x" (pretty-view-render-buffer-to-file out))
          (should (file-exists-p out)))
      (delete-directory (file-name-directory (directory-file-name dir)) t))))

(ert-deftest pretty-view-test-render-does-not-launch-a-browser ()
  "Writing the file and opening it are separate steps."
  (let ((out (make-temp-file "pv" nil ".html"))
        (opened nil))
    (unwind-protect
        (cl-letf (((symbol-function 'pretty-view-browser-open)
                   (lambda (f) (setq opened f))))
          (pv-in-mode text-mode "x" (pretty-view-render-buffer-to-file out))
          (should (null opened)))
      (delete-file out))))

(ert-deftest pretty-view-test-live-mode-adds-and-removes-hook ()
  (pv-in-mode text-mode "x"
    (pretty-view-live-mode 1)
    (should (memq #'pretty-view--live-update after-save-hook))
    (pretty-view-live-mode -1)
    (should-not (memq #'pretty-view--live-update after-save-hook))))

(ert-deftest pretty-view-test-live-document-carries-the-script ()
  (let ((out (make-temp-file "pv" nil ".html")))
    (unwind-protect
        (progn
          (pv-in-mode text-mode "x"
            (pretty-view-render-buffer-to-file out t))
          (with-temp-buffer
            (insert-file-contents out)
            (should (string-match-p "location.reload" (buffer-string)))))
      (delete-file out))))

(ert-deftest pretty-view-test-title-from-org ()
  (pv-in-mode org-mode "#+TITLE: My Doc\n* Hi\n"
    (should (equal (pretty-view--title) "My Doc"))))

(ert-deftest pretty-view-test-title-from-buffer-name-without-file ()
  (pv-in-mode text-mode "x"
    (should (stringp (pretty-view--title)))))

(ert-deftest pretty-view-test-select-theme-sets-the-variable ()
  (cl-letf (((symbol-function 'completing-read)
             (lambda (&rest _) "nord")))
    (call-interactively #'pretty-view-select-theme)
    (should (eq pretty-view-theme 'nord))))

(provide 'pretty-view-test)
;;; pretty-view-test.el ends here
```

`markdown-mode` and `gfm-mode` come from the `markdown-mode` package,
which is a *test-only* convenience and must not become a dependency. Guard
the two tests that need it:

```elisp
(skip-unless (fboundp 'markdown-mode))
```

as the first form in each, and add `(require 'markdown-mode nil t)` near
the top of the file.

- [ ] **Step 2: Run tests to verify they fail**

```bash
make test
```

Expected: FAIL — `Cannot open load file: pretty-view`.

- [ ] **Step 3: Write the implementation**

Create `pretty-view.el` with the standard GPL header, the package
headers, and the code below. This is the file `package.el` reads, so its
headers matter:

```elisp
;;; pretty-view.el --- Render Org, Markdown, and text to styled HTML  -*- lexical-binding: t -*-

;; Author: Kyeong Soo Choi <kyeongsoo@douzone.com>
;; Maintainer: Kyeong Soo Choi <kyeongsoo@douzone.com>
;; URL: https://github.com/mandoo180/pretty-view.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: outlines, hypermedia, markdown, org

;; [GPL header]

;;; Commentary:

;; `M-x pretty-view' renders the current Org, Markdown, or plain-text
;; buffer to a self-contained HTML file and opens it in the operating
;; system's browser.  `M-x pretty-view-live-mode' regenerates on every
;; save and reloads the browser tab.
;;
;; Everything is replaceable: `pretty-view-theme' picks the look,
;; `pretty-view-renderers' and `pretty-view-org-transcoders' replace how
;; any single element renders, and `pretty-view-head-functions' adds to
;; the document head.  Nothing outside Emacs is required.

;;; Code:

(require 'pretty-view-render)
(require 'pretty-view-gfm)
(require 'pretty-view-theme)
(require 'pretty-view-themes)
(require 'pretty-view-html)
(require 'pretty-view-org)
(require 'pretty-view-text)
(require 'pretty-view-browser)

(defun pretty-view-markdown-body ()
  "Return the current buffer rendered as Markdown."
  (pretty-view-render-document (pretty-view-gfm-parse (buffer-string))))

(defun pretty-view-text-buffer-body ()
  "Return the current buffer rendered as plain text."
  (pretty-view-text-body (buffer-string)))

(defcustom pretty-view-source-functions
  '((org-mode . pretty-view-org-body)
    (markdown-mode . pretty-view-markdown-body)
    (text-mode . pretty-view-text-buffer-body))
  "Map a major mode to the function producing its HTML body.
Each function is called with no arguments in the source buffer.  Modes
are matched with `derived-mode-p', so `gfm-mode' reaches the
`markdown-mode' entry.  A buffer matching nothing is rendered as text."
  :type '(alist :key-type symbol :value-type function)
  :group 'pretty-view)

(defun pretty-view-body ()
  "Return the HTML body for the current buffer."
  (let ((fn (seq-some (lambda (entry)
                        (and (derived-mode-p (car entry)) (cdr entry)))
                      pretty-view-source-functions)))
    (funcall (or fn #'pretty-view-text-buffer-body))))

(defun pretty-view--title ()
  "Return a title for the current buffer."
  (or (and (derived-mode-p 'org-mode) (pretty-view-org-title))
      (and buffer-file-name (file-name-nondirectory buffer-file-name))
      (buffer-name)))

(defun pretty-view--source-name ()
  "Return the identity used to name this buffer's output file."
  (or buffer-file-name (concat "buffer:" (buffer-name))))

(defun pretty-view-render-buffer-to-file (file &optional live)
  "Render the current buffer into FILE.
LIVE non-nil embeds the reload script.  Creates FILE's directory when
it does not exist.  Does not open a browser."
  (let* ((base default-directory)
         (title (pretty-view--title))
         (body (pretty-view-body))
         (html (pretty-view-html-document body
                                          :title title
                                          :base-directory base
                                          :live live)))
    (make-directory (file-name-directory file) t)
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file file (insert html)))
    file))

;;;###autoload
(defun pretty-view ()
  "Render the current buffer to HTML and open it in a browser."
  (interactive)
  (let ((file (pretty-view-browser-output-file (pretty-view--source-name))))
    (pretty-view-render-buffer-to-file file pretty-view-live-mode)
    (pretty-view-browser-open file)
    (message "pretty-view: %s" file)))

;;;###autoload
(defun pretty-view-file (file)
  "Render FILE to HTML and open it in a browser."
  (interactive "fFile to render: ")
  (with-current-buffer (find-file-noselect file)
    (pretty-view)))

;;;###autoload
(defun pretty-view-export (file)
  "Render the current buffer to FILE without opening a browser."
  (interactive
   (list (read-file-name
          "Export to: " nil nil nil
          (concat (file-name-base (or buffer-file-name (buffer-name)))
                  ".html"))))
  (pretty-view-render-buffer-to-file file)
  (message "pretty-view: wrote %s" file))

;;;###autoload
(defun pretty-view-select-theme (theme)
  "Set `pretty-view-theme' to THEME and re-render if this buffer was rendered."
  (interactive
   (list (intern (completing-read
                  "Theme: "
                  (cons "auto" (mapcar #'symbol-name (pretty-view-theme-names)))
                  nil t))))
  (setq pretty-view-theme theme)
  (let ((file (pretty-view-browser-output-file (pretty-view--source-name))))
    (when (file-exists-p file)
      (pretty-view-render-buffer-to-file file pretty-view-live-mode)))
  (message "pretty-view: theme is now %s" theme))

(defun pretty-view--live-update ()
  "Regenerate this buffer's rendered file.  Used by `pretty-view-live-mode'."
  (when pretty-view-live-mode
    (pretty-view-render-buffer-to-file
     (pretty-view-browser-output-file (pretty-view--source-name)) t)))

;;;###autoload
(define-minor-mode pretty-view-live-mode
  "Regenerate this buffer's rendered HTML on every save.
The rendered page reloads itself every `pretty-view-live-interval'
seconds, restoring the scroll position."
  :lighter " PV"
  :group 'pretty-view
  (if pretty-view-live-mode
      (add-hook 'after-save-hook #'pretty-view--live-update nil t)
    (remove-hook 'after-save-hook #'pretty-view--live-update t)))

(provide 'pretty-view)
;;; pretty-view.el ends here
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
make test
```

Expected: PASS, 205 tests, 0 unexpected. Two tests skip when
`markdown-mode` is not installed; install it into the test environment or
accept the skips.

- [ ] **Step 5: Verify byte-compilation is clean**

```bash
make compile
```

Expected: no output. Any warning is a failure — fix it before committing.
Expect to add `(declare-function ...)` or `(defvar ...)` forward
declarations for cross-file references the compiler cannot see.

- [ ] **Step 6: Open a real document and look at it**

```bash
emacs -Q -L . --eval '(progn (require (quote pretty-view))
  (find-file "docs/superpowers/specs/2026-09-11-pretty-view-design.md")
  (pretty-view))'
```

Check in the browser: headings, the tables, the code blocks, and the
links all render; the theme is applied; nothing is missing from the
bottom of the document. Then repeat with an Org file and a `.txt` file.

- [ ] **Step 7: Commit**

```bash
git add pretty-view.el tests/pretty-view-test.el
git commit -m "feat: commands, source dispatch, and live mode"
```

---

### Task 20: README, continuous integration, and package hygiene

**Files:**
- Create: `README.md`
- Create: `.github/workflows/ci.yml`
- Modify: every `pretty-view*.el` — fix whatever `checkdoc` reports

**Interfaces:**
- Consumes: the finished package
- Produces: a repository someone else can install from

- [ ] **Step 1: Run checkdoc and fix what it reports**

```bash
make checkdoc
```

Fix every complaint: docstrings on all public functions and variables,
first lines that are complete sentences, arguments named in docstrings
appearing in upper case. Do not silence checkdoc; fix the text.

- [ ] **Step 2: Write the README**

`README.md` must cover, in this order:

1. One sentence on what the package does, and a screenshot placeholder
2. Installation with `use-package` and `:vc`, exactly as a user would
   paste it:

   ```elisp
   (use-package pretty-view
     :vc (:url "https://github.com/mandoo180/pretty-view.el" :rev :newest)
     :commands (pretty-view pretty-view-file pretty-view-export
                pretty-view-live-mode pretty-view-select-theme)
     :custom
     (pretty-view-theme 'auto)
     :bind (("C-c C-v" . pretty-view)))
   ```

3. The commands table from the spec's section 12
4. The theme gallery: the five names, what each is for, and how to define
   one with `pretty-view-define-theme`, showing the full slot list
5. The customization API: `pretty-view-renderers`,
   `pretty-view-org-transcoders`, `pretty-view-source-functions`,
   `pretty-view-head-functions`, `pretty-view-body-filter-functions`,
   each with the signature from the spec's section 13.1 and one worked
   example
6. A "Recipes" section with two examples that prove the hook design:
   adding KaTeX through `pretty-view-head-functions`, and wrapping code
   blocks in a `<figure>` through `pretty-view-renderers`
7. Platform notes: where output is written on each platform, why WSL
   writes to the Windows temporary directory, and how to set
   `pretty-view-browser`
8. The live-mode trade-off, stated plainly: on `file://` the page cannot
   detect changes, so it reloads on a timer; set
   `pretty-view-live-interval` to nil to turn that off
9. What the package deliberately does not do, from the spec's section 2
10. License

- [ ] **Step 3: Write the CI workflow**

`.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        emacs_version: ['29.1', '30.1', '31.1']
    steps:
      - uses: actions/checkout@v4
      - uses: purcell/setup-emacs@master
        with:
          version: ${{ matrix.emacs_version }}
        # If setup-emacs has no build for a listed version, drop that leg
        # rather than lowering the floor: 29.1 is a spec requirement.
      - name: Byte-compile with warnings as errors
        run: make compile
      - name: Run tests
        run: make test
      - name: Checkdoc
        run: make checkdoc
```

- [ ] **Step 4: Verify the whole suite one more time**

```bash
make clean && make compile && make test && make checkdoc
```

Expected: a clean compile, all tests passing with 0 unexpected, and no
checkdoc output. Paste the actual tail of the test run into the commit
message body — not a claim that it passed.

- [ ] **Step 5: Commit**

```bash
git add README.md .github pretty-view*.el
git commit -m "docs: README, CI workflow, and checkdoc fixes"
```

---

### Task 21: Publish the repository

**Files:**
- No source changes

**Interfaces:**
- Consumes: the committed repository on `main`
- Produces: `https://github.com/mandoo180/pretty-view.el`

- [ ] **Step 1: Confirm the working tree is clean and on main**

```bash
git status --short && git branch --show-current
```

Expected: no output from `git status`, and `main`.

- [ ] **Step 2: Confirm the repository does not already exist**

```bash
gh repo view mandoo180/pretty-view.el 2>&1 | head -3
```

Expected: a "Could not resolve" error. If it already exists, stop and ask
before touching it — pushing over an existing repository is not
recoverable from here.

- [ ] **Step 3: Create the repository and push**

```bash
gh repo create mandoo180/pretty-view.el \
  --public \
  --source=. \
  --remote=origin \
  --description "Render Org, Markdown, and text buffers to styled HTML and open them in your browser" \
  --push
```

- [ ] **Step 4: Verify the push landed**

```bash
gh repo view mandoo180/pretty-view.el --json url,visibility,defaultBranchRef
git log origin/main --oneline -1
```

Expected: `"visibility": "PUBLIC"`, default branch `main`, and the remote
head matching the local head.

- [ ] **Step 5: Verify CI passes on the pushed commit**

```bash
gh run list --limit 1
gh run watch
```

Expected: the run concludes `success`. If a matrix leg fails on Emacs
29.1, fix it locally with `EMACS=emacs-29.1 make test` before moving on —
the spec's version floor is a requirement, not an aspiration.

---

### Task 22: Install and use the package from the author's configuration

The real test: install from GitHub the way a stranger would, and render actual documents.

**Files:**
- Modify: `~/Projects/emacs.light.d/init.el`

**Interfaces:**
- Consumes: the published repository
- Produces: a working `use-package` declaration

**Constraint:** `~/Projects/emacs.light.d` is a separate git repository
with its own remote. Edit `init.el`, but **do not commit or push that
repository** — raise it with the user instead.

- [ ] **Step 1: Read the existing declaration this one should match**

```bash
grep -n -A 10 "use-package mote" ~/Projects/emacs.light.d/init.el
```

The new block follows the same shape: `:vc` with the GitHub URL,
`:commands` for autoloading, `:custom`, `:bind`.

- [ ] **Step 2: Add the declaration**

Insert after the `markdown-mode` block in `~/Projects/emacs.light.d/init.el`:

```elisp
;; Pretty HTML preview for org, markdown and text
(use-package pretty-view
  :vc (:url "https://github.com/mandoo180/pretty-view.el" :rev :newest)
  :commands (pretty-view pretty-view-file pretty-view-export
             pretty-view-live-mode pretty-view-select-theme)
  :custom
  (pretty-view-theme 'auto)
  (pretty-view-toc 3)
  :bind (("C-c v v" . pretty-view)
         ("C-c v l" . pretty-view-live-mode)
         ("C-c v t" . pretty-view-select-theme)))
```

Verify the chosen bindings are free before using them:

```bash
grep -n '"C-c v' ~/Projects/emacs.light.d/init.el
```

- [ ] **Step 3: Verify the configuration byte-compiles**

```bash
cd ~/Projects/emacs.light.d && \
  emacs --batch -f batch-byte-compile early-init.el fu-platform.el init.el
```

Expected: warning-free, matching that repository's own standard.

- [ ] **Step 4: Install the package and render a real document**

```bash
emacs --init-directory=~/Projects/emacs.light.d \
  --eval '(progn (package-vc-install "https://github.com/mandoo180/pretty-view.el")
                 (require (quote pretty-view)))'
```

Then, interactively: open an Org file from the user's `denote` notes, a
Markdown file, and a `.txt` file; run `pretty-view` on each; confirm the
browser opens on Windows and the page renders. Try
`pretty-view-select-theme` and confirm the page changes. Turn on
`pretty-view-live-mode`, edit, save, and confirm the tab updates.

- [ ] **Step 5: Report the result and stop**

Report to the user what worked and what did not, and ask before
committing `~/Projects/emacs.light.d`. That repository has its own remote
and its own history; committing to it is the user's call.

---

## Appendix: File map

| File | Lines (estimate) | Responsibility |
|------|------------------|----------------|
| `pretty-view.el` | 180 | Commands, dispatch, live mode |
| `pretty-view-gfm.el` | 700 | Markdown → AST |
| `pretty-view-render.el` | 400 | AST → HTML, renderer table, code walker |
| `pretty-view-org.el` | 120 | Org → HTML body |
| `pretty-view-text.el` | 60 | Text → HTML body |
| `pretty-view-theme.el` | 350 | Theme registry, CSS, base stylesheet |
| `pretty-view-themes.el` | 150 | Five bundled palettes |
| `pretty-view-html.el` | 250 | Document shell |
| `pretty-view-browser.el` | 150 | Platform, output location, launch |
| `tests/` | 900 | ERT suites and the golden corpus |
