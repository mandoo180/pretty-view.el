# Linked Documents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every local link in a rendered page work: linked documents open as rendered pages, rendered in the background; other local files open in a new tab.

**Architecture:** A new module `pretty-view-links.el` rewrites `<a href>` values in the finished HTML (pure function) and runs a timer-driven FIFO queue that renders linked documents one tick at a time. It writes a page only when its HTML hash changed. `pretty-view-browser.el` gains `pretty-view-browser-file-url` (WSL-aware). `pretty-view.el` wires both into `pretty-view-render-buffer-to-file` through a new LINKS argument, and renders linked files in hook-free temporary buffers.

**Tech Stack:** Emacs Lisp (Emacs 29.1+, built-ins only: `cl-lib`, `seq`, `url-util`, `org`/`ox-html`), ERT, GNU Make.

**Spec:** `docs/superpowers/specs/2026-09-30-linked-documents-design.md`

## Global Constraints

- Emacs floor is 29.1 (`Package-Requires: ((emacs "29.1"))`): use no function newer than 29.1. `string-search`, `string-replace`, and `time-add` with nil are fine.
- No dependencies beyond built-in libraries.
- Every source file keeps the house layout: `-*- lexical-binding: t -*-` first line, the GPL block, `;;; Commentary:`, `;;; Code:`, `(provide 'FEATURE)`, `;;; FILE ends here`.
- `make compile-isolated` byte-compiles each `pretty-view*.el` alone with `byte-compile-error-on-warn t`. Any warning fails the build: no free variables, no unused lexicals, and **no docstring line wider than 80 columns** (the opening `"` and indentation count).
- `make checkdoc` must report zero diagnostics. Docstrings: first line is one complete sentence ending in a period; every argument named in CAPS; **two spaces after each sentence-ending period**; quote symbols as `` `like-this' ``.
- Tests run under `emacs -Q`. `markdown-mode` is absent there, so any test that selects a major mode from a file name uses `.org`, `.txt`, or `.json` fixtures, never `.md`. Pure rewriting tests may use `.md` names.
- User-visible messages are English and start with `pretty-view: `.
- Commit messages use the repo's conventional style (`feat:`, `fix:`, `docs:`, `test:`). **Never add a `Co-Authored-By:` trailer or any Claude signature** (the user's explicit rule).
- Work on branch `feat/follow-links` (already created; the spec is committed there).

**How to run tests.** A single file or name prefix:

```bash
emacs -Q --batch -L . -L tests --eval '(setq load-prefer-newer t)' -l ert \
  -l tests/pretty-view-links-test.el \
  --eval '(ert-run-tests-batch-and-exit "pretty-view-links-test-")'
```

The whole suite: `make test`. The full gate: `make all && make checkdoc && make clean`.

## Review Focus

1. The same document linked several times on one page (a table plus prose): every link must be rewritten, and the document queued once. Tests: Task 2 `every-link-is-rewritten`, Task 3 `document-linked-twice-is-queued-once`.
2. A page linking to itself (`README.md#usage` inside README): the link must point at its own page, and the page must never be queued. Test: Task 3 `self-link-is-not-queued`.
3. File names with spaces and an upper-case extension (`Release Notes.MD`): must count as a document and be linked percent-encoded. Test: Task 2 `spaces-and-upper-case-extension`.
4. Rendering an unsaved, modified root buffer: its links must still work, but its HTML must not be recorded as that file's page. Test: Task 4 `unsaved-buffer-page-is-not-recorded`.
5. A link to a non-document file carrying a query and an escaped `&` (`data.json?x=1&amp;y=2#k`): must open the file, keep the fragment, and drop the query. Test: Task 2 `other-file-keeps-fragment-drops-query`.

---

### Task 1: Browser-openable file URLs

**Files:**
- Modify: `pretty-view-browser.el` (requires; the defvars at the top; `pretty-view-browser--reset-caches`; new functions after `pretty-view-browser--windows-path`)
- Modify: `pretty-view-html.el` (requires; `pretty-view-inline-image-max-bytes` docstring; the fallback at the `(file-readable-p file) (concat "file://" file)` line in `pretty-view-html--inline-assets`)
- Test: `tests/pretty-view-browser-test.el`, `tests/pretty-view-html-test.el`

**Interfaces:**
- Consumes: `pretty-view-browser-wsl-p`, `pretty-view-browser--windows-path` (existing).
- Produces: `(pretty-view-browser-file-url FILE)` → string URL, where FILE is an absolute file name. `pretty-view-browser--wsl-root` → string such as `"//wsl.localhost/Ubuntu"`, or nil. Cache variable `pretty-view-browser--wsl-root-cache` (initially `'unset`).

- [ ] **Step 1: Write the failing tests**

Append to `tests/pretty-view-browser-test.el`, before `(provide 'pretty-view-browser-test)`:

```elisp
(defmacro pv-with-wsl-root (root &rest body)
  "Run BODY under WSL with the WSL root URL prefix cached as ROOT."
  (declare (indent 1))
  `(let ((pretty-view-browser--wsl-root-cache ,root))
     (pv-with-wsl t ,@body)))

(ert-deftest pretty-view-browser-test-file-url-plain-path ()
  (pv-with-wsl nil
    (should (equal (pretty-view-browser-file-url "/tmp/a b/x.pdf")
                   "file:///tmp/a%20b/x.pdf"))))

(ert-deftest pretty-view-browser-test-file-url-encodes-each-segment ()
  (pv-with-wsl nil
    (should (equal (pretty-view-browser-file-url "/d/설명#1.json")
                   "file:///d/%EC%84%A4%EB%AA%85%231.json"))))

(ert-deftest pretty-view-browser-test-file-url-windows-drive ()
  (pv-with-wsl nil
    (should (equal (pretty-view-browser-file-url "c:/Users/u/a b.pdf")
                   "file:///C:/Users/u/a%20b.pdf"))))

(ert-deftest pretty-view-browser-test-file-url-wsl-home ()
  (pv-with-wsl-root "//wsl.localhost/Ubuntu"
    (should (equal (pretty-view-browser-file-url "/home/u/data.json")
                   "file://wsl.localhost/Ubuntu/home/u/data.json"))))

