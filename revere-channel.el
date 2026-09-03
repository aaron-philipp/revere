;;; revere-channel.el --- Channels: talking to Revere from outside Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A channel is somewhere a message can arrive from and be sent to: a
;; Discord channel, a Matrix room, an email thread.  Each is named by a key
;; such as "discord:123".  An adapter registers a send function for its
;; prefix and calls `revere-channel-inbound' with what arrives.  This file
;; does the rest: which job a channel is talking to, the slash commands,
;; and telling the channel what the job said, asked for, or changed.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'revere-config)
(require 'revere-job)
(require 'revere-ws)
(require 'revere-loop)
(require 'revere-approve)
(require 'revere-worktree)

(defcustom revere-channel-default-directory "~/"
  "Where a job started from a channel works when nothing else says."
  :type 'directory
  :group 'revere)

(defcustom revere-channel-directories nil
  "Where jobs from each channel work: an alist of channel key to directory."
  :type '(alist :key-type string :value-type directory)
  :group 'revere)

(defconst revere-channel-help
  "Send a message to start a job, or reply to continue one.
/status   what the current job is doing
/ok  /no  answer an approval
/keep     keep the changes (save, or merge the branch)
/discard  discard them
/stop     stop the job
/new TEXT start another job even if one is waiting for review
/dir PATH work somewhere else from now on
/help     this list")

(defvar revere-channel--senders nil
  "Alist of channel prefix to a function called with (KEY TEXT).")

(defvar revere-channel--directories nil
  "Directories set with /dir this session, by channel key.")

(defvar revere-channel--announced (make-hash-table :test 'eq)
  "Job to the last state the channel was told about.")

;;;; Adapters

(defun revere-channel-register (prefix send)
  "Deliver text for channels whose key starts with PREFIX: through SEND."
  (setf (alist-get prefix revere-channel--senders nil nil #'equal) send))

(defun revere-channel-send (key text)
  "Send TEXT to the channel KEY."
  (let* ((prefix (car (split-string key ":")))
         (send (alist-get prefix revere-channel--senders nil nil #'equal)))
    (if send
        (funcall send key text)
      (message "Revere: no way to send to %s" key))))

;;;; Which job

(defun revere-channel-directory (key)
  "Where jobs from channel KEY work."
  (expand-file-name
   (or (alist-get key revere-channel--directories nil nil #'equal)
       (alist-get key revere-channel-directories nil nil #'equal)
       revere-channel-default-directory)))

(defun revere-channel-job (key)
  "The job channel KEY is talking to: its latest job that is not finished."
  (cl-find-if (lambda (job)
                (and (equal (revere-job-origin job) (list 'channel key))
                     (not (memq (revere-job-state job) '(done discarded failed)))))
              revere-job-list))

(defun revere-channel-last-job (key)
  "The latest job from channel KEY, whatever its state."
  (cl-find-if (lambda (job) (equal (revere-job-origin job) (list 'channel key)))
              revere-job-list))

(defun revere-channel--start (key text)
  "Start a job for TEXT from channel KEY."
  (let* ((directory (revere-channel-directory key))
         (job (revere-job-create text directory (list 'channel key))))
    (when (and (eq revere-unattended-mode 'worktree)
               (revere-worktree-repo-p directory))
      (condition-case err
          (revere-worktree-create job)
        (error (revere-channel-send key (format "Working in buffers; no worktree: %s"
                                                (error-message-string err))))))
    (revere-loop-start job)
    job))

;;;; Inbound

(defun revere-channel-inbound (key text)
  "Handle TEXT arriving from channel KEY."
  (let ((text (string-trim (or text ""))))
    (cond
     ((string-empty-p text) nil)
     ((string-prefix-p "/" text) (revere-channel--command key text))
     (t (revere-channel--message key text)))))

(defun revere-channel--message (key text)
  "A plain message from KEY: continue its job or start one."
  (let ((job (revere-channel-job key)))
    (cond
     ((null job) (revere-channel--start key text))
     ((revere-job-active-p job)
      (revere-channel-send key "Still working on the last one; /stop interrupts it."))
     (t (revere-loop-reply job text)))))

(defun revere-channel--command (key text)
  "Run the slash command TEXT from KEY."
  (let* ((parts (split-string text))
         (command (car parts))
         (argument (string-join (cdr parts) " "))
         (job (revere-channel-job key)))
    (pcase command
      ("/help" (revere-channel-send key revere-channel-help))
      ("/status" (revere-channel-send key (revere-channel--status
                                           (or job (revere-channel-last-job key)))))
      ("/ok" (revere-channel--answer key job t))
      ("/no" (revere-channel--answer key job nil))
      ("/keep" (revere-channel--keep key job))
      ("/discard" (revere-channel--discard key job))
      ("/stop" (if (and job (revere-job-active-p job))
                   (progn (revere-loop-interrupt job)
                          (revere-channel-send key "Stopped."))
                 (revere-channel-send key "Nothing is running.")))
      ("/new" (if (string-empty-p argument)
                  (revere-channel-send key "Say what to do: /new TEXT")
                (revere-channel--start key argument)))
      ("/dir" (if (string-empty-p argument)
                  (revere-channel-send key (format "Working in %s" (revere-channel-directory key)))
                (setf (alist-get key revere-channel--directories nil nil #'equal) argument)
                (revere-channel-send key (format "From now on, working in %s"
                                                 (revere-channel-directory key)))))
      (_ (revere-channel-send key (format "Unknown command %s.  /help lists them." command))))))

(defun revere-channel--status (job)
  "A line about JOB, or that there is none."
  (if job
      (format "Job %d: %s%s\n%s"
              (revere-job-number job)
              (revere-job-state-label job)
              (if (revere-job-detail job) (format " (%s)" (revere-job-detail job)) "")
              (car (split-string (revere-job-prompt job) "\n")))
    "Nothing in progress.  Send a message to start a job."))

(defun revere-channel--answer (key job granted)
  "Decide JOB's oldest pending approval for KEY: GRANTED or not."
  (let ((approval (and job (car (revere-approve-pending job)))))
    (if approval
        (revere-approve-decide approval granted)
      (revere-channel-send key "Nothing is waiting for your OK."))))

(defun revere-channel--keep (key job)
  "Keep JOB's changes for KEY."
  (cond
   ((or (null job) (not (eq (revere-job-state job) 'review)))
    (revere-channel-send key "Nothing is waiting for review."))
   ((eq (revere-job-mode job) 'worktree)
    (condition-case err
        (progn (revere-worktree-keep job)
               (revere-channel-send key "Merged into the project."))
      (error (revere-channel-send key (format "Could not merge: %s" (error-message-string err))))))
   (t
    (let ((n (revere-ws-keep-all job)))
      (revere-job-set-state job 'done)
      (revere-channel-send key (format "Kept %d file%s." n (if (= n 1) "" "s")))))))

(defun revere-channel--discard (key job)
  "Discard JOB's changes for KEY."
  (cond
   ((or (null job) (not (eq (revere-job-state job) 'review)))
    (revere-channel-send key "Nothing is waiting for review."))
   ((eq (revere-job-mode job) 'worktree)
    (revere-worktree-discard job)
    (revere-channel-send key "Dropped the branch."))
   (t
    (let ((n (revere-ws-discard-all job)))
      (revere-job-set-state job 'discarded)
      (revere-channel-send key (format "Discarded %d file%s." n (if (= n 1) "" "s")))))))

;;;; Outbound

(defun revere-channel--key (job)
  "The channel key JOB came from, or nil."
  (and (eq (car (revere-job-origin job)) 'channel)
       (cadr (revere-job-origin job))))

(defun revere-channel--on-event (job event)
  "Tell JOB's channel about EVENT."
  (let ((key (revere-channel--key job)))
    (when key
      (pcase (plist-get event :kind)
        ('said (revere-channel-send key (plist-get event :text)))
        ('approval
         (let ((approval (plist-get event :approval)))
           (when (eq (revere-approval-state approval) 'pending)
             (revere-channel-send key (format "⏸ Needs your OK: %s\nReply /ok or /no."
                                              (revere-approve-description approval))))))
        ('error (revere-channel-send key (concat "✗ " (plist-get event :text))))))))

(defun revere-channel-changes-summary (job)
  "What JOB changed, as a few lines."
  (if (eq (revere-job-mode job) 'worktree)
      (let ((files (ignore-errors (revere-worktree-numstat job))))
        (concat (format "Changes on %s, %d file%s:\n" (revere-job-branch job)
                        (length files) (if (= 1 (length files)) "" "s"))
                (mapconcat (lambda (f) (format "- %s  +%d -%d" (nth 2 f) (nth 0 f) (nth 1 f)))
                           files "\n")))
    (let ((entries (revere-ws-pending job)))
      (concat (format "Changes, %d file%s:\n" (length entries) (if (= 1 (length entries)) "" "s"))
              (mapconcat (lambda (entry)
                           (let ((stat (revere-ws-diffstat entry)))
                             (format "- %s  +%d -%d" (revere-ws-relative job entry)
                                     (car stat) (cdr stat))))
                         entries "\n")))))

(defun revere-channel--on-update (job)
  "Tell JOB's channel when it needs review or has failed."
  (let ((key (revere-channel--key job))
        (state (revere-job-state job)))
    (when (and key (not (eq state (gethash job revere-channel--announced))))
      (puthash job state revere-channel--announced)
      (pcase state
        ('review (revere-channel-send key (concat (revere-channel-changes-summary job)
                                                  "\nReply /keep or /discard.")))
        ('failed (revere-channel-send key (format "✗ Failed: %s" (or (revere-job-detail job) ""))))))))

(add-hook 'revere-job-event-hook #'revere-channel--on-event)
(add-hook 'revere-job-update-hook #'revere-channel--on-update)

(provide 'revere-channel)
;;; revere-channel.el ends here
