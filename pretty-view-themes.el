;;; pretty-view-themes.el --- The bundled themes  -*- lexical-binding: t -*-

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
  :keyword "#9a2f2f" :string "#4b6b2f" :comment "#736546"
  :doc "#4b6b2f" :function "#7a4b9a" :variable "#433422"
  :type "#96591a" :constant "#2f5d7c" :builtin "#2f5d7c"
  :preprocessor "#7a4b9a" :operator "#5c4a2e"
  :escape "#2f5d7c" :warning "#9a6b1a"
  :body-font pretty-view-themes--serif-font
  :measure "40rem" :line-height "1.75"
  :dark-variant 'nord)

;; Nord theme uses modified colors for contrast:
;; - :keyword, :muted, :comment differ from upstream nord3/nord4 to meet WCAG AA
;;   on code backgrounds. Upstream intends nord3 (#616e88) against nord0 (darkest),
;;   not nord1 (#3b4252 code-bg). Legibility trumps palette fidelity.
(pretty-view-define-theme 'nord
  :bg "#2e3440" :fg "#d8dee9" :muted "#909cb5"
  :accent "#88c0d0" :accent-muted "#3b4252"
  :border "#434c5e" :rule "#434c5e"
  :code-bg "#3b4252" :code-fg "#e5e9f0" :code-border "#4c566a"
  :quote-border "#4c566a" :quote-fg "#a9b3c6"
  :table-stripe "#353c4a" :mark-bg "#4c4322"
  :keyword "#8fb3d6" :string "#a3be8c" :comment "#a3aec4"
  :doc "#a3be8c" :function "#88c0d0" :variable "#d8dee9"
  :type "#8fbcbb" :constant "#c9a3d9" :builtin "#8fb3d6"
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
  :keyword "#ff2e88" :string "#9cf06b" :comment "#8b85b5"
  :doc "#9cf06b" :function "#4de2ff" :variable "#e8e6f0"
  :type "#ffd866" :constant "#c792ea" :builtin "#4de2ff"
  :preprocessor "#c792ea" :operator "#ff9f4a"
  :escape "#ffd866" :warning "#ffd866"
  :dark-variant 'cyberpunk)

(provide 'pretty-view-themes)
;;; pretty-view-themes.el ends here
