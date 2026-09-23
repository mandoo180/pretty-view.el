;;; pretty-view.el --- Render Org, Markdown, and text to styled HTML  -*- lexical-binding: t -*-

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

;; `M-x pretty-view' renders the current Org, Markdown, or plain-text
;; buffer to a self-contained HTML file and opens it in the operating
;; system's browser.  `M-x pretty-view-live-mode' regenerates on every
;; save, and the browser tab reloads only when the output changed.
;;
;; Everything is replaceable: `pretty-view-theme' picks the look,
;; `pretty-view-renderers' and `pretty-view-org-transcoders' replace how
;; any single element renders, and `pretty-view-head-functions' adds to
;; the document head.  Nothing outside Emacs is required.

;; Author: Kyeong Soo Choi <mandoo180@users.noreply.github.com>
;; Maintainer: Kyeong Soo Choi <mandoo180@users.noreply.github.com>
;; URL: https://github.com/mandoo180/pretty-view.el
;; Version: 0.1.0
;; The dependency name below must stay lowercase -- `package.el' only
;; recognizes the symbol `emacs', not `Emacs' -- so the leading
;; backslash is deliberate: it keeps checkdoc's prose rule that "emacs"
;; should read "Emacs" from misfiring on this machine-read header.
;; Package-Requires: ((\emacs "29.1"))
;; Keywords: outlines, hypermedia, markdown, org

;;; Code:

