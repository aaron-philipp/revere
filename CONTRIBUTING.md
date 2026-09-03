# Contributing

Thanks for looking. A few things worth knowing before you send a patch.

## Check your work

```bash
bin/check.sh
```

It byte-compiles every file with warnings as errors, runs checkdoc, and
runs the ert suite in `test/`. Everything must be green. Emacs is found on
the path or at the standard Windows location; set `EMACS` to override.

The tests never touch the network: the model is faked, the MCP server is a
fake written in Elisp, and `revere-directory` points at a throwaway
directory for the run.

## Style

- Emacs 29.1 is the floor. No dependencies outside Emacs for the core;
  optional integrations (`websocket`, `treemacs`) must degrade quietly.
- Lexical binding everywhere. Namespace public symbols `revere-`, internals
  `revere-<file>--`.
- Docstrings on everything public, first line under 80 columns, arguments
  named in capitals.
- Prefer `cl-lib`, `seq` and `subr-x` over hand-rolled loops.
- Replace a whole top-level form rather than editing inside one, so
  parentheses stay balanced.

## Words

User-facing text uses the vocabulary in `DESIGN.md` section 0: *job*, not
run or task; *routine* for a scheduled job; *keep* and *discard*, not
accept and reject; *logbook*, *check-in*, *board*. Words newcomers know
stay: prompt, tool, skill, memory, subagent, approval.

## Design

`DESIGN.md` explains why Revere works the way it does, above all that
edits land in buffers and never on disk until you keep them. A change that
writes a file behind the review, or that turns the chat into a plain
transcript with no link back into Emacs, is going the wrong way.
