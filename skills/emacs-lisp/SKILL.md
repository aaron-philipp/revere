---
name: emacs-lisp
description: Writing or changing Emacs Lisp, including Revere itself; how to check it compiles and passes tests
---

# Emacs Lisp

Use this when the job touches `.el` files.

## Rules

- Every file starts with `;;; name.el --- summary -*- lexical-binding: t; -*-`
  and ends with `(provide 'name)` and `;;; name.el ends here`.
- Docstrings: first line under 80 columns and a complete sentence; mention
  every argument in capitals.
- Prefer `cl-lib`, `seq` and `subr-x` over hand-rolled loops.  No `cl`.
- Keep functions short.  Replace a whole `defun` rather than editing inside
  it, so parentheses stay balanced.

## Checking your work

After editing, run `problems` on the file: the byte compiler and checkdoc
report through flymake.  Fix every warning.

For Revere itself, run the full check with the shell tool:

    bash bin/check.sh

It compiles with warnings as errors and runs the ert tests.  Do not say a
change is done until it passes.

## Looking things up

Use `describe` for any function or variable you are not sure of, and
`apropos` to find one by name.  Never guess an argument list.
