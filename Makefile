# Revere build driver.  Windows without make: run bin/check.sh in Git Bash.
EMACS ?= emacs

.PHONY: check compile test clean

check:
	bin/check.sh

compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile *.el

test:
	$(EMACS) -Q --batch -L . -L test -l revere-tests -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc test/*.elc
