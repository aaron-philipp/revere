;;; revere.el --- An assistant that does jobs, built on Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Revere does jobs for you inside Emacs.  You talk to it in a chat that
;; sits beside your files; it reads and edits them in buffers, never on
;; disk, showing you each file as it works.  When it stops you keep or
;; discard the changes, in the file, in the chat, or in a diff.
;;
;; Quick start:
;;   (add-to-list 'load-path "/path/to/revere")
;;   (require 'revere)
;;   (setq revere-base-url "http://localhost:4000" revere-model "qwen-3.8")
;;   M-x revere

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'easymenu)
(require 'revere-config)
(require 'revere-job)
(require 'revere-ws)
(require 'revere-changes)
(require 'revere-tools)
(require 'revere-tools-fs)
(require 'revere-tools-code)
(require 'revere-tools-web)
(require 'revere-tools-job)
(require 'revere-doctor)
(require 'revere-llm)
(require 'revere-models)
(require 'revere-loop)
(require 'revere-layout)
(require 'revere-review)
(require 'revere-approve)
(require 'revere-logbook)
(require 'revere-worktree)
(require 'revere-routines)
(require 'revere-daemon)
(require 'revere-channel)
(require 'revere-chan-discord)
(require 'revere-tree)
(require 'revere-skills)
(require 'revere-mcp)
(require 'revere-memory)
(require 'revere-board)
(require 'revere-prompt)
(require 'revere-chat)

(defconst revere-version "0.2.0"
  "Revere's version.")

(defun revere-project-directory ()
  "The current project's root, or `default-directory'."
  (let ((project (project-current)))
    (if project (project-root project) default-directory)))

(defun revere--default-directory ()
  "Where a new job should work when nothing else says."
  (or (and (project-current) (revere-project-directory))
      (and (revere-job-last) (revere-job-directory (revere-job-last)))
      (if (file-writable-p default-directory) default-directory "~/")))

(defun revere--latest-chat ()
  "The most recently used chat buffer, or nil."
  (cl-find-if (lambda (buffer)
                (with-current-buffer buffer (derived-mode-p 'revere-chat-mode)))
              (buffer-list)))

;;;###autoload
(defun revere ()
  "Talk to Revere: the latest chat, or a new one."
  (interactive)
  (revere-logbook-ensure-loaded)
  (let ((buffer (revere--latest-chat)))
    (if buffer
        (revere-chat-show buffer)
      (revere-new))))

;;;###autoload
(defun revere-new (&optional prompt directory)
  "Start a new job in a fresh chat.
Interactively, open the chat to write in.  With PROMPT, send it at once;
DIRECTORY defaults to the current project.  Return the job, if started."
  (interactive)
  (revere-logbook-ensure-loaded)
  (let ((buffer (revere-chat-create (or directory (revere--default-directory)))))
    (revere-chat-show buffer)
    (with-current-buffer buffer
      (when prompt
        (revere-chat-submit prompt))
      revere-chat--job)))

(defun revere-start (prompt directory)
  "Start a job for PROMPT in DIRECTORY and return it."
  (revere-new prompt directory))

;;;###autoload
(defun revere-say (text)
  "Say TEXT to the latest chat from anywhere, starting one if needed."
  (interactive (list (read-from-minibuffer "Revere › " nil nil nil 'revere-chat-history)))
  (let ((buffer (or (revere--latest-chat)
                    (revere-chat-create (revere--default-directory)))))
    (revere-chat-show buffer)
    (with-current-buffer buffer
      (revere-chat--dispatch text))))

;;;###autoload
(defun revere-jobs ()
  "Switch to one of this session's jobs."
  (interactive)
  (revere-logbook-ensure-loaded)
  (unless revere-job-list
    (user-error "No jobs yet"))
  (let* ((choices (mapcar (lambda (job)
                            (cons (format "%d  %-18s %s"
                                          (revere-job-number job)
                                          (revere-job-state-label job)
                                          (truncate-string-to-width
                                           (revere-job-prompt job) 60 nil nil "…"))
                                  job))
                          revere-job-list))
         (choice (completing-read "Job: " choices nil t)))
    (revere-chat-show (revere-chat-buffer (cdr (assoc choice choices))))))

(defun revere--job-or-error (job)
  "JOB, else the latest job, else a user error."
  (or job (revere-job-last) (user-error "No jobs yet")))

;;;###autoload
(defun revere-changes (&optional job)
  "Review the changes of JOB, default the latest, as one diff."
  (interactive)
  (revere-changes-show (revere--job-or-error job)))

;;;###autoload
(defun revere-keep-all (&optional job)
  "Keep every change of JOB, default the latest: save the files."
  (interactive)
  (with-current-buffer (revere-chat-buffer (revere--job-or-error job))
    (revere-chat-keep-all)))

;;;###autoload
(defun revere-discard-all (&optional job)
  "Discard every change of JOB, default the latest."
  (interactive)
  (with-current-buffer (revere-chat-buffer (revere--job-or-error job))
    (revere-chat-discard-all)))

;;;###autoload
(defun revere-interrupt (&optional job)
  "Stop JOB, default the latest."
  (interactive)
  (let ((job (revere--job-or-error job)))
    (revere-loop-interrupt job)
    (message "Revere: job %d stopped" (revere-job-number job))))

;;;###autoload
(defun revere-help ()
  "Show what Revere can do and how to drive it."
  (interactive)
  (with-help-window "*Revere help*"
    (princ revere-chat-help)))

;;;; Menu

(easy-menu-define revere-menu nil
  "Revere menu."
  '("Revere"
    ["Talk to Revere" revere t]
    ["Say something..." revere-say t]
    ["New job" revere-new t]
    ["Switch job..." revere-jobs revere-job-list]
    "---"
    ["Review changes" revere-changes revere-job-list]
    ["Keep all changes" revere-keep-all revere-job-list]
    ["Discard all changes" revere-discard-all revere-job-list]
    ["Approvals..." revere-approvals t]
    ["Chat to the side / full width" revere-chat-dock-toggle (derived-mode-p 'revere-chat-mode)]
    "---"
    ["Routines" revere-routines t]
    ["Add routine..." revere-routine-add t]
    ["Check-in notes" revere-check-in t]
    ["Board" revere-board t]
    ["Add a card..." revere-board-card-add t]
    ["Add a worker..." revere-board-worker-add t]
    ["Logbook" revere-logbook t]
    "---"
    ["Edit standing instructions" revere-edit-prompt t]
    ["Show the system prompt" revere-show-prompt t]
    ["Skills" revere-skills t]
    ["New skill..." revere-skill-new t]
    ["Memory" revere-memory t]
    ["Debrief now" revere-debrief t]
    ["Debrief every morning" revere-debrief-routine-add t]
    ["Start MCP servers" revere-mcp-start-all revere-mcp-servers]
    "---"
    ["Connect to Discord" revere-discord-connect (not revere-discord--state)]
    ["Disconnect from Discord" revere-discord-disconnect revere-discord--state]
    "---"
    ["Stop job" revere-interrupt revere-job-list]
    ["Run as daemon" revere-daemon-start (not revere-daemon--started)]
    ["Doctor" revere-doctor t]
    ["Help" revere-help t]))

(easy-menu-add-item global-map '("menu-bar") revere-menu "Help")

(provide 'revere)
;;; revere.el ends here
