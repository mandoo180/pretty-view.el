;;; pretty-view-test.el --- Tests for commands and dispatch  -*- lexical-binding: t -*-

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

;; Source dispatch, file writing, live mode, and theme selection.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'pretty-view)
(require 'markdown-mode nil t)

(defmacro pv-in-mode (mode text &rest body)
  "Run BODY in a temp buffer holding TEXT in MODE."
  (declare (indent 2))
  `(with-temp-buffer
     (insert ,text)
     (,mode)
     ,@body))

(ert-deftest pretty-view-test-dispatch-markdown ()
  (skip-unless (fboundp 'markdown-mode))
  (pv-in-mode markdown-mode "# Hi"
    (should (string-match-p "<h1" (pretty-view-body)))))

(ert-deftest pretty-view-test-dispatch-org ()
  (pv-in-mode org-mode "* Hi\n"
    (should (string-match-p "<h2" (pretty-view-body)))))

(ert-deftest pretty-view-test-dispatch-text ()
  (pv-in-mode text-mode "plain words"
    (should (string-match-p "pv-text" (pretty-view-body)))))

(ert-deftest pretty-view-test-dispatch-unknown-mode-uses-text ()
  (pv-in-mode fundamental-mode "words"
    (should (string-match-p "pv-text" (pretty-view-body)))))

(ert-deftest pretty-view-test-dispatch-honours-derived-modes ()
  (skip-unless (fboundp 'markdown-mode))
  "gfm-mode derives from markdown-mode and must take the markdown path."
  (pv-in-mode gfm-mode "# Hi"
    (should (string-match-p "<h1" (pretty-view-body)))))

(ert-deftest pretty-view-test-source-functions-override ()
  (let ((pretty-view-source-functions
         (cons '(text-mode . (lambda () "<p>probe</p>"))
               pretty-view-source-functions)))
    (pv-in-mode text-mode "x"
      (should (equal (pretty-view-body) "<p>probe</p>")))))

(ert-deftest pretty-view-test-render-writes-a-complete-document ()
  (skip-unless (fboundp 'markdown-mode))
  (let ((out (make-temp-file "pv" nil ".html")))
    (unwind-protect
        (progn
          (pv-in-mode markdown-mode "# Title"
            (pretty-view-render-buffer-to-file out))
          (with-temp-buffer
            (insert-file-contents out)
            (let ((html (buffer-string)))
              (should (string-prefix-p "<!DOCTYPE html>" html))
              (should (string-match-p "<h1" html))
              (should (string-match-p "--pv-bg" html)))))
      (delete-file out))))

(ert-deftest pretty-view-test-render-creates-missing-directory ()
  (let* ((dir (expand-file-name "pv-nested" (make-temp-file "pv-out" t)))
         (out (expand-file-name "a.html" dir)))
    (unwind-protect
        (progn
          (pv-in-mode text-mode "x" (pretty-view-render-buffer-to-file out))
          (should (file-exists-p out)))
      (delete-directory (file-name-directory (directory-file-name dir)) t))))

(ert-deftest pretty-view-test-render-does-not-launch-a-browser ()
  "Writing the file and opening it are separate steps."
  (let ((out (make-temp-file "pv" nil ".html"))
        (opened nil))
    (unwind-protect
        (cl-letf (((symbol-function 'pretty-view-browser-open)
                   (lambda (f) (setq opened f))))
          (pv-in-mode text-mode "x" (pretty-view-render-buffer-to-file out))
          (should (null opened)))
      (delete-file out))))

(ert-deftest pretty-view-test-live-mode-adds-and-removes-hook ()
  (pv-in-mode text-mode "x"
    (pretty-view-live-mode 1)
    (should (memq #'pretty-view--live-update after-save-hook))
    (pretty-view-live-mode -1)
    (should-not (memq #'pretty-view--live-update after-save-hook))))

(ert-deftest pretty-view-test-live-document-carries-the-script ()
  (let ((out (make-temp-file "pv" nil ".html")))
    (unwind-protect
        (progn
          (pv-in-mode text-mode "x"
            (pretty-view-render-buffer-to-file out t))
          (with-temp-buffer
            (insert-file-contents out)
            (should (string-match-p "location.reload" (buffer-string)))))
      (delete-file out))))

(ert-deftest pretty-view-test-title-from-org ()
  (pv-in-mode org-mode "#+TITLE: My Doc\n* Hi\n"
    (should (equal (pretty-view--title) "My Doc"))))

(ert-deftest pretty-view-test-title-from-buffer-name-without-file ()
  (pv-in-mode text-mode "x"
    (should (stringp (pretty-view--title)))))

(ert-deftest pretty-view-test-select-theme-sets-the-variable ()
  (let ((pretty-view-theme 'auto))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "nord")))
      (call-interactively #'pretty-view-select-theme)
      (should (eq pretty-view-theme 'nord)))))

(ert-deftest pretty-view-test-org-does-not-get-two-tocs ()
  "Org emits its own TOC, so the shell must not add another."
  (let ((pretty-view-toc t))
    (pv-in-mode org-mode "* One\n* Two\n* Three\n"
      (let ((html (pretty-view-html-document
                   (pretty-view-body)
                   :title "T"
                   :toc (if (derived-mode-p 'org-mode) 'none pretty-view-toc))))
        (should-not (string-match-p "class=\"pv-toc\"" html))))))

(ert-deftest pretty-view-test-markdown-gets-toc ()
  (skip-unless (fboundp 'markdown-mode))
  "Markdown should get the shell TOC when pretty-view-toc is t."
  (let ((pretty-view-toc t))
    (pv-in-mode markdown-mode "# One\n# Two\n# Three\n"
      (let ((html (pretty-view-html-document
                   (pretty-view-body)
                   :title "T"
                   :toc (if (derived-mode-p 'org-mode) 'none pretty-view-toc))))
        (should (string-match-p "class=\"pv-toc\"" html))))))

(ert-deftest pretty-view-test-live-update-cannot-break-save ()
  "A failing render must not propagate out of after-save-hook."
  (let ((tmp (make-temp-file "pv-src" nil ".txt")))
    (unwind-protect
        (with-current-buffer (find-file-noselect tmp)
          (insert "x")
          (pretty-view-live-mode 1)
          (cl-letf (((symbol-function 'pretty-view-body)
                     (lambda () (error "boom")))
                    ((symbol-function 'message) (lambda (&rest _) nil)))
            (should (progn (save-buffer) t)))
          (set-buffer-modified-p nil)
          (kill-buffer))
      (delete-file tmp))))

(ert-deftest pretty-view-test-own-toc-modes-suppresses-toc ()
  "Modes in pretty-view-own-toc-modes should suppress the shell TOC."
  (define-derived-mode pv-test-mode text-mode "PV-Test")
  (let ((pretty-view-toc t)
        (pretty-view-own-toc-modes '(pv-test-mode)))
    (pv-in-mode pv-test-mode "# One\n# Two\n"
      (let ((html (pretty-view-html-document
                   (pretty-view-body)
                   :title "T"
                   :toc (if (seq-some (lambda (m) (derived-mode-p m))
                                      pretty-view-own-toc-modes)
                           'none
                         pretty-view-toc))))
        (should-not (string-match-p "class=\"pv-toc\"" html))))))

(provide 'pretty-view-test)
;;; pretty-view-test.el ends here
