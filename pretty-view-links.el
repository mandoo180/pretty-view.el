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
that is not a regular file."
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
        (and (file-regular-p file) (cons file fragment))))))

(defun pretty-view-links--document-p (file)
  "Return non-nil when FILE's extension marks it as a document.
See `pretty-view-follow-links-extensions'."
  (let ((ext (file-name-extension file)))
    (and ext (member (downcase ext) pretty-view-follow-links-extensions) t)))

(defun pretty-view-links-rewrite (html base-directory accept)
  "Return HTML with its local links rewritten for the output directory.
BASE-DIRECTORY resolves relative links.  ACCEPT, when non-nil, is
called with the absolute file name of each linked document, one whose
extension is in `pretty-view-follow-links-extensions', and returns
the output file to link to, or nil.  A document ACCEPT declines, and
any other local file, is linked through a URL for the file itself that
opens in a new tab; see `pretty-view-browser-file-url'.  Remote,
same-page, and dangling links are left alone, as is everything when
BASE-DIRECTORY is remote."
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
               (local (pretty-view-links--local-file (match-string 1)
                                                     base-directory)))
          (when local
            (let* ((file (car local))
                   (output (and accept
                                (pretty-view-links--document-p file)
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

(provide 'pretty-view-links)
;;; pretty-view-links.el ends here
