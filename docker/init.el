;;; init.el --- Revere's init file inside the container -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Loaded by docker/entrypoint.sh as
;;   emacs -Q --fg-daemon=$REVERE_SERVER_NAME -l /opt/revere/init.el
;;
;; Every setting comes from the environment, so one image serves any site
;; and holds no addresses or secrets of its own.  Anything the environment
;; cannot express goes in local.el on the config volume, which is loaded
;; last and can set rules, MCP servers, hooks, or anything else.

;;; Code:

(require 'server)
(require 'package)
(require 'auth-source)

(defun revere-container-env (name &optional default)
  "The environment variable NAME, or DEFAULT when unset or empty."
  (let ((value (getenv name)))
    (if (and value (not (string-empty-p value))) value default)))

(defun revere-container-list (name)
  "The comma or space separated environment variable NAME as a list."
  (let ((value (revere-container-env name)))
    (and value (split-string value "[, ]+" t "[ \t]+"))))

(defun revere-container-flag (name)
  "Non-nil when environment variable NAME is set to a yes-like word."
  (member (downcase (or (revere-container-env name) ""))
          '("1" "true" "yes" "on")))

;;;; The package and its dependencies

;; websocket, installed at build time, is what Discord needs.
(setq package-user-dir "/opt/revere/elpa")
(package-initialize)

(add-to-list 'load-path "/opt/revere/lisp")
(require 'revere)
(require 'revere-daemon)

;;;; The volumes

;; Config is what you set: standing instructions, your own skills, and
;; local.el.  Data is what Revere writes: the logbook, routines, check-in,
;; board, memory, and the worktrees of unattended jobs.  Keeping them apart
;; means the folder you edit over the share is not the folder that churns.
(defconst revere-container-config
  (file-name-as-directory (revere-container-env "REVERE_CONFIG" "/config")))

(defconst revere-container-data
  (file-name-as-directory (revere-container-env "REVERE_DATA" "/data")))

(defconst revere-container-servers
  (file-name-as-directory (revere-container-env "REVERE_SERVERS" "/servers")))

(setq revere-directory revere-container-data
      revere-config-directory revere-container-config)

(make-directory revere-directory t)
(make-directory (expand-file-name "skills" revere-config-directory) t)

;; MCP and ACP servers that are not in the image live on their own volume,
;; along with the package caches that keep them from downloading on every
;; boot.  Anything executable under servers/bin can be named as a command.
(dolist (dir (list (expand-file-name "bin" revere-container-servers)
                   (expand-file-name "npm/bin" revere-container-servers)))
  (add-to-list 'exec-path dir))

;; These volumes are usually network shares.  Emacs's lock files and
;; backups do not belong on one: locking is unreliable over SMB and NFS,
;; and the backups would land in the folder you browse.
(let ((backups (expand-file-name ".cache/backups/" (getenv "HOME")))
      (auto-saves (expand-file-name ".cache/auto-save/" (getenv "HOME"))))
  (make-directory backups t)
  (make-directory auto-saves t)
  (setq create-lockfiles nil
        backup-directory-alist (list (cons ".*" backups))
        auto-save-file-name-transforms (list (list ".*" auto-saves t))))

;;;; The model

(setq revere-base-url (revere-container-env "REVERE_BASE_URL" "http://localhost:4000")
      revere-model    (revere-container-env "REVERE_MODEL" "qwen-3.8"))

(when-let* ((level (revere-container-env "REVERE_THINKING")))
  (setq revere-thinking-level (intern level)))

(when-let* ((fallbacks (revere-container-list "REVERE_MODEL_FALLBACKS")))
  (setq revere-model-fallbacks fallbacks))

;; A key in the environment is visible to anyone who can read the container
;; settings, so prefer the authinfo the entrypoint installs from the config
;; volume.
(when-let* ((key (revere-container-env "REVERE_API_KEY")))
  (setq revere-api-key key))

(setq auth-sources (list (expand-file-name ".authinfo" (getenv "HOME"))
                         (expand-file-name "authinfo" revere-config-directory)))

;;;; How it works when nobody is watching

;; No minibuffer here: anything the rules say to check waits in the
;; approvals list until you attach.
(setq revere-unattended-mode
      (intern (revere-container-env "REVERE_UNATTENDED_MODE" "worktree")))

(when-let* ((seconds (revere-container-env "REVERE_CHECK_IN_INTERVAL")))
  (setq revere-check-in-interval (string-to-number seconds)))

;;;; Discord

(when-let* ((token (revere-container-env "REVERE_DISCORD_TOKEN")))
  (setq revere-discord-token token))
(when-let* ((channels (revere-container-list "REVERE_DISCORD_CHANNELS")))
  (setq revere-discord-channels channels))
(when-let* ((users (revere-container-list "REVERE_DISCORD_USERS")))
  (setq revere-discord-users users))
(setq revere-discord-autoconnect
      (not (member (downcase (or (revere-container-env "REVERE_DISCORD") "on"))
                   '("0" "false" "no" "off"))))

;;;; How you attach

(setq server-name (revere-container-env "REVERE_SERVER_NAME" "revere")
      server-socket-dir (revere-container-env "REVERE_SOCKET_DIR" "/run/revere"))

;; With TCP on, another Emacs on your network can drive this daemon with
;; revere-client, but anyone holding the auth file can evaluate anything
;; here.  Publish the port only on a network you trust.
(when (revere-container-flag "REVERE_SERVER_TCP")
  (setq server-use-tcp t
        server-host "0.0.0.0"
        server-auth-dir (expand-file-name "server" revere-config-directory)
        server-port (string-to-number (revere-container-env "REVERE_SERVER_PORT" "9999")))
  (make-directory server-auth-dir t)
  (set-file-modes server-auth-dir #o700))

;;;; Your own settings

;; Nothing else in this Emacs's home is worth keeping: the entrypoint
;; writes .authinfo and .gitconfig fresh at every boot, and backups and
;; auto-saves are scratch.  Customize is the exception.  Without this,
;; saving from an attached frame would try to write into the image, which
;; the user cannot write and the next update would throw away.
(setq custom-file (expand-file-name "custom.el" revere-config-directory))
(when (file-exists-p custom-file)
  (condition-case err
      (load custom-file nil t)
    (error (message "revere: custom.el: %s" (error-message-string err)))))

;; Rules, MCP servers, routines, hooks: anything, and it wins over the
;; above.  Reload it without restarting the container:
;;   docker exec revere emacsclient -s /run/revere/revere \
;;     -e '(load "/config/local.el")'
(let ((local (expand-file-name "local.el" revere-config-directory)))
  (when (file-exists-p local)
    (condition-case err
        (load local nil t)
      (error (message "revere: local.el: %s" (error-message-string err))))))

;;;; Start

(defun revere-container--advertise ()
  "Put the address a client should dial into the server file.
Emacs writes the address it listens on, which inside a container is
0.0.0.0 and reaches nobody.  REVERE_SERVER_ADVERTISE replaces it, so the
file on the config volume can be used as it stands: 127.0.0.1 when you
reach the port through an SSH tunnel, or the NAS's own address when you
publish the port to the network."
  (let ((advertise (revere-container-env "REVERE_SERVER_ADVERTISE")))
    (when (and advertise server-use-tcp server-auth-dir server-name)
      (let* ((file (expand-file-name server-name server-auth-dir))
             (coding-system-for-read 'no-conversion)
             (coding-system-for-write 'no-conversion))
        (when (file-exists-p file)
          (let ((text (with-temp-buffer
                        (set-buffer-multibyte nil)
                        (insert-file-contents file)
                        (buffer-string))))
            (if (not (string-match "\\`\\([0-9.]+\\):\\([0-9]+\\)" text))
                (message "revere: server file has no address to replace")
              (let ((port (match-string 2 text)))
                (with-temp-file file
                  (set-buffer-multibyte nil)
                  (insert (replace-match advertise t t text 1)))
                (set-file-modes file #o600)
                (message "revere: server file points clients at %s:%s"
                         advertise port)))))))))

(defun revere-container-start ()
  "Start the service, then make its server file usable from elsewhere."
  (revere-daemon-start)
  (revere-container--advertise))

;; Emacs starts the daemon's server itself, after this file and after the
;; command line.  Waiting a turn lets that happen first, so the server is
;; started once, by Emacs, with the settings above.
(run-at-time 0 nil #'revere-container-start)

;; Stopping the container writes the logbook out.
(add-hook 'kill-emacs-hook #'revere-daemon-stop)

;;; init.el ends here
