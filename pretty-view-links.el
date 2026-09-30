;;; pretty-view-links.el --- Make local links work from the output directory  -*- lexical-binding: t -*-

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

;; Rendered pages live in a temporary directory, so a relative link in
;; one resolves against that directory and breaks.  This file rewrites
;; each local link: a link to another document points at that
;; document's rendered page, and a link to any other file points at the
;; file itself, through a URL the browser can open.
;;
;; Linked documents are rendered in the background, one timer tick at a
;; time, so Emacs stays responsive while a large set is written.  A page
;; is only rewritten when its HTML changed, because writing is what
;; costs time on the Windows drive that WSL output goes to.

;;; Code:

(require 'cl-lib)
(require 'url-util)
(require 'pretty-view-render)
(require 'pretty-view-browser)

(defcustom pretty-view-follow-links t
  "Whether to render the local documents a rendered page links to.
When non-nil, a link to a file whose extension is in
`pretty-view-follow-links-extensions' points at that file's rendered
page, which is written in the background.  When nil, such a link
opens the file itself in a new tab, like a link to any other file."
  :type 'boolean
  :group 'pretty-view)

(defcustom pretty-view-follow-links-limit 200
  "Most linked documents that one render follows.
Links are followed breadth-first from the rendered document.  Past
this many documents, further links open the linked file itself."
  :type 'integer
  :group 'pretty-view)

(defcustom pretty-view-follow-links-extensions '("md" "markdown" "org" "txt")
  "Lower-case extensions of the linked files that are rendered.
Extensions are compared case-insensitively."
  :type '(repeat string)
  :group 'pretty-view)

(defcustom pretty-view-follow-links-max-size 1000000
  "Largest linked document, in bytes, that is rendered.
A linked document bigger than this is not rendered in the background,
because one huge file would keep Emacs busy for a long time.  A link
to it opens the file itself in a new tab, like a link to any other
file."
  :type 'integer
  :group 'pretty-view)

;; Rewriting

(defconst pretty-view-links--anchor-re
  "<a[ \t\n]\\(?:[^>]*?[ \t\n]\\)?href=\"\\([^\"]*\\)\"[^>]*>"
  "Match an opening `a' tag with a double-quoted `href'.
Group 1 is the attribute value.")

(defun pretty-view-links--unescape (string)
  "Return STRING with the entities `pretty-view-escape-html' writes decoded."
  (let ((s string))
    (dolist (pair '(("&lt;" . "<") ("&gt;" . ">") ("&quot;" . "\"")
                    ("&#39;" . "'") ("&amp;" . "&")))
      (setq s (string-replace (car pair) (cdr pair) s)))
    s))

(defun pretty-view-links--decode (path)
  "Return PATH with its percent-escapes decoded as UTF-8."
  (if (string-search "%" path)
      (decode-coding-string
       (url-unhex-string (encode-coding-string path 'utf-8)) 'utf-8)
    path))

(defun pretty-view-links--local-file (href base-directory)
  "Return (FILE . FRAGMENT) when HREF names an existing local file.
HREF is an attribute value as rendered, still entity-escaped.  FILE is
its absolute file name, resolved against BASE-DIRECTORY, and FRAGMENT
its `#' part, or the empty string.  Return nil for a URL with a scheme
other than `file:', a network-path or same-page reference, and a name
that is not a regular file or that resolves to a remote file name."
  (let* ((href (pretty-view-links--unescape href))
         (hash (string-search "#" href))
         (fragment (if hash (substring href hash) ""))
         (path (substring href 0 hash))
         (query (string-search "?" path))
         (path (substring path 0 query)))
    (cond
     ((string-match "\\`file:\\(?://\\)?" path)
      (setq path (substring path (match-end 0))))
     ((string-match-p "\\`\\(?:[a-zA-Z][a-zA-Z0-9+.-]*:\\|//\\)" path)
      (setq path "")))
    (unless (string-empty-p path)
      (let ((file (expand-file-name (pretty-view-links--decode path)
                                    base-directory)))
        ;; Syntax only: a remote name must never start a connection.
        (and (not (file-remote-p file))
             (file-regular-p file)
             (cons file fragment))))))

(defun pretty-view-links--document-p (file)
  "Return non-nil when FILE's extension marks it as a document.
See `pretty-view-follow-links-extensions'."
  (let ((ext (file-name-extension file)))
    (and ext (member (downcase ext) pretty-view-follow-links-extensions) t)))

(defun pretty-view-links--followable-p (file)
  "Return non-nil when FILE is a document small enough to be rendered."
  (and (pretty-view-links--document-p file)
       (let ((size (file-attribute-size (file-attributes file))))
         (and size (<= size pretty-view-follow-links-max-size)))))

(defun pretty-view-links-rewrite (html base-directory accept)
  "Return HTML with its local links rewritten for the output directory.
BASE-DIRECTORY resolves relative links.  ACCEPT, when non-nil, is
called with the absolute file name of each linked document, one whose
extension is in `pretty-view-follow-links-extensions' and whose size is
at most `pretty-view-follow-links-max-size', and returns
the output file to link to, or nil.  A document ACCEPT declines, and
any other local file, is linked through a URL for the file itself that
opens in a new tab; see `pretty-view-browser-file-url'.  Remote,
same-page, and dangling links are left alone, as is everything when
BASE-DIRECTORY is remote.  A link that cannot be resolved is left alone."
  (if (file-remote-p base-directory)
      html
    (with-temp-buffer
      (insert html)
      (goto-char (point-min))
      (while (re-search-forward pretty-view-links--anchor-re nil t)
        (let* ((tag-end (copy-marker (match-end 0)))
               (tag (match-string 0))
               (beg (match-beginning 1))
               (end (match-end 1))
               (local (condition-case nil
                          (pretty-view-links--local-file (match-string 1)
                                                         base-directory)
                        (error nil))))
          (when local
            (let* ((file (car local))
                   (output (and accept
                                (pretty-view-links--followable-p file)
                                (funcall accept file))))
              ;; The tag's end is edited first, so BEG and END still
              ;; hold when the href is replaced.
              (unless (or output (string-match-p "[ \t\n]target=" tag))
                (goto-char (1- tag-end))
                (insert " target=\"_blank\" rel=\"noopener\""))
              (goto-char beg)
              (delete-region beg end)
              (insert (pretty-view-escape-attribute
                       (concat (if output
                                   (url-hexify-string
                                    (file-name-nondirectory output))
                                 (pretty-view-browser-file-url file))
                               (cdr local))))))
          (goto-char tag-end)
          (set-marker tag-end nil)))
      (buffer-string))))

;; Runs and the background queue

(cl-defstruct (pretty-view-links--run
               (:constructor pretty-view-links--make-run)
               (:copier nil))
  "One render's walk over the documents it links to, and its tallies."
  (render nil)
  (visited (make-hash-table :test #'equal))
  (count 0)
  (limit-hit nil)
  (pending 0)
  (written 0)
  (unchanged 0)
  (failed 0))

(defvar pretty-view-links-current-run nil
  "The run that the document being rendered belongs to, or nil.
`pretty-view-links-accept' queues linked documents into this run.")

(defvar pretty-view-links--queue nil
  "Documents waiting to be rendered, oldest first.
Each entry is a list (SOURCE OUTPUT RUN).")

(defvar pretty-view-links--queued (make-hash-table :test #'equal)
  "Output files that have an entry in `pretty-view-links--queue'.")

(defvar pretty-view-links--timer nil
  "The timer for the next tick of the queue, or nil.")

(defvar pretty-view-links--written (make-hash-table :test #'equal)
  "Map an output file to the SHA-1 of the HTML last written to it.")

(defun pretty-view-links-start-run (root render)
  "Return a new run for ROOT that renders linked documents with RENDER.
ROOT is the rendered document's absolute file name, or nil when it has
none.  RENDER is called with a linked document's absolute file name
while `pretty-view-links-current-run' is bound to the run, and returns
the document's HTML."
  (let ((run (pretty-view-links--make-run :render render)))
    (when root
      (puthash root t (pretty-view-links--run-visited run)))
    run))

(defun pretty-view-links-accept (source)
  "Return the output file to link SOURCE to, queueing SOURCE when new.
SOURCE is a linked document's absolute file name.  Return nil when no
run is current, or when the current run has already accepted
`pretty-view-follow-links-limit' documents."
  (let ((run pretty-view-links-current-run))
    (when run
      (let ((visited (pretty-view-links--run-visited run))
            (output (pretty-view-browser-output-file source)))
        (cond
         ((gethash source visited) output)
         ((>= (pretty-view-links--run-count run)
              pretty-view-follow-links-limit)
          (setf (pretty-view-links--run-limit-hit run) t)
          nil)
         (t
          (puthash source t visited)
          (cl-incf (pretty-view-links--run-count run))
          (pretty-view-links--enqueue source output run)
          output))))))

(defun pretty-view-links--enqueue (source output run)
  "Queue SOURCE, rendered to OUTPUT, for RUN, unless OUTPUT is queued."
  (unless (gethash output pretty-view-links--queued)
    (puthash output t pretty-view-links--queued)
    (cl-incf (pretty-view-links--run-pending run))
    (setq pretty-view-links--queue
          (nconc pretty-view-links--queue (list (list source output run))))
    (pretty-view-links--schedule 0)))

(defun pretty-view-links--schedule (delay)
  "Run the next tick of the queue in DELAY seconds, unless one is due."
  (unless pretty-view-links--timer
    (setq pretty-view-links--timer
          (run-at-time delay nil #'pretty-view-links--tick))))

(defun pretty-view-links-reset ()
  "Drop every queued document and cancel the pending tick."
  (when pretty-view-links--timer
    (cancel-timer pretty-view-links--timer))
  (setq pretty-view-links--timer nil
        pretty-view-links--queue nil)
  (clrhash pretty-view-links--queued))

(defun pretty-view-links--tick ()
  "Process queued documents for up to 50 ms, then yield to the user.
Pending input postpones the work.  An error outside any one document
clears the queue, so the next render starts from a clean state, and so
does a quit."
  ;; Called directly rather than by its timer, the tick must not leave
  ;; that timer to fire later.
  (when pretty-view-links--timer
    (cancel-timer pretty-view-links--timer)
    (setq pretty-view-links--timer nil))
  (condition-case err
      (if (input-pending-p)
          (pretty-view-links--schedule 0.2)
        (let ((deadline (time-add nil 0.05)))
          (while (progn
                   (pretty-view-links--process (pop pretty-view-links--queue))
                   (and pretty-view-links--queue
                        (not (input-pending-p))
                        (time-less-p nil deadline)))))
        (when pretty-view-links--queue
          ;; A render may have queued documents, which scheduled a tick
          ;; for now; the tick after this one is due 0.01 s from now.
          (when pretty-view-links--timer
            (cancel-timer pretty-view-links--timer)
            (setq pretty-view-links--timer nil))
          (pretty-view-links--schedule 0.01)))
    (quit
     ;; A prompt during a render let the user quit; drop the work.
     (pretty-view-links-reset)
     (pretty-view-links--log "pretty-view: linked documents cancelled"))
    (error
     (pretty-view-links-reset)
     (pretty-view-links--log "pretty-view: linked documents stopped (%s)"
                             (error-message-string err)))))

(defun pretty-view-links--process (item)
  "Render ITEM, a queue entry (SOURCE OUTPUT RUN), and write it if changed."
  (when item
    (let ((source (nth 0 item))
          (output (nth 1 item))
          (run (nth 2 item)))
      (remhash output pretty-view-links--queued)
      (condition-case err
          (let ((html (let ((pretty-view-links-current-run run))
                        (funcall (pretty-view-links--run-render run) source))))
            (if (or (pretty-view-links--owned-by-live-mode-p source output)
                    (pretty-view-links--unchanged-p output html))
                (cl-incf (pretty-view-links--run-unchanged run))
              (pretty-view-links-write output html)
              (cl-incf (pretty-view-links--run-written run))))
        (error
         (cl-incf (pretty-view-links--run-failed run))
         (pretty-view-links--log "pretty-view: could not render %s (%s)"
                                 source (error-message-string err))))
      (cl-decf (pretty-view-links--run-pending run))
      (pretty-view-links--report run))))

(defun pretty-view-links--owned-by-live-mode-p (source output)
  "Return non-nil when a live-mode buffer maintains OUTPUT for SOURCE.
That buffer's saves write the page with the watcher that reloads it,
which a background write would drop."
  (let ((buffer (find-buffer-visiting source)))
    (and buffer
         (local-variable-p 'pretty-view-live-mode buffer)
         (buffer-local-value 'pretty-view-live-mode buffer)
         (file-exists-p output))))

;; Unchanged pages

(defun pretty-view-links--hash (html)
  "Return the SHA-1 of HTML's UTF-8 encoding."
  (secure-hash 'sha1 (encode-coding-string html 'utf-8)))

(defun pretty-view-links-record (file html)
  "Remember that FILE now holds HTML."
  (puthash file (pretty-view-links--hash html) pretty-view-links--written))

(defun pretty-view-links--unchanged-p (output html)
  "Return non-nil when OUTPUT exists and last received exactly HTML."
  (and (equal (gethash output pretty-view-links--written)
              (pretty-view-links--hash html))
       (file-exists-p output)))

(defun pretty-view-links-write (file html)
  "Write HTML to FILE, creating its directory, and record it."
  (let ((coding-system-for-write 'utf-8-unix))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert html)))
  (pretty-view-links-record file html))

;; Messages

(defun pretty-view-links--log (format-string &rest args)
  "Log the message that FORMAT-STRING and ARGS make.
While the minibuffer is active the message only goes to `*Messages*',
so it never covers a prompt."
  (let ((inhibit-message (or inhibit-message
                             (and (active-minibuffer-window) t))))
    (apply #'message format-string args)))

(defun pretty-view-links--report (run)
  "Show RUN's progress, or its summary once nothing of it is pending."
  (let* ((written (pretty-view-links--run-written run))
         (unchanged (pretty-view-links--run-unchanged run))
         (failed (pretty-view-links--run-failed run))
         (done (+ written unchanged failed))
         (pending (pretty-view-links--run-pending run)))
    (cond
     ((> pending 0)
      (unless (active-minibuffer-window)
        (let ((message-log-max nil))
          (message "pretty-view: rendering linked documents %d/%d"
                   done (+ done pending)))))
     ;; A run that changed nothing and hit no limit has nothing to say.
     ((and (zerop written) (zerop failed)
           (not (pretty-view-links--run-limit-hit run))))
     (t
      (pretty-view-links--log
       "pretty-view: linked documents — %d written, %d unchanged, %d failed%s"
       written unchanged failed
       (if (pretty-view-links--run-limit-hit run)
           (format (concat "; stopped after %d linked documents; "
                          "see pretty-view-follow-links-limit")
                   pretty-view-follow-links-limit)
         ""))))))

(provide 'pretty-view-links)
;;; pretty-view-links.el ends here
