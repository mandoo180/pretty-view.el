;;; pretty-view-text.el --- Plain text converter  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Kyeong Soo Choi
;;
;; This file is part of pretty-view.el.
;;
;; pretty-view.el is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the Free
;; Software Foundation, either version 3 of the License, or (at your option)
;; any later version.
;;
;; pretty-view.el is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
;; more details.
;;
;; You should have received a copy of the GNU General Public License along with
;; this program. If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Plain text is rendered as plain text: escaped, split into paragraphs
;; on blank lines, with line structure preserved inside each paragraph
;; and bare URLs linked.  Setting `pretty-view-text-as-markdown' routes
;; text through the GFM parser instead.

;;; Code:

(require 'seq)
(require 'pretty-view-render)
(require 'pretty-view-gfm)

(defcustom pretty-view-text-as-markdown nil
  "When non-nil, render plain text files through the Markdown parser."
  :type 'boolean
  :group 'pretty-view)

(defconst pretty-view-text--url-re "\\bhttps?://[^ \t\n<>\"]+"
  "Match a bare URL in plain text.")

(defun pretty-view-text--autolink-raw (raw-text)
  "Process RAW-TEXT, escaping it and turning bare URLs into links.
Trimming happens on raw text before escaping, avoiding entity truncation.
Returns escaped HTML with <a> tags for URLs and escaped text for non-URLs."
  (let ((result "")
        (pos 0))
    ;; Loop through all URL matches in the raw text
    (while (string-match pretty-view-text--url-re raw-text pos)
      ;; Escape and append text before the URL match
      (let ((before-text (substring raw-text pos (match-beginning 0))))
        (setq result (concat result (pretty-view-escape-html before-text))))

      ;; Process the matched URL
      (let* ((raw-url (match-string 0 raw-text))
             (trimmed-url (pretty-view-gfm--trim-url-punctuation raw-url))
             (escaped-url (pretty-view-escape-html trimmed-url))
             (trimmed-off (substring raw-url (length trimmed-url))))

        ;; Create the link with escaped URL for both href and body
        (setq result (concat result (format "<a href=\"%s\">%s</a>" escaped-url escaped-url)))

        ;; The trimmed-off characters belong to the paragraph, so escape and append them
        (setq result (concat result (pretty-view-escape-html trimmed-off))))

      ;; Move position to after the URL match
      (setq pos (match-end 0)))

    ;; Escape and append any remaining text after the last URL
    (let ((remaining (substring raw-text pos)))
      (setq result (concat result (pretty-view-escape-html remaining))))

    result))

(defun pretty-view-text-body (text)
  "Return TEXT rendered as an HTML body.
Line endings are normalized to LF, allowing CRLF and old Mac CR line endings."
  (if pretty-view-text-as-markdown
      (pretty-view-render-document (pretty-view-gfm-parse text))
    ;; Normalize line endings: CRLF -> LF and CR -> LF (old Mac style).
    (let* ((normalized (replace-regexp-in-string "\r\n" "\n" text))
           (normalized (replace-regexp-in-string "\r" "\n" normalized))
           (split-paras (split-string (string-trim normalized) "\n[ \t]*\n+" t))
           ;; Filter out whitespace-only paragraphs.
           (paragraphs (seq-filter (lambda (p) (not (string-blank-p (string-trim p))))
                                    split-paras)))
      (mapconcat
       (lambda (para)
         (format "<p class=\"pv-text\">%s</p>\n"
                 (pretty-view-text--autolink-raw (string-trim para))))
       paragraphs ""))))

(provide 'pretty-view-text)
;;; pretty-view-text.el ends here
