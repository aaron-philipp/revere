# Revere on a Synology NAS

The daemon in a container: routines fire on schedule, the check-in looks
for work, Discord is answered, and unattended jobs run in git worktrees you
merge when you are happy. You attach to it when you want to watch or take
over.

Everything it keeps lives in a DSM shared folder, so you edit its
instructions and read its logbook over SMB from your desk.

- [What you need](#what-you-need)
  - [Which Emacs](#which-emacs)
- [The four folders](#the-four-folders)
- [Install](#install)
- [Check it works](#check-it-works)
- [Attaching](#attaching)
- [MCP and ACP servers](#mcp-and-acp-servers)
- [Updating](#updating)
- [Backups](#backups)
- [Reaching it from your own Emacs](#reaching-it-from-your-own-emacs)
- [When something is wrong](#when-something-is-wrong)

## What you need

- DSM 7.2 or later with **Container Manager** installed.
- An OpenAI-compatible endpoint the NAS can reach: a LiteLLM proxy, Ollama,
  or a provider's API.
- SSH to the NAS for two commands. Everything else is DSM's web interface.

Both Intel and ARM models work; the image builds on the NAS itself.

### Which Emacs

The image uses Debian's Emacs 30.1, which is past Revere's 29.1 floor and
builds in a couple of minutes. Emacs 31.1 came out in August 2026 and is
not packaged in any Debian release yet, so to run it here you build it:
set `EMACS_SOURCE: "31.1"` in the compose file. That adds half an hour or
so to the first build on NAS hardware and nothing afterwards, and it
installs over the packaged one.

It is worth it for one reason. Emacs 31 enables mouse support in terminal
frames by default, and a terminal frame is how you attach to this
container, so the chat's tool lines and change buttons become clickable
rather than keyboard-only. When Debian packages 31, clear the setting and
the plain build gets it.

## The four folders

One shared folder, four subfolders, mounted separately so the folder you
edit is not the folder that churns.

| In the container | On the NAS               | Holds                                                                 |
|------------------|--------------------------|-----------------------------------------------------------------------|
| `/config`        | `/volume1/revere/config` | what you set: `local.el`, `authinfo`, `prompt.md`, your own skills     |
| `/data`          | `/volume1/revere/data`   | what it writes: logbook, routines, check-in, board, memory, worktrees  |
| `/servers`       | `/volume1/revere/servers`| MCP and ACP servers not in the image, and their package caches         |
| `/work`          | `/volume1/code`          | the projects it works on                                              |

`/data` is the one to back up. `/config` is the one you edit.

## Install

**1. Make the shared folder.** Control Panel > Shared Folder > Create,
named `revere`. Then File Station: create `src`, `config`, `data` and
`servers` inside it. Enable SMB on it so you can reach it from your
desk.

**2. Find the user it should run as.** Over SSH:

```bash
id "$USER"
```

Note the `uid` and the `gid` of the `users` group, usually 1026 and 100.
Those are `PUID` and `PGID` below. Give that user read and write on the
`revere` shared folder, and on whatever holds your code.

**3. Put Revere on the NAS.** Over SSH:

```bash
git clone https://github.com/aaron-philipp/revere.git /volume1/revere/src
```

**4. Write the keys.** Create `/volume1/revere/config/authinfo`, one line
per service, no trailing blank line needed:

```
machine litellm.lan login revere password YOUR-API-KEY
machine discord.com login revere-bot password YOUR-BOT-TOKEN
```

The machine name for the model key is the **host of your endpoint**, which
is how Revere looks it up. Leave the Discord line out if you are not using
it. The entrypoint copies this file in as mode 600, because `auth-source`
refuses one that others can read.

**5. Edit the compose file.** In `/volume1/revere/src/docker/`, open
`docker-compose.yml` and change every line marked EDIT: timezone, `PUID`
and `PGID`, your endpoint and model, and the path to your code. If your
MCP servers are node or python programs, set `WITH_NODE` or `WITH_PYTHON`
to `"true"`.

**6. Create the project.** Container Manager > Project > Create:

- Project name: `revere`
- Path: `/volume1/revere/src/docker`
- Source: it finds `docker-compose.yml` there
- Next through the web-portal step, then Done.

It builds the image, which takes a few minutes the first time, then starts
the daemon.

## Check it works

The log in Container Manager should end with a line like:

```
Revere daemon ready: 0 jobs in the logbook, server revere
```

Over SSH, ask it what it thinks its settings are:

```bash
docker exec revere emacsclient -s /run/revere/revere -e '(list revere-base-url revere-model revere-directory)'
```

Then give it a job and watch the logbook fill:

```bash
docker exec revere emacsclient -s /run/revere/revere -e '(revere-job-number (revere-new "List the files in this project and say what it is." "/work/some-project"))'
```

`/volume1/revere/data/logbook.org` is that job, from your desk, in Org.

## Attaching

For a terminal frame inside the container, with the chat, the approvals
list and everything else:

```bash
docker exec -it revere emacsclient -s /run/revere/revere -t
```

`C-x 5 0` closes the frame and leaves the daemon running. Do not use
`C-x C-c`: that stops the daemon and the container with it.

`M-x revere-doctor` in that frame checks the endpoint, the model's context
window, and the tools it can find.

## MCP and ACP servers

Anything not in the image goes on the servers volume, and
`/servers/bin` is on `PATH`. Two ways:

**A program you drop in.** Put it in `/volume1/revere/servers/bin`, make it
executable, and name it in `local.el`:

```elisp
(setopt revere-mcp-servers '(("mine" :command "/servers/bin/my-server")))
```

**A published server.** Build with `WITH_NODE: "true"`, then npx caches
onto the servers volume rather than downloading on every boot:

```elisp
(setopt revere-mcp-servers
        '(("fs" :command "npx"
                :args ("-y" "@modelcontextprotocol/server-filesystem" "/work"))))
```

Copy `local.el.example` to `/volume1/revere/config/local.el` to start.
Its tools arrive as `mcp-SERVER-TOOL` and ask before running unless
`revere-rules` or `revere-mcp-rule` says otherwise. Reload it without
restarting:

```bash
docker exec revere emacsclient -s /run/revere/revere -e '(load "/config/local.el")'
```

An outside subagent, such as another agent's CLI, installs the same way:
put it on the servers volume, and it is on `PATH` for the shell tool.

## Updating

```bash
git -C /volume1/revere/src pull
```

Then in Container Manager: Project > revere > Build, and start it again.
Your config and data are untouched; only the image is rebuilt.

## Backups

Back up `/volume1/revere/data` and `/volume1/revere/config`. Hyper Backup
on the `revere` shared folder covers both. The image holds nothing you
cannot rebuild, and `servers` is a cache.

Unattended work is committed to branches in the projects themselves, so
your code is backed up by whatever already backs up your repositories.

## Reaching it from your own Emacs

Optional, and it deserves a warning. With `REVERE_SERVER_TCP` on, anyone
who can reach the port **and** read the auth file can evaluate any Lisp in
this daemon, which is a shell on your NAS. Only on a network you trust,
never forwarded through the router.

Set `REVERE_SERVER_TCP: "1"` and publish the port, then copy
`/volume1/revere/config/server/revere` into your own `server-auth-dir`,
and in your init:

```elisp
(require 'revere-client)
(setq revere-client-server "revere")
```

`M-x revere-client-new` starts a job on the NAS from the project you are
in. `M-x revere-client-status` lists what it is doing.

## When something is wrong

| What you see                                       | What it is                                                                    |
|----------------------------------------------------|-------------------------------------------------------------------------------|
| `/config is not writable by uid …`                  | `PUID`/`PGID` are not the owner of the shared folder. Fix them, or the folder's permissions. |
| Container restarts every minute                     | The healthcheck cannot reach the daemon. Read the log; usually the init file failed. |
| `Unable to start daemon: … already running`         | A stale socket. Stop the container and start it again.                        |
| Jobs stall with nothing in the log                  | They are waiting for approval. Attach and look at the approvals list, or loosen `revere-rules` in `local.el`. |
| `detected dubious ownership` from git               | The entrypoint sets `safe.directory`; if you overrode the entrypoint, set it yourself. |
| Routines fire at the wrong hour                     | `TZ` is not your timezone.                                                    |
| Discord silent                                      | Token missing or wrong in `authinfo`, or `revere-discord-channels` does not list the channel. |

Logs are in Container Manager, or:

```bash
docker logs -f revere
```
