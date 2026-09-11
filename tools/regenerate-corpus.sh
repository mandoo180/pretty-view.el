#!/usr/bin/env bash
# Regenerate the golden HTML for every tests/corpus/*.md.
# Run this only after an intentional rendering change, then read the diff.
set -euo pipefail
cd "$(dirname "$0")/.."
for md in tests/corpus/*.md; do
  emacs -Q --batch -L . \
    --eval "(progn
              (require 'pretty-view-gfm)
              (require 'pretty-view-render)
              (with-temp-buffer
                (insert-file-contents \"$md\")
                (let ((html (pretty-view-render-document
                             (pretty-view-gfm-parse (buffer-string)))))
                  (with-temp-file \"${md%.md}.html\"
                    (insert html)))))"
  html_file="${md%.md}.html"
  if [ ! -s "$html_file" ]; then
    echo "ERROR: $html_file is empty or missing"
    exit 1
  fi
  echo "wrote $html_file"
done
