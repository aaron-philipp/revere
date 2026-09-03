#!/bin/bash
# Prepare the mounted volumes, give git an identity, then hand the
# container over to the Emacs daemon as the unprivileged run user.
set -euo pipefail

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
CONFIG="${REVERE_CONFIG:-/config}"
DATA="${REVERE_DATA:-/data}"
SERVERS="${REVERE_SERVERS:-/servers}"
SOCKET_DIR="${REVERE_SOCKET_DIR:-/run/revere}"
SERVER_NAME="${REVERE_SERVER_NAME:-revere}"

if [ "$(id -u)" = "0" ]; then
  # Synology shares are owned by the DSM user that made them, commonly
  # uid 1026 in group users (100).  Match it rather than fighting it.
  if [ "$(id -g revere)" != "$PGID" ]; then
    groupmod -o -g "$PGID" revere
  fi
  if [ "$(id -u revere)" != "$PUID" ]; then
    usermod -o -u "$PUID" -g "$PGID" revere
  fi

  chown -R revere:revere /home/revere "$SOCKET_DIR"
  # Emacs refuses to put its socket in a directory others can reach, so
  # this has to be 700, not merely unwritable by them.
  chmod 700 "$SOCKET_DIR"

  # Not recursive on the volumes: they can be large, and on a mounted SMB
  # or NFS share ownership comes from the mount options and chown fails
  # outright.  The writability check below is what actually matters.
  for dir in "$CONFIG" "$DATA" "$SERVERS" "$SERVERS/bin"; do
    mkdir -p "$dir" 2>/dev/null || true
    chown revere:revere "$dir" 2>/dev/null || true
  done

  for dir in "$CONFIG" "$DATA"; do
    if ! gosu revere test -w "$dir"; then
      echo "revere: $dir is not writable by uid $PUID, gid $PGID." >&2
      echo "revere: for a folder on this NAS, set PUID and PGID to its owner." >&2
      echo "revere: for a mounted SMB or NFS share, set uid= and gid= in the" >&2
      echo "revere: volume's mount options to the same numbers." >&2
      exit 1
    fi
  done

  gosu revere git config --global user.name  "${GIT_AUTHOR_NAME:-Revere}"
  gosu revere git config --global user.email "${GIT_AUTHOR_EMAIL:-revere@localhost}"
  # Repositories on a mounted share are owned by another uid as far as git
  # is concerned; without this every git call in a job refuses to run.
  gosu revere git config --global --replace-all safe.directory '*'

  # auth-source refuses a group or world readable file, and a read-only
  # mount cannot be chmodded, so copy it in with the right permissions.
  for candidate in /run/secrets/authinfo "$CONFIG/authinfo"; do
    if [ -f "$candidate" ]; then
      install -o revere -g revere -m 600 "$candidate" /home/revere/.authinfo
      break
    fi
  done

  # The certificates arrive however they were copied: often mode 600 and
  # owned by whoever made them, which the run user cannot read.  Root can,
  # so take private copies the way authinfo is handled.
  if [ "${REVERE_TLS:-0}" = "1" ] || [ "${REVERE_TLS:-off}" = "on" ]; then
    CERTS="${REVERE_CERTS:-/certs}"
    for f in server.pem ca.pem; do
      if [ ! -r "$CERTS/$f" ]; then
        echo "revere: REVERE_TLS is on but $CERTS/$f is missing or unreadable." >&2
        echo "revere: make them with docker/make-certs.sh, then mount" >&2
        echo "revere: ca.pem and server.pem at $CERTS." >&2
        exit 1
      fi
    done
    install -d -o revere -g revere -m 700 "$SOCKET_DIR/tls"
    install -o revere -g revere -m 600 "$CERTS/server.pem" "$SOCKET_DIR/tls/server.pem"
    install -o revere -g revere -m 600 "$CERTS/ca.pem" "$SOCKET_DIR/tls/ca.pem"
  fi

  exec gosu revere "$0" "$@"
fi

# Second pass, now as the run user.
mkdir -p "$DATA" "$CONFIG" "$SERVERS/bin" "$SOCKET_DIR"
chmod 700 "$SOCKET_DIR"

# Mutual TLS in front of the Emacs server.  Emacs cannot speak TLS on a
# listening socket, so it listens on the loopback inside this container
# and stunnel is the only thing on the published port.  A caller without
# a certificate signed by our authority is refused at the handshake, long
# before it can offer Emacs a key.
if [ "${REVERE_TLS:-0}" = "1" ] || [ "${REVERE_TLS:-off}" = "on" ]; then
  STUNNEL="$(command -v stunnel || command -v stunnel4 || true)"
  if [ -z "$STUNNEL" ]; then
    echo "revere: REVERE_TLS is on but stunnel is not in this image." >&2
    exit 1
  fi
  cat > "$SOCKET_DIR/tls/stunnel.conf" <<EOF
foreground = yes
pid =
syslog = no
debug = 4
[revere]
accept = 0.0.0.0:${REVERE_TLS_PORT:-9999}
connect = 127.0.0.1:${REVERE_SERVER_PORT:-9998}
cert = $SOCKET_DIR/tls/server.pem
CAfile = $SOCKET_DIR/tls/ca.pem
requireCert = yes
verifyChain = yes
sslVersionMin = TLSv1.2
EOF
  echo "revere: TLS on ${REVERE_TLS_PORT:-9999}, clients must present a certificate"
  "$STUNNEL" "$SOCKET_DIR/tls/stunnel.conf" &
  stunnel_pid=$!
  # If it dies the published port simply closes, which is safe but silent.
  # Say so instead, and stop, rather than run with TLS quietly absent.
  sleep 1
  if ! kill -0 "$stunnel_pid" 2>/dev/null; then
    echo "revere: stunnel would not start, so TLS is not available; stopping." >&2
    exit 1
  fi
fi

echo "revere: starting as $(id -un) ($(id -u):$(id -g))"
echo "revere: config $CONFIG, data $DATA, servers $SERVERS"
exec emacs -Q --fg-daemon="$SERVER_NAME" -l /opt/revere/init.el "$@"
