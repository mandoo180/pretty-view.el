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
