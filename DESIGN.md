# Revere — an agentic framework built on Emacs

Revere does jobs for you inside Emacs. It has the same shape as Hermes and
OpenClaw (model loop, tool registry, skills, memory, routines, channels,
approvals) but is built from Emacs Lisp and long-lived Emacs packages. The
runtime is a headless `emacs --daemon`. Humans attach with `emacsclient`
frames; the daemon does the unattended work.

It grows out of `pi-emacs`, an earlier private prototype, which proved
the transport and tool loop but stalled on interaction: one `*pi*` buffer,
disk writes gated by `yes-or-no-p`, a blocking shell tool. Revere keeps the
transport and inverts the interaction model.

Design rules:

1. **Native Lisp first.** Every layer is Elisp calling Emacs primitives or a
   mature package. Subprocesses are for the outside world only (curl, git,
   compilers, containers).
2. **Revere edits buffers, never files.** Disk is touched only when you
   keep. Buffers are the staging area, undo is the rollback, diff/ediff/magit
   are the review, and flymake/eglot are the feedback loop. This is the one
   thing a terminal-based assistant cannot do and the whole reason to build
   on Emacs.
3. **The chat is the hub, not the whole UI.** You talk to Revere in a
   chat, and the chat drives the rest of Emacs: the file being edited shows
   in the main window with its changed lines marked, every tool line is a
   link to the buffer it touched, the diff opens in its own buffer on
   request, and review happens in the source buffer, the chat or the diff.
   A chat that is only a buffer (the gptel complaint) and a workspace with
   no conversation (an early mistake here) are both wrong.
4. **Org is the database of record.** Jobs, routines, memory and skills are
   Org files. SQLite (built in) is an index, never the truth.
5. **Everything is inspectable and patchable live.** Revere can read its
   own source, define tools at runtime, and `advice-add` its own behaviour.
6. **One process, fully asynchronous.** Emacs is single threaded. Nothing
   that blocks for more than ~50 ms runs on the main loop.

Target: Emacs 29.1 minimum; developed on the installed 31.1 (sqlite,
tree-sitter, TRAMP docker all confirmed present; native-comp is absent in this
build, so rely on byte-compilation).

---

## 0. Vocabulary

Names use Emacs's own words where one exists and ordinary work language
otherwise, with one exception: words that Cursor-level users already know
(prompt, tool, tool call, skill, memory, subagent, approval) stay, because
they are the on-ramp for people new to this. Revere describes itself as an
agentic framework, because that is what it is; inside the interface
nothing says agent, harness, run, changeset, or reflect. The harness words
appear in this document only in the left column below and in the left
columns of sections 1 and 8, where they are needed to map onto other
systems.

| Harness word                     | Revere word                          | Why                                                                  |
|----------------------------------|--------------------------------------|----------------------------------------------------------------------|
| agent, agentic harness           | Revere, or "it"                      | a program in your Emacs that does jobs                               |
| the LLM, the agent               | the model                            | the thing on the other end of the API, named factually               |
| run, task, session               | **job**                              | one piece of work with one prompt; ends when you keep or discard the result |
| cron job, scheduled task         | **routine**                          | a job that repeats; an Org heading with a repeater                   |
| prompt, goal, task description   | **prompt**                           | kept; what you asked for, one line at the top of the job buffer      |
| tool                             | **tool**                             | kept; it is also an Emacs command, so `M-x` works on it              |
| tool call                        | **tool call**                        | kept                                                                 |
| skill                            | **skill**                            | kept; matches `SKILL.md` and what Cursor and Claude Code call it     |
| memory                           | **memory**                           | kept; `memory/` and `MEMORY.org`                                     |
| reflect, self-improve            | **debrief**                          | the nightly pass that writes memory from the day's jobs              |
| memory consolidation             | **memory tidy-up**                   | the weekly merge and prune                                           |
| context, context window          | what it has read                     | shown as tokens only where cost matters                              |
| changeset                        | **changes**                          | the files it touched, unsaved                                        |
| accept, reject                   | **keep, discard**                    | magit's words                                                        |
| approval, permission request     | **approval**                         | kept; the dashboard section and the list are "Approvals"             |
| policy: allow / ask / deny       | **rules: go ahead / check with me / never** |                                                               |
| permission mode preset           | look only / check with me / go ahead |                                                                      |
| heartbeat                        | **check-in**                         | a timer that looks for anything to do                                |
| subagent, delegate               | **subagent**                         | kept; a side job whose changes fold into the main one                |
| ACP agent (Claude Code, pi)      | outside subagent                     |                                                                      |
| session buffer                   | **job buffer**                       |                                                                      |
| ledger, trace                    | **logbook**                          | Org's own word                                                       |
| diagnostics                      | **problems**                         |                                                                      |
| thinking / streaming / tool      | working / writing / running `make test` | mode-line words                                                   |
| dashboard, channel, daemon, workspace, inbox | unchanged                | plain already; daemon is Emacs's word                                |
| MCP, ACP                         | unchanged                            | protocol names                                                       |

Job states, which are also the Org todo keywords on the logbook heading:

```
queued -> working <-> waiting (for approval)
              |
              v
          to review  (it stopped; changes unreviewed)
              |
              +-> done       (kept, in whole or in part)
              +-> discarded
working ----> failed  (error, budget, deadline, tests)

#+TODO: QUEUED WORKING WAITING REVIEW | DONE DISCARDED FAILED
```

Commands: `revere` (the menu), `revere-new` (start a job from a prompt),
`revere-jobs`, `revere-routines`, `revere-memory`, `revere-skills`,
`revere-changes`, `revere-approvals`, `revere-workspace`.

Files: `logbook.org` (jobs), `routines.org`, `check-in.org`, `memory/`.

---

## 1. Concept map: OpenClaw / Hermes -> Emacs

