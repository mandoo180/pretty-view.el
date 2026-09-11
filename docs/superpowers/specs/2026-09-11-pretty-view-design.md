# pretty-view.el — Design

Date: 2026-09-11
Status: Approved for implementation planning

## 1. Purpose

An Emacs package that renders the current Org, Markdown, or plain-text
buffer to a styled, self-contained HTML file and opens it in the
operating system's browser.

Four requirements shape the design:

1. GitHub Flavored Markdown is the Markdown dialect.
2. Users pick from bundled themes and can define their own.
3. Users pick the browser; a working default is detected per platform.
4. Users can replace how any individual component renders or behaves.

It runs on Linux, macOS, Windows, and WSL with no external programs and
no network access.

## 2. Scope

### In scope

- Org, Markdown, and plain-text sources
- A GFM parser written in Emacs Lisp
- An Org exporter derived from `ox-html`
- Five bundled themes plus a theme-definition macro
- Per-node renderer overrides for both Markdown and Org
- Document-level hooks for `<head>` content and body filtering
- Single-file HTML output with images inlined as data URIs
- A live mode that regenerates on save and reloads the browser tab
- Platform-aware output location and browser launch, including WSL

### Out of scope

- An HTTP server
- Cursor-to-scroll synchronization between Emacs and the browser
- PDF export
- Multi-file site generation
- Bundled Mermaid, KaTeX, or MathJax — hook points only

## 3. Architecture

```
buffer/file ──dispatch on major-mode──┬─ org  → derived ox-html backend ─┐
                                      ├─ md   → GFM parser → AST ───────┼→ HTML body
                                      └─ text → minimal converter ──────┘      │
                                                                               ↓
       theme plist → CSS custom properties ────→ document shell                │
                                                 (head, TOC, live JS, assets) ←┘
                                                                               ↓
                                                        output file ─→ browser launcher
```

Three source formats converge on a common HTML body. The shell, the
theme, and the launcher never learn which format produced the body.
Adding a format is one entry in `pretty-view-source-functions`.

### 3.1 Module boundaries

| File | Responsibility | Depends on |
|------|----------------|------------|
| `pretty-view.el` | Commands, customization group, `pretty-view-live-mode`, dispatch | all others |
| `pretty-view-gfm.el` | Markdown text → AST | none |
| `pretty-view-render.el` | AST → HTML, renderer table, escaping, font-lock code walker | none |
| `pretty-view-org.el` | Org buffer → HTML body via derived backend | `pretty-view-render` (code walker) |
| `pretty-view-text.el` | Plain text → HTML body | `pretty-view-render` (escaping) |
| `pretty-view-theme.el` | Theme registry, palette → CSS | none |
| `pretty-view-themes.el` | The five bundled theme definitions | `pretty-view-theme` |
| `pretty-view-html.el` | Document shell: head, TOC, live-reload JS, asset inlining | `pretty-view-theme` |
| `pretty-view-browser.el` | Platform detection, path translation, launch | none |

`pretty-view-gfm.el`, `pretty-view-theme.el`, and
`pretty-view-browser.el` have no intra-package dependencies and are
testable in isolation. Nothing but `pretty-view.el` knows the whole
pipeline.

Public prefix is `pretty-view-`; internals use `pretty-view--`.

## 4. GFM parser (`pretty-view-gfm.el`)

Two phases, in the CommonMark manner.

### 4.1 Block phase

A line-oriented scanner produces the block tree. Constructs handled:

