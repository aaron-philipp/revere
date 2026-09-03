# Revere as a service: a headless Emacs daemon and the tools a job shells
# out to.  Build from the repository root, not from this directory:
#
#   docker build -f docker/Dockerfile -t revere:latest .
#
# Debian 13 carries Emacs 30, past Revere's 29.1 floor, on amd64 and arm64,
# which covers both Intel and ARM Synology models.
FROM debian:trixie-slim

# Add the runtimes MCP and ACP servers are usually written in.  Off by
# default: the image stays small and you mount servers that bring their
# own.  Turn one on with --build-arg WITH_NODE=true.
ARG WITH_NODE=false
ARG WITH_PYTHON=false

# emacs-nox is the runtime.  The rest is what the tools reach for: curl for
# the model transport and the fetch tool, diff for the review, git for
# worktrees and unattended jobs, ripgrep for fast search.  gosu drops from
# root to the run user once the entrypoint has fixed ownership.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      emacs-nox \
      ca-certificates \
      curl \
      diffutils \
      git \
      openssh-client \
      ripgrep \
      less \
      procps \
      gosu \
      tzdata \
 && if [ "$WITH_NODE" = "true" ]; then \
      apt-get install -y --no-install-recommends nodejs npm; fi \
 && if [ "$WITH_PYTHON" = "true" ]; then \
      apt-get install -y --no-install-recommends python3 python3-venv pipx; fi \
 && rm -rf /var/lib/apt/lists/*

# websocket is Revere's only Elisp dependency, and only Discord uses it.
# Installing it at build time keeps the container off the network at boot.
RUN emacs -Q --batch --eval "(progn \
      (require 'package) \
      (setq package-user-dir \"/opt/revere/elpa\") \
      (add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t) \
      (package-initialize) \
      (package-refresh-contents) \
      (package-install 'websocket))"

COPY lisp                 /opt/revere/lisp
COPY skills               /opt/revere/skills
COPY docker/init.el       /opt/revere/init.el
COPY docker/entrypoint.sh /usr/local/bin/revere-entrypoint

# Byte-compile so the daemon starts fast and a broken file fails the build
# rather than the boot.
RUN emacs -Q --batch \
      --eval "(progn (setq package-user-dir \"/opt/revere/elpa\") \
                     (require 'package) (package-initialize))" \
      -L /opt/revere/lisp -f batch-byte-compile /opt/revere/lisp/*.el

# The four mount points, all meant to be volumes:
#   /config   what you set:   local.el, authinfo, prompt.md, your skills
#   /data     what it writes: logbook, routines, check-in, board, memory,
#                             and the worktrees of unattended jobs
#   /servers  MCP and ACP servers that are not in this image, and the
#             package caches that keep them from downloading on every boot
#   /work     the projects it works on
RUN chmod +x /usr/local/bin/revere-entrypoint \
 && useradd --create-home --home-dir /home/revere --shell /bin/bash \
            --uid 1000 --user-group revere \
 && mkdir -p /config /data /servers/bin /work /run/revere \
 && chown -R revere:revere /home/revere /config /data /servers /work /run/revere

ENV HOME=/home/revere \
    REVERE_CONFIG=/config \
    REVERE_DATA=/data \
    REVERE_SERVERS=/servers \
    REVERE_SERVER_NAME=revere \
    REVERE_SOCKET_DIR=/run/revere \
    LANG=C.UTF-8 \
    NPM_CONFIG_CACHE=/servers/.npm \
    NPM_CONFIG_PREFIX=/servers/npm \
    PIPX_HOME=/servers/pipx \
    PIPX_BIN_DIR=/servers/bin \
    UV_CACHE_DIR=/servers/.uv \
    PATH=/servers/bin:/servers/npm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Reachable, and Revere loaded in it.
HEALTHCHECK --interval=60s --timeout=10s --start-period=45s --retries=3 \
  CMD emacsclient -s /run/revere/revere -e "(length revere-job-list)" >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/usr/local/bin/revere-entrypoint"]
