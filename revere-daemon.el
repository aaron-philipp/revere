;;; revere-daemon.el --- Running Revere as a daemon -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; `revere-daemon-start' turns the running Emacs into the Revere service:
;; it reads the logbook, starts the routine and check-in timers, makes sure
;; the server is up so `emacsclient' and `revere-client' can reach it, and
;; opens the approvals list or the chat when a client frame connects.
;;
;; Start it as: emacs --daemon=revere -Q -l ~/.revere/init.el
;; (see contrib/revere-daemon-init.el), or call it from a normal Emacs.

;;; Code:

(require 'server)
(require 'revere-config)
(require 'revere-job)
(require 'revere-logbook)
(require 'revere-routines)
(require 'revere-approve)

(declare-function revere "revere")

(defvar revere-daemon--started nil
  "Non-nil once `revere-daemon-start' has run.")

(defun revere-daemon--welcome ()
  "Show what a new client frame most needs to see."
  (if (revere-approve-pending)
      (revere-approvals)
    (revere)))

;;;###autoload
(defun revere-daemon-start ()
  "Make this Emacs the Revere service."
  (interactive)
  (unless revere-daemon--started
    (setq revere-daemon--started t)
    (make-directory (expand-file-name revere-directory) t)
    (revere-logbook-ensure-loaded)
    (revere-routines-enable)
    (revere-check-in-enable)
    (unless (and (boundp 'server-process) server-process)
      (unless server-name (setq server-name "revere"))
      (server-start))
    (add-hook 'server-after-make-frame-hook #'revere-daemon--welcome)
    (when (and (fboundp 'revere-mcp-start-all) (bound-and-true-p revere-mcp-servers))
      (revere-mcp-start-all))
    (when (and (bound-and-true-p revere-discord-autoconnect)
               (featurep 'websocket)
               (fboundp 'revere-discord-token)
               (ignore-errors (revere-discord-token)))
      (condition-case err
          (revere-discord-connect)
        (error (message "Revere: Discord not connected: %s" (error-message-string err)))))
    (message "Revere daemon ready: %d jobs in the logbook, server %s"
             (length revere-job-list) server-name)))

(declare-function revere-discord-token "revere-chan-discord")
(declare-function revere-discord-connect "revere-chan-discord")
(declare-function revere-mcp-start-all "revere-mcp")

(defun revere-daemon-stop ()
  "Stop the timers and write the logbook."
  (interactive)
  (revere-routines-disable)
  (revere-check-in-disable)
  (revere-logbook-flush-all)
  (remove-hook 'server-after-make-frame-hook #'revere-daemon--welcome)
  (setq revere-daemon--started nil)
  (message "Revere daemon stopped"))

(provide 'revere-daemon)
;;; revere-daemon.el ends here