| Harness concept            | Emacs building block                                                        |
|----------------------------|-----------------------------------------------------------------------------|
| Gateway / daemon           | `emacs --daemon=revere`, `server.el`, `server-eval-at`                      |
| Model transport, streaming | `pi-emacs-llm` curl + SSE client (OpenAI-compatible via LiteLLM)            |
| Tool loop                  | `pi-emacs-agent` state machine, made non-blocking                           |
| MCP servers                | `mcp.el` client (tools mapped into the registry)                            |
| Tool registry              | `revere-deftool` macro -> real `defun` + JSON schema                        |
| Edit staging               | file buffers, `buffer-modified-p`, `buffer-undo-list`                       |
| Multi-file transaction     | `prepare-change-group` / `cancel-change-group` across buffers               |
| Change review, all files   | `diff-mode` buffer built with `diff-no-select` (disk vs buffer)             |
| Change review, one file    | `ediff-current-file`, `diff-buffer-with-file`                               |
| Inline hunk accept/reject  | `diff-hl` (`diff-hl-flydiff-mode`, `diff-hl-revert-hunk`)                   |
| File tree                  | `treemacs` (annotation API, extension nodes, git mode); `neotree` adapter via advice; `dired` on the changes file list |
| Session view               | `magit-section` buffer (foldable sections, not a chat log)                  |
| Window layout              | `display-buffer-alist` side windows, saved `window-configuration`           |
| Post-edit feedback         | `flymake` + `eglot` (built in); `flycheck` + `lsp-mode` supported behind one dispatch layer |
| Unattended edits           | `git worktree` per job, `magit` for review, merge on keep                   |
| Skills                     | Agent Skills `SKILL.md` directories, read as is; optional `skill.el` beside it for Elisp tools |
| Memory                     | `~/.revere/memory/*.org` via `org-ql`; `org-roam` optional                  |
| Cron / scheduled jobs      | Org `SCHEDULED` + repeaters; `run-with-timer` tick                          |
| Run ledger                 | `logbook.org`, `org-clock` for timing                                          |
| Secrets                    | `auth-source`                                                               |
| Sandbox / remote           | TRAMP: `default-directory` = `/docker:sandbox:/work/` or `/ssh:host:/`      |
| Shell tool                 | `make-process` + sentinel (never `accept-process-output` loops)             |
| Code intelligence          | `project.el`, `xref`, `eglot`, `treesit`, `imenu`                           |
| Web                        | `url-retrieve` / `plz`, `shr`                                               |
| Approvals                  | rules alist + `*Revere: approvals*` (`tabulated-list-mode`)                   |
| Notifications              | `notifications.el`, `alert.el`                                              |
| Channels                   | `ement` (Matrix), `notmuch`/`gnus` + `smtpmail`, `telega`, `erc`, `simple-httpd` |
| Command palette            | `transient`                                                                 |
| Async Elisp                | `async.el`                                                                  |
| Tests                      | `ert` with a canned-SSE fake transport (pi-emacs already has one)           |

---

## 2. Workspace model

This section is the heart of the design. Everything else is plumbing.

### 2.0 The job

A job is one unit of work with one prompt, from the moment something starts
it to the moment you decide what to do with the result. It is the unit of
everything: one logbook heading, one set of changes, one budget, one
transcript, one approval queue, one worktree if unattended, one job
buffer, one mode-line segment. Hermes calls the nearest thing a task and
pi a session; the difference is that a job ends with your keep-or-discard
decision, not just with the model going quiet.

What starts one: `revere-new` from any buffer, a routine firing in
`routines.org`, an inbound channel message, the check-in finding something
actionable, or a parent job handing off to a subagent. What ends one: you keep or discard its changes,
it fails, it is discarded, or its budget or deadline runs out.

```elisp
(cl-defstruct revere-job
  id            ; org-id, shared with the heading in logbook.org
  goal          ; the prompt, one sentence at the top of the job buffer
  origin        ; (user) | (routine ID) | (channel ROOM) | (parent JOB-ID)
  state         ; queued | working | waiting | review | done | discarded | failed
  model rules budget deadline
  root          ; project root, or the worktree for unattended jobs
  directory     ; default-directory for tools: local, /docker:, /ssh:
  messages      ; transcript; also written to the logbook as it grows
  turns tokens cost
  changes       ; list of revere-change (2.2)
  approvals     ; pending rules prompts
  skills        ; triggered this job
  window-config ; restored by revere-switch-job
  started ended)
```

States:

```
queued -> working <-> waiting (approval)
            |
            v
          review  (it stopped, changes unreviewed: the "done, unreviewed" state)
            |
            +-> done      (kept, in whole or in part)
            +-> cancelled (discarded)
running --> failed  (error, budget, deadline, tests)
```

Boundaries that matter:

- **A job is not a conversation.** Replying in the job buffer adds a
  turn to the same job while the goal is the same. A new goal is a new job,
  started with `revere-new`, and it can reference the old one.
- **A job is not a buffer or a process.** It owns several buffers and
  spawns many subprocesses; they come and go, the job persists.
- **A job is durable.** The live object is a struct; the heading in
  `logbook.org` is its record. On daemon restart, jobs in `running` are
  rehydrated from the heading and resumed or marked failed; jobs in
  `review` wait for you.
- **Subagents.** A job may hand off to a subagent, a child job with its own set of changes and
  budget; on keep, the child's changes fold into the parent's changes,
  so you still review once.

### 2.1 Edits go to buffers

Every mutating tool resolves its path with `find-file-noselect` and edits the
buffer with ordinary primitives. Nothing calls `write-region` or
`with-temp-file` during a job.

```elisp
(revere-deftool edit ((path string "File path")
                      (old string "Exact text to replace")
                      (new string "Replacement")
                      (all boolean "Replace every occurrence" :optional t))
  "Replace OLD with NEW in PATH's buffer. Nothing is written to disk."
  (with-current-buffer (revere-ws-buffer path)      ; find-file-noselect + tracking
    (revere-ws-check-fresh (current-buffer))         ; see 2.4
    (save-excursion
      (goto-char (point-min))
      (let ((n 0))
        (while (search-forward old nil t)
          (replace-match new t t) (cl-incf n)
          (unless all (goto-char (point-max))))
        (when (zerop n) (error "edit: OLD not found in %s" path))
        (revere-ws-touch (current-buffer))
        (format "%d replacement%s in %s (unsaved)" n (if (= n 1) "" "s") path)))))
```

What that buys, with zero extra code:

- **Staging**: `buffer-modified-p` marks touched files; `save-some-buffers`
  with a predicate is "keep all"; `revert-buffer` is "discard file".
- **Undo**: every edit Revere makes is on `buffer-undo-list`. `C-/` undoes it like
  any other edit; `vundo` shows the tree.
- **Live feedback**: flymake and eglot re-check on change, so the model can
  ask for problems before it declares itself done.
- **Coexistence**: the user can have the same file open, watch edits arrive,
  and keep typing. Point is preserved with `save-excursion`; markers survive.

### 2.2 The changes

A job owns a set of changes: an ordered list of entries, one per touched buffer.

```elisp
(cl-defstruct revere-change
  file buffer          ; absolute path, live buffer
  base-tick            ; buffer-chars-modified-tick when the job first read it
  created-p            ; file did not exist on disk before this job
  status)              ; pending | kept | discarded
```

The changes is the single source for every view below and is written to
the job's Org heading on completion (paths, diffstat, outcome).

### 2.3 Review surfaces

All of these are derived from the same data: the on-disk file versus the
live buffer.

**Changes buffer, all files.** `revere-changes` builds a unified diff for
every entry with `diff-no-select` (old = disk contents in a temp buffer,
new = live buffer) and concatenates them into one `diff-mode` buffer.
`diff-mode` already gives multi-file navigation (`n`/`p`, `N`/`P` per file),
`diff-goto-source` on `RET`, and `diff-apply-hunk`. Revere adds:

