# pretty-view.el

Render Org, Markdown, and plain-text buffers to styled HTML in your browser.

## Installation

Use `use-package` with `:vc` to install from GitHub:

```elisp
(use-package pretty-view
  :vc (:url "https://github.com/mandoo180/pretty-view.el" :rev :newest)
  :commands (pretty-view pretty-view-file pretty-view-export
             pretty-view-live-mode pretty-view-select-theme)
  :custom
  (pretty-view-theme 'auto)
  :bind (("C-c C-v" . pretty-view)))
```

**Note on Emacs 29.1:** The `:vc` keyword requires Emacs 30 or newer (or use-package 2.4.5+ from ELPA). On Emacs 29.1, use `M-x package-vc-install` instead:

```
M-x package-vc-install RET
https://github.com/mandoo180/pretty-view.el RET
```

Then use the declaration above, but remove the `:vc` line.

The package requires Emacs 29.1 and has no external dependencies beyond built-in libraries (`org`, `cl-lib`, `seq`).

## Commands

| Command | Action |
|---------|--------|
| `pretty-view` | Render the current buffer and open it in the browser |
| `pretty-view-file` | Prompt for a file, render it, and open it in the browser |
| `pretty-view-export` | Render the current buffer to a file path you specify (no browser) |
| `pretty-view-live-mode` | Regenerate on every save; the browser tab reloads only when the output changed |
| `pretty-view-select-theme` | Choose a theme interactively; updates the display if already rendered |

On an unsaved buffer, `pretty-view` uses the buffer text and names the output after the buffer. On a file, it renders the file content and can regenerate it on subsequent saves via `pretty-view-live-mode`.

## Themes

Five bundled themes are included:

- **`github-light`** — The default. GitHub's light mode with cool grays and high contrast.
- **`github-dark`** — GitHub's dark mode. Pairs with `github-light` under `'auto` mode.
- **`sepia`** — Warm tones on paper-like background, best for long reading sessions.
- **`nord`** — Arctic, north-bluish color palette inspired by the Nord theme.
- **`cyberpunk`** — Neon synthwave aesthetic.

Every bundled theme passes WCAG AA contrast requirements on its own background. Set `pretty-view-theme` to one of these symbols, or set it to `'auto` to follow the operating system's light/dark mode preference.

Each theme is defined with `pretty-view-define-theme` using a palette of color and typography slots. For example:

```elisp
(pretty-view-define-theme 'my-theme
  :bg "#ffffff" :fg "#1f2328" :muted "#59636e"
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
  :body-font "system-ui, -apple-system, sans-serif"
  :mono-font "menlo, monospace"
  :measure "46rem" :radius "6px" :line-height "1.65"
  :dark-variant 'my-theme-dark
  :extra-css nil)
```

All 34 palette slots are listed above. Slots not specified inherit from the default palette. An unknown slot signals an error at definition time, preventing silent typos.

Under `'auto`, both a light and dark theme are emitted. The dark one is wrapped in `@media (prefers-color-scheme: dark)`, so the page follows the OS preference without user intervention.

## Customization API

### Renderers: `pretty-view-renderers`

**Signature:** `(NODE RENDER) → HTML string`

Override how any Markdown AST node type is rendered to HTML.

```elisp
(setf (alist-get 'strong pretty-view-renderers)
      (lambda (node render)
        (format "<mark>%s</mark>"
                (funcall render (plist-get node :children)))))
```

Each entry is a function taking a node (a plist with `:type`, `:children`, and node-specific slots) and a `RENDER` function that takes a list of nodes and returns their concatenated HTML. If a renderer signals, the built-in renderer is used as a fallback and a warning is logged.

### Org Transcoders: `pretty-view-org-transcoders`

**Signature:** `(ELEMENT CONTENTS INFO) → HTML string`

Override how any Org element type is transcoded to HTML, using the `ox` interface.

