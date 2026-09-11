EMACS ?= emacs
LOAD  := -L . -L tests
SRC   := $(wildcard pretty-view*.el)
TESTS := $(wildcard tests/*-test.el)

.PHONY: test compile checkdoc clean all

all: compile test

test:
	$(EMACS) -Q --batch $(LOAD) -l ert $(addprefix -l ,$(TESTS)) \
	  -f ert-run-tests-batch-and-exit

compile: clean
	$(EMACS) -Q --batch $(LOAD) \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SRC)

checkdoc:
	$(EMACS) -Q --batch $(LOAD) \
	  --eval '(dolist (f (file-expand-wildcards "pretty-view*.el")) (checkdoc-file f))'

clean:
	rm -f *.elc tests/*.elc
