;;; pretty-view-theme.el --- Theme registry and CSS generation  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Kyeong Soo Choi

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

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

;; Duplicated from pretty-view-render.el (`defgroup' merges harmlessly)
;; so this file's own defcustoms resolve when loaded standalone, e.g.
;; for just the palette machinery -- not an accidental copy-paste.
(defgroup pretty-view nil
  "Render Org, Markdown, and text buffers to styled HTML."
  :group 'convenience
  :prefix "pretty-view-")

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
  border-collapse: separate;
  border-spacing: 0;
  border-top: 1px solid var(--pv-border);
  border-left: 1px solid var(--pv-border);
  font-variant-numeric: tabular-nums;
}
table.pv-table th, table.pv-table td {
  padding: 0.45em 0.85em;
  border-right: 1px solid var(--pv-border);
  border-bottom: 1px solid var(--pv-border);
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

(defun pretty-view-theme--slots ()
  "Return the list of legal palette slot keywords."
  (seq-filter #'keywordp pretty-view-theme-default-palette))

(defun pretty-view-define-theme (name &rest palette)
  "Register theme NAME with PALETTE, a plist of slot keywords and values.
Slots omitted from PALETTE inherit `pretty-view-theme-default-palette'.
Signals when PALETTE names a slot that does not exist or is malformed.
Values are inserted into CSS verbatim, so they must be valid CSS and
must not contain `;' or `}'."
  (when (oddp (length palette))
    (error "pretty-view: Malformed palette plist in theme `%s'" name))
  (let ((legal (pretty-view-theme--slots))
        (keys (seq-filter #'keywordp palette)))
    (dolist (key keys)
      (unless (memq key legal)
        (error "pretty-view: Unknown theme slot `%s' in theme `%s'" key name))))
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
         ;; The dark half's :extra-css must come after the base
         ;; stylesheet too, exactly like the light half below -- inside
         ;; a media query is not "after" in the cascade, so emitting it
         ;; only inside the block above (which precedes the base
         ;; stylesheet) let base rules of equal specificity win under a
         ;; dark theme but not under a light one.
         (when (and dark (plist-get dark :extra-css))
           (format "@media (prefers-color-scheme: dark) {\n%s}\n"
                   (plist-get dark :extra-css)))
         (or (plist-get light :extra-css) "")))
    (let ((palette (or (pretty-view-theme-palette name)
                       pretty-view-theme-default-palette)))
      (concat
       (pretty-view-theme--variables palette ":root")
       pretty-view-theme--base-stylesheet
       (or (plist-get palette :extra-css) "")))))

(provide 'pretty-view-theme)
;;; pretty-view-theme.el ends here