```elisp
(setf (alist-get 'src-block pretty-view-org-transcoders)
      (lambda (element contents info)
        (let ((lang (org-element-property :language element))
              (code (org-element-property :value element)))
          (format "<pre><code class=\"language-%s\">%s</code></pre>"
                  lang code))))
```

Org's own `#+OPTIONS:` directives are respected, including `toc:` to emit your own table of contents.

### Source Functions: `pretty-view-source-functions`

**Signature:** `() → HTML body string`

Register how to convert new major modes to HTML. The function is called in the source buffer and returns the HTML body.

```elisp
(add-to-list 'pretty-view-source-functions
             '(my-markup-mode . my-markup-to-html))

(defun my-markup-to-html ()
  "Convert the current buffer's markup to HTML."
  ;; Parse buffer and return HTML string
  )
```

### Head Functions: `pretty-view-head-functions`

**Signature:** `() → string or nil`

Contribute additional markup to the document `<head>`. Each function is called with no arguments in the source buffer and returns a string to append to `<head>`, or nil to contribute nothing. This is where to add script tags for KaTeX, Mermaid, syntax highlighting, or other libraries.

```elisp
(defun my-setup-katex ()
  "Add KaTeX stylesheet and script to the document head."
  (concat
   "<link rel=\"stylesheet\" "
         "href=\"https://cdn.jsdelivr.net/npm/katex@latest/dist/katex.min.css\">\n"
   "<script defer src=\"https://cdn.jsdelivr.net/npm/katex@latest/dist/katex.min.js\"></script>\n"
   "<script defer src=\"https://cdn.jsdelivr.net/npm/katex@latest/dist/contrib/auto-render.min.js\" "
           "onload=\"renderMathInElement(document.body)\"></script>"))

(add-to-list 'pretty-view-head-functions 'my-setup-katex)
```

### Body Filters: `pretty-view-body-filter-functions`

**Signature:** `(BODY) → replacement body string`

Process the rendered body after all other rendering is complete. Each function is called with the body string in the source buffer and returns the replacement. Return nil to leave the body unchanged. Filters run in order, chaining their results.

```elisp
(defun my-wrap-code-blocks (body)
  "Wrap code blocks in <figure> elements."
  (replace-regexp-in-string
   "<pre><code class=\"language-\\([^\"]*\\)\">"
   "<figure><figcaption>\\1</figcaption><pre><code class=\"language-\\1\">"
   (replace-regexp-in-string "</code></pre>" "</code></pre></figure>" body)))

(add-to-list 'pretty-view-body-filter-functions 'my-wrap-code-blocks)
```

## Recipes

### Adding KaTeX via `pretty-view-head-functions`

To render LaTeX math in your documents, add KaTeX to the head:

```elisp
(defun pretty-view-recipe-katex ()
  "Add KaTeX support to pretty-view."
  (concat
   "<link rel=\"stylesheet\" "
         "href=\"https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css\">\n"
   "<script defer src=\"https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js\"></script>\n"
   "<script defer src=\"https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/contrib/auto-render.min.js\" "
           "onload=\"renderMathInElement(document.body, "
           "{delimiters: [{left: '$$', right: '$$', display: true}, "
           "{left: '$', right: '$', display: false}]})\"></script>\n"))

(add-to-list 'pretty-view-head-functions 'pretty-view-recipe-katex)
```

When called, this function returns:

```html
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css">
<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js"></script>
<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/contrib/auto-render.min.js" onload="renderMathInElement(document.body, {delimiters: [{left: '$$', right: '$$', display: true}, {left: '$', right: '$', display: false}]})"></script>
```

Save this to your `init.el`, then render any document containing `$...$` or `$$...$$` delimiters and the math will be typeset.

### Wrapping code blocks in `<figure>` via `pretty-view-renderers`

To add a caption showing the language above each code block, wrap the built-in renderer. Built-in renderers are named functions precisely so an override can delegate to them — `pretty-view-render-code-block`, `pretty-view-render-paragraph`, and so on are all callable:

