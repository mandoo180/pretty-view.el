;;; pretty-view-render-test.el --- Tests for pretty-view-render  -*- lexical-binding: t -*-

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
;; Tests for HTML escaping and the renderer table.
;;; Code:

(require 'ert)
(require 'pretty-view-render)

(ert-deftest pretty-view-render-test-escape-ampersand-first ()
  "Ampersands must be escaped before the entities we introduce."
  (should (equal (pretty-view-escape-html "a & b") "a &amp; b"))
  (should (equal (pretty-view-escape-html "<b>") "&lt;b&gt;"))
  (should (equal (pretty-view-escape-html "\"q\"") "&quot;q&quot;"))
  (should (equal (pretty-view-escape-html "it's") "it&#39;s")))

(ert-deftest pretty-view-render-test-escape-does-not-double-escape-its-own-output ()
  "Escaping `&lt;' must not turn into `&amp;lt;' for a single pass."
  (should (equal (pretty-view-escape-html "<&>") "&lt;&amp;&gt;")))

(ert-deftest pretty-view-render-test-escape-attribute ()
  (should (equal (pretty-view-escape-attribute "a\"b") "a&quot;b")))

(provide 'pretty-view-render-test)
;;; pretty-view-render-test.el ends here