| key       | action                                                              |
|-----------|---------------------------------------------------------------------|
| `k`       | discard hunk: `diff-apply-hunk` in reverse against the live buffer   |
| `a`       | keep hunk (mark only; kept hunks drop out of the view)        |
| `K` / `A` | discard / keep whole file                                          |
| `e`       | `ediff-current-file` for the file at point                          |
| `C-c C-c` | keep all: save every kept buffer, record outcome in logbook    |
| `C-c C-k` | discard all: revert every buffer, cancel the change group            |
| `g`       | regenerate the diff (Revere may still be working)                |

Because the diff is disk-vs-buffer, reversing a hunk edits the buffer back
to what is on disk. The view stays truthful without any bookkeeping.

**Side by side, one file.** `ediff-current-file` compares the live buffer
with its file on disk. Everything ediff does (region highlighting, `a`/`b`
copy, merge) applies unchanged.

**Inline, in the source buffer.** `diff-hl-mode` with `diff-hl-flyDIFFMODE`
draws fringe markers for unsaved hunks. `diff-hl-show-hunk` pops a hunk,
`diff-hl-revert-hunk` discards it in place. Revere enables both on every
buffer in the changes and sets `diff-hl-reference-revision` to nil so the
reference is the working file, not HEAD. `highlight-changes-mode` (built in)
is the fallback where `diff-hl` is not installed.

**File tree.** `treemacs` is the primary adapter because it has the APIs
this needs: annotations (`treemacs-set-annotation-suffix` and `-face`) put
a diffstat (`+12 -3`) and a face on changes files, and created files get
another; an extension node ("Job 42 · 5 files") lists the changes
directly; `treemacs-follow-mode` tracks the file Revere is editing;
`treemacs-git-mode` colours worktree-mode changes with no help from Revere;
`treemacs-magit` refreshes on commits and `treemacs-nerd-icons` matches the
icon set. A `neotree` adapter exists for users on that tree, done with an
`:after` advice on its file-entry renderer since it has no annotation API.
`dired` on the explicit file list (`(dired (cons "revere changes" files))`)
is the built-in fallback and supports marking, `=` for diff, and `Q` for
query-replace across the set.

### 2.4 Transactions and staleness

Before the first edit of a job, Revere calls `prepare-change-group` on each
buffer as it is touched and combines the handles. Discard-all is
`cancel-change-group`; keep-all is `accept-change-group` then save. A
crashed or interrupted job cancels its group in an `unwind-protect`.

Staleness is detected with `buffer-chars-modified-tick`, not file mtimes:
the `read` tool records the tick, and a later `edit` on a buffer whose tick
moved for reasons other than Revere's own edits returns an error telling
the model to re-read. This catches the user typing in the same buffer.

### 2.5 The save gate replaces per-write prompts

pi-emacs asked `yes-or-no-p` on every write. That is the wrong granularity:
it interrupts Revere mid-thought and the user before there is anything
worth judging. Revere's rules for `edit`/`write` is `go ahead` by default,
because nothing reaches disk. The gate is at keep-or-discard time, once, over a
complete and reviewable changes.

Rules still controls disk directly for tools that need it (`shell` running
a formatter, `vc-commit`), and `revere-autosave-dirs` lists directories
where kept-on-arrival is fine (scratch, generated code).

### 2.6 Unattended jobs

A daemon job has no reviewer, so it uses git as the staging area instead of
buffers: `git worktree add .revere/wt/<job-id> -b revere/<job-id>`, all tools
operate with `default-directory` inside the worktree, buffers are saved as
edits land, and the job ends with a commit. Review is `magit-diff` of the
branch, keep is a merge, discard is `git worktree remove` plus branch
delete. The changes buffer from 2.3 renders the same diff by pointing its
"old" side at the base commit, so the two modes share one review UI.

### 2.7 The chat (built: revere-chat.el, revere-review.el, revere-layout.el)

`*Revere: job N*` is a side window. Transcript on top, the changes block
above the rule, the input line below it. What makes it a hub rather than
a TUI:

- **It follows the work.** After each read, edit or write, the file shows
  in the main window at the spot touched, without stealing focus
  (`revere-follow`). Changed lines are highlighted and removed lines shown
  in place by `revere-review-mode`, which turns itself on in every buffer
  the job changed and gives `C-c r` keys to move between hunks, discard a
  hunk, keep or discard the file, open the diff or ediff, or return to the
  chat. Its header line says so.
- **Every tool line is a link.** RET or a click opens what it touched: the
  file at the edit, a `grep-mode` buffer you can jump from, a dired listing
  of the glob's files, the shell output.
- **The changes block is live.** Per file: open, diff, ediff, keep,
  discard. For the job: Review (the diff buffer), Keep all, Discard all.
- **Slash commands** for everything else: /changes /keep /discard /stop
  /new /dir /model /jobs /help. A Revere menu in the menu bar has the same.
- **Layout is `display-buffer-alist`.** Chat on the right, changes and tool
  output at the bottom, files in the main window; all overridable.

The plain-text job buffer this section originally described was replaced
by the chat; the magit-section treatment now applies to the transcript.

### 2.7a Job buffer (superseded)

`*Revere: job N*` is a `magit-section` buffer, not a transcript. Sections,
each foldable with `TAB`:

- **Prompt** — the prompt text, model, budget, elapsed time.
- **Progress** — the streamed response text (updates in place).
- **Tool calls** — one line each, folded; expand for arguments and result.
- **Changes** — the changes with diffstats; `RET` jumps to that file's
  hunks in the changes buffer, `e` to ediff.
- **Problems** — flymake errors across changed buffers after the last
  edit, refreshed on every tool result.
- **Approvals** — pending rules prompts with `a`/`d`.

`C-c C-c` in the job buffer sends a follow-up; `C-c C-k` interrupts.
The full transcript is persisted under the job's Org heading, and
`revere-transcript` opens it as Org when you actually want the log.

### 2.8 Layout

`revere-workspace` arranges: treemacs on the left, the job buffer on the
right side window, the changes buffer in the bottom side window, source
buffers in the centre. Done with `display-buffer-alist` entries so users can
override placement. The window configuration is stored on the job and
restored by `revere-switch-job`.

### 2.9 Feedback tools that exist because edits are buffers

`flymake` plus `eglot` are the primary backends: both are built in, both
have small stable public APIs, and `flymake-show-project-problems` is
already a project-wide error list. `flycheck` plus `lsp-mode` are supported
behind one dispatch file, `revere-code.el`, so no tool knows which is
loaded.

- `problems` — `flymake-diagnostics` over the changes after the
  checker reports (the tool is async so it returns the post-edit state, not
  the pre-edit one); `flycheck-current-errors` after
  `flycheck-after-syntax-check-hook` otherwise. Formatted as
  `file:line: severity message`. The same errors appear in the source
  buffer as Revere makes them.
- `rename-symbol` — `eglot-rename` or `lsp-rename`, a semantic multi-file
  rename that lands as more entries in the changes.
- `code-actions` — list and apply `eglot-code-actions` or
  `lsp-execute-code-action` at a location.
- `references` / `definition` — `xref`, which both LSP clients back, or
  tree-sitter.