```elisp
(defun my-pretty-view-code-figure (node render)
  "Render a code block inside a <figure> captioned with its language."
  (let ((lang (or (plist-get node :lang) "")))
    (if (string-empty-p lang)
        (pretty-view-render-code-block node render)
      (format "<figure class=\"pv-code-figure\"><figcaption>%s</figcaption>%s</figure>\n"
              (pretty-view-escape-html lang)
              (pretty-view-render-code-block node render)))))

(setf (alist-get 'code-block pretty-view-renderers)
      #'my-pretty-view-code-figure)
```

For a code block with language "python" and content `print('hello')`, this produces:

```html
<figure class="pv-code-figure"><figcaption>python</figcaption><pre class="pv-code"><code class="language-python"><span class="pv-builtin">print</span>(<span class="pv-string">&#39;hello&#39;</span>)
</code></pre>
</figure>
```

The built-in renderer handles escaping, syntax highlighting via font-lock, and all language-specific formatting. When you wrap it, you get all that for free.

## Customization Variables

In addition to the extension points above, the following variables control the package's appearance and behaviour. Set any of them via `M-x customize-group pretty-view` or in your `init.el` with `setq`.

### Appearance

| Variable | Default | Description |
|----------|---------|-------------|
| `pretty-view-theme` | `'github-light` | Theme symbol (`'github-light`, `'github-dark`, `'sepia`, `'nord`, `'cyberpunk`) or `'auto` to follow OS light/dark mode |
| `pretty-view-default-light-theme` | `'github-light` | Light theme used when `pretty-view-theme` is `'auto` |
| `pretty-view-html-lang` | `"en"` | Value of the `lang` attribute on the generated `html` element |

### Output and Browser

| Variable | Default | Description |
|----------|---------|-------------|
| `pretty-view-output-directory` | nil | Directory where HTML is written; nil means system temporary directory (or Windows `TEMP` on WSL) |
| `pretty-view-browser` | `'default` | How to open the rendered file: `'default` (uses `browse-url`), a program name string, or a function |

### Table of Contents

| Variable | Default | Description |
|----------|---------|-------------|
| `pretty-view-toc` | nil | Whether to emit a table of contents: nil for none, `t` for all levels, or an integer maximum depth. Org documents defer to their own `#+OPTIONS: toc:` |
| `pretty-view-own-toc-modes` | `'(org-mode)` | Major modes whose converters emit their own TOC; TOC generation is suppressed for these |

### Images and Media

| Variable | Default | Description |
|----------|---------|-------------|
| `pretty-view-inline-images` | `t` | When non-nil, embed local images as data URIs for a self-contained file |
| `pretty-view-inline-image-max-bytes` | 2000000 | Maximum image size (in bytes) to embed; larger files are linked as `file://` URLs |

### Content Rendering

| Variable | Default | Description |
|----------|---------|-------------|
| `pretty-view-allow-raw-html` | `t` | Markdown only: when non-nil, pass raw HTML blocks through unchanged; when nil, escape them. Org's `#+BEGIN_EXPORT html` blocks are governed by Org's own export settings, not by this variable. See Threat Model section |
| `pretty-view-text-as-markdown` | nil | When non-nil, route plain-text files through the Markdown parser instead of the plain-text converter |
| `pretty-view-live-interval` | 1.5 | Seconds between change checks in `pretty-view-live-mode`; nil disables auto-reload |

### Code and Syntax Highlighting

| Variable | Default | Description |
|----------|---------|-------------|
| `pretty-view-code-mode-alist` | (built-ins) | Map code block info strings to Emacs major modes for syntax highlighting (e.g., `'("python" . python-mode)`) |
| `pretty-view-face-class-alist` | (built-ins) | Map Emacs font-lock faces to CSS class names for syntax highlighting (e.g., `'((font-lock-keyword-face . "pv-keyword"))`) |

