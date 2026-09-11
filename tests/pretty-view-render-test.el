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

(provide 'pretty-view-render-test)
;;; pretty-view-render-test.el ends here
