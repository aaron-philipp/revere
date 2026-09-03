#!/usr/bin/env bash
# Compile with warnings as errors, lint docstrings, run the offline tests.
# Usage: bin/check.sh            (EMACS=/path/to/emacs to override)
set -euo pipefail
cd "$(dirname "$0")/.."

EMACS="${EMACS:-emacs}"
if ! command -v "$EMACS" >/dev/null 2>&1; then
  for candidate in "/c/Program Files/Emacs/emacs-31.1/bin/emacs.exe" \
                   "/c/Program Files/Emacs/emacs-30.1/bin/emacs.exe" \
                   "/Applications/Emacs.app/Contents/MacOS/Emacs"; do
    if [ -x "$candidate" ]; then EMACS="$candidate"; break; fi
  done
fi

echo "== compile (warnings are errors)"
rm -f ./*.elc test/*.elc
"$EMACS" -Q --batch -L . \
  --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile ./*.el

echo "== checkdoc (advisory)"
"$EMACS" -Q --batch -L . \
  --eval '(progn (require (quote checkdoc)) (dolist (f (file-expand-wildcards "*.el")) (checkdoc-file f)))' || true

echo "== tests"
"$EMACS" -Q --batch -L . -L test -l revere-tests -f ert-run-tests-batch-and-exit

echo "== ok"
