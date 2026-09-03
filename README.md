# Revere

An agentic framework built on Emacs.

Revere has the parts every agentic harness has: a model loop that calls
tools until the work is done, a tool registry, skills, long-term memory
with a nightly debrief, routines on a schedule, a board that jobs can be
pinned to, subagents, MCP servers, approvals and rules, and channels such
as Discord. It is built entirely from Emacs Lisp on a runtime that has
been debugged for forty years, and that runtime is what sets it apart:

- **It works in buffers, never on disk.** Edits land in Emacs buffers
  with the changed lines marked, undo is the rollback, and diff-mode is
  the review. You keep or discard in the file itself, from the chat, or
  in one diff across everything it touched. Nothing reaches disk until
  you say so.
- **The chat drives the editor.** Every tool call in the transcript is a
  link to the buffer, search, directory or shell output behind it. The
  file being edited follows along in the main window, and the chat docks
  to the side on its own once it has something to show.
- **Org is the database.** The logbook, routines, board, memory and
  check-in are Org files, so agenda, capture, search and version control
  already work on them.
- **It can see and change itself.** Every tool is an Emacs command, the
  whole framework is inspectable with `describe-function`, and the model
  can read its own source, define new tools at runtime, and advise its own
  behaviour, all without a restart.
- **One process, attended or not.** A headless `emacs --daemon` runs the
  routines, the check-in and the Discord channel; you attach with
  `emacsclient` to watch or take over. Unattended jobs run in git
  worktrees you merge when you are happy.

Everything sits on what Emacs already has: buffers, undo, diff-mode,
ediff, Org, TRAMP, the server. The reasoning behind it is in
[DESIGN.md](DESIGN.md).

