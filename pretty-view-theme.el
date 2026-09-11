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

(defconst pretty-view-theme--base-stylesheet
  "body { background: var(--pv-bg); color: var(--pv-fg); }\n"
  "The static stylesheet, written against the CSS custom properties.")

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
    (error "pretty-view: malformed palette plist in theme `%s'" name))
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
           (format "@media (prefers-color-scheme: dark) {\n%s%s}\n"
                   (pretty-view-theme--variables dark ":root")
                   (or (plist-get dark :extra-css) "")))
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
