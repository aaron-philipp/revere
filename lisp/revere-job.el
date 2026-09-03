;;; revere-job.el --- The job: one unit of work -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A job is one piece of work with one prompt.  It owns the transcript, the
;; changes, the token counts, and the model process.  Everything else in
;; Revere takes a job as its first argument.
;;
;; States: queued, working, waiting, review, done, discarded, failed.

;;; Code:

(require 'cl-lib)
(require 'revere-config)

(cl-defstruct (revere-job (:constructor revere-job--make) (:copier nil))
  number id prompt
  (origin '(user))
  (state 'queued) detail
  model root directory
  (messages nil)
  (turns 0) (tokens-in 0) (tokens-out 0)
  (changes nil) (approvals nil)
  process buffer started ended
  (progress "")
  (events nil)
  (mode 'buffers) worktree branch base
  thinking context-tokens
  (cost 0.0) (tried nil) plan instructions report-to)

(defvar revere-job-list nil
  "Jobs created this session, newest first.")

(defvar revere-job--counter 0
  "Number given to the next job.")

(defvar revere-current-job nil
  "The job whose tool or turn is running, or nil.")

(defvar revere-job-update-hook nil
  "Run with the job after any change worth redrawing.")

(defvar revere-job-event-hook nil
  "Run with (JOB EVENT) as a job progresses.
EVENT is a plist with :kind one of `prompt', `delta', `said', `tool-call',
`tool-result' or `error', plus the details of that kind.")

(defun revere-job-notify (job kind &rest plist)
  "Tell listeners that JOB produced an event of KIND with PLIST."
  (run-hook-with-args 'revere-job-event-hook job (append (list :kind kind) plist)))

(defun revere-job-create (prompt &optional directory origin)
  "Create a job for PROMPT working in DIRECTORY, default `default-directory'.
ORIGIN says what started it: (user), (routine ID), (check-in) or
\(channel ROOM)."
  (let* ((dir (file-name-as-directory
               (expand-file-name (or directory default-directory))))
         (job (revere-job--make
               :number (cl-incf revere-job--counter)
               :id (revere-job--new-id)
               :prompt prompt
               :origin (or origin '(user))
               :model revere-model
               :thinking revere-thinking-level
               :root dir
               :directory dir
               :started (float-time))))
    (push job revere-job-list)
    (revere-job-changed job)
    job))

(defun revere-job-by-id (id)
  "Return the job with ID, or nil."
  (cl-find id revere-job-list :key #'revere-job-id :test #'equal))

(defun revere-job-unattended-p (job)
  "Non-nil if nobody is watching JOB: it came from a routine or check-in."
  (memq (car (revere-job-origin job)) '(routine check-in)))

(defun revere-job--new-id ()
  "Return a short random identifier."
  (substring (secure-hash 'sha1 (format "%s-%s-%d" (float-time) (emacs-pid) (random)))
             0 12))

(defun revere-job-changed (job)
  "Tell listeners that JOB changed."
  (run-hook-with-args 'revere-job-update-hook job))

(defun revere-job-set-state (job state &optional detail)
  "Move JOB to STATE with optional DETAIL text."
  (setf (revere-job-state job) state)
  (setf (revere-job-detail job) detail)
  (when (memq state '(done discarded failed))
    (setf (revere-job-ended job) (float-time)))
  (revere-job-changed job))

(defun revere-job-record (job kind &rest plist)
  "Add an event of KIND with PLIST to JOB's history and return it."
  (let ((event (append (list :kind kind :time (float-time)) plist)))
    (push event (revere-job-events job))
    (revere-job-changed job)
    event))

(defun revere-job-history (job)
  "Return JOB's events oldest first."
  (reverse (revere-job-events job)))

(defun revere-job-append-message (job message)
  "Append MESSAGE, a plist, to JOB's transcript."
  (setf (revere-job-messages job)
        (append (revere-job-messages job) (list message))))

(defun revere-job-active-p (job)
  "Non-nil while JOB is still doing work."
  (memq (revere-job-state job) '(queued working waiting)))

(defun revere-job-elapsed (job)
  "Seconds JOB has run, or ran."
  (- (or (revere-job-ended job) (float-time)) (revere-job-started job)))

(defun revere-job-title (job)
  "Short name for JOB."
  (format "job %d" (revere-job-number job)))

(defun revere-job-by-number (number)
  "Return the job numbered NUMBER, or nil."
  (cl-find number revere-job-list :key #'revere-job-number))

(defun revere-job-last ()
  "The most recent job, or nil."
  (car revere-job-list))

(defun revere-job-state-label (job)
  "JOB's state as the words the user sees."
  (pcase (revere-job-state job)
    ('queued "queued")
    ('working "working")
    ('waiting "waiting for approval")
    ('review "to review")
    ('done "done")
    ('discarded "discarded")
    ('failed "failed")
    (other (format "%s" other))))

(provide 'revere-job)
;;; revere-job.el ends here
