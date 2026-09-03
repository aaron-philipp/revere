# State of Revere, 3 September 2026

Written as a handover. The package itself is unchanged and works; the work
in this window was the container deployment and the remote access around
it. One serious bug was found at the end of it and is not fixed. Read
[Broken](#broken) first, because it undermines the intended way of working.

- [Broken](#broken)
- [What was built](#what-was-built)
- [Verified, and how](#verified-and-how)
- [Not verified](#not-verified)
- [Open gaps](#open-gaps)
- [Where things are](#where-things-are)

## Broken

**The daemon never re-reads its Org files from disk.** This is the big
one. The intended way to work is that you edit `routines.org`,
`check-in.org` and `board.org` on the shared folder from your own Emacs,
and the daemon picks the changes up on its next tick. It does not.

`revere-routines--buffer` ([lisp/revere-routines.el:73](lisp/revere-routines.el))
calls `find-file-noselect` and returns the same buffer forever. There is
no `revert-buffer`, no `verify-visited-file-modtime`, and no file
notification anywhere in `revere-routines.el`, `revere-board.el`,
`revere-logbook.el` or `revere-memory.el`. Every reader goes through that
one accessor:

| Reader | Where |
|---|---|
| `revere-routines-due`, the routine tick | [revere-routines.el:119](lisp/revere-routines.el) |
| `revere-routines--mark` | [revere-routines.el:136](lisp/revere-routines.el) |
| `revere-check-in--notes`, the check-in tick | [revere-routines.el:303](lisp/revere-routines.el) |
| `revere-board-cards`, `revere-board--mark`, `revere-board-add` | [revere-board.el:79, 98, 112](lisp/revere-board.el) |
| `revere-board-worker-add` | [revere-board.el:219](lisp/revere-board.el) |
| `revere-debrief-routine-add` | [revere-memory.el:195](lisp/revere-memory.el) |

Two consequences, the second worse than the first:

1. **Instructions written to the share are invisible.** A routine you add
   from your desk never fires. A note in `check-in.org` is never read. A
   card on the board is never claimed.
2. **Your edits can be destroyed.** The daemon holds a stale buffer and
   saves it, so an edit you make to `board.org` is overwritten the next
   time the daemon writes a card. `save-buffer` on a file that changed
   underneath normally asks whether to proceed; in a daemon there is
   nobody to ask.

The outbound direction does work. `revere-logbook` saves about two seconds
after each change ([revere-logbook.el:145, 150](lisp/revere-logbook.el)),
so reading the logbook from the share is accurate and current.

So today the only inbound channels that function are Discord and
`docker exec`. That is the opposite of the intended design, in which the
Org files on the share are the primary way to hand the daemon work.

**Sketch of a fix**, for whoever takes it. Reverting when clean is the
easy half; the conflict policy is the real design question, because both
sides write `board.org`.

```elisp
(defun revere-routines--sync (buffer)
  "Re-read BUFFER from disk when the file changed and we have no edits."
  (with-current-buffer buffer
    (when (and buffer-file-name
               (not (buffer-modified-p))
               (not (verify-visited-file-modtime buffer)))
      (revert-buffer :ignore-auto :noconfirm :preserve-modes))))
```

Called at the top of `revere-routines--buffer` it covers every reader
above. Points to decide:

- What to do when the buffer *is* modified and the file also changed.
  Saving eagerly after every write, rather than holding modifications,
  would make that window small enough to treat as an error.
- Whether to use `file-notify-add-watch` instead of checking on each tick.
  Note that file notification does not work over SMB or NFS mounts, which
  is exactly the case here, so polling the modtime is probably right.
- Whether the check-in and routine ticks should re-read even when nothing
  appears to have changed, since modtime resolution over SMB is coarse.

## What was built

The package under `lisp/` is unchanged except for four small things, all
tested: `revere-config-directory`, `revere-skill-dirs` resolved when used
rather than at load, the TLS client in `revere-client.el`, and an error
instead of nil when the daemon closes on us.

Everything else was deployment:

- `docker/` builds and runs the daemon as a container. Four volumes:
  `/config` for what you set, `/data` for what it writes, `/servers` for
  MCP and ACP servers that are not in the image, `/work` for projects.
  Settings come from the environment, so the image holds no addresses or
  secrets; `local.el` on the config volume sets what the environment
  cannot and reloads without a restart.
- `.github/workflows/` build the image, run the suite inside it, exercise
  it, and publish to `ghcr.io/aaron-philipp/revere`. The NAS compiles
  nothing. Emacs 31.1 is built from source in CI because no Debian release
  packages it yet.
- `client/` is the other machine's half: certificate script, the local TLS
  proxy config, and how to load `revere-client.el`.
- Mutual TLS in front of the Emacs server, because Emacs's own
  authentication is a shared key sent in the clear that grants arbitrary
  Lisp. stunnel in the image holds the published port and requires a
  client certificate; Emacs listens only on the container's loopback.

## Verified, and how

Everything below was run, not reasoned about. The image checks are in
[.github/scripts/tls-check.sh](.github/scripts/tls-check.sh) and run on
every push.

| Claim | How it was checked |
|---|---|
| 72 tests pass on Emacs 31.1 and on Debian's 30.1 | `bin/check.sh` locally and in CI |
| The suite passes inside the shipped image | run in CI against the built image |
| The daemon starts and answers | container started in CI, polled with emacsclient |
| A certificate holder is served over TLS | real `revere-client` in CI, answered `("31.1" 0)` |
| A caller without one is refused | stunnel logged `peer did not return a certificate` |
| Six clients at once, each its own answer | six parallel clients in CI |
| `emacsclient` reaches the daemon through a client-side proxy | in CI, using the shipped `client/stunnel.conf` |
| The container init wiring | loaded under Emacs with paths redirected |
| `make-certs.sh` on Git Bash | run here; certificates inspected with openssl |

## Not verified

- **The image has never run on a Synology.** No Docker on the development
  machine, so everything was proven in CI on an x86 runner. The DSM
  specifics, Container Manager project creation, `PUID`/`PGID` against a
  real share, and SMB behaviour are all unproven.
- **No frame has been opened on the containerised daemon.** CI proves
  `emacsclient` can reach it and evaluate, which is the same transport,
  but nobody has looked at the chat in a terminal frame on the NAS.
- **Discord has not been exercised against the container.**
- **The Org files on a real SMB mount.** Given the bug above, this is the
  first thing to test once it is fixed.

## Open gaps

- **One endpoint at a time.** `revere-base-url` takes one address. It may
  be a function, but that function receives no arguments and cannot see
  which model the request is for, so it cannot route per model. Reaching
  several providers is currently the proxy's job.
- **No certificate revocation.** `make-certs.sh` issues for 825 days and
  nothing revokes early. stunnel supports `CRLfile`; it is not wired up.
- **A frame needs a proxy or a tunnel on the client side**, because
  `emacsclient` has no TLS. Both routes are documented in
  `client/README.md`.
- **The Emacs server's auth is a shared key**, per daemon, not per client.
  Certificates distinguish machines at the TLS layer; Emacs underneath
  cannot tell them apart.
- **Nothing restarts stunnel** if it dies after boot. The entrypoint
  checks it survived startup and stops the container if not.

## Where things are

| Path | What |
|---|---|
| `lisp/` | the package, 33 files, `revere.el` the entry point |
| `test/` | the suite, 72 tests |
| `docker/` | the NAS side: image, compose, entrypoint, container init |
| `client/` | your machine's side: certificates, local proxy, client setup |
| `.github/` | build, test and publish the image |
| `DESIGN.md` | why it works the way it does |
| `docker/README.md` | the Synology walkthrough |
| `client/README.md` | what goes on which machine |
