# Revere on a Synology NAS

The daemon in a container: routines fire on schedule, the check-in looks
for work, Discord is answered, and unattended jobs run in git worktrees you
merge when you are happy. You attach to it when you want to watch or take
over.

The NAS builds nothing. GitHub Actions builds the image, runs the test
suite inside it, starts the daemon and waits for it to answer, and only
then publishes to `ghcr.io/aaron-philipp/revere`. The package is public,
so Container Manager pulls it with no registry credentials.

- [What you need](#what-you-need)
- [Which Emacs](#which-emacs)
- [The four folders](#the-four-folders)
- [Install](#install)
- [Check it works](#check-it-works)
- [Attaching](#attaching)
- [Reaching it from your own Emacs](#reaching-it-from-your-own-emacs)
- [MCP and ACP servers](#mcp-and-acp-servers)
- [Updating](#updating)
- [Backups](#backups)
- [When something is wrong](#when-something-is-wrong)

## What you need

- A NAS with an Intel or AMD processor, running DSM 7.2 or later with
  **Container Manager** installed. The published image is `linux/amd64`.
- An OpenAI-compatible endpoint the NAS can reach: a LiteLLM proxy, Ollama,
  or a provider's API.
- SSH enabled for one command, to find the user id the container runs as.
  Everything else is DSM's web interface.

Note that DSM has no `git` on the command line and that only root can talk
to the docker socket, so every `docker` command below is run over SSH with
`sudo`. Nothing here needs the repository on the NAS.

## Which Emacs

The image carries Emacs 31.1, compiled in CI. Emacs 31 was released in
August 2026 and no Debian release packages it yet, so the workflow builds
it from source, where it costs a few minutes on a GitHub runner rather than
half an hour on NAS hardware.

It is worth having. Emacs 31 turns on mouse support in terminal frames by
default, and a terminal frame is how you attach to this container, so the
chat's tool lines and change buttons are clickable rather than
keyboard-only. Building the image yourself without `EMACS_SOURCE` gives you
Debian's Emacs 30.1 instead, which is past Revere's 29.1 floor and fine.

## The four folders

DSM keeps container configuration and data under `/volume1/docker`, so
Revere's live there too, mounted separately: the folder you edit is not the
folder that churns.

| In the container | On the NAS                      | Holds                                                                 |
|------------------|---------------------------------|-----------------------------------------------------------------------|
| `/config`        | `/volume1/docker/revere/config` | what you set: `local.el`, `authinfo`, `prompt.md`, your own skills     |
| `/data`          | `/volume1/docker/revere/data`   | what it writes: logbook, routines, check-in, board, memory, worktrees  |
| `/servers`       | `/volume1/docker/revere/servers`| MCP and ACP servers not in the image, and their package caches         |
| `/work`          | wherever your code lives        | the projects it works on                                              |

`/data` is the one to back up. `/config` is the one you edit. The `docker`
shared folder is reachable over SMB like any other, so you can read the
logbook and edit routines from your desk.

## Install

**1. Make the folders.** File Station, in the `docker` shared folder:
create `revere`, and inside it `config`, `data` and `servers`.

**2. Find the user it runs as.** Over SSH:

```bash
id "$USER"
```

Note `uid` and the `gid` of the `users` group, usually 1026 and 100. Those
are `PUID` and `PGID` below. That user needs read and write on
`/volume1/docker/revere` and on whatever holds your code.

**3. Write the keys.** Create `/volume1/docker/revere/config/authinfo`,
one line per service:

```
machine litellm.lan login revere password YOUR-API-KEY
machine discord.com login revere-bot password YOUR-BOT-TOKEN
```

The machine name for the model key is the **host of your endpoint**, which
is how Revere looks it up. Leave the Discord line out if you are not using
it. The container copies this file in as mode 600, because `auth-source`
refuses one that others can read.

**4. Create the project.** Container Manager > Project > Create:

- Project name: `revere`
- Path: `/volume1/docker/revere`
- Source: create `docker-compose.yml` and paste in
  [docker-compose.yml](docker-compose.yml) from this repository

Change every line marked EDIT: timezone, `PUID` and `PGID`, your endpoint
and model, and the path to your code. Then Next through the web portal
step, and Done. It pulls the image and starts the daemon.

## Check it works

The log in Container Manager should end with:

```
Revere daemon ready: 0 jobs in the logbook, server revere
```

Over SSH, ask it what it thinks its settings are:

```bash
sudo docker exec revere emacsclient -s /run/revere/revere -e '(list emacs-version revere-base-url revere-model)'
```

Then give it a job and watch the logbook fill:

```bash
sudo docker exec revere emacsclient -s /run/revere/revere -e '(revere-job-number (revere-new "List the files here and say what this project is." "/work/some-project"))'
```

`/volume1/docker/revere/data/logbook.org` is that job, from your desk, in
Org.

## Attaching

For a terminal frame inside the container, with the chat, the approvals
list and everything else:

```bash
sudo docker exec -it revere emacsclient -s /run/revere/revere -t
```

`C-x 5 0` closes the frame and leaves the daemon running. Do not use
`C-x C-c`: that stops the daemon and the container with it.

`M-x revere-doctor` in that frame checks the endpoint, the model's context
window, and the tools it can find.

Container Manager's own Terminal tab on the container works too: create a
`bash` session and run the same `emacsclient` line without `sudo`.

## Reaching it from your own Emacs

Port 9999 is the Emacs server, and `REVERE_SERVER_TCP` turns it on. It is
on in the compose file because driving the daemon from the Emacs you
already use is the point of running it here.

Understand what it is first. Anyone who can reach that port **and** read
`config/server/revere` can evaluate any Lisp in the daemon, which is a
shell on your NAS. Keep it on your LAN, never forward it at the router,
and set `REVERE_SERVER_TCP: "0"` and drop the port if you would rather
attach only from a shell on the NAS.

To use it, copy `/volume1/docker/revere/config/server/revere` into your own
`server-auth-dir`, and in your init:

```elisp
(require 'revere-client)
(setq revere-client-server "revere")
```

`M-x revere-client-new` starts a job on the NAS from the project you are
in. `M-x revere-client-status` lists what it is doing.

## MCP and ACP servers

Anything not in the image goes on the servers volume, and `/servers/bin` is
on `PATH`. Two ways:

**A program you drop in.** Put it in
`/volume1/docker/revere/servers/bin`, make it executable, and name it in
`local.el`:

```elisp
(setopt revere-mcp-servers '(("mine" :command "/servers/bin/my-server")))
```

**A published server.** These are usually node or python programs, and the
image has neither by default. Build your own image with
`WITH_NODE: "true"`, and npx then caches onto the servers volume rather
than downloading on every boot:

```elisp
(setopt revere-mcp-servers
        '(("fs" :command "npx"
                :args ("-y" "@modelcontextprotocol/server-filesystem" "/work"))))
```

Copy [local.el.example](local.el.example) to
`/volume1/docker/revere/config/local.el` to start. Its tools arrive as
`mcp-SERVER-TOOL` and ask before running unless `revere-rules` or
`revere-mcp-rule` says otherwise. Reload it without restarting:

```bash
sudo docker exec revere emacsclient -s /run/revere/revere -e '(load "/config/local.el")'
```

An outside subagent, such as another agent's CLI, installs the same way:
put it on the servers volume and it is on `PATH` for the shell tool.

## Updating

Container Manager > Project > revere > Action > Stop, then Build, pulls the
current image and starts again. Or over SSH:

```bash
sudo docker compose -f /volume1/docker/revere/docker-compose.yml pull
sudo docker compose -f /volume1/docker/revere/docker-compose.yml up -d
```

Your config and data are untouched. To pin a version instead of following
`latest`, change the tag in the compose file to one of the published
`sha-` or `v` tags.

## Backups

Back up `/volume1/docker/revere/data` and `/volume1/docker/revere/config`.
Hyper Backup on those folders covers everything; the image holds nothing
you cannot pull again, and `servers` is a cache.

Unattended work is committed to branches in the projects themselves, so
your code is covered by whatever already backs up your repositories.

## When something is wrong

| What you see                                | What it is                                                                                   |
|---------------------------------------------|----------------------------------------------------------------------------------------------|
| `/config is not writable by uid …`           | `PUID`/`PGID` are not the owner of `/volume1/docker/revere`. Fix them, or the folder's permissions. |
| The container restarts every minute          | The healthcheck cannot reach the daemon. Read the log; usually the init file failed.          |
| `Unable to start daemon: … already running`  | A stale socket. Stop the container and start it again.                                        |
| Jobs stall with nothing in the log           | They are waiting for approval. Attach and look at the approvals list, or loosen `revere-rules` in `local.el`. |
| `permission denied` on a docker command      | DSM only lets root use the docker socket. Use `sudo`.                                         |
| `detected dubious ownership` from git        | The container sets `safe.directory` at boot; if you overrode the entrypoint, set it yourself.  |
| Routines fire at the wrong hour              | `TZ` is not your timezone.                                                                    |
| Discord silent                               | Token missing or wrong in `authinfo`, or `revere-discord-channels` does not list the channel.  |

Logs are in Container Manager, or:

```bash
sudo docker logs -f revere
```