(require 'pretty-view-render)
(require 'pretty-view-gfm)
(require 'pretty-view-theme)
(require 'pretty-view-themes)
(require 'pretty-view-html)
(require 'pretty-view-org)
(require 'pretty-view-text)
(require 'pretty-view-browser)

(defvar pretty-view-live-mode nil
  "Minor mode variable for live rendering.")

(defcustom pretty-view-own-toc-modes '(org-mode)
  "Major modes whose converters emit their own table of contents.
For a buffer whose mode derives from one of these, the document shell
adds no table of contents of its own, and `pretty-view-toc' does not
apply -- the source format's own option governs, such as Org's
`#+OPTIONS: toc:'."
  :type '(repeat symbol)
  :group 'pretty-view)

(defun pretty-view-markdown-body ()
  "Return the current buffer rendered as Markdown."
  (pretty-view-render-document (pretty-view-gfm-parse (buffer-string))))

(defun pretty-view-text-buffer-body ()
  "Return the current buffer rendered as plain text."
  (pretty-view-text-body (buffer-string)))

(defcustom pretty-view-source-functions
  '((org-mode . pretty-view-org-body)
    (markdown-mode . pretty-view-markdown-body)
    (text-mode . pretty-view-text-buffer-body))
  "Map a major mode to the function producing its HTML body.
Each function is called with no arguments in the source buffer.  Modes
are matched with `derived-mode-p', so `gfm-mode' reaches the
`markdown-mode' entry.  A buffer matching nothing is rendered as text.

Entries are tried in order; the first whose mode the buffer derives from
wins.  Prepend an entry to override a built-in (e.g. a custom markdown
renderer).  WARNING: an entry for an ancestor mode also matches modes
derived from it, so an entry for `outline-mode' would silently override
`org-mode' if placed before it."
  :type '(alist :key-type symbol :value-type function)
  :group 'pretty-view)

(defun pretty-view-body ()
  "Return the HTML body for the current buffer."
  (let ((fn (seq-some (lambda (entry)
                        (and (derived-mode-p (car entry)) (cdr entry)))
                      pretty-view-source-functions)))
    (funcall (or fn #'pretty-view-text-buffer-body))))

(defun pretty-view--title ()
  "Return a title for the current buffer."
  (or (and (derived-mode-p 'org-mode) (pretty-view-org-title))
      (and buffer-file-name (file-name-nondirectory buffer-file-name))
      (buffer-name)))

(defun pretty-view--source-name ()
  "Return the identity used to name this buffer's output file."
  (or buffer-file-name (concat "buffer:" (buffer-name))))

(defun pretty-view--live-file (file)
  "Return the version script that FILE's live page polls."
  (concat (file-name-sans-extension file) ".live.js"))

(defun pretty-view-render-buffer-to-file (file &optional live)
  "Render the current buffer into FILE.
LIVE non-nil embeds a watcher that reloads the page when a later
render changes it, and writes the version script it polls; see
`pretty-view-live-interval'.  Creates FILE's directory when it does not
exist.  Does not open a browser."
  (let* ((base default-directory)
         (title (pretty-view--title))
         (body (pretty-view-body))
         (suppress-toc (seq-some (lambda (mode) (derived-mode-p mode))
                                 pretty-view-own-toc-modes))
         (html (pretty-view-html-document body
                                          :title title
                                          :base-directory base
                                          :toc (if suppress-toc 'none pretty-view-toc)))
         (live-file (and live pretty-view-live-interval
                         (pretty-view--live-file file)))
         (version (and live-file
                       (secure-hash 'sha1 (encode-coding-string html 'utf-8))))
         (coding-system-for-write 'utf-8-unix))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert (if live-file
                  (pretty-view-html-add-live-script
                   html version (file-name-nondirectory live-file))
                html)))
    ;; Written after the page, so a reload always finds the new page.
    (when live-file
      (with-temp-file live-file
        (insert (pretty-view-html-live-version-script version))))
    file))

;;;###autoload
(defun pretty-view ()
  "Render the current buffer to HTML and open it in a browser."
  (interactive)
  (let ((file (pretty-view-browser-output-file (pretty-view--source-name))))
    (pretty-view-render-buffer-to-file file pretty-view-live-mode)
    (pretty-view-browser-open file)
    (message "pretty-view: %s" file)))

;;;###autoload
(defun pretty-view-file (file)
  "Render FILE to HTML and open it in a browser."
  (interactive "fFile to render: ")
  (let ((was-open (get-file-buffer file)))
    (unwind-protect
        (with-current-buffer (find-file-noselect file)
          (pretty-view))
      (when (and (not was-open) (get-file-buffer file) (not (buffer-modified-p (get-file-buffer file))))
        (kill-buffer (get-file-buffer file))))))

;;;###autoload
(defun pretty-view-export (file)
  "Render the current buffer to FILE without opening a browser."
  (interactive
   (list (read-file-name
          "Export to: " nil nil nil
          (concat (file-name-base (or buffer-file-name (buffer-name)))
                  ".html"))))
  (pretty-view-render-buffer-to-file file)
  (message "pretty-view: wrote %s" file))

;;;###autoload
(defun pretty-view-select-theme (theme)
  "Set `pretty-view-theme' to THEME and re-render if this buffer was rendered."
  (interactive
   (list (intern (completing-read
                  "Theme: "
                  (cons "auto" (mapcar #'symbol-name (pretty-view-theme-names)))
                  nil t))))
  (setq pretty-view-theme theme)
  (let ((file (pretty-view-browser-output-file (pretty-view--source-name))))
    (when (file-exists-p file)
      (pretty-view-render-buffer-to-file file pretty-view-live-mode)))
  (message "pretty-view: theme is now %s" theme))

(defun pretty-view--live-update ()
  "Regenerate this buffer's rendered file.  Used by `pretty-view-live-mode'."
  (when pretty-view-live-mode
    (condition-case err
        (pretty-view-render-buffer-to-file
         (pretty-view-browser-output-file (pretty-view--source-name)) t)
      (quit (signal 'quit nil))
      (error
       (message "pretty-view: render failed (%s: %s) — output: %s"
                (car err) (cadr err)
                (pretty-view-browser-output-file (pretty-view--source-name)))))))

;;;###autoload
(define-minor-mode pretty-view-live-mode
  "Regenerate this buffer's rendered HTML on every save.
The rendered page checks every `pretty-view-live-interval' seconds
whether a save changed it, and only then reloads, restoring the
scroll position."
  :lighter " PV"
  :group 'pretty-view
  (if pretty-view-live-mode
      (add-hook 'after-save-hook #'pretty-view--live-update nil t)
    (remove-hook 'after-save-hook #'pretty-view--live-update t)))

(provide 'pretty-view)
;;; pretty-view.el ends here
