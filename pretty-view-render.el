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
