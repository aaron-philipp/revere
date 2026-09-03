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

  exec gosu revere "$0" "$@"
fi

# Second pass, now as the run user.
mkdir -p "$DATA" "$CONFIG" "$SERVERS/bin"

echo "revere: starting as $(id -un) ($(id -u):$(id -g))"
echo "revere: config $CONFIG, data $DATA, servers $SERVERS"
exec emacs -Q --fg-daemon="$SERVER_NAME" -l /opt/revere/init.el "$@"
