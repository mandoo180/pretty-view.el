EMACS ?= emacs
LOAD  := -L . -L tests
SRC   := $(wildcard pretty-view*.el)
TESTS := $(wildcard tests/*-test.el)

.PHONY: test compile compile-isolated checkdoc clean all

all: compile-isolated test

test:
	$(EMACS) -Q --batch $(LOAD) --eval '(setq load-prefer-newer t)' -l ert $(addprefix -l ,$(TESTS)) \
	  -f ert-run-tests-batch-and-exit

compile: clean
	$(EMACS) -Q --batch $(LOAD) \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SRC)

compile-isolated: clean
	@for f in $(SRC); do \
	  echo "--- $$f"; \
	  $(EMACS) -Q --batch $(LOAD) \
	    --eval '(setq byte-compile-error-on-warn t)' \
	    -f batch-byte-compile $$f || exit 1; \
	done

# Gate on a count of real diagnostics from `checkdoc-create-error-function',
# which exists and is called for every complaint on every supported Emacs
# version (29-32) -- unlike `checkdoc-pending-errors', which is reset before
# we can read it on 29/30 (no `checkdoc--batch-flag' guard there), and unlike
# the "*warn*" buffer, which always has a non-empty header line even with
# zero diagnostics. `checkdoc-verb-check-experimental-flag' defaults to t on
# 29/30 and nil on 31+; it flags correct English (e.g. "Return non-nil when
# LINE contains only whitespace" is not imperative -- LINE is the subject,
# not the reader) often enough that upstream disabled it by default, so it
# is forced off here too, for one consistent rule set on every version.
checkdoc:
	$(EMACS) -Q --batch $(LOAD) \
	  --eval '(progn (require (quote checkdoc)) (setq checkdoc-verb-check-experimental-flag nil) (let ((pv-checkdoc-count 0)) (setq checkdoc-create-error-function (lambda (text start end &optional unfixable) (setq pv-checkdoc-count (1+ pv-checkdoc-count)) (message "%s:%s: %s" (buffer-file-name) (if start (line-number-at-pos start) "?") text) nil)) (dolist (f (file-expand-wildcards "pretty-view*.el")) (checkdoc-file f)) (kill-emacs (if (> pv-checkdoc-count 0) 1 0))))'

clean:
	rm -f *.elc tests/*.elc
