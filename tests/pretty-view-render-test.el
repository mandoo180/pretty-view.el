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
(require 'cl-lib)
(require 'pretty-view-render)
(require 'pretty-view-gfm)

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

(ert-deftest pretty-view-render-test-fontified-code-emits-spans ()
  (let ((html (pretty-view-render-fontified-code "(defun foo ())" "elisp")))
    (should (string-match-p "<span class=\"pv-keyword\">defun</span>" html))
    (should (string-match-p "foo" html))))

(ert-deftest pretty-view-render-test-fontified-code-escapes ()
  (let ((html (pretty-view-render-fontified-code "a < b & c" nil)))
    (should (string-match-p "&lt;" html))
    (should (string-match-p "&amp;" html))
    (should-not (string-match-p "[^&]< " html))))

(ert-deftest pretty-view-render-test-fontified-code-unknown-language ()
  "An unknown language yields escaped plain text, not an error."
  (let ((html (pretty-view-render-fontified-code "x < y" "no-such-lang")))
    (should (equal html "x &lt; y"))))

(ert-deftest pretty-view-render-test-fontified-code-nil-language ()
  (should (equal (pretty-view-render-fontified-code "plain" nil) "plain")))

(ert-deftest pretty-view-render-test-code-mode-alist-alias ()
  (let ((pretty-view-code-mode-alist '(("elisp" . emacs-lisp-mode))))
    (should (eq (pretty-view-render--code-mode "elisp") 'emacs-lisp-mode))))

(ert-deftest pretty-view-render-test-code-mode-suffix-fallback ()
  "A language with no alist entry falls back to LANG-mode."
  (let ((pretty-view-code-mode-alist nil))
    (should (eq (pretty-view-render--code-mode "emacs-lisp") 'emacs-lisp-mode))
    (should (null (pretty-view-render--code-mode "definitely-not-a-mode")))))

(ert-deftest pretty-view-render-test-face-normalization ()
  "A face property may be a symbol, a list, or an anonymous plist."
  (should (equal (pretty-view-render--face-class 'font-lock-keyword-face)
                 "pv-keyword"))
  (should (equal (pretty-view-render--face-class
                  '(font-lock-keyword-face default))
                 "pv-keyword"))
  (should (null (pretty-view-render--face-class '(:foreground "red"))))
  (should (null (pretty-view-render--face-class nil))))

(ert-deftest pretty-view-render-test-fontified-code-preserves-newlines ()
  (let ((html (pretty-view-render-fontified-code "a\nb\n" nil)))
    (should (equal html "a\nb\n"))))

(ert-deftest pretty-view-render-test-ts-mode-requires-a-grammar ()
  "A -ts-mode is only chosen when its grammar is actually installed."
  (let ((pretty-view-code-mode-alist nil))
    (cl-letf (((symbol-function 'treesit-language-available-p)
               (lambda (&rest _) nil)))
      ;; python-mode is built in, so this must fall back to it, not to
      ;; python-ts-mode.
      (should (eq (pretty-view-render--code-mode "python") 'python-mode)))
    (cl-letf (((symbol-function 'treesit-language-available-p)
               (lambda (&rest _) t)))
      (should (eq (pretty-view-render--code-mode "python") 'python-ts-mode)))))

(ert-deftest pretty-view-render-test-fontifying-never-prompts ()
  "Rendering a code block must not ask the user anything."
  (let ((asked nil))
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (&rest _) (setq asked t) nil))
              ((symbol-function 'yes-or-no-p)
               (lambda (&rest _) (setq asked t) nil)))
      (dolist (lang '("python" "rust" "yaml" "ts" "rs" "js" "c" "json"))
        (pretty-view-render-fontified-code "x = 1" lang))
      (should-not asked))))

(ert-deftest pretty-view-render-test-fontify-honours-font-lock-face ()
  "A run boundary must be found on font-lock-face, not only on face."
  (with-temp-buffer
    (insert "keyword value")
    (put-text-property (point-min) (+ (point-min) 7)
                       'font-lock-face 'font-lock-keyword-face)
    (let ((html (pretty-view-render--fontify-buffer-html)))
      (should (string-match-p "<span class=\"pv-keyword\">keyword</span>" html))
      (should-not (string-match-p "keyword value</span>" html)))))

(ert-deftest pretty-view-render-test-fontify-mixed-face-properties ()
  "Both properties present, on different spans, must both be honoured."
  (with-temp-buffer
    (insert "aaa bbb ccc")
    (put-text-property 1 4 'face 'font-lock-keyword-face)
    (put-text-property 9 12 'font-lock-face 'font-lock-string-face)
    (let ((html (pretty-view-render--fontify-buffer-html)))
      (should (string-match-p "<span class=\"pv-keyword\">aaa</span>" html))
      (should (string-match-p "<span class=\"pv-string\">ccc</span>" html))
      (should (string-match-p ">bbb<\\| bbb " html)))))

(defun pv-render (markdown)
  "Parse MARKDOWN and render it to HTML."
  (pretty-view-render-document (pretty-view-gfm-parse markdown)))

(ert-deftest pretty-view-render-test-heading ()
  (should (equal (pv-render "# Hi") "<h1 id=\"hi\">Hi</h1>\n")))

(ert-deftest pretty-view-render-test-paragraph ()
  (should (equal (pv-render "text") "<p>text</p>\n")))

(ert-deftest pretty-view-render-test-emphasis-and-strong ()
  (should (equal (pv-render "*a* **b**")
                 "<p><em>a</em> <strong>b</strong></p>\n")))

(ert-deftest pretty-view-render-test-strikethrough ()
  (should (equal (pv-render "~~x~~") "<p><del>x</del></p>\n")))

(ert-deftest pretty-view-render-test-code-span-escapes ()
  (should (equal (pv-render "`<b>`") "<p><code>&lt;b&gt;</code></p>\n")))

(ert-deftest pretty-view-render-test-code-block-has-language-class ()
  (let ((html (pv-render "```elisp\n(foo)\n```")))
    (should (string-match-p "<pre class=\"pv-code\"" html))
    (should (string-match-p "language-elisp" html))))

(ert-deftest pretty-view-render-test-link ()
  (should (equal (pv-render "[t](https://e.com)")
                 "<p><a href=\"https://e.com\">t</a></p>\n")))

(ert-deftest pretty-view-render-test-link-title-and-escaping ()
  (should (string-match-p "title=\"A &amp; B\""
                          (pv-render "[t](https://e.com \"A & B\")"))))

(ert-deftest pretty-view-render-test-image ()
  (should (equal (pv-render "![a](i.png)")
                 "<p><img src=\"i.png\" alt=\"a\" /></p>\n")))

(ert-deftest pretty-view-render-test-bullet-list ()
  (should (equal (pv-render "- a\n- b")
                 "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n")))

(ert-deftest pretty-view-render-test-ordered-list-start ()
  (should (string-match-p "<ol start=\"3\">" (pv-render "3. a"))))

(ert-deftest pretty-view-render-test-task-item ()
  (let ((html (pv-render "- [x] done")))
    (should (string-match-p "class=\"pv-task\"" html))
    (should (string-match-p "checked" html))
    (should (string-match-p "disabled" html))))

(ert-deftest pretty-view-render-test-blockquote ()
  (should (equal (pv-render "> q")
                 "<blockquote>\n<p>q</p>\n</blockquote>\n")))

(ert-deftest pretty-view-render-test-thematic-break ()
  (should (equal (pv-render "---") "<hr />\n")))

(ert-deftest pretty-view-render-test-table ()
  (let ((html (pv-render "| a |\n|:--|\n| 1 |")))
    (should (string-match-p "<table" html))
    (should (string-match-p "<th style=\"text-align:left\">a</th>" html))
    (should (string-match-p "<td style=\"text-align:left\">1</td>" html))))

(ert-deftest pretty-view-render-test-raw-html-passthrough ()
  (let ((pretty-view-allow-raw-html t))
    (should (string-match-p "<div>" (pv-render "<div>\n</div>")))))

(ert-deftest pretty-view-render-test-raw-html-escaped-when-disallowed ()
  (let ((pretty-view-allow-raw-html nil))
    (should (string-match-p "&lt;div&gt;" (pv-render "<div>\n</div>")))))

(ert-deftest pretty-view-render-test-user-renderer-override ()
  (let ((pretty-view-renderers
         (cons '(thematic-break . (lambda (_node _render) "<hr class=\"x\">"))
               pretty-view-renderers)))
    (should (equal (pv-render "---") "<hr class=\"x\">"))))

(ert-deftest pretty-view-render-test-signalling-renderer-falls-back ()
  "A broken override must not lose the document."
  (let* ((warned nil)
         (pretty-view-renderers
          (cons '(thematic-break . (lambda (_n _r) (error "boom")))
                pretty-view-renderers)))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (&rest _) (setq warned t))))
      (should (equal (pv-render "---") "<hr />\n"))
      (should warned))))

(ert-deftest pretty-view-render-test-unknown-node-type-renders-children ()
  (should (equal (pretty-view-render-node
                  '(:type no-such-type
                    :children ((:type text :value "x"))))
                 "x")))

(ert-deftest pretty-view-render-test-soft-break-becomes-newline ()
  (should (equal (pv-render "a\nb") "<p>a\nb</p>\n")))

(ert-deftest pretty-view-render-test-hard-break ()
  (should (equal (pv-render "a  \nb") "<p>a<br />\nb</p>\n")))

(ert-deftest pretty-view-render-test-footnotes ()
  (let ((html (pv-render "text[^a]\n\n[^a]: note")))
    (should (string-match-p "id=\"fnref-a\"" html))
    (should (string-match-p "href=\"#fn-a\"" html))
    (should (string-match-p "id=\"fn-a\"" html))))

(ert-deftest pretty-view-render-test-table-ragged-body-fewer-cells ()
  "A body row with fewer cells than the header should render without error."
  (let ((html (pv-render "| a | b |\n|---|---|\n| 1 |")))
    (should (string-match-p "<th" html))
    (should (string-match-p "<td" html))
    (should-not (string-match-p "error" html))))

(ert-deftest pretty-view-render-test-table-ragged-body-more-cells ()
  "A body row with more cells than the header should render without error."
  (let ((html (pv-render "| a |\n|---|\n| 1 | 2 |")))
    (should (string-match-p "<th" html))
    (should (string-match-p "<td" html))
    (should-not (string-match-p "error" html))))

(provide 'pretty-view-render-test)
;;; pretty-view-render-test.el ends here