- `reformat` — buffer-local `indent-region` or the mode's formatter.
- `compile` — `compilation-start` with the sentinel feeding errors back as
  structured data via `compilation-next-error`.

---

### 2.10 Look and feel

The visual reference is the user's `init.el`, and the point is the look,
not the module list. What that config says about taste:

- **Zenburn.** Low-contrast warm grey ground, muted pastel accents, nothing
  saturated. State is shown with zenburn's own green, red, yellow and
  orange, never with new colours.
- **Icons everywhere.** Nerd icons in dired and the tree, mode icons in the
  mode line, emoji rendered inline. Glyphs carry meaning at the start of a
  line; text carries the detail.
- **Dense, powerline-style mode lines** with segments, not a bare string.
- **A dashboard with a centred banner and a motto,** navigator buttons, and
  icon-headed sections. Startup is a place, not a scratch buffer.
- **Line numbers and current-line highlight** on, light transparency, menu
  bar kept, toolbar gone. Chrome is minimal but not austere.
- **A little playfulness.** A mascot in pi-emacs, emojify, chess. The tone
  is personal, not corporate.

Applied to Revere (mockup: the "Revere Workspace" artifact):

- **Job buffer** reads like a magit status buffer: bold yellow section
  headings with counts, one line per item, a glyph in the first column,
  arguments and timestamps dimmed. No prose beyond the task and the
  progress line.
- **Changes buffer** is diff-mode under zenburn: pastel green and red on a
  faint tint, file headers in yellow with a diffstat, a one-line key legend
  in the header, nothing else.
- **Tree** shows a diffstat suffix on changed files and a "Job 42" node
  listing the changes; icons match the rest of the tree.
- **Mode-line segment** replaces pi-emacs's bottom bar and mascot: one
  state glyph, job number, model, tokens and cost, in the theme's orange
  family, which appears nowhere else. It changes colour only for the two
  states that need you: waiting for approval, and done but unreviewed.
- **Dashboard.** The daemon has its own, built on `dashboard.el` with
  custom item generators, and it is what a fresh `emacsclient -c` frame
  opens to. Navigator buttons: New job, Approvals, Jobs, Jobs, Memory, Skills.
  Three sections, no more: Needs you (approvals, done-but-unreviewed
  sets of changes, proposed memories; the only section with keys), Activity
  (recent jobs with outcomes, the next scheduled jobs, a weekly tally),
  Workspaces (projects with an open job or a leftover worktree). Memory and
  Skills are behind their buttons; channel health is a mode-line segment.
  The user's personal dashboard is untouched; a single Revere item
  generator is available to drop into it if wanted.
- **Approvals** is a tabulated list in the form of `package-list` or `proced`,
  a detail pane beneath, single-letter keys.

The stack below is secondary and adjusted only where a component lacks an
API Revere needs or duplicates something built in.

| Component        | Keep / swap                         | Why                                                                 |
|------------------|-------------------------------------|---------------------------------------------------------------------|
| File tree        | `neotree` -> **`treemacs`**         | Annotation and extension-node APIs, follow mode, git mode, `treemacs-magit`, `treemacs-nerd-icons`. neotree has none of these and is effectively unmaintained. The single most consequential swap. |
| Git              | (absent) -> **add `magit` + `diff-hl`** | Worktree review, hunk staging, inline hunk markers. Revere's review model depends on them. |
| LSP client       | `lsp-mode` + `lsp-ui` -> **`eglot`** | Built in, small stable API, uses `jsonrpc.el` and `xref` natively. `lsp-mode` stays supported behind the dispatch layer if you prefer its UI. |
| Problems      | `flycheck` -> **`flymake`**          | Built in, structured `flymake-diagnostics`, project-wide list already exists. Pairs with eglot. |
| Completion UI    | `ivy`/`counsel`/`swiper` -> **`vertico` + `consult` + `marginalia` + `orderless` + `embark`** | These use the built-in completion metadata, so Revere's `completing-read` pickers get annotations (job status, diffstat) and `embark-act` actions (ediff, discard, open) for free, with no ivy-specific code. `consult-flymake`, `consult-xref`, `consult-ripgrep` with live preview are the search UI. |
| Project          | `projectile` -> **`project.el`**     | Built in and what eglot, xref, consult and Revere already use. |
| Python           | `elpy` + `anaconda-mode` + `lsp-mode` -> **eglot + a Python server** | Three overlapping stacks today; one is enough. |
| Modeline         | `spaceline` + `mode-icons` -> **`doom-modeline`** (optional) | Actively maintained, nerd-icons native, simple segment API. Revere's segment goes into `global-mode-string` so any modeline works. |
| Folding          | `origami` -> `hideshow` / `outline` (optional) | Built in. Revere buffers fold via `magit-section` regardless. |
| Emoji            | `emojify` -> native (optional)       | Emacs 28+ renders emoji; the fontset line already does the work. |
| Theme, icons, dashboard, company, org, web-mode, auto-revert, line numbers, hl-line | keep | Fine as they are. `company` can become `corfu` to match vertico, but nothing depends on it. |

The two entries that matter for Revere are treemacs and magit. Everything
else is coherence and can be done gradually or not at all; the dispatch
layers keep the old choices working.

Rules the UI follows regardless of stack:

- **Faces inherit, never hardcode.** Every Revere face is a `defface`
  inheriting a standard one: `diff-added` / `diff-removed` for hunks,
  `success` / `warning` / `error` for job and approval states,
  `font-lock-function-name-face` for tool names,
  `font-lock-comment-face` for arguments and timestamps,
  `magit-section-heading` for section titles. Zenburn colours all of it.
- **Icons through nerd-icons, with a text fallback.** Tool calls get a glyph
  by category, files get `nerd-icons-icon-for-file`, states get the same
  glyphs the dashboard uses. In a TTY or without `nerd-icons`, a
  one-character ASCII marker takes the same column. No emoji in tabulated
  lists; their width breaks alignment.
- **Dashboard section.** A `revere` entry in `dashboard-item-generators`
  shows pending approvals, recent jobs with status glyphs, and the next
  scheduled jobs; a navigator button opens `M-x revere`. Adding `routines.org`
  to `org-agenda-files` puts scheduled jobs on the dashboard agenda with no
  code.
- **Mode-line segment.** Active job state, model, and tokens or cost in
  `global-mode-string`, with a `doom-modeline` segment definition when that
  is loaded. This is where pi-emacs's bottom bar and mascot live now.
- **Pickers are `completing-read`** with `completion-metadata` categories
  and affixation functions. Under vertico that yields marginalia
  annotations and embark actions automatically; under ivy it still works,
  minus the actions.
- **Project root** from `project-current`, with `projectile-project-root`
  honoured when projectile is loaded.
- **Special buffers switch off line numbers** in their mode hooks.
  `hl-line` stays on.
- **Auto-revert is compatible.** Staged edits set the modified flag, so
  `global-auto-revert-mode` leaves them alone; in worktree mode Revere's
  saves appear immediately in any buffer visiting the file.
