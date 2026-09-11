;;; pretty-view-theme-test.el --- Tests for the theme layer  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Kyeong Soo Choi

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;; Palette merging, CSS generation, and automatic dark mode.

;;; Code:

(require 'ert)
(require 'pretty-view-theme)

(defmacro pv-with-clean-themes (&rest body)
  "Run BODY with an empty theme registry."
  `(let ((pretty-view-theme--registry (make-hash-table :test #'eq)))
     ,@body))

(ert-deftest pretty-view-theme-test-define-and-lookup ()
  (pv-with-clean-themes
   (pretty-view-define-theme 'demo :bg "#000" :fg "#fff")
   (should (memq 'demo (pretty-view-theme-names)))
   (should (equal (plist-get (pretty-view-theme-palette 'demo) :bg) "#000"))))

(ert-deftest pretty-view-theme-test-missing-slot-inherits-default ()
  (pv-with-clean-themes
   (pretty-view-define-theme 'demo :bg "#000")
   (should (equal (plist-get (pretty-view-theme-palette 'demo) :accent)
                  (plist-get pretty-view-theme-default-palette :accent)))))

(ert-deftest pretty-view-theme-test-unknown-slot-signals ()
  (pv-with-clean-themes
   (should-error (pretty-view-define-theme 'demo :bgg "#000"))))

(ert-deftest pretty-view-theme-test-unknown-theme-returns-nil ()
  (pv-with-clean-themes
   (should (null (pretty-view-theme-palette 'nope)))))

(ert-deftest pretty-view-theme-test-css-emits-custom-properties ()
  (pv-with-clean-themes
   (pretty-view-define-theme 'demo :bg "#123456")
   (let ((css (pretty-view-theme-css 'demo)))
     (should (string-match-p ":root" css))
     (should (string-match-p "--pv-bg: *#123456" css)))))

(ert-deftest pretty-view-theme-test-css-includes-base-stylesheet ()
  (pv-with-clean-themes
   (pretty-view-define-theme 'demo :bg "#000")
   (should (string-match-p "var(--pv-bg)" (pretty-view-theme-css 'demo)))))

(ert-deftest pretty-view-theme-test-extra-css-is-appended-last ()
  (pv-with-clean-themes
   (pretty-view-define-theme 'demo :bg "#000" :extra-css ".marker{}")
   (let ((css (pretty-view-theme-css 'demo)))
     (should (string-match-p "\\.marker{}" css))
     (should (> (string-match "\\.marker{}" css)
                (string-match "var(--pv-bg)" css))))))

(ert-deftest pretty-view-theme-test-auto-emits-both-palettes ()
  (pv-with-clean-themes
   (pretty-view-define-theme 'dark-demo :bg "#111111")
   (pretty-view-define-theme 'light-demo :bg "#eeeeee" :dark-variant 'dark-demo)
   (let* ((pretty-view-default-light-theme 'light-demo)
          (css (pretty-view-theme-css 'auto)))
     (should (string-match-p "#eeeeee" css))
     (should (string-match-p "#111111" css))
     (should (string-match-p "prefers-color-scheme: *dark" css)))))

(ert-deftest pretty-view-theme-test-auto-without-dark-variant ()
  "A light theme with no dark variant still produces valid CSS."
  (pv-with-clean-themes
   (pretty-view-define-theme 'solo :bg "#eeeeee")
   (let* ((pretty-view-default-light-theme 'solo)
          (css (pretty-view-theme-css 'auto)))
     (should (string-match-p "#eeeeee" css))
     (should-not (string-match-p "prefers-color-scheme" css)))))

(ert-deftest pretty-view-theme-test-unknown-theme-css-falls-back ()
  "An unknown theme name must still produce a usable stylesheet."
  (pv-with-clean-themes
   (let ((css (pretty-view-theme-css 'nope)))
     (should (string-match-p "var(--pv-bg)" css))
     (should (string-match-p "--pv-bg" css)))))

(ert-deftest pretty-view-theme-test-auto-keeps-dark-extra-css ()
  "A dark variant's :extra-css must survive, inside the dark media block."
  (pv-with-clean-themes
   (pretty-view-define-theme 'dark-demo :bg "#111111"
                             :extra-css ".dark-marker{}")
   (pretty-view-define-theme 'light-demo :bg "#eeeeee"
                             :dark-variant 'dark-demo
                             :extra-css ".light-marker{}")
   (let* ((pretty-view-default-light-theme 'light-demo)
          (css (pretty-view-theme-css 'auto)))
     (should (string-match-p "\\.dark-marker{}" css))
     (should (string-match-p "\\.light-marker{}" css))
     ;; The dark rule must sit inside the media block, the light one outside.
     (let ((media (string-match "prefers-color-scheme" css))
           (dark (string-match "\\.dark-marker{}" css))
           (light (string-match "\\.light-marker{}" css)))
       (should (< media dark))
       (should (< dark light))))))

(ert-deftest pretty-view-theme-test-odd-length-palette-signals ()
  (pv-with-clean-themes
   (should-error (pretty-view-define-theme 'demo :bg "#111" :fg))))

(provide 'pretty-view-theme-test)
;;; pretty-view-theme-test.el ends here
