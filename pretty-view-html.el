;;; pretty-view-html.el --- Document shell with TOC, asset inlining, live reload  -*- lexical-binding: t -*-

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

;; Wraps a body in a complete HTML document. Format-agnostic by construction:
;; the TOC is extracted from rendered headings, so it works identically for
;; Org and Markdown. Also handles asset inlining and live-reload script.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'pretty-view-theme)
(require 'pretty-view-themes)
(require 'pretty-view-render)

(defgroup pretty-view nil
  "Render Org, Markdown, and text buffers to styled HTML."
  :group 'convenience
  :prefix "pretty-view-")

(defcustom pretty-view-toc nil
  "Whether to emit a table of contents.
Nil for none, t for all heading levels, or an integer maximum depth.
Org documents defer to their own `#+OPTIONS: toc:' instead."
  :type '(choice (const :tag "None" nil)
                 (const :tag "All levels" t)
                 (integer :tag "Maximum depth"))
  :group 'pretty-view)

(defcustom pretty-view-inline-images t
  "When non-nil, embed local images in the output as data URIs.
This is what makes the output a single self-contained file."
  :type 'boolean
  :group 'pretty-view)

(defcustom pretty-view-inline-image-max-bytes 2000000
  "Largest image, in bytes, that is embedded as a data URI.
Larger files are linked with a `file://' URL instead."
  :type 'integer
  :group 'pretty-view)

(defcustom pretty-view-live-interval 1.5
  "Seconds between browser reloads in `pretty-view-live-mode'.
Nil omits the reload script.

On `file://' the page cannot ask whether its source changed, so the
reload is unconditional and happens even while the document is idle."
  :type '(choice (const :tag "No automatic reload" nil) number)
  :group 'pretty-view)

(defcustom pretty-view-html-lang "en"
  "Value of the `lang' attribute on the generated `html' element."
  :type 'string
  :group 'pretty-view)

(defcustom pretty-view-head-functions nil
  "Functions contributing markup to the document's `<head>'.
Each is called with no arguments in the source buffer and returns a
string or nil.  This is where to add a KaTeX or Mermaid script tag."
  :type 'hook
  :group 'pretty-view)

(defcustom pretty-view-body-filter-functions nil
  "Functions filtering the rendered body.
Each is called with the body string in the source buffer and returns
the replacement, applied in order."
  :type 'hook
  :group 'pretty-view)

;; Table of contents implementation

(defconst pretty-view-html--heading-re
  "<h\\([1-6]\\)[^>]*\\bid=\"\\([^\"]+\\)\"[^>]*>\\(.*?\\)</h\\1>"
  "Match a rendered heading carrying an id.
Group 1 is the level, group 2 the id, group 3 the inner HTML.")

(defun pretty-view-html--strip-tags (html)
  "Return HTML with element tags removed, keeping text and entities."
  (replace-regexp-in-string "<[^>]*>" "" html))

(defun pretty-view-html--headings (body max-depth)
  "Return (LEVEL ID TEXT) for each heading in BODY up to MAX-DEPTH."
  (let ((result nil) (start 0))
    (while (string-match pretty-view-html--heading-re body start)
      (let ((level (string-to-number (match-string 1 body))))
        (when (<= level max-depth)
          (push (list level (match-string 2 body)
                      (pretty-view-html--strip-tags (match-string 3 body)))
                result)))
      (setq start (match-end 0)))
    (nreverse result)))

(defun pretty-view-html--toc (body max-depth)
  "Return a table of contents for BODY up to MAX-DEPTH, or nil.
Returns nil when BODY holds fewer than two headings with ids, because a
one-entry contents list is noise."
  (let* ((all-headings (pretty-view-html--headings body 6))
         (headings (pretty-view-html--headings body max-depth)))
    (when (> (length all-headings) 1)
      (format "<nav class=\"pv-toc\"><ul>\n%s</ul></nav>\n"
              (mapconcat
               (lambda (h)
                 (format "<li class=\"pv-toc-%d\"><a href=\"#%s\">%s</a></li>\n"
                         (nth 0 h)
                         (pretty-view-escape-attribute (nth 1 h))
                         (nth 2 h)))
               headings "")))))

;; Asset inlining implementation

(defconst pretty-view-html--image-mime-alist
  '(("png" . "image/png") ("jpg" . "image/jpeg") ("jpeg" . "image/jpeg")
    ("gif" . "image/gif") ("svg" . "image/svg+xml")
    ("webp" . "image/webp") ("avif" . "image/avif")
    ("bmp" . "image/bmp") ("ico" . "image/x-icon"))
  "Map an image file extension to its MIME type.")

(defun pretty-view-html--data-uri (file)
  "Return FILE as a data URI, or nil when it cannot be embedded."
  (let ((mime (cdr (assoc (downcase (or (file-name-extension file) ""))
                          pretty-view-html--image-mime-alist))))
    (when (and mime
               (file-readable-p file)
               (<= (file-attribute-size (file-attributes file))
                   pretty-view-inline-image-max-bytes))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file)
        (format "data:%s;base64,%s"
                mime (base64-encode-string (buffer-string) t))))))

(defun pretty-view-html--inline-assets (html base-directory)
  "Return HTML with local image sources under BASE-DIRECTORY embedded.
Remote URLs, unreadable files, and files over
`pretty-view-inline-image-max-bytes' are left as links."
  (if (not pretty-view-inline-images)
      html
    (replace-regexp-in-string
     "\\(<img[^>]*\\bsrc=\"\\)\\([^\"]+\\)\\(\"\\)"
     (lambda (match)
       (let ((src (match-string 2 match)))
         (if (string-match-p "\\`\\(?:[a-z][a-z0-9+.-]*:\\|//\\)" src)
             match
           (let* ((file (expand-file-name src base-directory))
                  (uri (pretty-view-html--data-uri file)))
             (concat (match-string 1 match)
                     (cond (uri uri)
                           ((file-readable-p file) (concat "file://" file))
                           (t src))
                     (match-string 3 match))))))
     html t)))