- **Keys.** Transient on `C-c r`, `F9` toggles the workspace layout, `F8`
  stays the tree. Nothing else global.

The dashboard banner reads "Take Dead Aim", which is the brief for the
job buffer: the job's goal at the top, no chatter, the changes below.

Recommended `use-package` forms for the swaps, ready to paste:

```elisp
(use-package treemacs        :bind ("<f8>" . treemacs) :config (treemacs-follow-mode 1) (treemacs-git-mode 'deferred))
(use-package treemacs-nerd-icons :after (treemacs nerd-icons) :config (treemacs-load-theme "nerd-icons"))
(use-package treemacs-magit  :after (treemacs magit))
(use-package magit           :bind ("C-x g" . magit-status))
(use-package diff-hl         :config (global-diff-hl-mode) (diff-hl-flyDIFFMODE))
(use-package eglot           :ensure nil :hook ((python-mode web-mode) . eglot-ensure))
(use-package flymake         :ensure nil)
(use-package vertico         :init (vertico-mode))
(use-package orderless       :custom (completion-styles '(orderless basic)))
(use-package marginalia      :init (marginalia-mode))
(use-package consult         :bind (("C-s" . consult-line) ("C-x b" . consult-buffer) ("C-c j" . consult-ripgrep)))
(use-package embark          :bind (("C-." . embark-act)))
(use-package embark-consult  :after (embark consult))
(use-package doom-modeline   :init (doom-modeline-mode 1))
```

---

## 3. Process model

```
                 +----------------------------------------------+
  emacsclient -c |  emacs --daemon=revere                        |
  (frames) ----> |                                                |
  emacsclient -e |  server.el      timers       curl/SSE          |
  (scripts,   -->|  +----------+  +---------+  +-----------+      |
   cron, CI)     |  | commands |  | sched   |  | model I/O |      |
                 |  +----+-----+  +----+----+  +-----+-----+      |
  server-eval-at |       +----------+-+------------+              |
  (your daily -->|             +----v-----+                        |
   Emacs)        |             | job loop |<-- channels            |
                 |             +----+-----+                        |
                 |                  v                              |
                 |   workspace: buffers . sets of changes . worktrees   |
                 |   tools: fs shell code web org vc emacs msg     |
                 +----------------------------------------------+
                     state: ~/.revere/{logbook,routines,memory,skills}
```

One daemon named `revere`, separate from the daily-driver Emacs so a Revere
restart never costs you buffers. The daily Emacs loads `revere-client.el`,
which forwards commands over `server-eval-at`. Interactive jobs open their
frames on the daemon with `emacsclient -c`, which is where the workspace
lives. If you would rather run it all in one process, `(require 'revere)`
in the daily Emacs is supported and nothing else changes.

**Concurrency model: single-threaded workspace, parallel workers.** The
constraint is that only one Lisp thread touches buffers at a time. That is
the same rule a browser applies to the DOM, and it is a feature for the
workspace: no data races between Revere's edits and yours. Everything
else runs off the main thread:

- **I/O waits** use cooperative `make-thread` (Emacs 26+). A tool written in
  straight-line style that blocks in `accept-process-output` or
  `condition-wait` yields to the UI while it waits, so tools can look
  synchronous without freezing anything. Threads never mutate buffers; they
  hand results back through `thread-join` or a mutex-guarded queue.
- **CPU-bound Lisp** runs in a worker pool: N child Emacsen started with
  `async-start`, each with the Revere code loaded, receiving closures and
  returning sexps over the process pipe. Grep over a large tree, diff
  generation for a big changes, embedding computation, and Org parsing of
  the logbook go here. Code is data, so shipping a job is `prin1`, not a
  serialization layer.
- **Real OS threads** are available through dynamic modules (`emacs-module.h`
  with the Rust `emacs` crate or C) delivering results via
  `make-pipe-process`. Reserved for hot paths such as a websocket gateway or
  vector search if the worker pool is not enough.
- **Native speed where it matters.** `json-parse-buffer`, regex search,
  `replace-match`, `diff` via the `diff` binary, and ripgrep as a subprocess
  keep bulk text work in C.

Model calls are curl subprocesses with filters; shell tools are
`make-process` with sentinels. The one banned pattern is pi-emacs's
`accept-process-output` loop on the main thread.

Lifecycle:

```elisp
;; ~/.revere/init.el   started by: runemacs --daemon=revere -Q -l ~/.revere/init.el
(setq server-name "revere" server-use-tcp t)     ; TCP is required on Windows
(require 'revere)
(revere-daemon-start)
```

---

## 4. Layers and files

```
revere/
  lisp/
  revere.el               entry, defcustoms, autoloads
  revere-llm.el           transport: curl + SSE (from pi-emacs-llm), backends
  revere-models.el        model discovery (from pi-emacs-models)
  revere-loop.el          job loop, non-blocking tool dispatch (from pi-emacs-agent)
  revere-tools.el         revere-deftool, registry, schema, rules
  revere-ws.el            workspace: buffer tracking, sets of changes, change groups,
                          staleness, save/revert, worktrees
  revere-changes.el       diff-mode changes buffer, hunk keep/discard
  revere-tree.el          treemacs annotations + extension node, dired fallback
  revere-job.el       magit-section job buffer
  revere-layout.el        display-buffer-alist, workspace command
  revere-tools-fs.el      read/edit/write/list/glob/grep (buffer-based)
  revere-tools-code.el    problems, rename, code actions, xref, compile
  revere-tools-shell.el   async shell, TRAMP aware
  revere-tools-web.el     fetch, render
  revere-tools-org.el     memory, capture, agenda
  revere-tools-vc.el      status/diff/commit via vc + magit
  revere-tools-emacs.el   eval, describe, apropos, define-tool
  revere-routines.el         org jobs, timers, check-in
  revere-approve.el       approval queue, approvals list
  revere-chan-*.el        ement, mail, telega, http
  revere-daemon.el        bootstrap, restore, shutdown
  revere-client.el        thin client for the daily Emacs
  skills/*.org
  test/*.el

~/.revere/
  init.el custom.el logbook.org routines.org check-in.org
  memory/MEMORY.org memory/*.org
  skills/*.org
  wt/<job-id>/            worktrees for unattended jobs
```

### 4.1 Model layer

`pi-emacs-llm` stays: a curl subprocess speaking OpenAI-compatible SSE to a
LiteLLM proxy, which already fronts every provider. It is small, tested
against canned byte streams, and has no UI opinions. gptel is not a
dependency. If direct provider APIs are wanted later, the `llm` library
(GNU ELPA) slots in behind the same `revere-llm-stream` signature; gptel's
`gptel-request` would also fit but brings nothing the transport lacks.

Two changes from pi-emacs:

- Tool calls are dispatched asynchronously. A tool may return a value or a
  promise-like `(revere-async FN)`; the loop resumes when every call for the
  turn has resolved. Shell, compile and web tools are async.
- The loop has a `:workspace` slot and hands every tool the job, so tools
  record entries in the changes without globals.

