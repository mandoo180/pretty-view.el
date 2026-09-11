;;; pretty-view-gfm-test.el --- Tests for the GFM parser  -*- lexical-binding: t -*-

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
;; Block and inline parsing.  Assertions read specific fields; plist key
;; order is not part of the contract.
;;; Code:

(require 'ert)
(require 'pretty-view-gfm)
(require 'pretty-view-test-helper)

(ert-deftest pretty-view-gfm-test-atx-heading ()
  (let ((node (pv-test-block "## Hello world")))
    (should (eq (pv-test-type node) 'heading))
    (should (= (plist-get node :level) 2))
    (should (equal (plist-get node :raw) "Hello world"))
    (should (equal (plist-get node :id) "hello-world"))))

(ert-deftest pretty-view-gfm-test-atx-heading-levels ()
  (should (= (plist-get (pv-test-block "# a") :level) 1))
  (should (= (plist-get (pv-test-block "###### a") :level) 6)))

(ert-deftest pretty-view-gfm-test-seven-hashes-is-a-paragraph ()
  "Seven hashes is not a heading in CommonMark."
  (should (eq (pv-test-type (pv-test-block "####### a")) 'paragraph)))

(ert-deftest pretty-view-gfm-test-hash-without-space-is-a-paragraph ()
  (should (eq (pv-test-type (pv-test-block "#hashtag")) 'paragraph)))

(ert-deftest pretty-view-gfm-test-closing-sequence-stripped ()
  (should (equal (plist-get (pv-test-block "## Hello ##") :raw) "Hello")))

(ert-deftest pretty-view-gfm-test-setext-heading ()
  (let ((node (pv-test-block "Title\n=====")))
    (should (eq (pv-test-type node) 'heading))
    (should (= (plist-get node :level) 1))
    (should (equal (plist-get node :raw) "Title")))
  (should (= (plist-get (pv-test-block "Title\n-----") :level) 2)))

(ert-deftest pretty-view-gfm-test-paragraph-joins-lines ()
  (let ((node (pv-test-block "one\ntwo")))
    (should (eq (pv-test-type node) 'paragraph))
    (should (equal (plist-get node :raw) "one\ntwo"))))

(ert-deftest pretty-view-gfm-test-blank-line-separates-paragraphs ()
  (let ((blocks (pv-test-blocks "one\n\ntwo")))
    (should (= (length blocks) 2))
    (should (equal (plist-get (nth 1 blocks) :raw) "two"))))

(ert-deftest pretty-view-gfm-test-thematic-break ()
  (dolist (s '("---" "***" "___" " - - -" "_____________"))
    (should (eq (pv-test-type (pv-test-block s)) 'thematic-break))))

(ert-deftest pretty-view-gfm-test-thematic-break-interrupts-paragraph ()
  (let ((blocks (pv-test-blocks "text\n---\nmore")))
    ;; `text' followed by `---' is a setext level-2 heading, not a break.
    (should (eq (pv-test-type (nth 0 blocks)) 'heading))
    (should (= (plist-get (nth 0 blocks) :level) 2))))

(ert-deftest pretty-view-gfm-test-slug ()
  (should (equal (pretty-view-gfm--slug "Hello, World!") "hello-world"))
  (should (equal (pretty-view-gfm--slug "  spaced  out  ") "spaced-out"))
  (should (equal (pretty-view-gfm--slug "한글 제목") "한글-제목")))

(ert-deftest pretty-view-gfm-test-parse-returns-document ()
  (let ((doc (pretty-view-gfm-parse "hi")))
    (should (eq (plist-get doc :type) 'document))
    (should (= (length (plist-get doc :children)) 1))))

(ert-deftest pretty-view-gfm-test-empty-input ()
  (should (equal (plist-get (pretty-view-gfm-parse "") :children) nil)))

(provide 'pretty-view-gfm-test)
;;; pretty-view-gfm-test.el ends here