;; Live-reload script

(defun pretty-view-html--live-script ()
  "Return the reload script, or an empty string when reloading is off."
  (if (not pretty-view-live-interval)
      ""
    (format "<script>
(function () {
  var key = 'pv-scroll:' + location.pathname;
  try {
    var y = sessionStorage.getItem(key);
    if (y !== null) window.scrollTo(0, parseInt(y, 10));
  } catch (e) {}
  window.addEventListener('beforeunload', function () {
    try { sessionStorage.setItem(key, String(window.scrollY)); } catch (e) {}
  });
  setInterval(function () {
    if (document.visibilityState !== 'hidden') location.reload();
  }, %d);
})();
</script>\n" (truncate (* 1000 pretty-view-live-interval)))))

;; Document shell

(cl-defun pretty-view-html-document (body &key title base-directory live)
  "Wrap BODY in a complete HTML document and return it.
TITLE names the document, BASE-DIRECTORY resolves relative image paths,
and LIVE non-nil embeds the reload script."
  (let* ((body (seq-reduce (lambda (acc fn) (funcall fn acc))
                           pretty-view-body-filter-functions body))
         (body (pretty-view-html--inline-assets
                body (or base-directory default-directory)))
         (depth (cond ((integerp pretty-view-toc) pretty-view-toc)
                      (pretty-view-toc 6)
                      (t nil)))
         (toc (and depth (pretty-view-html--toc body depth)))
         (head (mapconcat (lambda (fn) (or (funcall fn) ""))
                          pretty-view-head-functions "\n")))
    (concat
     "<!DOCTYPE html>\n<html lang=\"" pretty-view-html-lang "\">\n<head>\n"
     "<meta charset=\"utf-8\" />\n"
     "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />\n"
     "<title>" (pretty-view-escape-html (or title "Document")) "</title>\n"
     "<style>\n" (pretty-view-theme-css pretty-view-theme) "</style>\n"
     (if (string-empty-p head) "" (concat head "\n"))
     "</head>\n<body>\n<main class=\"pv-doc\">\n"
     (or toc "")
     body
     "</main>\n"
     (if live (pretty-view-html--live-script) "")
     "</body>\n</html>\n")))

(provide 'pretty-view-html)
;;; pretty-view-html.el ends here