- [Requirements](#requirements)
- [Install](#install)
- [Your first job](#your-first-job)
- [Using Revere](#using-revere)
  - [The chat](#the-chat)
  - [Reviewing changes](#reviewing-changes)
  - [Approvals](#approvals)
  - [Keys and commands](#keys-and-commands)
- [Running unattended](#running-unattended)
  - [Routines](#routines)
  - [The check-in](#the-check-in)
  - [Worktrees](#worktrees)
  - [The daemon](#the-daemon)
  - [In a container](#in-a-container)
  - [Discord](#discord)
- [Extending Revere](#extending-revere)
  - [The system prompt](#the-system-prompt)
  - [Skills](#skills)
  - [Memory and the debrief](#memory-and-the-debrief)
  - [Tools](#tools)
  - [MCP servers](#mcp-servers)
  - [Sandbox and remote work](#sandbox-and-remote-work)
- [Reference](#reference)
  - [Words](#words)
  - [Files](#files)
  - [Settings](#settings)
  - [Rules](#rules)
- [Troubleshooting](#troubleshooting)
- [Developing](#developing)

## Requirements

- Emacs 29.1 or later. Built and tested on 31.1.
- An OpenAI-compatible chat endpoint: a LiteLLM proxy, Ollama, or a
  provider's API. The key comes from `auth-source` or `revere-api-key`.
- On the path: `curl` (the model transport) and `diff` (the review). On
  Windows both come with Git for Windows.
- Optional: `git` for worktrees and unattended jobs, `rg` (ripgrep) for
  faster search, the `websocket` package for Discord, `treemacs` for badges
  in the file tree.

## Install

Clone or copy the directory, then in your init:

```elisp
(add-to-list 'load-path "~/src/revere/lisp")
(require 'revere)
(setq revere-base-url "http://localhost:4000"   ; your endpoint
      revere-model    "qwen-3.8")
```

If the endpoint needs a key, either set `revere-api-key` or add a line to
`~/.authinfo` (on Windows, `%APPDATA%\.authinfo`) for the endpoint's host:

```
machine api.example.com login revere password YOUR-KEY
```

Then `M-x revere`. A **Revere** menu appears in the menu bar with
everything below.

## Your first job

1. Open a file in a project and run `M-x revere`. A chat opens on the
   right, working in that project; its header says where.
2. Type what you want done, on as many lines as you like (`S-RET` adds
   one), and press `RET`.
3. Watch. Your message appears as `You ›`, then `Revere ›` streams the
   reply. Each tool call is a line such as
   `✎ edit  README.md → Edited README.md: 1 replacement (unsaved)`. As
   it reads or edits a file, that file opens in the main window at the spot
   it touched, without taking your cursor. Added lines are highlighted and
   removed lines shown in place.
4. When it stops, the header says **to review** and a **Changes** block
   appears above the input: each file with its diffstat and `open`, `diff`,
   `ediff`, `keep` and `discard` links, plus `Review`, `Keep all` and
   `Discard all` for the job.
5. Decide. Click `Review` (or press `c`) for one diff across every file,
   where `k` discards a hunk and `C-c C-c` keeps the rest. Or go to the
   file itself, where `C-c r n` and `p` move between hunks and `C-c r k`
   discards one. Or just click `Keep all`.
6. Nothing touched disk until you kept it. Discarded changes are undone in
   the buffer; the file on disk was never changed.

Follow-ups go in the same chat and continue the same job. `/new` starts
another.

## Using Revere

### The chat

The chat is the hub. Everything Revere does shows up there, and everything
there links back into Emacs. You type in the minibuffer: `RET` in the chat,
or just starting to type, opens a `Revere ›` prompt at the bottom of the
frame, with `M-p` for earlier messages and `C-q C-j` for a line break.
`M-x revere-say` does the same from any buffer. The chat itself is a
read-only transcript with a footer pinned to the bottom of its window: the
horse, and a status line with state, model, thinking level, context use,
tokens, cost and elapsed time. The horse has its head down when there is
nothing to do or something failed, up while it works or waits for you, and
gallops while a job runs; its colour follows the state. `revere-chat-input`
set to `buffer` brings back an input line inside the chat instead of the
minibuffer.

```
       ▄▄▄██
 ▄████████    ◑ working (writing) · qwen-3.8 · think low · ctx 18k/200k 9% · 21k tok $0.04 · 1m02s
▄▀ ▀   ▀ ▀▄   RET or type to talk · /help
```

The sprite is twelve by six pixels drawn with half-block characters, in the
spirit of an Atari 2600 horse; `revere-mascot.el` holds it as rows of `#`
so it can be redrawn by anyone who has drawn a sprite before.

- **Tool lines are links.** `RET` or a click on one opens what it touched:
  the file at the edited spot, a grep result as a buffer you can jump from,
  a glob's files in dired, a shell command's output.
- **Results fold out.** Click the result at the end of a tool line to see
  the full text under it; click again to hide it.
- **The file follows the work** (`revere-follow`). Reads and edits show the
  file in the main window as they happen.
- **The header line** shows the job's state, model, thinking level, how
  full the context is (`ctx 18.4k/200k 9%`, turning amber past 70% and red
  past 90%), total tokens and elapsed time. The context window comes from
  a LiteLLM proxy's model info when there is one, else from
  `revere-context-limits`.
- **Slash commands** do the rest: `/changes` `/keep` `/discard` `/stop`
  `/new` `/dir PATH` `/model M` `/think L` `/jobs` `/ok` `/no` `/prompt`
  `/help`.
- **Approvals** appear inline with buttons when a tool needs your OK.

The chat opens in the main window, full width, and docks itself to a side
window the first time Revere shows you a file, so the file can have the
main window (`revere-chat-dock`: `on-follow`, `always` or `never`).
`/side` and `/wide`, or `C-c C-w`, move it by hand; `revere-chat-side`
and `revere-chat-window-size` say where and how big. The changes buffer
and tool output open at the bottom.

### Reviewing changes

Three places, one set of changes:

| Where              | What it's for                                          |
|--------------------|--------------------------------------------------------|
| the file itself    | see hunks in context; discard one; keep or discard the file |
| the changes buffer | every file as one diff; hunk by hunk with `diff-mode`'s keys |
| the chat           | per-file links and the job-wide `Keep all` / `Discard all` |

Every buffer's header line lists the keys that apply in it. `ediff` is one
key away in all three.

Keeping saves the file. Discarding undoes back to the state when the job
first opened it, using a change group, so your own undo history survives.
If you type in a file the job is working on, its next edit to that file is
refused until it reads the file again, so nothing of yours is overwritten
silently.

### Approvals

Each tool has a rule: **go ahead**, **check with me**, or **never** (see
[Rules](#rules)). When a tool's rule is *check with me*, the job pauses and
the chat shows

```
⏸ needs your OK: shell npm publish --access public   Go ahead   No
```

Click, or type `/ok` or `/no`. `M-x revere-approvals` lists every pending
approval across every job (`y` go ahead, `n` no, `RET` opens the job), and
a desktop notification goes out when one is created. A job that came from
Discord asks there too.

### Keys and commands

| Where               | Key         | Does                                  |
|---------------------|-------------|---------------------------------------|
| chat                | `RET`       | start a message, or follow the link at point |
| chat                | any letter  | start a message with it               |
| minibuffer          | `M-p`       | recall an earlier message             |
| minibuffer          | `C-q C-j`   | add a line break                      |
| chat                | `TAB`       | move between links                    |
| chat                | `c`         | open the changes buffer               |
| chat                | `C-c C-k`   | stop the job                          |
| chat                | `C-c C-w`   | move the chat to the side, or back    |
| a file it changed   | `C-c r n/p` | next / previous hunk                  |
| a file it changed   | `C-c r k`   | discard this hunk                     |
| a file it changed   | `C-c r A`   | keep this file (save)                 |
| a file it changed   | `C-c r K`   | discard this file                     |
| a file it changed   | `C-c r d`   | show the diff                         |
| a file it changed   | `C-c r e`   | ediff against disk                    |
| a file it changed   | `C-c r c`   | back to the chat                      |
| changes buffer      | `n` / `p`   | next / previous hunk                  |
| changes buffer      | `k`         | discard this hunk                     |
| changes buffer      | `K` / `A`   | discard / keep this file              |
| changes buffer      | `e`         | ediff this file against disk          |
| changes buffer      | `RET`       | jump to the source line               |
| changes buffer      | `C-c C-c`   | keep everything                       |
| changes buffer      | `C-c C-k`   | discard everything                    |
| approvals list      | `y` / `n`   | go ahead / no                         |

Commands, all on the Revere menu: `revere` (the latest chat, or a new
one), `revere-new`, `revere-jobs` (switch between jobs, past ones
included), `revere-changes`, `revere-keep-all`, `revere-discard-all`,
`revere-interrupt`, `revere-approvals`, `revere-routines`,
`revere-routine-add`, `revere-check-in`, `revere-logbook`,
`revere-edit-prompt`, `revere-show-prompt`, `revere-skills`,
`revere-skill-new`, `revere-memory`, `revere-debrief`,
`revere-debrief-routine-add`, `revere-mcp-start-all`,
`revere-discord-connect`, `revere-discord-disconnect`,
`revere-daemon-start`, `revere-help`.

Every tool is also a command: `M-x revere-tool-read`, `revere-tool-edit`,
`revere-tool-grep` and so on. `C-h f` on one shows exactly what the model
is told about it.

## Running unattended

Jobs you don't watch come from routines, the check-in, and Discord. They
need somewhere safe to leave their work and a way to reach you.

### Routines

A routine is a heading in `~/.revere/routines.org` with a `SCHEDULED`
time. An Org repeater (`+1d`, `++1w`) makes it recur; Org does the date
maths when the job finishes.

```org
* ROUTINE Nightly tidy
SCHEDULED: <2026-09-03 Thu 06:00 +1d>
:PROPERTIES:
:DIRECTORY: ~/src/revere
:MODEL: qwen-3.8
:END:
Run the tests, fix any warnings the byte compiler reports, and keep the
README's command list in step with revere.el.
```

`M-x revere-routine-add` writes one for you. The text under the heading is
the prompt; `DIRECTORY`, `MODEL` and `MODE` (`worktree` or `buffers`) say
where and how it works. Two more properties: `NOTIFY` names a channel,
such as `discord:123456789012345678`, that hears how the job ended and what
it changed; `PROMPT_FILE` points at a file of standing instructions for
that routine alone, so a reviewer and a coder can have different
personas. Workers on the board take both from their routine. `M-x revere-routine-run-now` on a heading starts
it at once. Add the file to `org-agenda-files` and routines show on your
agenda.

### The check-in

`~/.revere/check-in.org` is a scratchpad Revere reads every half hour
(`revere-check-in-interval`). Write anything below the header; the next
check-in starts a job with it and files the notes under a *Handled*
heading. `#+DIRECTORY:` at the top says where such jobs work.

### The board

`~/.revere/board.org` is a kanban board: one heading per card, its todo
keyword the column, `TODO CLAIMED DOING REVIEW | DONE DROPPED`. Workers
pick cards up.

```org
* TODO Add a --version flag to the CLI
:PROPERTIES:
:FOR: coder
:DIRECTORY: D:/proj/tool
:SKILL: emacs-lisp
:END:
Parse --version, print the version from the package header, exit 0.
```

A worker is a routine of kind `board` with a `WORKER` name;
`M-x revere-board-worker-add` writes one that looks every few minutes. On
each look it takes the first `TODO` card whose `FOR` names it or is empty,
marks it `DOING` with the job number, and runs it as a job, on a branch in
a git repository. The card follows the job: `REVIEW` when it stops with
changes, `DONE` when you keep them, `DROPPED` if discarded or failed. Two
workers with different models or skills split the board by `FOR`.

Jobs can post cards for other workers with the `board-add` tool, which is
how one job hands off work. `M-x revere-board` opens the file,
`M-x revere-board-card-add` adds a card, and `C-c C-x C-c` in the file
shows the columns view. The `org-kanban` package draws it as a board.

### Worktrees

An unattended job in a git repository works on a branch named
`revere/<job-id>` in a worktree under `~/.revere/wt/`, and commits when it
stops, so nothing is lost if Emacs restarts. Its chat shows the branch's
files; **Keep all** merges the branch into the project and **Discard all**
drops it. Outside a repository, or with `revere-unattended-mode` set to
`buffers`, it works in buffers like an interactive job.

### The daemon

Both timers, the logbook and Discord are started by
`M-x revere-daemon-start`, which you can call in a normal Emacs. To run
Revere as a service instead, use `contrib/revere-daemon-init.el` (a copy
sits at `~/.revere/init.el` after install):

```
runemacs --daemon=revere -Q -l %USERPROFILE%\.revere\init.el
```

Connect with `emacsclientw -s revere -c`; the frame opens on the approvals
list if anything is waiting, else on the chat. From your daily Emacs,
`(require 'revere-client)` gives `revere-client-new`,
`revere-client-status` and `revere-client-frame`, which talk to the daemon
over `server-eval-at`.

### In a container

`docker/` holds a Dockerfile and a compose file that run the daemon as a
service, with Emacs 31, git, ripgrep and curl in the image. GitHub Actions
builds it, runs the test suite inside it, and publishes it, so the machine
you deploy to compiles nothing. It is written for Synology Container
Manager and is ordinary Docker everywhere else.
[docker/README.md](docker/README.md) is the walkthrough.

Four volumes, so the folder you edit is not the folder that churns:

| Mount      | Holds                                                                 |
|------------|-----------------------------------------------------------------------|
| `/config`  | what you set: `local.el`, `authinfo`, `prompt.md`, your own skills     |
| `/data`    | what it writes: logbook, routines, check-in, board, memory, worktrees  |
| `/servers` | MCP and ACP servers not in the image, and their package caches         |
| `/work`    | the projects it works on                                              |

Point them at a shared folder and everything it keeps is on your network:
you read the logbook and edit routines over SMB while it works. Settings
come from the environment, so the image holds no addresses or secrets;
`local.el` on the config volume sets anything the environment cannot, and
reloads without a restart.

Attach to it the same way as any daemon, from a shell on the host:

```bash
docker exec -it revere emacsclient -s /run/revere/revere -t
```

### Discord

Messages in the channels you name start jobs or continue them; replies,
approvals and finished changes come back to the channel. Once:

1. In the [developer portal](https://discord.com/developers/applications)
   create an application, open **Bot**, and copy the token. Under
   **Privileged Gateway Intents** turn on **Message Content Intent**.
2. Under **OAuth2 → URL Generator** pick scope `bot` with permissions
   *View Channels*, *Send Messages* and *Read Message History*, open the
   URL and add the bot to your server.
3. Turn on Developer Mode in Discord's settings, right-click the channel
   the bot should listen in, and *Copy Channel ID*.
4. Put the token in `~/.authinfo` (`%APPDATA%\.authinfo` on Windows):

   ```
   machine discord.com login revere-bot password YOUR-TOKEN
   ```

5. Tell Revere the channel and where its jobs work:

   ```elisp
   (setq revere-discord-channels '("123456789012345678")
         revere-channel-directories '(("discord:123456789012345678" . "~/src/revere/lisp")))
   ```

Then `M-x revere-discord-connect`; the daemon connects by itself.
`revere-discord-users` restricts who may talk to it. In the channel:
`/status` `/ok` `/no` `/keep` `/discard` `/stop` `/new TEXT` `/dir PATH`
`/help`.

## Extending Revere

### The system prompt

Every job starts with a system message assembled from, in order:

1. **Standing instructions**: `~/.revere/prompt.md` if it exists, else the
   built-in default. `M-x revere-edit-prompt` creates it from the default.
   Say who Revere is and how it should work here.
2. **Project instructions**: the first of `AGENTS.md`, `CLAUDE.md`,
   `.revere.md` or `REVERE.md` found in the job's directory or a parent.
3. **Environment**: working directory, platform, Emacs version, date, git.
4. **Skills** on offer and what Revere **remembers**.

`/prompt` in the chat, or `M-x revere-show-prompt`, shows the result.

### Skills

A skill is a folder holding `SKILL.md`: YAML frontmatter with `name` and
`description`, then Markdown instructions. It is the format Claude Code
and Hermes use, so published skills install with `git clone` into
`~/.revere/skills/`. Names and descriptions go into every prompt; the model
loads the body with the `skill` tool when one fits. A `skill.el` beside
`SKILL.md` is loaded on first use and may define tools with
`revere-deftool`. `M-x revere-skills` lists them, `M-x revere-skill-new`
writes one. Revere ships with `emacs-lisp`.

### Memory and the debrief

`memory-add` and `memory-search` are tools the model uses for durable
lessons: corrections, preferences, project facts. Facts live in
`~/.revere/memory/facts.org` with a type, dates and a hit count; the index
`MEMORY.org` goes into every prompt. `M-x revere-memory` opens it.

`M-x revere-debrief` starts a job that reads the day's jobs from the
logbook and remembers what is worth keeping. `M-x revere-debrief-routine-add`
makes that run every morning at six.

### Tools

Built in: `read`, `edit`, `write`, `glob`, `grep`, `shell`, `problems`,
`describe`, `apropos`, `eval`, `define-tool`, `skill`, `memory-add`,
`memory-search`.

- `problems` runs the editor's checkers (flymake, or flycheck where it's
  on) over the changed files. The prompt tells the model to run it after
  editing code. For Emacs Lisp the byte compiler only checks files in
  `trusted-content`.
- `describe` and `apropos` give the model Emacs's own documentation.
- `eval` runs Lisp in the running Emacs. `define-tool` adds a tool from
  source once it byte-compiles without warnings and its ert tests pass.
  Both ask first by default.

Defining one yourself, in your init or a skill's `skill.el`:

```elisp
(revere-deftool word-count ((path string "File to count"))
  "Count the words in a file."
  (with-temp-buffer
    (insert-file-contents path)
    (format "%d words" (count-words (point-min) (point-max)))))
```

The docstring's first paragraph is what the model sees; the arguments
become its JSON schema; `M-x revere-tool-word-count` works too. Give it a
rule in `revere-rules` or it inherits the default (`never`).

### MCP servers

```elisp
(setq revere-mcp-servers
      '(("fs" :command "npx"
              :args ("-y" "@modelcontextprotocol/server-filesystem" "D:/proj"))))
```

`M-x revere-mcp-start-all` (the daemon does it) registers each server's
tools as `mcp-SERVER-TOOL`. They ask first unless `revere-rules` or
`revere-mcp-rule` says otherwise.

### Web

`fetch` gets a URL and renders HTML to text with shr, the engine behind
eww. `search` uses DuckDuckGo with no setup; `revere-search-provider` can
instead name a SearXNG instance (`revere-search-url`) or Brave (key in
`auth-source` for `api.search.brave.com`).

### Long jobs

- **Compaction.** When a request uses more than `revere-compact-fraction`
  of the model's window (or `revere-compact-tokens` when it is unknown),
  the older part of the transcript is summarized into one message before
  the next turn, keeping the last `revere-compact-keep` messages. The chat
  notes when it happens.
- **A plan.** The `plan` tool keeps a checklist the chat shows above the
  changes, with items ticked off as the model goes.
- **Helpers.** The `delegate` tool runs a self-contained task as a helper
  job with its own context and waits for the answer. The helper's edits
  join the parent's changes, so you still review once.
- **Past jobs.** The `logbook-search` tool finds earlier jobs by words in
  their prompts, replies and tool results.
- **Fallback models.** `revere-model-fallbacks` lists models to try in
  order when a request fails; the chat notes the switch.

### Sandbox and remote work

Tools follow the job's directory, and TRAMP paths are directories too.
`/dir /docker:sandbox:/work/` in the chat, or a `DIRECTORY` of
`/ssh:host:/srv/app/` on a routine, runs every read, edit, grep and shell
command there. Nothing else changes.

## Reference

### Words

| Word          | Meaning                                                              |
|---------------|----------------------------------------------------------------------|
| job           | one piece of work with one prompt; ends when you keep or discard the result |
| routine       | a job that runs itself on a schedule                                 |
| check-in      | the scratch file Revere reads every so often                         |
| keep, discard | accept or undo changes; magit's words                                |
| approval      | a tool waiting for your OK                                           |
| logbook       | every job, on disk, in Org                                           |
| skill         | a folder of instructions the model loads when they fit               |
| memory        | facts Revere keeps between jobs                                      |
| debrief       | the job that reads the day's logbook and writes memory               |

### Files

All under `revere-directory`, `~/.revere/` by default. Set
`revere-config-directory` to keep the first four somewhere else, as the
container does when configuration and state are separate volumes:

| File            | Holds                                                    |
|-----------------|----------------------------------------------------------|
| `logbook.org`   | every job: state, prompt, transcript, events, changes    |
| `routines.org`  | scheduled jobs                                           |
| `check-in.org`  | notes for the next check-in                              |
| `prompt.md`     | your standing instructions (optional)                    |
| `memory/`       | `MEMORY.org` index and `facts.org`                       |
| `skills/`       | your skills, one folder each                             |
| `wt/`           | worktrees of unattended jobs                             |
| `init.el`       | the daemon's init (from `contrib/`)                      |

### Settings

Model and transport: `revere-base-url`, `revere-api-key`, `revere-model`,
`revere-model-fallbacks`, `revere-thinking-level`, `revere-context-limits`,
`revere-context-limit`, `revere-llm-timeout`, `revere-max-turns`,
`revere-compact-fraction`, `revere-compact-tokens`, `revere-compact-keep`.

Tools: `revere-rules`, `revere-command-rules`, `revere-shell-timeout`,
`revere-tool-result-limit`, `revere-read-limit`, `revere-grep-limit`,
`revere-glob-limit`, `revere-glob-skip`, `revere-problems-wait`,
`revere-search-provider`, `revere-search-url`, `revere-fetch-limit`.

Chat and layout: `revere-chat-input`, `revere-chat-dock`, `revere-chat-side`,
`revere-chat-window-size`, `revere-follow`, `revere-mascot-frames`,
`revere-mascot-interval`.

Unattended: `revere-directory`, `revere-config-directory`, `revere-routine-tick`,
`revere-check-in-interval`, `revere-unattended-mode`.

Channels: `revere-discord-token`, `revere-discord-channels`,
`revere-discord-users`, `revere-discord-autoconnect`,
`revere-channel-directories`, `revere-channel-default-directory`,
`revere-client-server`.

Extending: `revere-system-prompt`, `revere-project-instruction-files`,
`revere-project-instructions-limit`, `revere-skill-dirs`,
`revere-memory-prompt-limit`, `revere-mcp-servers`, `revere-mcp-rule`.

`M-x customize-group RET revere` shows them all with their docs.

### Rules

`revere-rules` is an alist of tool name to `go-ahead`, `check` or
`never`, with `t` as the default. The shipped setting lets the file, search,
lookup, skill and memory tools run freely, because nothing reaches disk
until you keep it, and asks before `shell`, `eval` and `define-tool`:

```elisp
(setq revere-rules
      '((read . go-ahead) (edit . go-ahead) (write . go-ahead)
        (glob . go-ahead) (grep . go-ahead) (problems . go-ahead)
        (describe . go-ahead) (apropos . go-ahead)
        (skill . go-ahead) (memory-search . go-ahead) (memory-add . go-ahead)
        (shell . check) (eval . check) (define-tool . check)
        (t . never)))
```

A tool's own rule (MCP tools carry `revere-mcp-rule`) applies when the
alist has no entry for it.

Shell commands are also matched against `revere-command-rules`, a list of
regexps tried in order, before the `shell` rule applies. The shipped list
refuses `rm -rf`, `sudo` and forced pushes outright, asks before `git
push`, and lets `git status`, `ls`, the test runners and `bin/check.sh`
through without asking.

## Troubleshooting

`M-x revere-doctor` first: it checks the endpoint, the programs on the
path, the optional packages, the Discord token, the files under
`~/.revere/`, and whether the byte-compile checker will run.

- **"curl exited with status 7"** or the job fails at once: the endpoint
  isn't answering. Check `revere-base-url`; `localhost:4000` is only a
  default.
- **Job stops with "stopped after 25 turns"**: the model kept calling tools.
  Raise `revere-max-turns` or give a narrower prompt.
- **"Stale: … changed since it was last read"** in a tool line: you typed
  in a file the job was editing. It will read the file again; nothing of
  yours was lost.
- **`problems` reports nothing for an `.el` file with obvious errors**: the
  byte-compile checker only runs on trusted files. Add the project to
  `trusted-content`.
- **Discord won't connect**: install the `websocket` package, check the
  token line in `.authinfo`, and confirm the Message Content intent is on.
  The bot only answers in `revere-discord-channels`.
- **Nothing on the dashboard or agenda**: add
  `~/.revere/routines.org` to `org-agenda-files`.
- **Emacs started from a terminal finds no config**: on Windows the GUI
  uses `%APPDATA%\.emacs.d`; Git Bash sets `HOME` elsewhere.

## Developing

```bash
bin/check.sh
```

compiles every file with warnings as errors, runs checkdoc, and runs the
ert suite in `test/`. Emacs is found on the path or at the standard Windows
location; set `EMACS` to override. The tests fake the model and use a
throwaway `revere-directory`; the MCP test runs a fake server written in
Elisp.

Layout:

| Path        | Holds                                                    |
|-------------|----------------------------------------------------------|
| `lisp/`     | the package, one file per concern, `revere.el` the entry point and menu |
| `test/`     | the ert suite and the fake MCP server                    |
| `skills/`   | skills shipped with Revere                               |
| `contrib/`  | an example init and the daemon init                      |
| `bin/`      | `check.sh`                                               |
| `DESIGN.md` | why it works the way it does                             |

## License

GNU General Public License, version 3 or later. See [LICENSE](LICENSE).
