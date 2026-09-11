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

checkdoc:
	$(EMACS) -Q --batch $(LOAD) \
	  --eval '(progn (require (quote checkdoc)) (let ((checkdoc--batch-flag t)) (dolist (f (file-expand-wildcards "pretty-view*.el")) (checkdoc-file f))) (kill-emacs (if checkdoc-pending-errors 1 0)))'

clean:
	rm -f *.elc tests/*.elc