### Extension Points

| Variable | Default | Description |
|----------|---------|-------------|
| `pretty-view-renderers` | (built-ins) | Map Markdown AST node types to rendering functions; customize to override rendering |
| `pretty-view-org-transcoders` | (built-ins) | Map Org element types to transcoding functions; customize to override Org export |
| `pretty-view-source-functions` | (built-ins) | Map major modes to HTML body converters; add entries to support new formats |
| `pretty-view-head-functions` | nil | Hook: functions contributing markup to `<head>` (e.g., script tags for KaTeX or Mermaid) |
| `pretty-view-body-filter-functions` | nil | Hook: functions filtering the rendered body (e.g., to post-process HTML) |

## Platform Notes

### Output Location

By default, rendered HTML is written to:

| Platform | Directory |
|----------|-----------|
| Linux, macOS, Windows | The system temporary directory (`/tmp` on Linux, `/var/folders` on macOS, `%TEMP%` on Windows) |
| WSL | Windows `%TEMP%` (discovered by running `cmd.exe /c echo %TEMP%` and converting with `wslpath -u`), or the system temp directory if WSL host detection fails |

This is configured by `pretty-view-output-directory`. The rationale for writing to Windows `TEMP` under WSL is to avoid `\\wsl.localhost\` UNC paths in the browser's address bar, which many browsers do not handle well. The file is still readable on the WSL side.

File names are `<sanitized base name>-<hash>.html`, where the hash is the first ten characters of a SHA1 hash of the full file path. This ensures repeated renders of the same file reuse one output path (enabling browser tab reload in place) while preventing collisions when multiple files have the same base name.

### Choosing a Browser

Set `pretty-view-browser` to control how the rendered file is opened:

- `'default` (the default) uses `browse-url`, with automatic adjustment for WSL
- A string names a program to invoke with the file URL (e.g., `"firefox"` or `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"`)
- A function is called with the file path and is responsible for opening it

On WSL, the resolution order is: `wslview` if installed; then `explorer.exe` with the path converted by `wslpath -w`; then `browse-url`. This allows the document to open natively in the Windows host's browser.

## Live Mode

Enable `pretty-view-live-mode` in a buffer to regenerate the rendered HTML on every save. The browser tab reloads only when a save actually changed the output, and keeps its scroll position (via `sessionStorage`). Edit in Emacs, save, and the tab catches up; leave it idle and it stays put.

A `file://` page cannot fetch anything, so it cannot read its own source to see whether it changed. It can still load a script, so each live render writes a one-line version script next to the page (`<name>.live.js`, holding a hash of the rendered HTML). The page loads that script every `pretty-view-live-interval` seconds (default 1.5), skipping hidden tabs, and reloads only when the reported version differs from its own.

To disable automatic reloads entirely, set `pretty-view-live-interval` to nil. The file will still regenerate on save, but the page carries no watcher.

## Threat Model

The package is designed for rendering documents you author or trust. Raw HTML and `javascript:` URLs in the source both reach the browser unchanged, so:

- **Do not render untrusted HTML or Markdown.** An attacker-controlled document can inject arbitrary JavaScript.
- **Do not set `pretty-view-allow-raw-html` to nil** to prevent this; the right approach is not to render documents you don't trust. Note also that this variable only affects the Markdown path — it does not gate Org `#+BEGIN_EXPORT html` blocks, which pass through under Org's own export settings.

If you must render external content, filter it through a sanitizer before rendering.

## What This Package Does Not Do

- Serve over HTTP or provide a local web server
- Synchronize the cursor or scroll position between Emacs and the browser
- Export to PDF or other formats
- Generate multi-file sites
- Bundle Mermaid, KaTeX, or other JavaScript libraries; use `pretty-view-head-functions` to add them

## License

GPL-3.0-or-later. See the file `LICENSE` in the repository.
