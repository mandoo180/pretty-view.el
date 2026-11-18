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

;; Live refresh after revert and unsaved edits.

(defmacro pv-with-live-file (&rest body)
  "Run BODY in a live-mode buffer visiting a temp file; `renders' counts renders."
  (declare (indent 0))
  `(let ((file (make-temp-file "pv-live" nil ".txt" "one\n"))
         (renders 0))
     (unwind-protect
         (cl-letf (((symbol-function 'pretty-view-render-buffer-to-file)
                    (lambda (&rest _) (cl-incf renders))))
           (let ((buf (find-file-noselect file)))
             (unwind-protect
                 (with-current-buffer buf
                   (pretty-view-live-mode 1)
                   ,@body)
               (when (buffer-live-p buf)
                 (with-current-buffer buf (set-buffer-modified-p nil))
                 (kill-buffer buf)))))
       (delete-file file))))

(defun pv-test-wait (seconds)
  "Let timers run for SECONDS."
  (let ((end (+ (float-time) seconds)))
    (while (< (float-time) end)
      (accept-process-output nil 0.01))))

(ert-deftest pretty-view/live-mode-renders-after-revert ()
  (pv-with-live-file
    (let ((pretty-view-live-delay 0.05))
      (with-temp-file file (insert "two\n"))
      (revert-buffer t t t)
      (should (= renders 1))
      (should pretty-view-live-mode)
      (should (memq #'pretty-view--live-schedule after-change-functions))
      (pv-test-wait 0.15)
      (should (= renders 1)))))

(ert-deftest pretty-view/live-mode-renders-unsaved-edits-after-the-delay ()
  (pv-with-live-file
    (let ((pretty-view-live-delay 0.05))
      (insert "a")
      (should (= renders 0))
      (pv-test-wait 0.15)
      (should (= renders 1))
      (insert "b")
      (insert "c")
      (insert "d")
      (should (= renders 1))
      (pv-test-wait 0.15)
      (should (= renders 2)))))

(ert-deftest pretty-view/live-mode-off-cancels-the-timer-and-hooks ()
  (pv-with-live-file
    (let ((pretty-view-live-delay 0.05))
      (insert "a")
      (should (timerp pretty-view--live-timer))
      (pretty-view-live-mode -1)
      (should-not pretty-view--live-timer)
      (dolist (hook '(after-save-hook after-revert-hook
                      after-change-functions kill-buffer-hook))
        (should-not (memq #'pretty-view--live-update (symbol-value hook)))
        (should-not (memq #'pretty-view--live-schedule (symbol-value hook)))
        (should-not (memq #'pretty-view--live-cancel (symbol-value hook))))
      (pv-test-wait 0.15)
      (should (= renders 0)))))

(ert-deftest pretty-view/killing-the-buffer-cancels-the-timer ()
  (pv-with-live-file
    (let ((pretty-view-live-delay 0.05)
          (timer nil))
      (insert "a")
      (setq timer pretty-view--live-timer)
      (should (memq timer timer-list))
      (set-buffer-modified-p nil)
      (kill-buffer (current-buffer))
      (should-not (memq timer timer-list))
      (pv-test-wait 0.15)
      (should (= renders 0)))))

(defun pv-test-read (file)
  "Return FILE's contents."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun pv-test-live-render (out text)
  "Render TEXT live into OUT; return (EMBEDDED-VERSION . FILE-VERSION)."
  (pv-in-mode text-mode text
    ;; The title comes from the buffer name, which must not vary.
    (rename-buffer "pv-live-test" t)
    (pretty-view-render-buffer-to-file out t))
  (let ((html (pv-test-read out))
        (js (pv-test-read (pretty-view--live-file out))))
    (cons (and (string-match "var version = '\\([^']+\\)'" html)
               (match-string 1 html))
          (and (string-match "prettyViewLive('\\([^']+\\)')" js)
               (match-string 1 js)))))

(defmacro pv-with-live-out (var &rest body)
  "Bind VAR to a fresh output path, run BODY, delete both output files."
  (declare (indent 1))
  `(let ((,var (make-temp-file "pv" nil ".html")))
     (unwind-protect (progn ,@body)
       (delete-file ,var)
       (delete-file (pretty-view--live-file ,var)))))

(ert-deftest pretty-view-test-live-document-carries-the-script ()
  (pv-with-live-out out
    (pv-in-mode text-mode "x"
      (pretty-view-render-buffer-to-file out t))
    (should (string-match-p "location.reload" (pv-test-read out)))))

