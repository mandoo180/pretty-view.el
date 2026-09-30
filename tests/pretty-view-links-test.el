;;; pretty-view-links-test.el --- Tests for linked documents  -*- lexical-binding: t -*-

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
;; Link rewriting, and the background queue that renders linked
;; documents.  The queue is driven by calling its tick function
;; directly; no test waits on a real timer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'pretty-view-links)

(defmacro pv-links-with-tree (dir files &rest body)
  "Bind DIR to a fresh directory holding FILES, run BODY, delete it.
FILES are names relative to DIR; each is created with placeholder
contents, along with any directory it needs."
  (declare (indent 2))
  `(let ((,dir (file-name-as-directory (make-temp-file "pv-links" t))))
     (unwind-protect
         (progn
           (dolist (f ,files)
             (let ((path (expand-file-name f ,dir)))
               (make-directory (file-name-directory path) t)
               (with-temp-file path (insert "x"))))
           ,@body)
       (delete-directory ,dir t))))

(defmacro pv-links-with-urls (&rest body)
  "Run BODY with file URLs stubbed to \"URL:\" plus the file name."
  `(cl-letf (((symbol-function 'pretty-view-browser-file-url)
              (lambda (f) (concat "URL:" f))))
     ,@body))

(defun pv-links-accept-all (file)
  "Accept FILE, linking it to a fake output named after its base name."
  (concat "/out/" (file-name-base file) "-h.html"))

(defun pv-links-href (html)
  "Return the first href value in HTML."
  (and (string-match "href=\"\\([^\"]*\\)\"" html) (match-string 1 html)))

;;; Rewriting

(ert-deftest pretty-view-links-test-document-link-points-at-its-page ()
  (pv-links-with-tree dir '("sub/doc.md")
    (should (equal (pretty-view-links-rewrite
                    "<a href=\"sub/doc.md\">d</a>" dir #'pv-links-accept-all)
                   "<a href=\"doc-h.html\">d</a>"))))

(ert-deftest pretty-view-links-test-accept-gets-the-absolute-file ()
  (pv-links-with-tree dir '("sub/doc.md")
    (pv-links-with-urls
     (let (seen)
       (pretty-view-links-rewrite "<a href=\"sub/doc.md\">d</a>" dir
                                  (lambda (f) (push f seen) nil))
       (should (equal seen (list (expand-file-name "sub/doc.md" dir))))))))

(ert-deftest pretty-view-links-test-fragment-is-kept ()
  (pv-links-with-tree dir '("doc.md")
    (should (equal (pv-links-href
                    (pretty-view-links-rewrite
                     "<a href=\"doc.md#part-two\">d</a>" dir
                     #'pv-links-accept-all))
                   "doc-h.html#part-two"))))

(ert-deftest pretty-view-links-test-korean-names-raw-and-percent-encoded ()
  (pv-links-with-tree dir '("설명.md")
    (dolist (href '("설명.md" "%EC%84%A4%EB%AA%85.md"))
      (should (equal (pv-links-href
                      (pretty-view-links-rewrite
                       (format "<a href=\"%s\">d</a>" href) dir
                       #'pv-links-accept-all))
                     "%EC%84%A4%EB%AA%85-h.html")))))

(ert-deftest pretty-view-links-test-entities-are-decoded ()
  (pv-links-with-tree dir '("a&b.txt")
    (should (equal (pv-links-href
                    (pretty-view-links-rewrite
                     "<a href=\"a&amp;b.txt\">d</a>" dir
                     #'pv-links-accept-all))
                   "a%26b-h.html"))))

(ert-deftest pretty-view-links-test-spaces-and-upper-case-extension ()
  "Review focus: `Release Notes.MD' is a document, linked encoded."
  (pv-links-with-tree dir '("Release Notes.MD")
    (let (seen)
      (should (equal (pv-links-href
                      (pretty-view-links-rewrite
                       "<a href=\"Release%20Notes.MD\">n</a>" dir
                       (lambda (f) (push f seen) (pv-links-accept-all f))))
                     "Release%20Notes-h.html"))
      (should (equal seen
                     (list (expand-file-name "Release Notes.MD" dir)))))))

(ert-deftest pretty-view-links-test-other-links-are-untouched ()
  (pv-links-with-tree dir '("sub/doc.md")
    (pv-links-with-urls
     (dolist (html '("<a href=\"#top\">t</a>"
                     "<a href=\"\">e</a>"
                     "<a href=\"https://e.com/sub/doc.md\">r</a>"
                     "<a href=\"mailto:a@b.c\">m</a>"
                     "<a href=\"//cdn.example/sub/doc.md\">n</a>"
                     "<a href=\"missing.md\">x</a>"
                     "<a href=\"sub\">dir</a>"
                     "<a data-href=\"sub/doc.md\">no href</a>"))
       (should (equal (pretty-view-links-rewrite
                       html dir #'pv-links-accept-all)
                      html))))))

(ert-deftest pretty-view-links-test-other-files-open-in-a-new-tab ()
  (pv-links-with-tree dir '("data.json")
    (pv-links-with-urls
     (should (equal (pretty-view-links-rewrite
                     "<a href=\"data.json\">j</a>" dir #'pv-links-accept-all)
                    (format (concat "<a href=\"URL:%sdata.json\""
                                    " target=\"_blank\" rel=\"noopener\">j</a>")
                            dir))))))

(ert-deftest pretty-view-links-test-other-file-keeps-fragment-drops-query ()
  "Review focus: a query and an escaped `&' do not break the link."
  (pv-links-with-tree dir '("data.json" "manual.pdf")
    (pv-links-with-urls
     (should (equal (pv-links-href
                     (pretty-view-links-rewrite
                      "<a href=\"data.json?x=1&amp;y=2#k\">j</a>" dir nil))
                    (concat "URL:" dir "data.json#k")))
     (should (equal (pv-links-href
                     (pretty-view-links-rewrite
                      "<a href=\"manual.pdf#page=3\">p</a>" dir nil))
                    (concat "URL:" dir "manual.pdf#page=3"))))))

(ert-deftest pretty-view-links-test-existing-target-is-kept ()
  (pv-links-with-tree dir '("data.json")
    (pv-links-with-urls
     (let ((html (pretty-view-links-rewrite
                  "<a href=\"data.json\" target=\"_self\">j</a>" dir nil)))
       (should (string-match-p "target=\"_self\"" html))
       (should-not (string-match-p "_blank" html))))))

(ert-deftest pretty-view-links-test-declined-document-opens-the-file ()
  (pv-links-with-tree dir '("doc.md")
    (pv-links-with-urls
     (dolist (accept (list nil #'ignore))
       (should (equal (pretty-view-links-rewrite
                       "<a href=\"doc.md\">d</a>" dir accept)
                      (format (concat "<a href=\"URL:%sdoc.md\""
                                      " target=\"_blank\""
                                      " rel=\"noopener\">d</a>")
                              dir)))))))

(ert-deftest pretty-view-links-test-extensions-option ()
  (pv-links-with-tree dir '("notes.txt")
    (pv-links-with-urls
     (let ((pretty-view-follow-links-extensions '("md")))
       (should (string-prefix-p
                "URL:"
                (pv-links-href (pretty-view-links-rewrite
                                "<a href=\"notes.txt\">n</a>" dir
                                #'pv-links-accept-all))))))))

(ert-deftest pretty-view-links-test-file-url-href ()
  (pv-links-with-tree dir '("doc.md")
    (should (equal (pv-links-href
                    (pretty-view-links-rewrite
                     (format "<a href=\"file://%sdoc.md\">d</a>" dir) dir
                     #'pv-links-accept-all))
                   "doc-h.html"))))

(ert-deftest pretty-view-links-test-other-attributes-survive ()
  (pv-links-with-tree dir '("doc.md")
    (should (equal (pretty-view-links-rewrite
                    "<a class=\"c\" href=\"doc.md\" title=\"t\">d</a>" dir
                    #'pv-links-accept-all)
                   "<a class=\"c\" href=\"doc-h.html\" title=\"t\">d</a>"))))

(ert-deftest pretty-view-links-test-every-link-is-rewritten ()
  "Review focus: one document linked twice, amid other text."
  (pv-links-with-tree dir '("doc.md")
    (should (equal (pretty-view-links-rewrite
                    (concat "<p><a href=\"doc.md\">1</a> and "
                            "<a href=\"doc.md#b\">2</a></p>")
                    dir #'pv-links-accept-all)
                   (concat "<p><a href=\"doc-h.html\">1</a> and "
                           "<a href=\"doc-h.html#b\">2</a></p>")))))

(ert-deftest pretty-view-links-test-remote-base-is-left-alone ()
  (let ((html "<a href=\"doc.md\">d</a>"))
    (should (equal (pretty-view-links-rewrite
                    html "/ssh:host:/x/" #'pv-links-accept-all)
                   html))))

;;; Guarded resolution

(ert-deftest pretty-view-links-test-tramp-shaped-href-is-untouched ()
  (pv-links-with-tree dir '("doc.md")
    (let ((html "<a href=\"/ssh:pv-probe-host.invalid:/x.md\">d</a>"))
      (cl-letf (((symbol-function 'file-regular-p)
                 (lambda (f)
                   (when (file-remote-p f)
                     (error "Connected to %s" f))
                   nil)))
        (should (equal (pretty-view-links-rewrite
                        html dir #'pv-links-accept-all)
                       html))))))

(ert-deftest pretty-view-links-test-malformed-href-leaves-only-that-link ()
  (pv-links-with-tree dir '("doc.md")
    (should (equal (pretty-view-links-rewrite
                    (concat "<a href=\"a%00b.md\">x</a>"
                            "<a href=\"doc.md\">d</a>")
                    dir #'pv-links-accept-all)
                   (concat "<a href=\"a%00b.md\">x</a>"
                           "<a href=\"doc-h.html\">d</a>")))))

(ert-deftest pretty-view-links-test-oversized-document-opens-the-file ()
  (pv-links-with-tree dir '("doc.md")
    (pv-links-with-urls
     (let* ((html "<a href=\"doc.md\">d</a>")
            (accepted nil)
            (accept (lambda (f) (push f accepted) "/out/doc-h.html")))
       (let ((pretty-view-follow-links-max-size 0))
         (should (string-match-p
                  "href=\"URL:.*doc\\.md\" target=\"_blank\""
                  (pretty-view-links-rewrite html dir accept)))
         (should-not accepted))
       (let ((pretty-view-follow-links-max-size 1))
         (should (equal (pretty-view-links-rewrite html dir accept)
                        "<a href=\"doc-h.html\">d</a>"))
         (should (= (length accepted) 1)))))))

;;; Queue

(defvar pv-queue-rendered nil
  "Sources the fake render function was called with, in order.")

(defmacro pv-queue-test (&rest body)
  "Run BODY with an empty queue and page table, and fresh output."
  `(let ((pretty-view-links--queue nil)
         (pretty-view-links--queued (make-hash-table :test #'equal))
         (pretty-view-links--timer nil)
         (pretty-view-links--written (make-hash-table :test #'equal))
         (pretty-view-links-current-run nil)
         (pretty-view-output-directory (make-temp-file "pv-out" t))
         (pv-queue-rendered nil))
     (unwind-protect (progn ,@body)
       (pretty-view-links-reset)
       (delete-directory pretty-view-output-directory t))))

(defun pv-queue-render (graph)
  "Return a fake render function over GRAPH.
GRAPH is an alist (SOURCE . LINKED-SOURCES).  Rendering SOURCE records
it in `pv-queue-rendered', accepts each linked source as link
rewriting would, and returns the resulting links as the page's HTML."
  (lambda (source)
    (setq pv-queue-rendered (append pv-queue-rendered (list source)))
    (mapconcat (lambda (s) (or (pretty-view-links-accept s) "declined"))
               (cdr (assoc source graph))
               "\n")))

(defun pv-queue-start (root graph)
  "Start a run at ROOT over GRAPH and accept ROOT's links; return it."
  (let ((pretty-view-links-current-run
         (pretty-view-links-start-run root (pv-queue-render graph))))
    (dolist (s (cdr (assoc root graph)))
      (pretty-view-links-accept s))
    pretty-view-links-current-run))

(defun pv-queue-drain ()
  "Tick the queue until it is empty."
  (while pretty-view-links--queue
    (pretty-view-links--tick)))

(defun pv-queue-page (source)
  "Return the contents of SOURCE's output file, or nil when absent."
  (let ((out (pretty-view-browser-output-file source)))
    (and (file-exists-p out)
         (with-temp-buffer (insert-file-contents out) (buffer-string)))))

(defmacro pv-queue-capturing (log &rest body)
  "Run BODY, pushing every formatted `message' onto the list LOG."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'message)
              (lambda (fmt &rest args)
                (push (apply #'format fmt args) ,log))))
     ,@body))

(ert-deftest pretty-view-links-test-accept-without-a-run ()
  (pv-queue-test
   (should (null (pretty-view-links-accept "/s/a.md")))
   (should (null pretty-view-links--queue))))

(ert-deftest pretty-view-links-test-queue-renders-breadth-first ()
  (pv-queue-test
   (pv-queue-start "/s/root.md" '(("/s/root.md" "/s/a.md" "/s/b.md")
                                  ("/s/a.md" "/s/c.md")))
   (pv-queue-drain)
   (should (equal pv-queue-rendered '("/s/a.md" "/s/b.md" "/s/c.md")))
   (should (pv-queue-page "/s/c.md"))))

(ert-deftest pretty-view-links-test-queue-survives-a-cycle ()
  (pv-queue-test
   (pv-queue-start "/s/root.md" '(("/s/root.md" "/s/a.md")
                                  ("/s/a.md" "/s/b.md")
                                  ("/s/b.md" "/s/a.md" "/s/root.md")))
   (pv-queue-drain)
   (should (equal pv-queue-rendered '("/s/a.md" "/s/b.md")))))

(ert-deftest pretty-view-links-test-back-link-to-root-is-linked-not-queued ()
  (pv-queue-test
   (let ((run (pv-queue-start "/s/root.md" '(("/s/root.md" "/s/a.md")
                                              ("/s/a.md" "/s/root.md")))))
     (pv-queue-drain)
     (should (equal (pv-queue-page "/s/a.md")
                    (pretty-view-browser-output-file "/s/root.md")))
     (should (= (pretty-view-links--run-count run) 1)))))

(ert-deftest pretty-view-links-test-self-link-is-not-queued ()
  "Review focus: a root linking to itself, as a `#section' link would."
  (pv-queue-test
   (let ((pretty-view-links-current-run
          (pretty-view-links-start-run "/s/root.md" #'ignore)))
     (should (equal (pretty-view-links-accept "/s/root.md")
                    (pretty-view-browser-output-file "/s/root.md")))
     (should (null pretty-view-links--queue)))))

(ert-deftest pretty-view-links-test-document-linked-twice-is-queued-once ()
  "Review focus: the same document linked from several places."
  (pv-queue-test
   (pv-queue-start "/s/root.md"
                   '(("/s/root.md" "/s/a.md" "/s/a.md" "/s/a.md")))
   (should (= (length pretty-view-links--queue) 1))))

(ert-deftest pretty-view-links-test-runs-share-queued-documents ()
  (pv-queue-test
   (pv-queue-start "/s/one.md" '(("/s/one.md" "/s/a.md")))
   (let ((two (pv-queue-start "/s/two.md" '(("/s/two.md" "/s/a.md")))))
     (should (= (length pretty-view-links--queue) 1))
     (should (= (pretty-view-links--run-pending two) 0)))))

(ert-deftest pretty-view-links-test-limit-declines-and-is-reported ()
  (pv-queue-test
   (let ((pretty-view-follow-links-limit 2)
         (log nil))
     (pv-queue-capturing log
       (let ((run (pv-queue-start
                   "/s/root.md"
                   '(("/s/root.md" "/s/a.md" "/s/b.md" "/s/c.md")))))
         (should (pretty-view-links--run-limit-hit run))
         (should (= (length pretty-view-links--queue) 2))
         (pv-queue-drain)
         (should (equal (car log)
                        (concat "pretty-view: linked documents — "
                                "2 written, 0 unchanged, 0 failed; "
                                "stopped after 2 linked documents; "
                                "see pretty-view-follow-links-limit"))))))))

(ert-deftest pretty-view-links-test-unchanged-page-is-not-rewritten ()
  (pv-queue-test
   (let ((graph '(("/s/root.md" "/s/a.md") ("/s/a.md" "/s/c.md"))))
     (pv-queue-start "/s/root.md" graph)
     (pv-queue-drain)
     ;; Mark a's page: if the second run rewrote it, the mark would go.
     (with-temp-file (pretty-view-browser-output-file "/s/a.md")
       (insert "MARK"))
     (setq pv-queue-rendered nil)
     (let ((run (pv-queue-start "/s/root.md" graph)))
       (pv-queue-drain)
       (should (equal (pv-queue-page "/s/a.md") "MARK"))
       ;; Its links were still followed.
       (should (equal pv-queue-rendered '("/s/a.md" "/s/c.md")))
       (should (= (pretty-view-links--run-unchanged run) 2))
       (should (= (pretty-view-links--run-written run) 0))))))

(ert-deftest pretty-view-links-test-no-op-run-logs-no-summary ()
  (pv-queue-test
   (let ((graph '(("/s/root.md" "/s/a.md")))
         (log nil))
     (pv-queue-start "/s/root.md" graph)
     (pv-queue-drain)
     (pv-queue-capturing log
       (pv-queue-start "/s/root.md" graph)
       (pv-queue-drain))
     (should-not (seq-some (lambda (m) (string-search "linked documents" m))
                           log)))))

(ert-deftest pretty-view-links-test-changed-page-is-rewritten ()
  (pv-queue-test
   (let* ((version 1)
          (render (lambda (s) (format "%s v%d" s version))))
     (dotimes (_ 2)
       (let ((pretty-view-links-current-run
              (pretty-view-links-start-run "/s/root.md" render)))
         (pretty-view-links-accept "/s/a.md"))
       (pv-queue-drain)
       (should (equal (pv-queue-page "/s/a.md")
                      (format "/s/a.md v%d" version)))
       (setq version 2)))))

(ert-deftest pretty-view-links-test-deleted-page-is-rewritten ()
  (pv-queue-test
   (let ((graph '(("/s/root.md" "/s/a.md"))))
     (pv-queue-start "/s/root.md" graph)
     (pv-queue-drain)
     (delete-file (pretty-view-browser-output-file "/s/a.md"))
     (pv-queue-start "/s/root.md" graph)
     (pv-queue-drain)
     (should (pv-queue-page "/s/a.md")))))

(ert-deftest pretty-view-links-test-failure-is-isolated-and-logged ()
  (pv-queue-test
   (let ((log nil))
     (pv-queue-capturing log
       (let* ((render (lambda (s)
                        (if (equal s "/s/a.md") (error "Boom") "ok")))
              (run (pretty-view-links-start-run "/s/root.md" render)))
         (let ((pretty-view-links-current-run run))
           (pretty-view-links-accept "/s/a.md")
           (pretty-view-links-accept "/s/b.md"))
         (pv-queue-drain)
         (should (= (pretty-view-links--run-failed run) 1))
         (should (= (pretty-view-links--run-written run) 1))
         (should (pv-queue-page "/s/b.md"))
         (should (seq-some (lambda (m)
                             (string-match-p
                              "could not render /s/a\\.md (Boom)" m))
                           log)))))))

(ert-deftest pretty-view-links-test-quit-in-a-render-clears-the-queue ()
  (pv-queue-test
   (let ((log nil))
     (pv-queue-capturing log
       (let ((pretty-view-links-current-run
              (pretty-view-links-start-run
               "/s/root.md" (lambda (_s) (signal 'quit nil)))))
         (pretty-view-links-accept "/s/a.md")
         (pretty-view-links-accept "/s/b.md"))
       (pretty-view-links--tick))
     (should (null pretty-view-links--queue))
     (should (zerop (hash-table-count pretty-view-links--queued)))
     (should (null pretty-view-links--timer))
     (should (member "pretty-view: linked documents cancelled" log)))))

(ert-deftest pretty-view-links-test-live-mode-page-is-left-to-live-mode ()
  (pv-queue-test
   (let* ((src (make-temp-file "pv-live" nil ".txt"))
          (out (pretty-view-browser-output-file src))
          (buf (find-file-noselect src)))
     (unwind-protect
         (progn
           (with-current-buffer buf (setq-local pretty-view-live-mode t))
           (with-temp-file out (insert "LIVE PAGE"))
           (let ((run (pretty-view-links-start-run
                       nil (lambda (_s) "background"))))
             (let ((pretty-view-links-current-run run))
               (pretty-view-links-accept src))
             (pv-queue-drain)
             (should (equal (pv-queue-page src) "LIVE PAGE"))
             (should (= (pretty-view-links--run-unchanged run) 1)))
           ;; With no page yet, the background writes one.
           (delete-file out)
           (let ((pretty-view-links-current-run
                  (pretty-view-links-start-run
                   nil (lambda (_s) "background"))))
             (pretty-view-links-accept src))
           (pv-queue-drain)
           (should (equal (pv-queue-page src) "background")))
       (kill-buffer buf)
       (delete-file src)))))

(ert-deftest pretty-view-links-test-summary-counts ()
  (pv-queue-test
   (let ((log nil))
     (pv-queue-capturing log
       (pv-queue-start "/s/root.md" '(("/s/root.md" "/s/a.md" "/s/b.md")))
       (pv-queue-drain))
     (should (equal (car log)
                    (concat "pretty-view: linked documents — "
                            "2 written, 0 unchanged, 0 failed")))
     (should (member "pretty-view: rendering linked documents 1/2" log)))))

(ert-deftest pretty-view-links-test-quiet-while-minibuffer-is-active ()
  (pv-queue-test
   (let ((log nil))
     (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () t))
               ((symbol-function 'message)
                (lambda (fmt &rest args)
                  (push (cons inhibit-message (apply #'format fmt args))
                        log))))
       (pv-queue-start "/s/root.md" '(("/s/root.md" "/s/a.md" "/s/b.md")))
       (pv-queue-drain))
     ;; No progress; the summary is logged but not displayed.
     (should (= (length log) 1))
     (should (car (car log)))
     (should (string-match-p "2 written" (cdr (car log)))))))

(ert-deftest pretty-view-links-test-pending-input-defers-the-work ()
  (pv-queue-test
   (pv-queue-start "/s/root.md" '(("/s/root.md" "/s/a.md")))
   (cl-letf (((symbol-function 'input-pending-p) (lambda (&rest _) t)))
     (pretty-view-links--tick))
   (should (= (length pretty-view-links--queue) 1))
   (should (null pv-queue-rendered))
   (should (timerp pretty-view-links--timer))))

(ert-deftest pretty-view-links-test-tick-reschedules-itself-at-10-ms ()
  "A render that queues a document must not make the next tick due now."
  (pv-queue-test
   (let ((scheduled nil)
         (cancelled nil))
     (cl-letf (((symbol-function 'run-at-time)
                (lambda (delay &rest _)
                  (let ((timer (timer-create)))
                    (push (cons delay timer) scheduled)
                    timer)))
               ((symbol-function 'cancel-timer)
                (lambda (timer) (push timer cancelled)))
               ((symbol-function 'input-pending-p) (lambda (&rest _) nil))
               ((symbol-function 'time-less-p) (lambda (&rest _) nil)))
       ;; root links a and b; rendering a queues c.
       (pv-queue-start "/s/root.md" '(("/s/root.md" "/s/a.md" "/s/b.md")
                                      ("/s/a.md" "/s/c.md")))
       (setq scheduled nil cancelled nil)
       (pretty-view-links--tick)
       (should (equal pv-queue-rendered '("/s/a.md")))
       (should (= (length pretty-view-links--queue) 2))
       (let ((live (seq-remove (lambda (entry) (memq (cdr entry) cancelled))
                               scheduled)))
         (should (equal (mapcar #'car live) '(0.01)))
         (should (eq (cdr (car live)) pretty-view-links--timer)))))))

(ert-deftest pretty-view-links-test-bookkeeping-error-clears-the-queue ()
  (pv-queue-test
   (let ((log nil))
     (pv-queue-start "/s/root.md" '(("/s/root.md" "/s/a.md" "/s/b.md")))
     (pv-queue-capturing log
       (cl-letf (((symbol-function 'pretty-view-links--report)
                  (lambda (_run) (error "Bug"))))
         (pretty-view-links--tick)))
     (should (null pretty-view-links--queue))
     (should (zerop (hash-table-count pretty-view-links--queued)))
     (should (null pretty-view-links--timer))
     (should (string-match-p "linked documents stopped (Bug)" (car log))))))

(ert-deftest pretty-view-links-test-write-creates-directory-and-records ()
  (pv-queue-test
   (let ((file (expand-file-name "deep/er/p.html"
                                 pretty-view-output-directory)))
     (pretty-view-links-write file "<p>é</p>")
     (should (file-exists-p file))
     (should (pretty-view-links--unchanged-p file "<p>é</p>"))
     (should-not (pretty-view-links--unchanged-p file "<p>e</p>")))))

(provide 'pretty-view-links-test)
;;; pretty-view-links-test.el ends here