### 4.2 Tool layer

```elisp
(defmacro revere-deftool (name args docstring &rest body)
  "Define revere-tool-NAME as a function and register it.
ARGS: list of (SYM TYPE DESCRIPTION &key optional)."
  (declare (indent defun) (doc-string 3))
  (let ((fn (intern (format "revere-tool-%s" name))))
    `(progn
       (defun ,fn ,(mapcar #'car args) ,docstring ,@body)
       (revere-tools-register
        ',name #',fn
        ,(car (split-string docstring "\n\n"))
        (revere-tools--schema ',args)))))       ; -> JSON schema plist as in pi-tools
```

The docstring is the description the model sees; `describe-function` shows
it verbatim. Tools are plain functions Revere can also call from Elisp,
and `ert` tests them with no model in the loop.

One correctness note carried over from pi-emacs: `return-from` inside a plain
`defun` has no enclosing block and signals at runtime. Revere uses
`cl-defun` where early exit is needed, or restructures with `cond`.

### 4.3 Rules

```elisp
(setq revere-rules
      '((read edit write glob grep problems . go-ahead)   ; buffers only
        (save-changes . check)                                ; the real gate
        (shell . ((never . ("\\brm -rf\\b" "\\bsudo\\b" "--force"))
                  (go-ahead . ("^\\(ls\\|git status\\|git diff\\|make test\\)"))
                  (t     . check)))
        (eval . check)
        (send-message . check)
        (t . never)))
```

Interactive: `check with me` prompts in the job buffer's Approvals section (never
a modal `yes-or-no-p` mid-stream). Daemon: the job parks as
`WAITING`, the approvals list and the job's channel are notified, and the
next client frame opens `*Revere: approvals*`.

### 4.4 Logbook, scheduler, memory, skills, self-reference, channels

Unchanged in substance from the first draft; summarised here.

- **Logbook** `logbook.org`: one heading per job with `:ID:`, `:STATUS:`,
  `:MODEL:`, `:CHANGES:` (paths + diffstat + outcome), transcript as
  subheadings, `org-clock` for timing. The states from 2.0 are `org-todo`
  keywords (`QUEUED WORKING WAITING REVIEW | DONE FAILED DISCARDED`), so
  `org-agenda` is a dashboard for free.
- **Scheduler** `routines.org`: `ROUTINE` headings with `SCHEDULED` repeaters; a
  60 s `run-with-timer` tick runs `org-ql-select` for due entries; `org-todo`
  to `DONE` bumps the repeater. Check-in is a 30 min timer over
  `check-in.org`.
- **Memory** `memory/MEMORY.org` index injected into the system prompt;
  `memory-search` via `org-ql`, `memory-add` via a programmatic
  `org-capture` template.
- **Skills** use the Agent Skills format that Hermes, Claude Code and the
  Anthropic skills repo share: a directory holding `SKILL.md` with YAML
  frontmatter (`name`, `description`, optional `allowed-tools`, `metadata`)
  and a Markdown body, plus optional `scripts/`, `references/`, `assets/`.
  Revere reads it as is, so any published skill installs with `git clone`
  into `~/.revere/skills/`. Progressive disclosure is the same three tiers:
  name and description in the system prompt at startup, body inserted when
  the skill triggers, references read on demand by the `read` tool.

  ```elisp
  (defun revere-skill--frontmatter (file)
    "Return the YAML frontmatter of FILE as an alist. Flat key: value only."
    (with-temp-buffer
      (insert-file-contents file nil 0 4096)
      (goto-char (point-min))
      (when (looking-at "---\n")
        (let ((end (save-excursion (re-search-forward "^---$" nil t))) out)
          (while (re-search-forward "^\\([a-z-]+\\):[ \t]*\\(.*\\)$" end t)
            (push (cons (intern (match-string 1)) (string-trim (match-string 2))) out))
          out))))

  (defun revere-skills-index ()
    "Scan `revere-skill-dirs' for */SKILL.md; return (name description dir) triples."
    (cl-loop for dir in revere-skill-dirs
             append (cl-loop for f in (file-expand-wildcards (expand-file-name "*/SKILL.md" dir))
                             for fm = (revere-skill--frontmatter f)
                             collect (list (alist-get 'name fm)
                                           (alist-get 'description fm)
                                           (file-name-directory f)))))
  ```

  The Emacs-native extension is one optional file beside `SKILL.md`:
  `skill.el` (or `SKILL.org` with `elisp` blocks for the literate style).
  If present it is loaded when the skill triggers and may define tools with
  `revere-deftool`, add advice, or register hooks; `unload-feature` removes
  it. A skill with only `SKILL.md` and `scripts/` is portable to Hermes and
  Claude Code unchanged; one with `skill.el` is Revere-only and says so in
  its `metadata`. `revere-skill-new` scaffolds a directory from a template;
  Revere's `define-skill` tool writes the same layout and must pass the
  byte compiler, `checkdoc`, and any `ert` block before it is enabled.
- **Self-reference** tools (`eval`, `describe`, `apropos`, `find-source`,
  `define-tool`, `edit-self`, `trace`) are all rules-gated; `edit-self`
  goes through the same changes review as any other edit.
- **Channels**: the adapter contract is two functions (send, and a listener
  that enqueues inbound messages), so a channel is a small file. Available
  building blocks, by maturity:
  - Mature packages: Telegram (`telega`, TDLib), Matrix (`ement`), IRC
    (`erc`, built in), XMPP (`jabber`), Mastodon (`mastodon`), email
    (`gnus`/`notmuch`/`mu4e` + `smtpmail`), RSS (`elfeed`), GitHub/GitLab
    (`ghub`, `forge`).
  - Aging but usable: Slack (`emacs-slack`, on `websocket.el`).
  - Thin adapters to write: Discord (bot gateway over `websocket.el` +
    `plz`, a few hundred lines; third-party user clients are against
    Discord's terms so a bot is the right shape anyway), Signal
    (`signal-cli` JSON-RPC daemon as a subprocess), WhatsApp (Business API
    over `plz`, or a bridge process).
  - Inbound webhooks: `simple-httpd` or `web-server`.
  Order: emacsclient, Matrix, email, Telegram, Discord.
- **Other agents as tools**: `acp.el` / `agent-shell` give Emacs an Agent
  Client Protocol client, so Claude Code, Gemini CLI or Codex can job as
  Revere subagents inside the same workspace. `mcp-server-lib` runs Emacs as
  an MCP server, exposing Revere's tools to outside assistants.
- **Voice and vision**: `whisper.el` for speech to text, TTS via `piper` or
  `edge-tts` subprocess, native image display plus `tesseract` for OCR,
  vision by sending images to the model. Hermes does these through
  subprocesses and API calls too; parity is adapter work, not a gap.

---

### 4.5 Subagents over ACP

The Agent Client Protocol is JSON-RPC over stdio between a client (an
editor) and an agent process. `acp.el` implements the client; `agent-shell`
ships launch configurations for Claude Code, Gemini CLI, Codex and others.
Revere spawns the agent, owns the session, and is the client for every
callback. The flow that matters:

```
Revere (client)                          agent process (Claude Code, pi, ...)
  initialize  ── client caps: fs, terminal ──►
  session/new ── cwd, mcpServers ─────────►
  session/prompt ── text + resource blocks ►
             ◄── session/update (chunks, tool calls, plan)
             ◄── fs/read_text_file            → Revere serves from the live buffer
             ◄── fs/write_text_file           → Revere edits the buffer; entry in the changes
             ◄── terminal/create, /output     → Revere shell tool, TRAMP aware
             ◄── session/request_permission   → Revere rules; Approvals section
  session/cancel, session/set_mode, session/load
```

ACP has no system-prompt field and no skills concept, so each thing Revere
wants the subagent to know travels on the channel that agent already reads:

| What                                   | Channel                                                                 |
|----------------------------------------|-------------------------------------------------------------------------|
| The task, triggered skill bodies, relevant memories | `session/prompt`: text plus `resource` content blocks (inline file text) so nothing depends on the agent's own discovery |
| Standing instructions, persona, house rules | `AGENTS.md` (also `CLAUDE.md` / `GEMINI.md` where the agent insists) written into the cwd; the closest thing ACP agents have to a system prompt |
| The skills library                     | Shared `SKILL.md` directories: point the agent's config at `~/.revere/skills`, or place a directory junction at `.claude/skills` in the worktree. Same format, so nothing is converted |
| Tools                                  | `mcpServers` in `session/new`. Revere itself is one of them via `mcp-server-lib`, so the subagent can call `memory-search`, read the logbook, or run Revere tools |
| Permission mode                        | `session/set_mode` mapped from the job's rules preset                  |
| Where it works                         | `cwd` is the job's worktree for unattended jobs, the project for interactive ones |

The part that makes ACP worth using rather than a plain subprocess is the
reverse direction. Because Revere advertises the `fs` capability, the
subagent's file reads come from live buffers and its writes land in buffers
as entries in the changes, so its work is reviewed in the same changes buffer,
with the same hunk-level discard, as Revere's own. Terminal calls go through
Revere's shell tool, so `default-directory` decides whether the subagent's
commands run locally, in Docker, or over SSH without the subagent knowing.
Permission requests hit Revere's rules. The agent's session id is stored on
the job heading so `session/load` can resume it.

Agents that speak only their own RPC (pi's `--mode rpc`, for instance) are
wrapped by a small adapter that maps to the same five callbacks; the rest
of Revere does not care which subagent is on the other end.

## 5. What to carry from pi-emacs

| Keep                                                    | Replace                                                       |
|---------------------------------------------------------|---------------------------------------------------------------|
| `pi-emacs-llm`: curl + SSE, tool-fragment merge, timeouts | `pi-tools--apply-write` / `--refresh-buffer` (disk writes)  |
| `pi-emacs-models`: discovery, tool-capability tristate   | `yes-or-no-p` gates in `write`/`edit`/`pi-tools/call`        |
| `pi-emacs-agent`: message list, usage accounting, interrupt | `pi-tools--bash` blocking loop -> `make-process` + sentinel |
| Tool schema shape (`:type "object"` plists)              | `*pi*` buffer and footer -> job buffer + changes + tree         |
| Test approach: canned SSE streams                        | `pi-tools--walk` / grep in Elisp -> `project-files` + `xref-matches-in-files` or ripgrep subprocess |
| Mascot, if you like it (as a mode-line segment)          | `return-from` in `defun`                                     |

---

## 6. Delivery phases

Status as of 2026-09-02: every phase is built and tested, plus the board
(cards workers pick up), compaction, logbook search, web fetch and search,
routine delivery to channels, shell rules by pattern, cost, model
fallback, a plan tool, delegation to helper jobs, a doctor, and per-worker
personas. Two deliberate departures remain. Phase 5 has the channel layer and Discord, the
user's choice, and no Matrix or email. Phase 2's magit-section transcript
was not done; tool results fold out under their line with a click instead,
which keeps the chat free of external dependencies. The section 10 memory
and debrief are built; the weekly tidy-up is left to the debrief prompt.

1. **Workspace core.** `revere-ws`, `revere-changes`, buffer-based
   `read`/`edit`/`write`, change groups, staleness, save/revert. Drive it
   with the pi-emacs loop and a plain `M-x revere-new` from a normal Emacs.
   Success: run a multi-file refactor, review it in the changes buffer,
   discard two hunks, keep the rest.
2. **Session + tree + layout.** `magit-section` job buffer, treemacs
   annotations, `revere-workspace`, async shell, problems tool.
3. **Daemon + logbook + scheduler.** Worktree mode for unattended jobs,
   `logbook.org`, `routines.org`, restore on restart, `revere-client.el`.
4. **Approvals + approvals list + notifications.**
5. **Channels.** Matrix, then email.
6. **Skills, MCP, sandbox, self-extension.**

---

## 7. Risks and mitigations

| Risk                                                | Mitigation                                                        |
|-----------------------------------------------------|-------------------------------------------------------------------|
| User and Revere edit the same buffer                | tick-based staleness check; edits are undoable; change groups     |
| Large sets of changes make `diff-no-select` slow          | regenerate per file on demand; cap at N files then fall back to worktree mode |
| `diff-apply-hunk` misapplies after the buffer moved  | regenerate the diff before applying (`g` is implicit on `k`)      |
| Main thread stalls                                  | I/O in cooperative threads, CPU in the worker pool, modules for hot paths; buffers only from the main thread |
| Model proxy drift                                   | transport isolated in `revere-llm.el`; `llm` as fallback          |
| Runaway cost                                        | `:BUDGET:` and `:DEADLINE_MIN:` per job; interrupt kills curl     |
| Windows daemon quirks                               | TCP server, `runemacs`, Task Scheduler; tested in phase 3         |

## 8. Principles carried from modern harnesses

The design goal is old substrate, new shape. Each principle below is
something Claude Code, Hermes, OpenClaw or pi got right; the right column is
the Emacs mechanism that already implements it, usually older than the
harness by decades.

| Harness principle                         | Revere mechanism                                                      |
|-------------------------------------------|-----------------------------------------------------------------------|
| Structured tool calling with schemas      | `revere-deftool`: schema derived from the arglist and docstring       |
| Programmatic tool calling ("code mode")   | an `elisp` tool: the model writes a small program composing tools, run once under rules; Emacs is the ideal host for this |
| Permission modes (plan / ask / auto)      | rule presets: `look only`, `check with me`, `go ahead`, per-directory    |
| Pre/post tool hooks                       | `revere-before-tool-functions` / `-after-` abnormal hooks, plus `advice-add` on any tool for users |
| Progressive disclosure (skills on demand) | `SKILL.md` frontmatter always loaded, body on trigger, references on demand; format shared with Hermes and Claude Code so their skill libraries install with `git clone` |
| Memory files + compaction                 | `MEMORY.org` index in the system prompt; old turns summarised into the job heading |
| Checkpoints and rewind                    | change groups, `buffer-undo-list`, worktree branches                  |
| Subagents / delegation                    | a child job with its own set of changes in-process, or `async-start` / a second daemon via `server-eval-at` for isolation |
| Headless mode (`claude -p`)               | `emacsclient -s revere -e '(revere-new "...")'`                       |
| Cron and check-in                        | Org repeaters + `run-with-timer`                                      |
| MCP                                       | `mcp.el`, tools mapped into the registry                              |
| Sandboxing                                | TRAMP `/docker:` and `/ssh:` via `default-directory`                  |
| Cost and budget                           | usage accounting from pi-emacs, `:BUDGET:` per job                    |
| Streaming, interruptible UI               | curl filter -> job buffer; interrupt kills the process            |
| Traces and observability                  | `logbook.org` logbook, `*revere-log*`, `trace-function` on demand         |
| Slash commands                            | `transient` menu and plain `M-x`                                      |
| Multi-channel gateway                     | `revere-chan-*` adapters                                              |
| Self-improvement (agent writes skills)    | `define-tool` / `define-skill` gated by byte-compile warnings, `checkdoc`, `ert` |

## 9. Self-debrief in practice

Emacs is a Lisp image with forty years of introspection built in. Revere
uses it directly instead of building a parallel registry.

- **Tools are commands.** `revere-deftool` adds an `interactive` spec, so
  every tool is also `M-x revere-tool-<name>` for a human, `C-h f` documents
  it, and it can be bound to a key. The reverse also holds:
  `revere-expose-command` turns any existing command into a tool, taking the
  description from `documentation` and the parameters from
  `help-function-arglist`. The curated registry is a front page; the tool
  surface is all of Emacs, reached through `eval` under rules.
- **Discovery is a tool.** `apropos-internal` and `apropos-documentation`
  let the model find `dired-do-rename` or `org-schedule` by itself, then
  read the docstring, then call it. No tool description needs to be written
  for functionality Emacs already documents.
- **Metadata lives on the symbol.** Rules, category, and origin are stored
  with `function-put` and read with `function-get`. `load-history` records
  which file defined each tool, so `unload-feature` removes a skill cleanly
  and `find-function` opens its source.
- **Hooks are advice.** Users extend or restrict any tool with `advice-add`
  without touching Revere. Revere's own hook points are ordinary
  `run-hook-with-args-until-success` chains, which is also how the rules
  engine composes rules.
- **Revere debugs itself.** A `trace` tool wraps a function with
  `trace-function-background` for one job; `profiler-start` answers "why is
  this slow"; `macroexpand-all` shows what a `deftool` form became;
  `edebug` is available when a human is attached.
- **Model-written code is linted by the compiler.** Before `define-tool` or
  `edit-self` loads anything, the form goes through `byte-compile` with
  warnings captured, `checkdoc` on the docstring, and the skill's `ert`
  block. Failures are returned to the model as tool errors.
- **Config is typed.** Settings are `defcustom` with `:type`, so when the
  model changes one through `customize-set-variable` the value is validated
  and persisted to `custom-file` like any user change.
- **Code is data.** Transcripts, tool calls, and sets of changes are sexps that
  `print` and `read` round-trip, so `logbook.org` source blocks are executable
  records, not just logs.

The stability argument cuts one way in dependency choice: everything in
section 9 is core Emacs and can be relied on across versions without pins.
Of the external packages, `magit-section`, `diff-hl`, `treemacs`, `org-ql`
and `async` are eight to fifteen years old and safe to depend on directly;
`ement`, `mcp.el`, and `telega` are younger and stay behind adapter files so
they can be swapped without touching the core.

## 10. Learning over time

"Getting better at the work" has three layers with different mechanisms.
Hermes's RL is the third and is a non-goal here; the first two deliver the
practical gain and are entirely in Org.

### 10.1 In-context: memory and skills

What every job sees: `MEMORY.org` index in the system prompt, skill names
and descriptions, and `memory-search` for recall. Memories are one heading
per fact with properties:

```org
* Prefer eglot-rename over textual rename for Elisp symbols
:PROPERTIES:
:ID:         3a1f...
:TYPE:       feedback
:CREATED:    [2026-09-02 Wed]
:LAST_USED:  [2026-09-02 Wed]
:HITS:       4
:CONFIDENCE: high
:SOURCE:     job:7f3c
:END:
Why: a text rename in job 7f3c touched a docstring and was discarded.
How to apply: call rename-symbol first; fall back to edit only if eglot is off.
```

This is where the reinforcement lives, and it is all `org-ql` and
properties. Recall bumps `:HITS:` and `:LAST_USED:`. A weekly tidy-up
job promotes high-hit facts into the always-loaded index, demotes unused
ones to search-only, merges duplicates, and flags contradictions for you.
Because memory edits are buffer edits, proposed memories go through
the same changes buffer as code: you keep or discard what it learned,
hunk by hunk. Unlike weights, what was learned is readable and correctable.

Skills carry the same signal. `:METADATA:` in the skill's sidecar records
jobs used, kept fraction, and last failure, so the index orders skills
by track record and a failing skill is surfaced for revision rather than
silently retried.

### 10.2 Debrief: the nightly debrief job

A scheduled `ROUTINE` in `routines.org` runs after quiet hours. It queries
`logbook.org` for jobs finished since the last debrief and looks at the
signals the workspace produced for free:

- hunks discarded, with the optional one-line reason typed at `k`
- edits the user made to kept files within the following day (`vc`
  history shows them)
- tool errors and retries, especially stale-buffer errors
- approvals denied, and shell commands that hit a `never` rule
- tests or problems that failed after Revere declared done
- repeated instructions across prompts ("no, use the Makefile target")

It writes candidate memories and skill revisions, which land in the
changes for your review next morning. This is what Hermes calls
self-improvement and OpenClaw does through check-in; here it is an Org
query plus one model call, and its output is reviewable text.

### 10.3 Weight-level training: out of scope

Revere does not train models and has no plans to. The logbook happens to
hold everything a trainer would want (prompts, transcripts, tool calls,
sets of changes, per-hunk outcomes), so if that ever changes it is an export
command over `org-element`, not an architectural change. Nothing in the
design is shaped to accommodate it.

## 11. Dependencies

Built in (29+): `server`, `timer`, `tramp`, `auth-source`, `sqlite`, `json`,
`url`, `shr`, `org`, `project`, `xref`, `eglot`, `flymake`, `treesit`,
`diff-mode`, `ediff`, `hilit-chg`, `dired`, `vc`, `transient`,
`tabulated-list`, `ert`, `notifications`, `smtpmail`, `erc`.

ELPA/MELPA: `magit` + `magit-section`, `diff-hl`, `treemacs`, `org-ql`,
`async`, `plz`, `ement`, `alert`, `simple-httpd`, `mcp.el`; optional `llm`,
`telega`, `notmuch`, `org-roam`, `vundo`.