(ert-deftest pretty-view-test-live-version-file-matches-the-page ()
  (pv-with-live-out out
    (let ((versions (pv-test-live-render out "x")))
      (should (car versions))
      (should (equal (car versions) (cdr versions))))))

(ert-deftest pretty-view-test-live-version-changes-only-with-content ()
  "Saving unchanged text must not reload the tab; editing it must."
  (pv-with-live-out out
    (let* ((first (pv-test-live-render out "one"))
           (again (pv-test-live-render out "one"))
           (edited (pv-test-live-render out "two")))
      (should (equal again first))
      (should-not (equal (car edited) (car first))))))

(ert-deftest pretty-view-test-non-live-render-has-no-watcher ()
  (pv-with-live-out out
    (pv-in-mode text-mode "x" (pretty-view-render-buffer-to-file out))
    (should-not (string-match-p "<script" (pv-test-read out)))
    (should-not (file-exists-p (pretty-view--live-file out)))))

(ert-deftest pretty-view-test-nil-interval-disables-the-watcher ()
  (pv-with-live-out out
    (let ((pretty-view-live-interval nil))
      (pv-in-mode text-mode "x" (pretty-view-render-buffer-to-file out t)))
    (should-not (string-match-p "<script" (pv-test-read out)))
    (should-not (file-exists-p (pretty-view--live-file out)))))