- ATX headings (`#`..`######`) and setext headings
- Fenced code blocks (``` and `~~~`) with an info string; indented code blocks
- Block quotes, recursively
- Lists: bullet and ordered, nested by indentation, loose and tight
- GFM task list items (`- [ ]`, `- [x]`)
- GFM pipe tables with alignment row
- Thematic breaks
- HTML blocks
- Link reference definitions
- GFM footnote definitions
- Paragraphs

### 4.2 Inline phase

Applied to each text run, in this order:

1. Code spans (backtick runs, matched by length)
2. Autolinks: `<https://...>` and bare GFM URLs
3. Raw inline HTML
4. Links and images, including reference resolution
5. Emphasis and strong emphasis (delimiter-run algorithm)
6. Strikethrough (`~~`)
7. Footnote references (`[^label]`)
8. Hard line breaks (two trailing spaces, or a trailing backslash)
9. Backslash escapes and character entities

### 4.3 AST

Nodes are plists. Every node has `:type`; container nodes have
`:children`.

```elisp
(:type heading :level 2 :id "installation" :children (...))
(:type code-block :lang "elisp" :code "...")
(:type list :ordered t :start 1 :tight t :children (...))
(:type table :align (left center right) :children (...))
(:type link :href "..." :title "..." :children (...))
(:type text :value "...")
```

Node types: `document`, `heading`, `paragraph`, `code-block`,
`blockquote`, `list`, `list-item`, `task-item`, `table`, `table-row`,
`table-cell`, `thematic-break`, `html-block`, `footnote-definition`,
`text`, `emphasis`, `strong`, `strikethrough`, `code-span`, `link`,
`image`, `autolink`, `footnote-reference`, `line-break`, `soft-break`,
`html-inline`.

### 4.4 Stated limits

Full CommonMark conformance is not a goal. The emphasis
delimiter-run algorithm implements left/right flanking but not the
complete "rule of 3" multiple-of-three exceptions. Behaviour is pinned
by a golden-file corpus covering realistic documents rather than by the
CommonMark spec suite. A construct the parser does not recognize
degrades to paragraph text, which is Markdown's own fallback.

The parser never signals. It has no dependency on `markdown-mode`.

## 5. Rendering (`pretty-view-render.el`)

### 5.1 Renderer table

```elisp
(defvar pretty-view-renderers
  '((heading    . pretty-view-render-heading)
    (code-block . pretty-view-render-code-block)
    ...))
```

Each renderer is called as `(FN NODE RENDER)` where `RENDER` is a
function taking a node list and returning the concatenated HTML of its
children. Renderers return a string.

```elisp
(setf (alist-get 'code-block pretty-view-renderers)
      (lambda (node render)
        (format "<figure class=\"code\">%s</figure>"
                (pretty-view-render-code-block node render))))
```

If a user renderer signals, the node falls back to the built-in
renderer and a warning is logged through `display-warning`. One broken
override must not lose the document.

### 5.2 Code highlighting

`pretty-view-render-fontified-code` renders code through Emacs itself:
insert the code into a temporary buffer, activate the major mode
resolved from the info string, run `font-lock-ensure`, then walk the
`face` and `font-lock-face` text properties and emit
`<span class="pv-keyword">`-style markup. Face names map to class names
through `pretty-view-face-class-alist`; unmapped faces emit no span.

Consequences: language support equals the set of major modes the user
has, tree-sitter modes included; colours come from the document theme
rather than the user's Emacs theme; there is no external dependency and
no `htmlize` requirement. Both the Org and Markdown paths call this one
function, so code blocks look identical across formats.

Mode resolution goes through `pretty-view-code-mode-alist` (info string
→ major mode), falling back to `<lang>-ts-mode`, then `<lang>-mode`,
then no highlighting. Modes are activated with hooks suppressed and a
`with-timeout` guard; failure yields plain escaped code.

### 5.3 Escaping

`pretty-view-escape-html` is the single escaping entry point, used by
every module. Raw HTML passes through only where the parser produced an
`html-block` or `html-inline` node, and only when
`pretty-view-allow-raw-html` is non-nil (default `t`).

## 6. Org path (`pretty-view-org.el`)

`org-export-define-derived-backend` creates `pretty-view-org` from
`html`. The translate alist is assembled at export time from
`pretty-view-org-transcoders`, so user overrides take effect without
redefining the backend.

Defaults applied for the export:

- `org-html-head-include-default-style` → nil; the theme supplies all CSS
- `org-html-head-include-scripts` → nil
- A `src-block` transcoder calling `pretty-view-render-fontified-code`,
  replacing `ox-html`'s htmlize path
- Export is body-only; the shell in `pretty-view-html.el` wraps it

Org's own `#+OPTIONS:` are honoured, including `toc:`. Export runs
inside `condition-case`; a failure renders the error into the document
body rather than producing an empty page.

## 7. Plain text (`pretty-view-text.el`)

Default behaviour (`pretty-view-text-as-markdown` nil): escape the
text, split on blank lines into paragraphs, preserve intra-paragraph
newlines via `white-space: pre-wrap` on the container, and autolink bare
URLs. Setting `pretty-view-text-as-markdown` to `t` routes `.txt`
through the GFM parser instead.

## 8. Themes (`pretty-view-theme.el`, `pretty-view-themes.el`)

### 8.1 Definition

```elisp
(pretty-view-define-theme 'github-light
  :bg "#ffffff" :fg "#1f2328" :muted "#59636e"
  :accent "#0969da" :border "#d1d9e0"
  :code-bg "#f6f8fa" :code-fg "#1f2328"
  :keyword "#cf222e" :string "#0a3069" :comment "#59636e"
  :function "#8250df" :constant "#0550ae" :type "#953800"
  :variable "#1f2328" :builtin "#0550ae"
  :body-font "..." :mono-font "..." :measure "46rem"
  :dark-variant 'github-dark
  :extra-css "...")
```

Every theme fills the same slots, so coverage is uniform. Slots resolve
against `pretty-view-theme-default-palette` in `pretty-view-theme.el`,
and a theme missing a slot inherits that default rather than producing
broken CSS. An unknown slot is an error at definition time, which keeps
typos from silently doing nothing.

`pretty-view-theme-css` turns a palette into a `:root` block of CSS
custom properties, followed by the static stylesheet, followed by
`:extra-css`. The static stylesheet is written once against the custom
properties; themes never restate layout.

### 8.2 Bundled themes

`github-light` (default), `github-dark`, `sepia`, `nord`, `cyberpunk`.

### 8.3 Automatic dark mode

`pretty-view-theme` accepts a theme symbol or `'auto`. Under `'auto`
the theme named by `pretty-view-default-light-theme` and its
`:dark-variant` are both emitted, the dark one inside
`@media (prefers-color-scheme: dark)`, so the page follows the OS.

## 9. Document shell (`pretty-view-html.el`)

Assembles the final document:

- `<head>`: charset, viewport, `<title>` from the document title or file
  name, the theme stylesheet, then each string returned by
  `pretty-view-head-functions`
- Optional table of contents, controlled by `pretty-view-toc`
  (nil, `t`, or a maximum depth integer; Org defers to its own
  `#+OPTIONS: toc:`)
- The body, after passing through `pretty-view-body-filter-functions`
- The live-reload script when live mode generated the file

### 9.1 Asset inlining

With `pretty-view-inline-images` non-nil (default), local image
references are read and embedded as `data:` URIs, subject to
`pretty-view-inline-image-max-bytes` (default 2 MB). Larger or
unreadable files fall back to a `file://` URL. Remote URLs are left
untouched — the package never fetches over the network.

The result is a single self-contained file, which is what removes
path-translation problems on WSL.

## 10. Browser and platform (`pretty-view-browser.el`)

### 10.1 Output location

`pretty-view-output-directory` defaults to a value computed at load
time:

| Platform | Default output directory |
|----------|--------------------------|
| Linux, macOS, Windows | `temporary-file-directory` |
| WSL | Windows `TEMP` under `/mnt/<drive>/`, else `temporary-file-directory` |

Writing to Windows `TEMP` under WSL avoids `\\wsl.localhost\` UNC paths
entirely.

Output file names are `<sanitized base name>-<hash>.html`, where the
hash is the first ten characters of `(secure-hash 'sha1 <full path>)`.
Two files with the same base name therefore do not collide, and
repeated renders of one file reuse one path — which is what lets the
browser tab reload in place.

### 10.2 Launching

`pretty-view-browser` accepts:

- `'default` — `browse-url`, after WSL adjustment
- a string — a program name or path, invoked with the file URL
- a function — called with the output file path

WSL resolution order: `wslview` if installed, else `explorer.exe` with
the path converted by `wslpath -w`, else `browse-url`.

`pretty-view-browser--command` is a pure function returning the argument
list; it is unit-tested without executing anything. Launch failure
reports the output path through `message` so the file can be opened by
hand.

### 10.3 Platform detection

WSL is detected from the kernel release string plus `WSL_DISTRO_NAME`.
Detection lives only in `pretty-view-browser.el`.

## 11. Live mode

`pretty-view-live-mode` is a buffer-local minor mode. It adds a
regeneration function to `after-save-hook`, writing to the same output
path each time.

The generated page carries a script that calls `location.reload()` every
`pretty-view-live-interval` seconds (default 1.5), saves and restores
`window.scrollY` through `sessionStorage` keyed by the document path,
and skips reloading while `document.visibilityState` is `"hidden"`.

Stated trade-off: on `file://`, CORS prevents the page from checking
whether the source changed, so the reload is unconditional. The page
therefore refreshes on a timer even when idle. For a local file this
costs roughly 50 ms and the scroll position survives. Setting
`pretty-view-live-interval` to nil disables the script.

Disabling the mode removes the hook; it does not delete the output file.

## 12. Commands

| Command | Behaviour |
|---------|-----------|
| `pretty-view` | Render the current buffer and open it in the browser |
| `pretty-view-file` | Prompt for a file, render, open |
| `pretty-view-export` | Render to a chosen path without opening a browser |
| `pretty-view-live-mode` | Regenerate on every save |
| `pretty-view-select-theme` | Completing-read over registered themes; sets `pretty-view-theme` and re-renders the current buffer if it has already been rendered |

`pretty-view` on an unsaved buffer renders the buffer text and names the
output after the buffer.

## 13. Customization summary

| Variable | Default | Meaning |
|----------|---------|---------|
| `pretty-view-theme` | `'github-light` | Theme symbol or `'auto` |
| `pretty-view-default-light-theme` | `'github-light` | Light half of `'auto` |
| `pretty-view-browser` | `'default` | Symbol, program string, or function |
| `pretty-view-output-directory` | computed | Where HTML is written |
| `pretty-view-toc` | nil | nil, `t`, or a depth integer |
| `pretty-view-inline-images` | `t` | Embed local images as data URIs |
| `pretty-view-inline-image-max-bytes` | 2000000 | Inlining size ceiling |
| `pretty-view-allow-raw-html` | `t` | Pass raw HTML through |
| `pretty-view-text-as-markdown` | nil | Route plain text through the GFM parser |
| `pretty-view-live-interval` | 1.5 | Reload period in seconds, or nil |
| `pretty-view-renderers` | built-ins | Markdown node type → renderer |
| `pretty-view-org-transcoders` | built-ins | Org element type → transcoder |
| `pretty-view-source-functions` | built-ins | Major mode → body converter |
| `pretty-view-head-functions` | nil | Functions returning `<head>` strings |
| `pretty-view-body-filter-functions` | nil | Filters applied to the body string |
| `pretty-view-code-mode-alist` | built-ins | Info string → major mode |
| `pretty-view-face-class-alist` | built-ins | Emacs face → CSS class |

### 13.1 Extension point signatures

| Extension point | Signature |
|-----------------|-----------|
| `pretty-view-renderers` entry | `(NODE RENDER)` → HTML string. `RENDER` takes a list of nodes and returns their concatenated HTML |
| `pretty-view-org-transcoders` entry | The `ox` transcoder signature: `(ELEMENT CONTENTS INFO)` → HTML string |
| `pretty-view-source-functions` entry | `()` called in the source buffer → HTML body string |
| `pretty-view-head-functions` member | `()` → a string for `<head>`, or nil |
| `pretty-view-body-filter-functions` member | `(BODY)` → the replacement body string |
| `pretty-view-browser` as a function | `(FILE)` → ignored; opens `FILE` |

`pretty-view-head-functions` and `pretty-view-body-filter-functions`
run in the source buffer, so they can read buffer-local state.

## 14. Error handling

- The parser never signals; unrecognized syntax becomes paragraph text
- Org export errors are caught and rendered into the document body
- A signalling user renderer falls back to the built-in for that node
  and logs a warning
- Code fontification failure yields plain escaped code
- Browser launch failure reports the output path

## 15. Testing

ERT throughout, under `tests/`.

| Suite | Covers |
|-------|--------|
| `pretty-view-gfm-test.el` | Block and inline parsing, unit tests plus golden files |
| `pretty-view-render-test.el` | Renderer table, overrides, fallback on signal, escaping, code walker |
| `pretty-view-org-test.el` | Body export, transcoder override, error capture |
| `pretty-view-text-test.el` | Paragraph splitting, autolinking, escaping |
| `pretty-view-theme-test.el` | Palette defaults, CSS generation, `'auto` pairing |
| `pretty-view-html-test.el` | Shell assembly, TOC, image inlining and its ceiling |
| `pretty-view-browser-test.el` | Path translation, command construction, output directory |

Golden files live in `tests/corpus/` as `NAME.md` paired with
`NAME.html`. Development follows the test-driven workflow: a failing
test precedes each behaviour.

CI runs on GitHub Actions across Emacs 29.1, 30, and 31: ERT, a
byte-compile that treats warnings as errors, and `checkdoc`.

## 16. Packaging

- Name: `pretty-view`, repository `mandoo180/pretty-view.el`, public
- Emacs requirement: 29.1
- Dependencies: none beyond built-ins (`org`, `cl-lib`, `seq`)
- License: GPL-3.0-or-later
- `README.md` covering installation, the theme gallery, and the
  customization API

## 17. Delivery

1. Build the package with tests passing and a warning-free byte-compile
2. Create the public repository and push `main`
3. Add a `use-package` block with `:vc` to
   `~/Projects/emacs.light.d/init.el`, following the existing `mote.el`
   declaration, and verify the package loads and renders there

Step 3 edits a separate git repository; committing or pushing that
repository is a separate decision and will be raised before it happens.
