;;; pretty-view-browser.el --- Platform-aware browser launch and output location  -*- lexical-binding: t -*-

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

;; Every platform decision in the package lives here.  WSL is the reason
;; the file exists: it is Linux with a Windows browser behind it, so the
;; output goes to the Windows temporary directory and the file is handed
;; over as a Windows path.  Writing to `/mnt/c' avoids
;; `\\\\wsl.localhost' UNC paths entirely.
;;
;; `pretty-view-browser-command' returns an argument list and launches
;; nothing, which is what makes the platform logic testable.

;;; Code:

(require 'seq)

(declare-function browse-url "browse-url" (url &rest args))

(defvar pretty-view-browser--uname nil
  "Kernel release string, computed on first use and cached.
A variable rather than a call so tests can rebind it.")

(defvar pretty-view-browser--windows-temp-cache 'unset
  "Cached Windows temporary directory, or `unset' if not yet computed.
A variable rather than a call so tests can reset it.")

(defun pretty-view-browser--reset-caches ()
  "Reset all caches for testing."
  (setq pretty-view-browser--windows-temp-cache 'unset)
  (setq pretty-view-browser--uname nil))

(defun pretty-view-browser-wsl-p ()
  "Return non-nil when running under the Windows Subsystem for Linux."
  ;; Ensure uname is loaded (compute on first use)
  (when (and (eq system-type 'gnu/linux) (null pretty-view-browser--uname))
    (setq pretty-view-browser--uname
          (or (car (split-string (shell-command-to-string "uname -r") "\n" t)) "")))
  (and (eq system-type 'gnu/linux)
       (or (string-match-p "[Mm]icrosoft" pretty-view-browser--uname)
           (and (getenv "WSL_DISTRO_NAME") t))
       t))

(defun pretty-view-browser--windows-temp ()
  "Return the Windows temporary directory as a Linux path, or nil.
The result is computed on first use and cached for the session."
  ;; Return nil immediately if not on WSL
  (if (not (pretty-view-browser-wsl-p))
      nil
    ;; Return cached result if available (cache holds either nil or a path)
    (if (not (eq pretty-view-browser--windows-temp-cache 'unset))
        pretty-view-browser--windows-temp-cache
      ;; Compute the result
      (let (result)
        (condition-case nil
            (let ((output (string-trim
                           (replace-regexp-in-string "\r\n\\|\r" ""
                                                     (shell-command-to-string
                                                      "sh -c 'cd /mnt/c && wslpath -u \"$(cmd.exe /c echo %TEMP% 2>/dev/null)\" 2>/dev/null'")))))
              (when (not (string-empty-p output))
                (setq result output)))
          (error nil))

        ;; Fall back to guessing if discovery failed
        (unless result
          (let ((user (or (getenv "WSLUSER") (getenv "USER"))))
            (setq result
                  (seq-find
                   #'file-directory-p
                   (delq nil
                         (list (getenv "TEMP_LINUX")
                               (when user
                                 (format "/mnt/c/Users/%s/AppData/Local/Temp" user))))))))

        ;; Cache and return
        (setq pretty-view-browser--windows-temp-cache result)
        result))))

(defun pretty-view-browser--windows-path (file)
  "Return FILE as a Windows path, or nil when conversion fails."
  (when (executable-find "wslpath")
    (let ((out (string-trim
                (shell-command-to-string
                 (format "wslpath -w %s" (shell-quote-argument file))))))
      (unless (string-empty-p out) out))))

(defcustom pretty-view-output-directory nil
  "Directory that rendered HTML is written to.
Nil means `pretty-view-browser-default-output-directory', which is the
system temporary directory, or the Windows one under WSL."
  :type '(choice (const :tag "Automatic" nil) directory)
  :group 'pretty-view)

(defcustom pretty-view-browser 'default
  "How to open the rendered file.
`default' uses `browse-url', after adjusting for WSL.  A string names a
program, invoked with the file URL.  A function is called with the
output file path."
  :type '(choice (const :tag "System default" default)
                 (string :tag "Program")
                 (function :tag "Function"))
  :group 'pretty-view)

(defun pretty-view-browser-default-output-directory ()
  "Return the directory rendered HTML should be written to."
  (let ((wsl-temp (and (pretty-view-browser-wsl-p)
                       (pretty-view-browser--windows-temp))))
    (expand-file-name "pretty-view" (or wsl-temp temporary-file-directory))))

(defun pretty-view-browser-output-file (source)
  "Return the output path for SOURCE, a file name or a buffer name.
The name combines a sanitized base name with a hash of SOURCE, so two
documents never collide and one document always reuses its path."
  (let* ((dir (or pretty-view-output-directory
                  (pretty-view-browser-default-output-directory)))
         (base (file-name-base source))
         (base (replace-regexp-in-string "[^[:alnum:]-]+" "-" base))
         (base (string-trim base "-" "-"))
         (base (if (string-empty-p base) "document" base))
         (hash (substring (secure-hash 'sha1 source) 0 10)))
    (expand-file-name (format "%s-%s.html" base hash) dir)))

(defun pretty-view-browser-command (file)
  "Return the argument list that opens FILE, or nil to use `browse-url'.
FILE is an absolute path."
  (cond
   ((stringp pretty-view-browser)
    (list pretty-view-browser (concat "file://" file)))
   ((pretty-view-browser-wsl-p)
    (let ((wslview (executable-find "wslview")))
      (if wslview
          (list wslview file)
        (let ((explorer (executable-find "explorer.exe"))
              (win (pretty-view-browser--windows-path file)))
          (when (and explorer win) (list explorer win))))))
   (t nil)))

(defun pretty-view-browser-open (file)
  "Open FILE in a browser.
Reports the path and returns nil when no browser could be launched, so
the file can be opened by hand."
  (condition-case err
      (cond
       ((functionp pretty-view-browser)
        (funcall pretty-view-browser file)
        t)
       (t
        (let ((command (pretty-view-browser-command file)))
          (if command
              (apply #'start-process "pretty-view" nil command)
            (browse-url (concat "file://" file)))
          t)))
    (error
     (message "pretty-view: could not open a browser (%s); the file is at %s"
              (error-message-string err) file)
     nil)))

(provide 'pretty-view-browser)
;;; pretty-view-browser.el ends here
