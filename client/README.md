# Driving the NAS daemon from your own Emacs

Everything in this folder runs on **your machine**, not the NAS. It is
only needed if you want to reach the daemon in the container from the
Emacs you work in. Skip all of it and the daemon still runs its routines,
answers Discord, and commits unattended work to branches; you read its
logbook over SMB like any other file.

- [What goes where](#what-goes-where)
- [Push jobs to the daemon](#push-jobs-to-the-daemon)
- [Open a frame on the daemon](#open-a-frame-on-the-daemon)
- [Certificates](#certificates)

## What goes where

Two machines, and every file belongs to one of them.

| File                        | Lives on   | Doing what                                       |
|-----------------------------|------------|--------------------------------------------------|
| `client/make-certs.sh`      | your machine | run once, makes the authority and both certificates |
| `client/stunnel.conf`       | your machine | the local TLS proxy, only for frames            |
| `lisp/revere-client.el`     | your machine | the commands, loaded in your Emacs               |
| `ca.pem`, `client.pem`, `client-key.pem` | your machine | what you present and what you trust |
| `docker/docker-compose.yml` | the NAS      | the only repository file the NAS needs           |
| `docker/local.el.example`   | the NAS      | copied to `config/local.el` if you want it       |
| `ca.pem`, `server.pem`      | the NAS      | in `/volume1/docker/revere/certs`                |
| `ca-key.pem`                | neither      | keep it offline or delete it; it signs new certificates |

Everything else in `docker/` is built into the image by CI. It never
lands on the NAS as a file.

## Push jobs to the daemon

The smaller of the two setups, and the one to start with. No proxy.

`revere-client.el` needs only `server` and `project`, both of which come
with Emacs, so one file on your `load-path` is enough. If you already run
Revere here, you have it.

```elisp
(require 'revere-client)
(setq revere-client-server "revere"
      revere-client-tls t
      revere-client-host "nas.lan"          ; a name in the certificate
      revere-client-port 9999
      revere-client-ca "~/revere/ca.pem"
      revere-client-certificate '("~/revere/client-key.pem"
                                  "~/revere/client.pem")
      ;; The daemon's key changes whenever it restarts, so read its file
      ;; from the share instead of keeping a copy that goes stale.
      revere-client-auth-dir "//nas/docker/revere/config/server/")
```

`M-x revere-client-new` sends a job, working in the project you are in.
`M-x revere-client-status` lists what the daemon is doing. That is all
this setup gives you, and for handing work over it is enough.

## Open a frame on the daemon

A frame is the whole interface running on the NAS: chat, approvals, the
lot. It is `emacsclient` that opens it, and `emacsclient` has no TLS, so
something local has to carry it. Two ways, and neither is better in
general.

**A proxy on your machine.** Nothing to start each time, but stunnel has
to be installed here.

Copy `stunnel.conf`, change `connect` to your NAS and the three file paths
to where you keep the certificates, then run it:

```bash
stunnel ~/revere/stunnel.conf
```

On Windows, install stunnel, then either run `stunnel.exe your.conf` or
put the file where the installer keeps its configuration and start it from
the tray icon. It can also be installed as a service so it is simply
always there.

It listens on `127.0.0.1:9998`, which is the address the daemon already
records in its server file, so nothing else needs configuring. In your
Emacs, let the proxy do the TLS:

```elisp
(setq revere-client-tls nil
      revere-client-host "127.0.0.1"
      revere-client-port 9998
      revere-client-auth-dir "//nas/docker/revere/config/server/")
```

Then `M-x revere-client-frame`.

**Or an SSH tunnel**, with no software to install, since Windows has `ssh`
built in. Turn TLS off in the compose file, publish the port on the NAS
loopback as the comment there shows, and:

```bash
ssh -L 9998:127.0.0.1:9998 you@nas
```

The Emacs settings are the same as above. The cost is a tunnel to keep
open; the saving is that there is nothing to install and no certificates
at all.

## Certificates

Run this once, on your machine, naming the daemon the way you will dial
it. Git Bash is fine on Windows.

```bash
client/make-certs.sh nas.lan 192.168.1.20
```

It writes a `certs` folder. Send `ca.pem` and `server.pem` to
`/volume1/docker/revere/certs` on the NAS. Keep `ca.pem`, `client.pem`
and `client-key.pem` here. `ca-key.pem` signs future client certificates:
keep it somewhere safe or delete it, and never put it on the NAS.

To add another machine later, issue it a certificate of its own from the
same authority and copy only that machine's files to it:

```bash
openssl req -newkey rsa:2048 -sha256 -nodes -keyout laptop-key.pem \
  -out laptop.csr -subj "/CN=laptop"
openssl x509 -req -in laptop.csr -CA ca.pem -CAkey ca-key.pem \
  -days 825 -sha256 -out laptop.pem
```

Nothing revokes a certificate before it expires, and these last 825 days.
If a machine is lost, the way back is a revocation list in the daemon's
proxy, which is not set up today.