(ert-deftest pretty-view-browser-test-file-url-wsl-windows-drive ()
  "A file on a mounted Windows drive needs no WSL root, and no wslpath."
  (pv-with-wsl-root 'unset
    (cl-letf (((symbol-function 'pretty-view-browser--windows-path)
               (lambda (_f) (error "wslpath must not run"))))
      (should (equal (pretty-view-browser-file-url
                      "/mnt/c/Users/u/My Docs/a.pdf")
                     "file:///C:/Users/u/My%20Docs/a.pdf"))
      (should (equal (pretty-view-browser-file-url "/mnt/d")
                     "file:///D:/")))))

(ert-deftest pretty-view-browser-test-file-url-wsl-root-falls-back ()
  "Without a WSL root the URL is the plain Linux one, as before."
  (pv-with-wsl-root nil
    (should (equal (pretty-view-browser-file-url "/home/u/x.json")
                   "file:///home/u/x.json"))))

(ert-deftest pretty-view-browser-test-wsl-root-from-wslpath ()
  (let ((pretty-view-browser--wsl-root-cache 'unset)
        (calls 0))
    (cl-letf (((symbol-function 'pretty-view-browser--windows-path)
               (lambda (f)
                 (should (equal f "/"))
                 (setq calls (1+ calls))
                 "\\\\wsl.localhost\\Ubuntu-24.04\\")))
      (should (equal (pretty-view-browser--wsl-root)
                     "//wsl.localhost/Ubuntu-24.04"))
      (should (equal (pretty-view-browser--wsl-root)
                     "//wsl.localhost/Ubuntu-24.04"))
      (should (= calls 1)))))

(ert-deftest pretty-view-browser-test-wsl-root-rejects-garbage ()
  (let ((pretty-view-browser--wsl-root-cache 'unset))
    (cl-letf (((symbol-function 'pretty-view-browser--windows-path)
               (lambda (_f) "wslpath: /: error")))
      (should (null (pretty-view-browser--wsl-root))))))

(ert-deftest pretty-view-browser-test-reset-clears-wsl-root ()
  (let ((pretty-view-browser--wsl-root-cache "//x/y")
        (pretty-view-browser--windows-temp-cache nil)
        (pretty-view-browser--uname "k"))
    (pretty-view-browser--reset-caches)
    (should (eq pretty-view-browser--wsl-root-cache 'unset))))
```

Append to `tests/pretty-view-html-test.el`, before its `(provide ...)`:

```elisp
(ert-deftest pretty-view-html-test-oversized-image-uses-browser-file-url ()
  "An image too large to embed is linked through a browser-ready URL."
  (let* ((dir (make-temp-file "pv-assets" t))
         (png (expand-file-name "big.png" dir))
         (pretty-view-inline-image-max-bytes 8))
    (unwind-protect
        (cl-letf (((symbol-function 'pretty-view-browser-file-url)
                   (lambda (f) (concat "URL:" f))))
          (with-temp-file png (insert (make-string 100 ?a)))
          (should (string-match-p
                   (regexp-quote (concat "src=\"URL:" png "\""))
                   (pretty-view-html--inline-assets
                    "<img src=\"big.png\" />" dir))))
      (delete-directory dir t))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
emacs -Q --batch -L . -L tests --eval '(setq load-prefer-newer t)' -l ert \
  -l tests/pretty-view-browser-test.el -l tests/pretty-view-html-test.el \
  --eval '(ert-run-tests-batch-and-exit "\\(file-url\\|wsl-root\\|oversized\\)")'
```
Expected: FAIL. The new browser tests fail with `void-function pretty-view-browser-file-url` or `void-variable pretty-view-browser--wsl-root-cache`, and the html test fails because `src` is `file://...`.

- [ ] **Step 3: Implement the file URLs in `pretty-view-browser.el`**

Change `(require 'seq)` to:

```elisp
(require 'seq)
(require 'url-util)
```

After the `pretty-view-browser--windows-temp-cache` defvar, add:

```elisp
(defvar pretty-view-browser--wsl-root-cache 'unset
  "Cached URL prefix of the WSL root file system, or `unset'.
Either a string such as \"//wsl.localhost/Ubuntu\", or nil when
`wslpath' could not produce one.  A variable rather than a call so
tests can rebind it.")
```

Replace `pretty-view-browser--reset-caches` with:

```elisp
(defun pretty-view-browser--reset-caches ()
  "Reset all caches for testing."
  (setq pretty-view-browser--windows-temp-cache 'unset)
  (setq pretty-view-browser--wsl-root-cache 'unset)
  (setq pretty-view-browser--uname nil))
```

Directly after `pretty-view-browser--windows-path`, add:

```elisp
(defun pretty-view-browser--wsl-root ()
  "Return the URL prefix of the WSL root file system, or nil.
It is `wslpath -w /' with slashes for backslashes and no trailing
slash, such as \"//wsl.localhost/Ubuntu\".  The result is computed on
first use and cached for the session."
  (when (eq pretty-view-browser--wsl-root-cache 'unset)
    (setq pretty-view-browser--wsl-root-cache
          (let ((win (pretty-view-browser--windows-path "/")))
            (and win
                 (string-prefix-p "\\\\" win)
                 (string-trim-right (string-replace "\\" "/" win) "/+")))))
  pretty-view-browser--wsl-root-cache)

(defun pretty-view-browser--encode-path (path)
  "Return PATH with each segment percent-encoded and its slashes kept."
  (mapconcat #'url-hexify-string (split-string path "/") "/"))

(defun pretty-view-browser--drive-url (drive rest)
  "Return the URL of REST, a slash-led path or nil, on Windows DRIVE."
  (concat "file:///" (upcase drive) ":"
          (pretty-view-browser--encode-path (or rest "/"))))

(defun pretty-view-browser-file-url (file)
  "Return a URL the browser can open for FILE, an absolute file name.
Under WSL the browser runs on Windows, so a file on a mounted Windows
drive becomes a drive URL and any other file a URL under the WSL root;
see `pretty-view-browser--wsl-root'.  A Windows file name becomes a
drive URL, and anything else a plain `file://' URL.  Every path
segment is percent-encoded."
  (let ((wsl (pretty-view-browser-wsl-p)))
    (cond
     ((and wsl (string-match "\\`/mnt/\\([a-zA-Z]\\)\\(/.*\\)?\\'" file))
      (pretty-view-browser--drive-url (match-string 1 file)
                                      (match-string 2 file)))
     ((string-match "\\`\\([a-zA-Z]\\):\\(/.*\\)?\\'" file)
      (pretty-view-browser--drive-url (match-string 1 file)
                                      (match-string 2 file)))
     ((and wsl (pretty-view-browser--wsl-root))
      (concat "file:" (pretty-view-browser--wsl-root)
              (pretty-view-browser--encode-path file)))
     (t (concat "file://" (pretty-view-browser--encode-path file))))))
```

- [ ] **Step 4: Use it for the oversized-image fallback in `pretty-view-html.el`**

After `(require 'pretty-view-render)`, add `(require 'pretty-view-browser)`.

In `pretty-view-html--inline-assets`, replace

```elisp
                           ((file-readable-p file) (concat "file://" file))
```

with

```elisp
                           ((file-readable-p file)
                            (pretty-view-browser-file-url file))
```

Replace the `pretty-view-inline-image-max-bytes` docstring with:

```elisp
  "Largest image, in bytes, that is embedded as a data URI.
Larger files are linked with a `file://' URL the browser can open
instead; see `pretty-view-browser-file-url'."
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the Step 2 command. Expected: all selected tests PASS. Then run `make test`. Expected: all tests pass, and the existing `pretty-view-html-test-inline-respects-size-ceiling` still passes (its URL still contains `file://`).

- [ ] **Step 6: Gate and commit**

```bash
make compile-isolated && make checkdoc && make clean
git add pretty-view-browser.el pretty-view-html.el tests/pretty-view-browser-test.el tests/pretty-view-html-test.el
git commit -m "feat: open local files through browser-ready file URLs

Under WSL the browser runs on Windows, so a Linux path in a file://
URL names nothing.  pretty-view-browser-file-url maps /mnt/<d>/ to a
drive URL and any other path under the wsl.localhost root.  The
oversized-image fallback uses it, which makes large images show on
WSL."
```

---

### Task 2: Link rewriting

**Files:**
- Create: `pretty-view-links.el`
- Create: `tests/pretty-view-links-test.el`

**Interfaces:**
- Consumes: `pretty-view-escape-attribute` (`pretty-view-render.el`), `pretty-view-browser-file-url` (Task 1).
- Produces:
  - Options `pretty-view-follow-links` (boolean, default t), `pretty-view-follow-links-limit` (integer, default 200), `pretty-view-follow-links-extensions` (list of strings, default `("md" "markdown" "org" "txt")`).
  - `(pretty-view-links-rewrite HTML BASE-DIRECTORY ACCEPT)` → string. ACCEPT is nil or a function of one absolute file name, returning an output file name (string) or nil.
  - Internal: `pretty-view-links--local-file`, `pretty-view-links--document-p`, `pretty-view-links--decode`, `pretty-view-links--unescape`.

- [ ] **Step 1: Write the failing tests**

Create `tests/pretty-view-links-test.el`:

```elisp
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
emacs -Q --batch -L . -L tests --eval '(setq load-prefer-newer t)' -l ert \
  -l tests/pretty-view-links-test.el \
  --eval '(ert-run-tests-batch-and-exit "pretty-view-links-test-")'
```
Expected: FAIL at load with `Cannot open load file ... pretty-view-links`.

- [ ] **Step 3: Create `pretty-view-links.el` with the options and the rewriter**

```elisp
;;; pretty-view-links.el --- Make local links work from the output directory  -*- lexical-binding: t -*-

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

;; Rendered pages live in a temporary directory, so a relative link in
;; one resolves against that directory and breaks.  This file rewrites
;; each local link: a link to another document points at that
;; document's rendered page, and a link to any other file points at the
;; file itself, through a URL the browser can open.
;;
;; Linked documents are rendered in the background, one timer tick at a
;; time, so Emacs stays responsive while a large set is written.  A page
;; is only rewritten when its HTML changed, because writing is what
;; costs time on the Windows drive that WSL output goes to.

;;; Code:

(require 'cl-lib)
(require 'url-util)
(require 'pretty-view-render)
(require 'pretty-view-browser)

(defcustom pretty-view-follow-links t
  "Whether to render the local documents a rendered page links to.
When non-nil, a link to a file whose extension is in
`pretty-view-follow-links-extensions' points at that file's rendered
page, which is written in the background.  When nil, such a link
opens the file itself in a new tab, like a link to any other file."
  :type 'boolean
  :group 'pretty-view)

(defcustom pretty-view-follow-links-limit 200
  "Most linked documents that one render follows.
Links are followed breadth-first from the rendered document.  Past
this many documents, further links open the linked file itself."
  :type 'integer
  :group 'pretty-view)

(defcustom pretty-view-follow-links-extensions '("md" "markdown" "org" "txt")
  "Lower-case extensions of the linked files that are rendered.
Extensions are compared case-insensitively."
  :type '(repeat string)
  :group 'pretty-view)

;; Rewriting

(defconst pretty-view-links--anchor-re
  "<a[ \t\n]\\(?:[^>]*?[ \t\n]\\)?href=\"\\([^\"]*\\)\"[^>]*>"
  "Match an opening `a' tag with a double-quoted `href'.
Group 1 is the attribute value.")

(defun pretty-view-links--unescape (string)
  "Return STRING with the entities `pretty-view-escape-html' writes decoded."
  (let ((s string))
    (dolist (pair '(("&lt;" . "<") ("&gt;" . ">") ("&quot;" . "\"")
                    ("&#39;" . "'") ("&amp;" . "&")))
      (setq s (string-replace (car pair) (cdr pair) s)))
    s))

(defun pretty-view-links--decode (path)
  "Return PATH with its percent-escapes decoded as UTF-8."
  (if (string-search "%" path)
      (decode-coding-string
       (url-unhex-string (encode-coding-string path 'utf-8)) 'utf-8)
    path))

(defun pretty-view-links--local-file (href base-directory)
  "Return (FILE . FRAGMENT) when HREF names an existing local file.
HREF is an attribute value as rendered, still entity-escaped.  FILE is
its absolute file name, resolved against BASE-DIRECTORY, and FRAGMENT
its `#' part, or the empty string.  Return nil for a URL with a scheme
other than `file:', a network-path or same-page reference, and a name
that is not a regular file."
  (let* ((href (pretty-view-links--unescape href))
         (hash (string-search "#" href))
         (fragment (if hash (substring href hash) ""))
         (path (substring href 0 hash))
         (query (string-search "?" path))
         (path (substring path 0 query)))
    (cond
     ((string-match "\\`file:\\(?://\\)?" path)
      (setq path (substring path (match-end 0))))
     ((string-match-p "\\`\\(?:[a-zA-Z][a-zA-Z0-9+.-]*:\\|//\\)" path)
      (setq path "")))
    (unless (string-empty-p path)
      (let ((file (expand-file-name (pretty-view-links--decode path)
                                    base-directory)))
        (and (file-regular-p file) (cons file fragment))))))

(defun pretty-view-links--document-p (file)
  "Return non-nil when FILE's extension marks it as a document.
See `pretty-view-follow-links-extensions'."
  (let ((ext (file-name-extension file)))
    (and ext (member (downcase ext) pretty-view-follow-links-extensions) t)))

(defun pretty-view-links-rewrite (html base-directory accept)
  "Return HTML with its local links rewritten for the output directory.
BASE-DIRECTORY resolves relative links.  ACCEPT, when non-nil, is
called with the absolute file name of each linked document, one whose
extension is in `pretty-view-follow-links-extensions', and returns
the output file to link to, or nil.  A document ACCEPT declines, and
any other local file, is linked through a URL for the file itself that
opens in a new tab; see `pretty-view-browser-file-url'.  Remote,
same-page, and dangling links are left alone, as is everything when
BASE-DIRECTORY is remote."
  (if (file-remote-p base-directory)
      html
    (with-temp-buffer
      (insert html)
      (goto-char (point-min))
      (while (re-search-forward pretty-view-links--anchor-re nil t)
        (let* ((tag-end (copy-marker (match-end 0)))
               (tag (match-string 0))
               (beg (match-beginning 1))
               (end (match-end 1))
               (local (pretty-view-links--local-file (match-string 1)
                                                     base-directory)))
          (when local
            (let* ((file (car local))
                   (output (and accept
                                (pretty-view-links--document-p file)
                                (funcall accept file))))
              ;; The tag's end is edited first, so BEG and END still
              ;; hold when the href is replaced.
              (unless (or output (string-match-p "[ \t\n]target=" tag))
                (goto-char (1- tag-end))
                (insert " target=\"_blank\" rel=\"noopener\""))
              (goto-char beg)
              (delete-region beg end)
              (insert (pretty-view-escape-attribute
                       (concat (if output
                                   (url-hexify-string
                                    (file-name-nondirectory output))
                                 (pretty-view-browser-file-url file))
                               (cdr local))))))
          (goto-char tag-end)
          (set-marker tag-end nil)))
      (buffer-string))))

(provide 'pretty-view-links)
;;; pretty-view-links.el ends here
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the Step 2 command. Expected: all `pretty-view-links-test-` tests PASS.

- [ ] **Step 5: Gate and commit**

```bash
make compile-isolated && make checkdoc && make test && make clean
git add pretty-view-links.el tests/pretty-view-links-test.el
git commit -m "feat: rewrite local links in rendered pages

A link to a document points at its rendered page; a link to any other
local file opens the file through a browser-ready URL in a new tab.
Remote, same-page, and dangling links are left alone."
```

---

### Task 3: Background queue for linked documents

**Files:**
- Modify: `pretty-view-links.el` (append before `(provide 'pretty-view-links)`)
- Test: `tests/pretty-view-links-test.el` (append before its `(provide ...)`)

**Interfaces:**
- Consumes: `pretty-view-browser-output-file` (existing), `pretty-view-follow-links-limit` (Task 2).
- Produces:
  - `pretty-view-links-current-run`: dynamic variable holding the run for the document being rendered, or nil.
  - `(pretty-view-links-start-run ROOT RENDER)` → run. ROOT is an absolute file name or nil. RENDER is a function of one absolute file name, called with `pretty-view-links-current-run` bound, returning an HTML string.
  - `(pretty-view-links-accept SOURCE)` → output file name, or nil. Suitable as the ACCEPT argument of `pretty-view-links-rewrite`.
  - `(pretty-view-links-record FILE HTML)`: remembers that FILE holds HTML.
  - `(pretty-view-links-write FILE HTML)`: writes FILE (UTF-8, creating directories) and records it.
  - `(pretty-view-links-reset)`: drops the queue and cancels the pending tick.
  - Internal but used by tests: `pretty-view-links--tick`, `pretty-view-links--queue`, `pretty-view-links--queued`, `pretty-view-links--timer`, `pretty-view-links--written`, `pretty-view-links--unchanged-p`, `pretty-view-links--report`, run accessors `pretty-view-links--run-{count,limit-hit,pending,written,unchanged,failed}`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/pretty-view-links-test.el`, before `(provide 'pretty-view-links-test)`:

```elisp
;;; Queue

(defvar pv-queue-rendered nil
  "Sources the fake render function was called with, in order.")

(defmacro pv-queue-test (&rest body)
  "Run BODY with an empty queue and page table, and fresh output."
  `(let ((pretty-view-links--queue nil)
         (pretty-view-links--queued (make-hash-table :test #'equal))
         (pretty-view-links--timer nil)
         (pretty-view-links--written (make-hash-table :test #'equal))
         (pretty-view-links-current-run nil)
         (pretty-view-output-directory (make-temp-file "pv-out" t))
         (pv-queue-rendered nil))
     (unwind-protect (progn ,@body)
       (pretty-view-links-reset)
       (delete-directory pretty-view-output-directory t))))

(defun pv-queue-render (graph)
  "Return a fake render function over GRAPH.
GRAPH is an alist (SOURCE . LINKED-SOURCES).  Rendering SOURCE records
it in `pv-queue-rendered', accepts each linked source as link
rewriting would, and returns the resulting links as the page's HTML."
  (lambda (source)
    (setq pv-queue-rendered (append pv-queue-rendered (list source)))
    (mapconcat (lambda (s) (or (pretty-view-links-accept s) "declined"))
               (cdr (assoc source graph))
               "\n")))

(defun pv-queue-start (root graph)
  "Start a run at ROOT over GRAPH and accept ROOT's links; return it."
  (let ((pretty-view-links-current-run
         (pretty-view-links-start-run root (pv-queue-render graph))))
    (dolist (s (cdr (assoc root graph)))
      (pretty-view-links-accept s))
    pretty-view-links-current-run))

(defun pv-queue-drain ()
  "Tick the queue until it is empty."
  (while pretty-view-links--queue
    (pretty-view-links--tick)))

(defun pv-queue-page (source)
  "Return the contents of SOURCE's output file, or nil when absent."
  (let ((out (pretty-view-browser-output-file source)))
    (and (file-exists-p out)
         (with-temp-buffer (insert-file-contents out) (buffer-string)))))

(defmacro pv-queue-capturing (log &rest body)
  "Run BODY, pushing every formatted `message' onto the list LOG."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'message)
              (lambda (fmt &rest args)
                (push (apply #'format fmt args) ,log))))
     ,@body))

(ert-deftest pretty-view-links-test-accept-without-a-run ()
  (pv-queue-test
   (should (null (pretty-view-links-accept "/s/a.md")))
   (should (null pretty-view-links--queue))))

(ert-deftest pretty-view-links-test-queue-renders-breadth-first ()
  (pv-queue-test
   (pv-queue-start "/s/root.md" '(("/s/root.md" "/s/a.md" "/s/b.md")
                                  ("/s/a.md" "/s/c.md")))
   (pv-queue-drain)
   (should (equal pv-queue-rendered '("/s/a.md" "/s/b.md" "/s/c.md")))
   (should (pv-queue-page "/s/c.md"))))

(ert-deftest pretty-view-links-test-queue-survives-a-cycle ()
  (pv-queue-test
   (pv-queue-start "/s/root.md" '(("/s/root.md" "/s/a.md")
                                  ("/s/a.md" "/s/b.md")
                                  ("/s/b.md" "/s/a.md" "/s/root.md")))
   (pv-queue-drain)
   (should (equal pv-queue-rendered '("/s/a.md" "/s/b.md")))))

(ert-deftest pretty-view-links-test-back-link-to-root-is-linked-not-queued ()
  (pv-queue-test
   (let ((run (pv-queue-start "/s/root.md" '(("/s/root.md" "/s/a.md")
                                              ("/s/a.md" "/s/root.md")))))
     (pv-queue-drain)
     (should (equal (pv-queue-page "/s/a.md")
                    (pretty-view-browser-output-file "/s/root.md")))
     (should (= (pretty-view-links--run-count run) 1)))))

(ert-deftest pretty-view-links-test-self-link-is-not-queued ()
  "Review focus: a root linking to itself, as a `#section' link would."
  (pv-queue-test
   (let ((pretty-view-links-current-run
          (pretty-view-links-start-run "/s/root.md" #'ignore)))
     (should (equal (pretty-view-links-accept "/s/root.md")
                    (pretty-view-browser-output-file "/s/root.md")))
     (should (null pretty-view-links--queue)))))

(ert-deftest pretty-view-links-test-document-linked-twice-is-queued-once ()
  "Review focus: the same document linked from several places."
  (pv-queue-test
   (pv-queue-start "/s/root.md"
                   '(("/s/root.md" "/s/a.md" "/s/a.md" "/s/a.md")))
   (should (= (length pretty-view-links--queue) 1))))

(ert-deftest pretty-view-links-test-runs-share-queued-documents ()
  (pv-queue-test
   (pv-queue-start "/s/one.md" '(("/s/one.md" "/s/a.md")))
   (let ((two (pv-queue-start "/s/two.md" '(("/s/two.md" "/s/a.md")))))
     (should (= (length pretty-view-links--queue) 1))
     (should (= (pretty-view-links--run-pending two) 0)))))

(ert-deftest pretty-view-links-test-limit-declines-and-is-reported ()
  (pv-queue-test
   (let ((pretty-view-follow-links-limit 2)
         (log nil))
     (pv-queue-capturing log
       (let ((run (pv-queue-start
                   "/s/root.md"
                   '(("/s/root.md" "/s/a.md" "/s/b.md" "/s/c.md")))))
         (should (pretty-view-links--run-limit-hit run))
         (should (= (length pretty-view-links--queue) 2))
         (pv-queue-drain)
         (should (string-match-p "stopped after 2" (car log))))))))

(ert-deftest pretty-view-links-test-unchanged-page-is-not-rewritten ()
  (pv-queue-test
   (let ((graph '(("/s/root.md" "/s/a.md") ("/s/a.md" "/s/c.md"))))
     (pv-queue-start "/s/root.md" graph)
     (pv-queue-drain)
     ;; Mark a's page: if the second run rewrote it, the mark would go.
     (with-temp-file (pretty-view-browser-output-file "/s/a.md")
       (insert "MARK"))
     (setq pv-queue-rendered nil)
     (let ((run (pv-queue-start "/s/root.md" graph)))
       (pv-queue-drain)
       (should (equal (pv-queue-page "/s/a.md") "MARK"))
       ;; Its links were still followed.
       (should (equal pv-queue-rendered '("/s/a.md" "/s/c.md")))
       (should (= (pretty-view-links--run-unchanged run) 2))
       (should (= (pretty-view-links--run-written run) 0))))))

(ert-deftest pretty-view-links-test-changed-page-is-rewritten ()
  (pv-queue-test
   (let* ((version 1)
          (render (lambda (s) (format "%s v%d" s version))))
     (dotimes (_ 2)
       (let ((pretty-view-links-current-run
              (pretty-view-links-start-run "/s/root.md" render)))
         (pretty-view-links-accept "/s/a.md"))
       (pv-queue-drain)
       (should (equal (pv-queue-page "/s/a.md")
                      (format "/s/a.md v%d" version)))
       (setq version 2)))))

(ert-deftest pretty-view-links-test-deleted-page-is-rewritten ()
  (pv-queue-test
   (let ((graph '(("/s/root.md" "/s/a.md"))))
     (pv-queue-start "/s/root.md" graph)
     (pv-queue-drain)
     (delete-file (pretty-view-browser-output-file "/s/a.md"))
     (pv-queue-start "/s/root.md" graph)
     (pv-queue-drain)
     (should (pv-queue-page "/s/a.md")))))

(ert-deftest pretty-view-links-test-failure-is-isolated-and-logged ()
  (pv-queue-test
   (let ((log nil))
     (pv-queue-capturing log
       (let* ((render (lambda (s)
                        (if (equal s "/s/a.md") (error "Boom") "ok")))
              (run (pretty-view-links-start-run "/s/root.md" render)))
         (let ((pretty-view-links-current-run run))
           (pretty-view-links-accept "/s/a.md")
           (pretty-view-links-accept "/s/b.md"))
         (pv-queue-drain)
         (should (= (pretty-view-links--run-failed run) 1))
         (should (= (pretty-view-links--run-written run) 1))
         (should (pv-queue-page "/s/b.md"))
         (should (seq-some (lambda (m)
                             (string-match-p
                              "could not render /s/a\\.md (Boom)" m))
                           log)))))))

(ert-deftest pretty-view-links-test-live-mode-page-is-left-to-live-mode ()
  (pv-queue-test
   (let* ((src (make-temp-file "pv-live" nil ".txt"))
          (out (pretty-view-browser-output-file src))
          (buf (find-file-noselect src)))
     (unwind-protect
         (progn
           (with-current-buffer buf (setq-local pretty-view-live-mode t))
           (with-temp-file out (insert "LIVE PAGE"))
           (let ((run (pretty-view-links-start-run
                       nil (lambda (_s) "background"))))
             (let ((pretty-view-links-current-run run))
               (pretty-view-links-accept src))
             (pv-queue-drain)
             (should (equal (pv-queue-page src) "LIVE PAGE"))
             (should (= (pretty-view-links--run-unchanged run) 1)))
           ;; With no page yet, the background writes one.
           (delete-file out)
           (let ((pretty-view-links-current-run
                  (pretty-view-links-start-run
                   nil (lambda (_s) "background"))))
             (pretty-view-links-accept src))
           (pv-queue-drain)
           (should (equal (pv-queue-page src) "background")))
       (kill-buffer buf)
       (delete-file src)))))

(ert-deftest pretty-view-links-test-summary-counts ()
  (pv-queue-test
   (let ((log nil))
     (pv-queue-capturing log
       (pv-queue-start "/s/root.md" '(("/s/root.md" "/s/a.md" "/s/b.md")))
       (pv-queue-drain))
     (should (equal (car log)
                    (concat "pretty-view: linked documents — "
                            "2 written, 0 unchanged, 0 failed")))
     (should (member "pretty-view: rendering linked documents 1/2" log)))))

(ert-deftest pretty-view-links-test-quiet-while-minibuffer-is-active ()
  (pv-queue-test
   (let ((log nil))
     (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () t))
               ((symbol-function 'message)
                (lambda (fmt &rest args)
                  (push (cons inhibit-message (apply #'format fmt args))
                        log))))
       (pv-queue-start "/s/root.md" '(("/s/root.md" "/s/a.md" "/s/b.md")))
       (pv-queue-drain))
     ;; No progress; the summary is logged but not displayed.
     (should (= (length log) 1))
     (should (car (car log)))
     (should (string-match-p "2 written" (cdr (car log)))))))

(ert-deftest pretty-view-links-test-pending-input-defers-the-work ()
  (pv-queue-test
   (pv-queue-start "/s/root.md" '(("/s/root.md" "/s/a.md")))
   (cl-letf (((symbol-function 'input-pending-p) (lambda (&rest _) t)))
     (pretty-view-links--tick))
   (should (= (length pretty-view-links--queue) 1))
   (should (null pv-queue-rendered))
   (should (timerp pretty-view-links--timer))))

(ert-deftest pretty-view-links-test-bookkeeping-error-clears-the-queue ()
  (pv-queue-test
   (let ((log nil))
     (pv-queue-start "/s/root.md" '(("/s/root.md" "/s/a.md" "/s/b.md")))
     (pv-queue-capturing log
       (cl-letf (((symbol-function 'pretty-view-links--report)
                  (lambda (_run) (error "Bug"))))
         (pretty-view-links--tick)))
     (should (null pretty-view-links--queue))
     (should (zerop (hash-table-count pretty-view-links--queued)))
     (should (null pretty-view-links--timer))
     (should (string-match-p "linked documents stopped (Bug)" (car log))))))

(ert-deftest pretty-view-links-test-write-creates-directory-and-records ()
  (pv-queue-test
   (let ((file (expand-file-name "deep/er/p.html"
                                 pretty-view-output-directory)))
     (pretty-view-links-write file "<p>é</p>")
     (should (file-exists-p file))
     (should (pretty-view-links--unchanged-p file "<p>é</p>"))
     (should-not (pretty-view-links--unchanged-p file "<p>e</p>")))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
emacs -Q --batch -L . -L tests --eval '(setq load-prefer-newer t)' -l ert \
  -l tests/pretty-view-links-test.el \
  --eval '(ert-run-tests-batch-and-exit "pretty-view-links-test-")'
```
Expected: the Task 2 tests pass. The new tests fail with `void-variable pretty-view-links--queue` (the `pv-queue-test` let) or `void-function pretty-view-links-accept`.

- [ ] **Step 3: Implement the queue**

Append to `pretty-view-links.el`, before `(provide 'pretty-view-links)`:

```elisp
;; Runs and the background queue

(cl-defstruct (pretty-view-links--run
               (:constructor pretty-view-links--make-run)
               (:copier nil))
  "One render's walk over the documents it links to, and its tallies."
  (render nil)
  (visited (make-hash-table :test #'equal))
  (count 0)
  (limit-hit nil)
  (pending 0)
  (written 0)
  (unchanged 0)
  (failed 0))

(defvar pretty-view-links-current-run nil
  "The run that the document being rendered belongs to, or nil.
`pretty-view-links-accept' queues linked documents into this run.")

(defvar pretty-view-links--queue nil
  "Documents waiting to be rendered, oldest first.
Each entry is a list (SOURCE OUTPUT RUN).")

(defvar pretty-view-links--queued (make-hash-table :test #'equal)
  "Output files that have an entry in `pretty-view-links--queue'.")

(defvar pretty-view-links--timer nil
  "The timer for the next tick of the queue, or nil.")

(defvar pretty-view-links--written (make-hash-table :test #'equal)
  "Map an output file to the SHA-1 of the HTML last written to it.")

(defun pretty-view-links-start-run (root render)
  "Return a new run for ROOT that renders linked documents with RENDER.
ROOT is the rendered document's absolute file name, or nil when it has
none.  RENDER is called with a linked document's absolute file name
while `pretty-view-links-current-run' is bound to the run, and returns
the document's HTML."
  (let ((run (pretty-view-links--make-run :render render)))
    (when root
      (puthash root t (pretty-view-links--run-visited run)))
    run))

(defun pretty-view-links-accept (source)
  "Return the output file to link SOURCE to, queueing SOURCE when new.
SOURCE is a linked document's absolute file name.  Return nil when no
run is current, or when the current run has already accepted
`pretty-view-follow-links-limit' documents."
  (let ((run pretty-view-links-current-run))
    (when run
      (let ((visited (pretty-view-links--run-visited run))
            (output (pretty-view-browser-output-file source)))
        (cond
         ((gethash source visited) output)
         ((>= (pretty-view-links--run-count run)
              pretty-view-follow-links-limit)
          (setf (pretty-view-links--run-limit-hit run) t)
          nil)
         (t
          (puthash source t visited)
          (cl-incf (pretty-view-links--run-count run))
          (pretty-view-links--enqueue source output run)
          output))))))

(defun pretty-view-links--enqueue (source output run)
  "Queue SOURCE, rendered to OUTPUT, for RUN, unless OUTPUT is queued."
  (unless (gethash output pretty-view-links--queued)
    (puthash output t pretty-view-links--queued)
    (cl-incf (pretty-view-links--run-pending run))
    (setq pretty-view-links--queue
          (nconc pretty-view-links--queue (list (list source output run))))
    (pretty-view-links--schedule 0)))

(defun pretty-view-links--schedule (delay)
  "Run the next tick of the queue in DELAY seconds, unless one is due."
  (unless pretty-view-links--timer
    (setq pretty-view-links--timer
          (run-at-time delay nil #'pretty-view-links--tick))))

(defun pretty-view-links-reset ()
  "Drop every queued document and cancel the pending tick."
  (when pretty-view-links--timer
    (cancel-timer pretty-view-links--timer))
  (setq pretty-view-links--timer nil
        pretty-view-links--queue nil)
  (clrhash pretty-view-links--queued))

(defun pretty-view-links--tick ()
  "Process queued documents for up to 50 ms, then yield to the user.
Pending input postpones the work.  An error outside any one document
clears the queue, so the next render starts from a clean state."
  ;; Called directly rather than by its timer, the tick must not leave
  ;; that timer to fire later.
  (when pretty-view-links--timer
    (cancel-timer pretty-view-links--timer)
    (setq pretty-view-links--timer nil))
  (condition-case err
      (if (input-pending-p)
          (pretty-view-links--schedule 0.2)
        (let ((deadline (time-add nil 0.05)))
          (while (progn
                   (pretty-view-links--process (pop pretty-view-links--queue))
                   (and pretty-view-links--queue
                        (not (input-pending-p))
                        (time-less-p nil deadline)))))
        (when pretty-view-links--queue
          (pretty-view-links--schedule 0.01)))
    (error
     (pretty-view-links-reset)
     (pretty-view-links--log "pretty-view: linked documents stopped (%s)"
                             (error-message-string err)))))

(defun pretty-view-links--process (item)
  "Render ITEM, a queue entry (SOURCE OUTPUT RUN), and write it if changed."
  (when item
    (let ((source (nth 0 item))
          (output (nth 1 item))
          (run (nth 2 item)))
      (remhash output pretty-view-links--queued)
      (condition-case err
          (let ((html (let ((pretty-view-links-current-run run))
                        (funcall (pretty-view-links--run-render run) source))))
            (if (or (pretty-view-links--owned-by-live-mode-p source output)
                    (pretty-view-links--unchanged-p output html))
                (cl-incf (pretty-view-links--run-unchanged run))
              (pretty-view-links-write output html)
              (cl-incf (pretty-view-links--run-written run))))
        (error
         (cl-incf (pretty-view-links--run-failed run))
         (pretty-view-links--log "pretty-view: could not render %s (%s)"
                                 source (error-message-string err))))
      (cl-decf (pretty-view-links--run-pending run))
      (pretty-view-links--report run))))

(defun pretty-view-links--owned-by-live-mode-p (source output)
  "Return non-nil when a live-mode buffer maintains OUTPUT for SOURCE.
That buffer's saves write the page with the watcher that reloads it,
which a background write would drop."
  (let ((buffer (find-buffer-visiting source)))
    (and buffer
         (local-variable-p 'pretty-view-live-mode buffer)
         (buffer-local-value 'pretty-view-live-mode buffer)
         (file-exists-p output))))

;; Unchanged pages

(defun pretty-view-links--hash (html)
  "Return the SHA-1 of HTML's UTF-8 encoding."
  (secure-hash 'sha1 (encode-coding-string html 'utf-8)))

(defun pretty-view-links-record (file html)
  "Remember that FILE now holds HTML."
  (puthash file (pretty-view-links--hash html) pretty-view-links--written))

(defun pretty-view-links--unchanged-p (output html)
  "Return non-nil when OUTPUT exists and last received exactly HTML."
  (and (equal (gethash output pretty-view-links--written)
              (pretty-view-links--hash html))
       (file-exists-p output)))

(defun pretty-view-links-write (file html)
  "Write HTML to FILE, creating its directory, and record it."
  (let ((coding-system-for-write 'utf-8-unix))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert html)))
  (pretty-view-links-record file html))

;; Messages

(defun pretty-view-links--log (format-string &rest args)
  "Log the message that FORMAT-STRING and ARGS make.
While the minibuffer is active the message only goes to `*Messages*',
so it never covers a prompt."
  (let ((inhibit-message (or inhibit-message
                             (and (active-minibuffer-window) t))))
    (apply #'message format-string args)))

(defun pretty-view-links--report (run)
  "Show RUN's progress, or its summary once nothing of it is pending."
  (let* ((written (pretty-view-links--run-written run))
         (unchanged (pretty-view-links--run-unchanged run))
         (failed (pretty-view-links--run-failed run))
         (done (+ written unchanged failed))
         (pending (pretty-view-links--run-pending run)))
    (if (> pending 0)
        (unless (active-minibuffer-window)
          (let ((message-log-max nil))
            (message "pretty-view: rendering linked documents %d/%d"
                     done (+ done pending))))
      (pretty-view-links--log
       "pretty-view: linked documents — %d written, %d unchanged, %d failed%s"
       written unchanged failed
       (if (pretty-view-links--run-limit-hit run)
           (format "; stopped after %d, see `pretty-view-follow-links-limit'"
                   pretty-view-follow-links-limit)
         "")))))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the Step 2 command. Expected: all `pretty-view-links-test-` tests PASS.

- [ ] **Step 5: Gate and commit**

```bash
make compile-isolated && make checkdoc && make test && make clean
git add pretty-view-links.el tests/pretty-view-links-test.el
git commit -m "feat: render linked documents in a background queue

A timer drains a breadth-first queue for up to 50 ms per tick and
steps aside on pending input.  Every document is rendered again, but
its page is only written when the HTML changed, which is what keeps
repeated runs cheap on /mnt/c."
```

---

### Task 4: Wire links into rendering and commands

**Files:**
- Modify: `pretty-view-org.el` (new defvar after the requires; `pretty-view-org-body`: a `let` binding, a seeded export, its docstring)
- Modify: `pretty-view.el` (requires; replace `pretty-view-render-buffer-to-file`; add `pretty-view--render-html` and `pretty-view--render-linked`; call sites in `pretty-view`, `pretty-view-select-theme`, `pretty-view--live-update`)
- Test: `tests/pretty-view-org-test.el`, `tests/pretty-view-test.el`

**Interfaces:**
- Consumes: everything Task 2 and Task 3 produce, and `pretty-view-browser-file-url` (Task 1).
- Produces:
  - `pretty-view-org-keep-org-links`: dynamic variable. Non-nil keeps `.org` in exported links.
  - `(pretty-view--render-html &optional LINKS)` → HTML string for the current buffer.
  - `(pretty-view--render-linked SOURCE)` → HTML string for the file SOURCE.
  - `(pretty-view-render-buffer-to-file FILE &optional LIVE LINKS)` → FILE (signature extended).

- [ ] **Step 1: Write the failing tests**

Append to `tests/pretty-view-org-test.el`, before its `(provide ...)`:

```elisp
(ert-deftest pretty-view-org-test-org-links-keep-their-extension-on-request ()
  (should (string-match-p "href=\"foo.html\"" (pv-org "[[file:foo.org][F]]\n")))
  (let ((pretty-view-org-keep-org-links t))
    (should (string-match-p "href=\"foo.org\""
                            (pv-org "[[file:foo.org][F]]\n")))))

(ert-deftest pretty-view-org-test-export-is-deterministic ()
  "Unchanged text must export to identical HTML, headline ids included."
  (should (equal (pv-org "* A\n** B\n") (pv-org "* A\n** B\n"))))

(ert-deftest pretty-view-org-test-export-reseeds-random ()
  "The fixed seed must not leak: `random' is unpredictable afterwards."
  (pv-org "* A\n")
  (let ((first (random most-positive-fixnum)))
    (pv-org "* A\n")
    (should-not (equal first (random most-positive-fixnum)))))
```

Append to `tests/pretty-view-test.el`, before `(provide 'pretty-view-test)`:

```elisp
;;; Linked documents

(defmacro pv-with-org-tree (dir files &rest body)
  "Bind DIR to a fresh directory holding FILES, run BODY, delete it.
FILES is an alist (NAME . CONTENTS) with names relative to DIR.  Output
goes to a fresh directory, the link queue and page table start empty,
file URLs are stubbed to \"URL:\" plus the file name, and no browser
opens."
  (declare (indent 2))
  `(let* ((,dir (file-name-as-directory (make-temp-file "pv-tree" t)))
          (pretty-view-output-directory (make-temp-file "pv-out" t))
          (pretty-view-links--queue nil)
          (pretty-view-links--queued (make-hash-table :test #'equal))
          (pretty-view-links--timer nil)
          (pretty-view-links--written (make-hash-table :test #'equal)))
     (unwind-protect
         (cl-letf (((symbol-function 'pretty-view-browser-open) #'ignore)
                   ((symbol-function 'pretty-view-browser-file-url)
                    (lambda (f) (concat "URL:" f))))
           (dolist (f ,files)
             (let ((path (expand-file-name (car f) ,dir)))
               (make-directory (file-name-directory path) t)
               (with-temp-file path (insert (cdr f)))))
           ,@body)
       (pretty-view-links-reset)
       (delete-directory ,dir t)
       (delete-directory pretty-view-output-directory t))))

(defun pv-tree-page (file)
  "Return the rendered page of FILE, or nil when it was not written."
  (let ((out (pretty-view-browser-output-file file)))
    (and (file-exists-p out) (pv-test-read out))))

(defun pv-tree-href (file)
  "Return the href attribute that links to FILE's page."
  (format "href=\"%s\""
          (url-hexify-string
           (file-name-nondirectory (pretty-view-browser-output-file file)))))

(ert-deftest pretty-view-test-linked-render-matches-a-direct-render ()
  (pv-with-org-tree dir '(("a.org" . "#+TITLE: Alpha\n* A\n"))
    (let* ((src (expand-file-name "a.org" dir))
           (html (pretty-view--render-linked src))
           (opened nil))
      (should (string-match-p "<title>Alpha</title>" html))
      (cl-letf (((symbol-function 'pretty-view-browser-open)
                 (lambda (f) (setq opened f))))
        (pretty-view-file src))
      (should (equal opened (pretty-view-browser-output-file src)))
      (should (equal (pv-test-read opened) html)))))

(ert-deftest pretty-view-test-linked-render-skips-mode-hooks ()
  (pv-with-org-tree dir '(("a.org" . "* A\n"))
    (let* ((ran nil)
           (org-mode-hook (list (lambda () (setq ran t)))))
      (pretty-view--render-linked (expand-file-name "a.org" dir))
      (should-not ran))))

(ert-deftest pretty-view-test-linked-render-resolves-links-from-its-directory ()
  (pv-with-org-tree dir '(("sub/a.org" . "[[file:c.json][C]]\n")
                          ("sub/c.json" . "{}"))
    (should (string-match-p
             (regexp-quote (concat "href=\"URL:" dir "sub/c.json\""))
             (pretty-view--render-linked (expand-file-name "sub/a.org" dir))))))

(ert-deftest pretty-view-test-linked-render-leaves-nothing-behind ()
  (pv-with-org-tree dir '(("a.org" . "* A\n"))
    (let ((src (expand-file-name "a.org" dir)))
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (&rest _) (error "Prompted")))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (error "Prompted"))))
        (pretty-view--render-linked src))
      (should (null (get-file-buffer src)))
      (should (null (directory-files dir nil "\\`\\.#"))))))

(ert-deftest pretty-view-test-linked-documents-render-in-the-background ()
  (pv-with-org-tree dir
      '(("root.org" . "* Root\n[[file:menus/a.org][A]] [[file:data.json][D]]\n")
        ("menus/a.org" . "* A\n[[file:../root.org][Back]] [[file:b.org][B]]\n")
        ("menus/b.org" . "* B\n")
        ("data.json" . "{}"))
    (let* ((root (expand-file-name "root.org" dir))
           (a (expand-file-name "menus/a.org" dir))
           (b (expand-file-name "menus/b.org" dir))
           (buf (find-file-noselect root)))
      (unwind-protect
          (progn
            (with-current-buffer buf (pretty-view))
            ;; The root is written at once; its links point at pages
            ;; that the queue writes later.
            (let ((page (pv-tree-page root)))
              (should (string-match-p (regexp-quote (pv-tree-href a)) page))
              (should (string-match-p
                       (regexp-quote
                        (format "href=\"URL:%sdata.json\" target=\"_blank\""
                                dir))
                       page)))
            (should-not (pv-tree-page a))
            (while pretty-view-links--queue (pretty-view-links--tick))
            (let ((page (pv-tree-page a)))
              (should (string-match-p (regexp-quote (pv-tree-href root)) page))
              (should (string-match-p (regexp-quote (pv-tree-href b)) page)))
            (should (pv-tree-page b)))
        (kill-buffer buf)))))

(ert-deftest pretty-view-test-export-leaves-links-alone ()
  (pv-with-org-tree dir '(("a.org" . "[[file:b.org][B]] [[file:c.json][C]]\n")
                          ("b.org" . "* B\n")
                          ("c.json" . "{}"))
    (let ((out (expand-file-name "a.html" dir))
          (buf (find-file-noselect (expand-file-name "a.org" dir))))
      (unwind-protect
          (progn
            (with-current-buffer buf (pretty-view-export out))
            (let ((html (pv-test-read out)))
              (should (string-match-p "href=\"b.html\"" html))
              (should (string-match-p "href=\"c.json\"" html))
              (should-not (string-match-p "target=" html)))
            (should (null pretty-view-links--queue)))
        (kill-buffer buf)))))

(ert-deftest pretty-view-test-follow-links-off-opens-documents-as-files ()
  (pv-with-org-tree dir '(("a.org" . "[[file:b.org][B]]\n")
                          ("b.org" . "* B\n"))
    (let ((pretty-view-follow-links nil)
          (buf (find-file-noselect (expand-file-name "a.org" dir))))
      (unwind-protect
          (progn
            (with-current-buffer buf (pretty-view))
            (should (string-match-p
                     (regexp-quote
                      (format "href=\"URL:%sb.org\" target=\"_blank\"" dir))
                     (pv-tree-page (expand-file-name "a.org" dir))))
            (should (null pretty-view-links--queue)))
        (kill-buffer buf)))))

(ert-deftest pretty-view-test-live-update-rewrites-links ()
  (pv-with-org-tree dir '(("a.org" . "[[file:b.org][B]]\n")
                          ("b.org" . "* B\n"))
    (let* ((a (expand-file-name "a.org" dir))
           (buf (find-file-noselect a)))
      (unwind-protect
          (with-current-buffer buf
            (pretty-view-live-mode 1)
            (pretty-view--live-update)
            (should (string-match-p
                     (regexp-quote (pv-tree-href (expand-file-name "b.org" dir)))
                     (pv-tree-page a)))
            (pretty-view-live-mode -1))
        (kill-buffer buf)))))

(ert-deftest pretty-view-test-select-theme-rewrites-links ()
  (pv-with-org-tree dir '(("a.org" . "[[file:b.org][B]]\n")
                          ("b.org" . "* B\n"))
    (let* ((a (expand-file-name "a.org" dir))
           (buf (find-file-noselect a))
           (pretty-view-theme 'github-light))
      (unwind-protect
          (with-current-buffer buf
            (pretty-view)
            (pretty-view-select-theme 'nord)
            (should (string-match-p
                     (regexp-quote (pv-tree-href (expand-file-name "b.org" dir)))
                     (pv-tree-page a))))
        (kill-buffer buf)))))

(ert-deftest pretty-view-test-unsaved-buffer-page-is-not-recorded ()
  "Review focus: an unsaved root still gets working links, but its page
must not pass for its file's page when the file is later reached."
  (pv-with-org-tree dir '(("a.org" . "[[file:b.org][B]]\n")
                          ("b.org" . "* B\n"))
    (let* ((a (expand-file-name "a.org" dir))
           (out (pretty-view-browser-output-file a))
           (buf (find-file-noselect a)))
      (unwind-protect
          (with-current-buffer buf
            (pretty-view)
            (should (gethash out pretty-view-links--written))
            (clrhash pretty-view-links--written)
            (goto-char (point-max))
            (insert "Unsaved.\n")
            (pretty-view)
            (should (string-match-p
                     (regexp-quote (pv-tree-href (expand-file-name "b.org" dir)))
                     (pv-tree-page a)))
            (should-not (gethash out pretty-view-links--written))
            (set-buffer-modified-p nil))
        (kill-buffer buf)))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
emacs -Q --batch -L . -L tests --eval '(setq load-prefer-newer t)' -l ert \
  -l tests/pretty-view-org-test.el -l tests/pretty-view-test.el \
  --eval '(ert-run-tests-batch-and-exit "\\(keep-their-extension\\|deterministic\\|reseeds\\|linked\\|export-leaves\\|follow-links-off\\|rewrites-links\\|unsaved-buffer\\)")'
```

`pretty-view-org-test-export-is-deterministic` also fails (the headline ids differ). `pretty-view-org-test-export-reseeds-random` may already pass; it guards Step 3.
Expected: FAIL. The keep-extension Org test fails with `href="foo.html"` under the binding (the variable is ignored). The others fail with `void-variable pretty-view-links--queue` or `void-function pretty-view--render-linked`, because `pretty-view.el` does not require the new module yet.

- [ ] **Step 3: Keep `.org` links on request in `pretty-view-org.el`**

After `(require 'pretty-view-render)`, add:

```elisp
(defvar pretty-view-org-keep-org-links nil
  "Non-nil makes links to Org files keep their `.org' extension.
`ox-html' otherwise changes them to `.html', naming a file that does
not exist.  `pretty-view-render-buffer-to-file' binds this while it
rewrites links, so each link still names the source to render.")
```

In `pretty-view-org-body`, add a binding to the existing `let`, after `(org-export-with-smart-quotes t)`:

```elisp
            (org-html-link-org-files-as-html
             (and (not pretty-view-org-keep-org-links)
                  org-html-link-org-files-as-html))
```

In the same function, replace the export call `(org-export-as (pretty-view-org--backend) nil nil t nil)` with:

```elisp
        ;; `ox' draws headline ids from `random' (see
        ;; `org-export-new-reference'); a fixed seed makes unchanged text
        ;; export to identical HTML, so an unchanged page is not
        ;; rewritten.  Reseeding afterwards keeps `random' unpredictable.
        (unwind-protect
            (progn
              (random "pretty-view")
              (org-export-as (pretty-view-org--backend) nil nil t nil))
          (random t))
```

and change its docstring to:

```elisp
  "Return the current Org buffer exported to an HTML body.
The same text always exports to the same HTML, headline ids included."
```

- [ ] **Step 4: Wire links into `pretty-view.el`**

After `(require 'pretty-view-browser)`, add `(require 'pretty-view-links)`.

Replace the whole `pretty-view-render-buffer-to-file` defun with these three functions:

```elisp
(defun pretty-view--render-html (&optional links)
  "Return the current buffer rendered as a complete HTML document.
LINKS non-nil means the page is for the output directory, so its local
links are rewritten to work from there; see
`pretty-view-links-rewrite'."
  (let* ((base default-directory)
         (title (pretty-view--title))
         (body (let ((pretty-view-org-keep-org-links links))
                 (pretty-view-body)))
         (suppress-toc (seq-some (lambda (mode) (derived-mode-p mode))
                                 pretty-view-own-toc-modes))
         (html (pretty-view-html-document body
                                          :title title
                                          :base-directory base
                                          :toc (if suppress-toc 'none pretty-view-toc))))
    (if links
        (pretty-view-links-rewrite html base #'pretty-view-links-accept)
      html)))

(defun pretty-view--render-linked (source)
  "Return SOURCE, a linked document's file name, rendered as HTML.
SOURCE is read into a temporary buffer that behaves as if it visited
the file, so its title, base directory, and output file match a
`pretty-view-file' render.  The major mode comes from the file name,
but mode hooks do not run.  Links are rewritten as for any page in the
output directory."
  (with-temp-buffer
    (insert-file-contents source)
    (let ((create-lockfiles nil))
      (setq buffer-file-name source
            default-directory (file-name-directory source))
      (unwind-protect
          (progn
            (delay-mode-hooks (set-auto-mode))
            (pretty-view--render-html t))
        ;; Unmodified and nameless, the buffer is killed without a prompt.
        (set-buffer-modified-p nil)
        (setq buffer-file-name nil)))))

(defun pretty-view-render-buffer-to-file (file &optional live links)
  "Render the current buffer into FILE.
LIVE non-nil embeds a watcher that reloads the page when a later
render changes it, and writes the version script it polls; see
`pretty-view-live-interval'.  LINKS non-nil means FILE is in the output
directory: local links are rewritten to work from there and, when
`pretty-view-follow-links' is non-nil, the documents they name are
rendered next to FILE in the background.  Creates FILE's directory
when it does not exist.  Does not open a browser."
  (let* ((pretty-view-links-current-run
          (and links pretty-view-follow-links
               (pretty-view-links-start-run buffer-file-name
                                            #'pretty-view--render-linked)))
         (html (pretty-view--render-html links))
         (live-file (and live pretty-view-live-interval
                         (pretty-view--live-file file)))
         (version (and live-file
                       (secure-hash 'sha1 (encode-coding-string html 'utf-8))))
         (page (if live-file
                   (pretty-view-html-add-live-script
                    html version (file-name-nondirectory live-file))
                 html))
         (coding-system-for-write 'utf-8-unix))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert page))
    ;; Written after the page, so a reload always finds the new page.
    (when live-file
      (with-temp-file live-file
        (insert (pretty-view-html-live-version-script version))))
    ;; An unsaved buffer's page does not show its file, so it must not
    ;; count as that file's page when the file is reached by a link.
    (when (and links (not (buffer-modified-p)))
      (pretty-view-links-record file page))
    file))
```

Pass LINKS at the three call sites:

- In `pretty-view`: `(pretty-view-render-buffer-to-file file pretty-view-live-mode t)`
- In `pretty-view-select-theme`: `(pretty-view-render-buffer-to-file file pretty-view-live-mode t)`
- In `pretty-view--live-update`, replace the render call with:

```elisp
        (pretty-view-render-buffer-to-file
         (pretty-view-browser-output-file (pretty-view--source-name)) t t)
```

`pretty-view-export` keeps calling `(pretty-view-render-buffer-to-file file)`.

- [ ] **Step 5: Run the tests to verify they pass**

Run the Step 2 command. Expected: all selected tests PASS. Then `make test`. Expected: the whole suite passes, including the existing live-mode, export, and `pretty-view-file` tests.

- [ ] **Step 6: Gate and commit**

```bash
make compile-isolated && make checkdoc && make test && make clean
git add pretty-view.el pretty-view-org.el tests/pretty-view-test.el tests/pretty-view-org-test.el
git commit -m "feat: follow links from pretty-view, live mode, and theme changes

Pages written to the output directory get working local links, and
the documents they link to are rendered in the background in
hook-free temporary buffers.  Org keeps .org in links while
rendering, so they name a source to render, and exports with a fixed
random seed, so unchanged Org text gives identical HTML and its page
is not rewritten.  pretty-view-export is unchanged."
```

---

### Task 5: Documentation and final gate

**Files:**
- Modify: `README.md` (new section after "## Live Mode"; new table under "## Customization Variables"; the images table row; "## What This Package Does Not Do")

**Interfaces:**
- Consumes: option names and behaviour from Tasks 1–4.
- Produces: user documentation only.

- [ ] **Step 1: Add the "Linked Documents" section**

Insert before `## Threat Model` (that is, right after the Live Mode section):

```markdown
## Linked Documents

Rendered pages live in the output directory, not next to their sources, so a relative link such as `[Setup](docs/setup.md)` would otherwise break. `pretty-view` rewrites every local link in the page it writes:

- **A link to another document** (`.md`, `.markdown`, `.org`, `.txt`) points at that document's rendered page, which opens in the same tab with the same theme. Fragments such as `#installation` are kept.
- **A link to any other local file** (JSON, PDF, images, …) opens the file itself in a new tab. Under WSL the link is a `file://wsl.localhost/<distro>/…` URL, or a `file:///C:/…` URL for a file on a Windows drive.
- Remote URLs, `mailto:` links, and same-page `#` links are left alone.

Linked documents are rendered in the background, breadth-first, and the documents they link to are followed in turn, up to `pretty-view-follow-links-limit` documents. The page you asked for opens immediately. The echo area shows `pretty-view: rendering linked documents 12/55` and then a one-line summary. Emacs stays responsive throughout: each timer tick does at most about 50 ms of work and steps aside whenever you type.

Every linked document is rendered again on every run, which is cheap, but its page is only rewritten when the HTML changed. This matters under WSL, where each write to the Windows drive takes around 90 ms. The first render in an Emacs session writes every linked page; later renders and live-mode saves write only what changed.

On the very first render of a set of documents, a link clicked before the background reaches it shows the browser's "file not found" page; reload it a moment later. Links are processed in document order, so the first ones are ready first.

`pretty-view-export` rewrites nothing: it writes a single file where you choose, typically next to the sources, where relative links already work.
```

- [ ] **Step 2: Add the options table and fix the image row**

Under `## Customization Variables`, after the `### Images and Media` table, add:

```markdown
### Linked Documents

| Variable | Default | Description |
|----------|---------|-------------|
| `pretty-view-follow-links` | `t` | When non-nil, render linked local documents in the background and link to their pages; when nil, document links open the source file in a new tab |
| `pretty-view-follow-links-limit` | 200 | Most linked documents one render follows |
| `pretty-view-follow-links-extensions` | `("md" "markdown" "org" "txt")` | Extensions (lower case, matched case-insensitively) of the linked files that are rendered |
```

In the `### Images and Media` table, change the `pretty-view-inline-image-max-bytes` description to:

```markdown
Maximum image size (in bytes) to embed; larger files are linked with a `file://` URL the browser can open (a `wsl.localhost` URL under WSL)
```

In `## What This Package Does Not Do`, replace `- Generate multi-file sites` with:

```markdown
- Generate multi-file sites (linked local documents are rendered alongside the page, nothing more)
```

- [ ] **Step 3: Run the full gate**

Run: `make all && make checkdoc && make clean`
Expected: every file compiles with no warnings, all tests pass, and checkdoc exits 0.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document linked documents and their options"
```
