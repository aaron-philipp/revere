;;; revere-config.el --- Settings for Revere -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Every user-facing setting in one place, so the other files can require
;; this one without circularity.

;;; Code:

(defgroup revere nil
  "An agentic framework built on Emacs."
  :group 'tools
  :prefix "revere-")

(defcustom revere-base-url "http://localhost:4000"
  "Base URL of the OpenAI-compatible endpoint, a LiteLLM proxy by default.
The chat endpoint is <root>/v1/chat/completions.  A string, or a function
that returns one."
  :type '(choice string function))

(defcustom revere-api-key nil
  "Bearer token for the endpoint.
A string, a function that returns one, or nil to look the key up with
`auth-source' by the endpoint's host name.  Never logged."
  :type '(choice (const :tag "Use auth-source" nil) string function))

(defcustom revere-model "qwen-3.8"
  "Model name sent with each request."
  :type 'string)

(defcustom revere-thinking-level 'off
  "Value for the request's reasoning_effort field, or `off' to omit it."
  :type '(choice (const off) (const low) (const medium) (const high)))

(defcustom revere-max-turns 25
  "Most model turns a job may take for one prompt before it is stopped."
  :type 'integer)

(defcustom revere-llm-timeout 300
  "Seconds before a model request is abandoned."
  :type 'integer)

(defcustom revere-shell-timeout 120
  "Seconds before a shell tool command is killed."
  :type 'integer)

(defcustom revere-tool-result-limit 60000
  "Longest tool result, in characters, sent back to the model."
  :type 'integer)

(defcustom revere-read-limit 2000
  "Lines the read tool returns when no line count is given."
  :type 'integer)

(defcustom revere-grep-limit 200
  "Most matching lines the grep tool returns."
  :type 'integer)

(defcustom revere-glob-limit 500
  "Most files the glob tool returns."
  :type 'integer)

(defcustom revere-glob-skip
  '(".git" ".hg" ".svn" "node_modules" "dist" "build" "__pycache__" ".venv" ".tox" "elpa")
  "Directory names the glob and grep tools do not descend into."
  :type '(repeat string))

(defcustom revere-rules
  '((read . go-ahead) (edit . go-ahead) (write . go-ahead)
    (glob . go-ahead) (grep . go-ahead) (problems . go-ahead)
    (describe . go-ahead) (apropos . go-ahead)
    (skill . go-ahead) (memory-search . go-ahead) (memory-add . go-ahead)
    (board-add . go-ahead) (logbook-search . go-ahead)
    (fetch . go-ahead) (search . go-ahead) (plan . go-ahead) (delegate . go-ahead)
    (shell . check) (eval . check) (define-tool . check)
    (t . never))
  "What each tool may do without asking.
An alist of (TOOL . RULE).  TOOL is a tool name as a symbol, or t for the
default.  RULE is `go-ahead', `check' (check with me first), or `never'."
  :type '(alist :key-type symbol
                :value-type (choice (const go-ahead) (const check) (const never))))

(defcustom revere-directory "~/.revere/"
  "Where Revere keeps its logbook, routines, check-in notes and worktrees."
  :type 'directory)

(defcustom revere-config-directory nil
  "Where your standing instructions and your own skills live.
Nil means keep them with everything else, in `revere-directory'.  Set it
when configuration and state belong in different places, as they do when
Revere runs in a container with one folder mounted for each."
  :type '(choice (const :tag "Same as revere-directory" nil) directory))

(defun revere-config-directory ()
  "The directory holding standing instructions and your own skills."
  (file-name-as-directory
   (expand-file-name (or revere-config-directory revere-directory))))

(defcustom revere-routine-tick 60
  "Seconds between looks at the routines file for anything due."
  :type 'integer)

(defcustom revere-check-in-interval 1800
  "Seconds between looks at the check-in file for anything to do."
  :type 'integer)

(defcustom revere-unattended-mode 'worktree
  "How unattended jobs, from routines and check-ins, hold their changes.
`worktree' commits them to a branch in a git worktree of the project, to be
merged or dropped on review.  `buffers' keeps them in buffers like an
interactive job.  Falls back to buffers outside a git repository."
  :type '(choice (const worktree) (const buffers)))

(defcustom revere-chat-input 'minibuffer
  "Where you type in the chat.
`minibuffer': RET, or just typing, opens a prompt at the bottom of the
frame and the chat itself is a read-only transcript with the mascot and a
status footer.  `buffer': an input line at the end of the chat."
  :type '(choice (const minibuffer) (const buffer)))

(defcustom revere-model-fallbacks nil
  "Models to try, in order, when a request to the current model fails."
  :type '(repeat string))

(defcustom revere-compact-fraction 0.75
  "Compact the transcript once the context is this full, as a fraction."
  :type 'number)

(defcustom revere-compact-tokens 60000
  "Compact the transcript past this many prompt tokens when the window is unknown."
  :type 'integer)

(defcustom revere-compact-keep 6
  "How many recent messages to keep verbatim when compacting."
  :type 'integer)

(defcustom revere-command-rules
  '(("\\brm +-[a-z]*r[a-z]*f\\b" . never)
    ("\\bsudo\\b" . never)
    ("--force\\b\\|-f\\b.*\\bpush\\|push\\b.*-f\\b" . never)
    ("\\bgit +push\\b" . check)
    ("\\`\\(git \\(status\\|diff\\|log\\|show\\|branch\\)\\|ls\\|dir\\|pwd\\|cat\\|type\\|head\\|tail\\|wc\\)\\b" . go-ahead)
    ("\\`\\(bash \\)?bin/check\\.sh" . go-ahead)
    ("\\`\\(make\\|npm test\\|npm run test\\|cargo test\\|pytest\\|go test\\)\\b" . go-ahead))
  "Rules for shell commands by pattern, tried in order; the first match wins.
Each entry is (REGEXP . RULE) with RULE `go-ahead', `check' or `never'.
Commands matching nothing fall back to the shell tool's own rule."
  :type '(alist :key-type regexp
                :value-type (choice (const go-ahead) (const check) (const never))))

(defcustom revere-search-provider 'duckduckgo
  "Which web search to use.
`duckduckgo' needs no setup; `searxng' uses the instance at
`revere-search-url'; `brave' needs an API key in `auth-source' for
api.search.brave.com."
  :type '(choice (const duckduckgo) (const searxng) (const brave)))

(defcustom revere-search-url "http://localhost:8080"
  "Base URL of the SearXNG instance when `revere-search-provider' is `searxng'."
  :type 'string)

(defcustom revere-fetch-limit 40000
  "Most characters of a fetched page to return."
  :type 'integer)

(defcustom revere-system-prompt
  "You are Revere, working inside the user's Emacs.
Use the tools to read and change files in the project. Your edits land in
Emacs buffers, not on disk: the user reviews every change as a diff and keeps
or discards it, so make complete, careful changes and never ask permission to
edit. If a tool reports a file is stale, read it again before editing it.
Prefer small, verifiable steps and check your work with the tools: after
editing code, run problems and fix what it reports. When a skill fits the
job, load it with the skill tool first. For anything with more than a few
steps, keep a plan with the plan tool and tick items off as you go. Use
memory-add for durable lessons and corrections, not for what you did. When
you are done, say in a few lines what you changed."
  "Standing instructions sent as the system message of every job."
  :type 'string)

(provide 'revere-config)
;;; revere-config.el ends here
