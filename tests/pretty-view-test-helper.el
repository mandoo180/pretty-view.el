;;; pretty-view-test-helper.el --- Shared test helpers  -*- lexical-binding: t -*-

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
