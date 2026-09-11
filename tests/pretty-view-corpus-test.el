;;; pretty-view-corpus-test.el --- Golden-file tests  -*- lexical-binding: t -*-

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