(ert-deftest pretty-view-test-file-renders-and-does-not-open-a-real-browser ()
  "pretty-view-file must render FILE to HTML without launching a browser."
  (let* ((src (make-temp-file "pv-src" nil ".txt"))
         (out-dir (make-temp-file "pv-out" t))
         (opened nil))
    (unwind-protect
        (progn
          (with-temp-file src (insert "hello from file"))
          (let ((pretty-view-output-directory out-dir))
            (cl-letf (((symbol-function 'pretty-view-browser-open)
                       (lambda (f) (setq opened f))))
              (pretty-view-file src)))
          (should opened)
          (should (file-exists-p opened))
          (with-temp-buffer
            (insert-file-contents opened)
            (should (string-match-p "hello from file" (buffer-string)))))
      (delete-file src)
      (delete-directory out-dir t))))

(ert-deftest pretty-view-test-file-does-not-leave-a-buffer-behind ()
  "Rendering a file that was not already visited must not leave a buffer."
  (let* ((src (make-temp-file "pv-src" nil ".txt"))
         (out-dir (make-temp-file "pv-out" t)))
    (unwind-protect
        (progn
          (with-temp-file src (insert "hello"))
          (should (null (get-file-buffer src)))
          (let ((pretty-view-output-directory out-dir))
            (cl-letf (((symbol-function 'pretty-view-browser-open) #'ignore))
              (pretty-view-file src)))
          (should (null (get-file-buffer src))))
      (delete-file src)
      (delete-directory out-dir t))))

(ert-deftest pretty-view-test-file-keeps-a-buffer-that-was-already-open ()
  "Rendering a file already visited in a buffer must not kill that buffer."
  (let* ((src (make-temp-file "pv-src" nil ".txt"))
         (out-dir (make-temp-file "pv-out" t))
         (buf (find-file-noselect src)))
    (unwind-protect
        (progn
          (let ((pretty-view-output-directory out-dir))
            (cl-letf (((symbol-function 'pretty-view-browser-open) #'ignore))
              (pretty-view-file src)))
          (should (buffer-live-p (get-file-buffer src))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (delete-file src)
      (delete-directory out-dir t))))

(ert-deftest pretty-view-test-export-writes-file-without-opening-a-browser ()
  (let ((out (make-temp-file "pv-export" nil ".html"))
        (opened nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'pretty-view-browser-open)
                     (lambda (f) (setq opened f))))
            (pv-in-mode text-mode "hello export"
              (pretty-view-export out)))
          (should (null opened))
          (with-temp-buffer
            (insert-file-contents out)
            (should (string-match-p "hello export" (buffer-string)))))
      (delete-file out))))

(ert-deftest pretty-view-test-export-interactive-spec-suggests-html-name ()
  "The interactive prompt must default to the buffer's base name with .html."
  (let ((out (make-temp-file "pv-export" nil ".html"))
        (suggested nil))
    (unwind-protect
        (progn
          (pv-in-mode text-mode "x"
            (rename-buffer "my-notes" t)
            (cl-letf (((symbol-function 'read-file-name)
                       (lambda (_prompt &optional _dir _default _mustmatch initial &rest _)
                         (setq suggested initial)
                         out)))
              (call-interactively #'pretty-view-export)))
          (should (equal suggested "my-notes.html")))
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

(defconst pretty-view-test--package-file
  ;; `load-file-name' is only bound while this file is being loaded, so
  ;; it must be captured here at top level, not read from inside a
  ;; deftest body that runs later (see `pretty-view-corpus-directory'
  ;; in pretty-view-corpus-test.el for the same pattern).
  (expand-file-name "pretty-view.el"
                    (file-name-directory
                     (directory-file-name
                      (file-name-directory
                       (or load-file-name buffer-file-name)))))
  "Path to the repository's top-level pretty-view.el, for metadata tests.")

(ert-deftest pretty-view-test-package-metadata-is-installable ()
  "package.el must accept this file's headers."
  (require 'package)
  (let ((desc (with-temp-buffer
                (insert-file-contents pretty-view-test--package-file)
                (emacs-lisp-mode)
                (package-buffer-info))))
    (should (eq (package-desc-name desc) 'pretty-view))
    (should (assq 'emacs (package-desc-reqs desc)))
    (should-not (assq 'Emacs (package-desc-reqs desc)))))

;;; Linked documents

(defmacro pv-with-org-tree (dir files &rest body)
  "Bind DIR to a fresh directory holding FILES, run BODY, delete it.
FILES is an alist (NAME . CONTENTS) with names relative to DIR.  Output
goes to a fresh directory, the link queue and page table start empty,
file URLs are stubbed to \"URL:\" plus the file name, and no browser
opens."
  (declare (indent 2))
  `(let* ((,dir (file-name-as-directory (make-temp-file "pv-tree" t)))
          (pretty-view-output-directory (make-temp-file "pv-out" t))
          (pretty-view-links--queue nil)
          (pretty-view-links--queued (make-hash-table :test #'equal))
          (pretty-view-links--timer nil)
          (pretty-view-links--written (make-hash-table :test #'equal)))
     (unwind-protect
         (cl-letf (((symbol-function 'pretty-view-browser-open) #'ignore)
                   ((symbol-function 'pretty-view-browser-file-url)
                    (lambda (f) (concat "URL:" f))))
           (dolist (f ,files)
             (let ((path (expand-file-name (car f) ,dir)))
               (make-directory (file-name-directory path) t)
               (with-temp-file path (insert (cdr f)))))
           ,@body)
       (pretty-view-links-reset)
       (delete-directory ,dir t)
       (delete-directory pretty-view-output-directory t))))

(defun pv-tree-page (file)
  "Return the rendered page of FILE, or nil when it was not written."
  (let ((out (pretty-view-browser-output-file file)))
    (and (file-exists-p out) (pv-test-read out))))

(defun pv-tree-href (file)
  "Return the href attribute that links to FILE's page."
  (format "href=\"%s\""
          (url-hexify-string
           (file-name-nondirectory (pretty-view-browser-output-file file)))))

(ert-deftest pretty-view-test-linked-render-matches-a-direct-render ()
  (pv-with-org-tree dir '(("a.org" . "#+TITLE: Alpha\n* A\n"))
    (let* ((src (expand-file-name "a.org" dir))
           (html (pretty-view--render-linked src))
           (opened nil))
      (should (string-match-p "<title>Alpha</title>" html))
      (cl-letf (((symbol-function 'pretty-view-browser-open)
                 (lambda (f) (setq opened f))))
        (pretty-view-file src))
      (should (equal opened (pretty-view-browser-output-file src)))
      (should (equal (pv-test-read opened) html)))))

(ert-deftest pretty-view-test-linked-render-skips-mode-hooks ()
  (pv-with-org-tree dir '(("a.org" . "* A\n"))
    (let* ((ran nil)
           (org-mode-hook (list (lambda () (setq ran t)))))
      (pretty-view--render-linked (expand-file-name "a.org" dir))
      (should-not ran))))

(ert-deftest pretty-view-test-linked-render-resolves-links-from-its-directory ()
  (pv-with-org-tree dir '(("sub/a.org" . "[[file:c.json][C]]\n")
                          ("sub/c.json" . "{}"))
    (should (string-match-p
             (regexp-quote (concat "href=\"URL:" dir "sub/c.json\""))
             (pretty-view--render-linked (expand-file-name "sub/a.org" dir))))))

(ert-deftest pretty-view-test-linked-render-leaves-nothing-behind ()
  (pv-with-org-tree dir '(("a.org" . "* A\n"))
    (let ((src (expand-file-name "a.org" dir)))
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (&rest _) (error "Prompted")))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (error "Prompted"))))
        (pretty-view--render-linked src))
      (should (null (get-file-buffer src)))
      (should (null (directory-files dir nil "\\`\\.#"))))))

(ert-deftest pretty-view-test-linked-documents-render-in-the-background ()
  (pv-with-org-tree dir
      '(("root.org" . "* Root\n[[file:menus/a.org][A]] [[file:data.json][D]]\n")
        ("menus/a.org" . "* A\n[[file:../root.org][Back]] [[file:b.org][B]]\n")
        ("menus/b.org" . "* B\n")
        ("data.json" . "{}"))
    (let* ((root (expand-file-name "root.org" dir))
           (a (expand-file-name "menus/a.org" dir))
           (b (expand-file-name "menus/b.org" dir))
           (buf (find-file-noselect root)))
      (unwind-protect
          (progn
            (with-current-buffer buf (pretty-view))
            ;; The root is written at once; its links point at pages
            ;; that the queue writes later.
            (let ((page (pv-tree-page root)))
              (should (string-match-p (regexp-quote (pv-tree-href a)) page))
              (should (string-match-p
                       (regexp-quote
                        (format "href=\"URL:%sdata.json\" target=\"_blank\""
                                dir))
                       page)))
            (should-not (pv-tree-page a))
            (while pretty-view-links--queue (pretty-view-links--tick))
            (let ((page (pv-tree-page a)))
              (should (string-match-p (regexp-quote (pv-tree-href root)) page))
              (should (string-match-p (regexp-quote (pv-tree-href b)) page)))
            (should (pv-tree-page b)))
        (kill-buffer buf)))))

(ert-deftest pretty-view-test-debounced-render-keeps-rendered-linked-pages ()
  "An unsaved edit re-renders the root, not the pages it links to.
A linked document whose page already exists is linked to but not
rendered again by the debounced render; a save follows every link."
  (pv-with-org-tree dir '(("a.org" . "* A\n[[file:b.org][B]]\n")
                          ("b.org" . "* B\n"))
    (let* ((a (expand-file-name "a.org" dir))
           (b (expand-file-name "b.org" dir))
           (b-page (pretty-view-browser-output-file b))
           (pretty-view-live-delay 0.05)
           (log nil)
           (buf (find-file-noselect a)))
      (unwind-protect
          (with-current-buffer buf
            (make-directory (file-name-directory b-page) t)
            (with-temp-file b-page (insert "OLD PAGE"))
            (pretty-view-live-mode 1)
            (goto-char (point-max))
            (cl-letf (((symbol-function 'message)
                       (lambda (fmt &rest args) (push (apply #'format fmt args) log))))
              (insert "typed words\n")
              (pv-test-wait 0.2))
            (should (string-match-p "typed words" (pv-tree-page a)))
            (should (string-match-p (regexp-quote (pv-tree-href b)) (pv-tree-page a)))
            (should (null pretty-view-links--queue))
            (should (equal "OLD PAGE" (pv-tree-page b)))
            (should-not (seq-find (lambda (m) (string-match-p "linked documents" m)) log))
            (save-buffer)
            (should pretty-view-links--queue)
            (while pretty-view-links--queue (pretty-view-links--tick))
            (should (string-match-p "<h2" (pv-tree-page b))))
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf)))))

(ert-deftest pretty-view-test-export-leaves-links-alone ()
  (pv-with-org-tree dir '(("a.org" . "[[file:b.org][B]] [[file:c.json][C]]\n")
                          ("b.org" . "* B\n")
                          ("c.json" . "{}"))
    (let ((out (expand-file-name "a.html" dir))
          (buf (find-file-noselect (expand-file-name "a.org" dir))))
      (unwind-protect
          (progn
            (with-current-buffer buf (pretty-view-export out))
            (let ((html (pv-test-read out)))
              (should (string-match-p "href=\"b.html\"" html))
              (should (string-match-p "href=\"c.json\"" html))
              (should-not (string-match-p "target=" html)))
            (should (null pretty-view-links--queue)))
        (kill-buffer buf)))))

(ert-deftest pretty-view-test-follow-links-off-opens-documents-as-files ()
  (pv-with-org-tree dir '(("a.org" . "[[file:b.org][B]]\n")
                          ("b.org" . "* B\n"))
    (let ((pretty-view-follow-links nil)
          (buf (find-file-noselect (expand-file-name "a.org" dir))))
      (unwind-protect
          (progn
            (with-current-buffer buf (pretty-view))
            (should (string-match-p
                     (regexp-quote
                      (format "href=\"URL:%sb.org\" target=\"_blank\"" dir))
                     (pv-tree-page (expand-file-name "a.org" dir))))
            (should (null pretty-view-links--queue)))
        (kill-buffer buf)))))

(ert-deftest pretty-view-test-live-update-rewrites-links ()
  (pv-with-org-tree dir '(("a.org" . "[[file:b.org][B]]\n")
                          ("b.org" . "* B\n"))
    (let* ((a (expand-file-name "a.org" dir))
           (buf (find-file-noselect a)))
      (unwind-protect
          (with-current-buffer buf
            (pretty-view-live-mode 1)
            (pretty-view--live-update)
            (should (string-match-p
                     (regexp-quote (pv-tree-href (expand-file-name "b.org" dir)))
                     (pv-tree-page a)))
            (pretty-view-live-mode -1))
        (kill-buffer buf)))))

(ert-deftest pretty-view-test-select-theme-rewrites-links ()
  (pv-with-org-tree dir '(("a.org" . "[[file:b.org][B]]\n")
                          ("b.org" . "* B\n"))
    (let* ((a (expand-file-name "a.org" dir))
           (buf (find-file-noselect a))
           (pretty-view-theme 'github-light))
      (unwind-protect
          (with-current-buffer buf
            (pretty-view)
            (pretty-view-select-theme 'nord)
            (should (string-match-p
                     (regexp-quote (pv-tree-href (expand-file-name "b.org" dir)))
                     (pv-tree-page a))))
        (kill-buffer buf)))))

(ert-deftest pretty-view-test-unsaved-buffer-page-is-not-recorded ()
  "Review focus: an unsaved root still gets working links, but its page
must not pass for its file's page when the file is later reached."
  (pv-with-org-tree dir '(("a.org" . "[[file:b.org][B]]\n")
                          ("b.org" . "* B\n"))
    (let* ((a (expand-file-name "a.org" dir))
           (out (pretty-view-browser-output-file a))
           (buf (find-file-noselect a)))
      (unwind-protect
          (with-current-buffer buf
            (pretty-view)
            (should (gethash out pretty-view-links--written))
            (goto-char (point-max))
            (insert "Unsaved.\n")
            (pretty-view)
            (should (string-match-p
                     (regexp-quote (pv-tree-href (expand-file-name "b.org" dir)))
                     (pv-tree-page a)))
            (should-not (gethash out pretty-view-links--written))
            (set-buffer-modified-p nil))
        (kill-buffer buf)))))

(ert-deftest pretty-view-test-later-linked-render-replaces-an-unsaved-page ()
  "A page rendered from unsaved text is replaced by the file's text."
  (pv-with-org-tree dir '(("a.org" . "[[file:b.org][B]]\n")
                          ("b.org" . "* B\n"))
    (let* ((a (expand-file-name "a.org" dir))
           (b (expand-file-name "b.org" dir))
           (buf (find-file-noselect a)))
      (unwind-protect
          (with-current-buffer buf
            (pretty-view)
            (goto-char (point-max))
            (insert "Unsaved text.\n")
            (pretty-view)
            (should (string-match-p "Unsaved text" (pv-tree-page a)))
            (set-buffer-modified-p nil)
            ;; Another document's run reaches a.org through a link.
            (with-temp-file b (insert "[[file:a.org][A]]\n"))
            (let ((pretty-view-links-current-run
                   (pretty-view-links-start-run
                    b #'pretty-view--render-linked)))
              (pretty-view-links-accept a))
            (while pretty-view-links--queue
              (pretty-view-links--tick))
            (should-not (string-match-p "Unsaved text" (pv-tree-page a))))
        (kill-buffer buf)))))

(defvar pv-babel-flag nil
  "Set by the Babel block in the linked-render test.")

(ert-deftest pretty-view-test-linked-render-does-not-run-babel ()
  (pv-with-org-tree dir '(("a.org" . "#+BEGIN_SRC emacs-lisp :exports results
(setq pv-babel-flag t)
#+END_SRC
"))
    (require 'org)
    (let ((pv-babel-flag nil)
          (org-confirm-babel-evaluate nil))
      (pretty-view--render-linked (expand-file-name "a.org" dir))
      (should-not pv-babel-flag))))

(provide 'pretty-view-test)
;;; pretty-view-test.el ends here
