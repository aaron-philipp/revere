;;; revere-routines.el --- Routines and the check-in: jobs that start themselves -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A routine is a heading in ~/.revere/routines.org with a SCHEDULED time.
;; An Org repeater (+1d, ++1w) makes it recur; Org does the date maths when
;; the heading is marked DONE.  A timer looks for due routines and starts
;; a job for each, on a worktree branch when the directory is a git repo.
;;
;; The check-in is simpler: a timer reads ~/.revere/check-in.org and, if
;; you wrote anything there, starts a job with it and files the notes
;; under a Handled heading.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'revere-config)
(require 'revere-job)
(require 'revere-loop)
(require 'revere-worktree)
(require 'revere-channel)

(declare-function revere-notify "revere-approve")

(defvar revere-routines--timer nil "The routines tick timer.")
(defvar revere-check-in--timer nil "The check-in timer.")
(defvar revere-routines--settled nil "Ids of routine jobs already marked in the file.")

(defvar revere-routines-kinds nil
  "Alist of a routine KIND to a function called with the routine's plist.
It returns a prompt string to run as a job, a job it started itself, or nil
when there is nothing to do this time.  The debrief and the board register
themselves this way.")

(defconst revere-routines--header
  "#+TITLE: Revere routines
#+TODO: ROUTINE RUNNING | DONE

# A routine is a heading with a SCHEDULED time.  A repeater such as +1d or
# ++1w makes it recur.  The text under the heading is the prompt.
# Properties: DIRECTORY (where to work), MODEL, MODE (worktree or buffers).

")

(defconst revere-check-in--header
  "#+TITLE: Revere check-in
#+DIRECTORY: ~/

# Write anything below.  Revere reads this file every so often and starts a
# job with what it finds, then files it under a Handled heading.

")

;;;; Files

(defun revere-routines-file ()
  "Path of the routines file."
  (expand-file-name "routines.org" revere-directory))

(defun revere-check-in-file ()
  "Path of the check-in file."
  (expand-file-name "check-in.org" revere-directory))

(defun revere-routines--buffer (file header)
  "The Org buffer for FILE, created with HEADER if new."
  (make-directory (expand-file-name revere-directory) t)
  (let ((buffer (find-file-noselect file t)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'org-mode)
        (org-mode))
      (when (= (buffer-size) 0)
        (insert header)
        (org-set-regexps-and-options)
        (let ((save-silently t) (inhibit-message t)) (save-buffer))))
    buffer))

(defun revere-routines--save ()
  "Save the current Org buffer quietly."
  (let ((save-silently t) (inhibit-message t))
    (save-buffer)))

;;;; Finding what is due

(defun revere-routines--body ()
  "The prompt text of the routine at point."
  (save-excursion
    (org-end-of-meta-data t)
    (string-trim (buffer-substring-no-properties (point) (org-entry-end-position)))))

(defun revere-routines--at-point ()
  "The routine at point as a plist."
  (let ((id (or (org-entry-get nil "ID")
                (let ((new (revere-job--new-id)))
                  (org-entry-put nil "ID" new)
                  new))))
    (list :id id
          :title (org-get-heading t t t t)
          :prompt (revere-routines--body)
          :directory (org-entry-get nil "DIRECTORY" t)
          :kind (org-entry-get nil "KIND" t)
          :worker (org-entry-get nil "WORKER" t)
          :notify (org-entry-get nil "NOTIFY" t)
          :prompt-file (org-entry-get nil "PROMPT_FILE" t)
          :model (org-entry-get nil "MODEL" t)
          :mode (let ((mode (org-entry-get nil "MODE" t)))
                  (if mode (intern mode) revere-unattended-mode)))))

(defun revere-routines-due ()
  "Routines whose scheduled time has passed and that are not running."
  (with-current-buffer (revere-routines--buffer (revere-routines-file) revere-routines--header)
    (let (due)
      (org-map-entries
       (lambda ()
         (let ((scheduled (org-get-scheduled-time (point))))
           (when (and (equal (org-get-todo-state) "ROUTINE")
                      scheduled
                      (time-less-p scheduled (current-time)))
             (push (revere-routines--at-point) due))))
       "LEVEL=1")
      (revere-routines--save)
      (nreverse due))))

;;;; Starting and finishing

(defun revere-routines--mark (id keyword &optional properties)
  "Set the routine with ID to KEYWORD and PROPERTIES, an alist."
  (with-current-buffer (revere-routines--buffer (revere-routines-file) revere-routines--header)
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward (format "^:ID: +%s$" (regexp-quote id)) nil t)
        (org-back-to-heading t)
        (dolist (property properties)
          (org-entry-put nil (car property) (cdr property)))
        (let ((org-log-repeat nil))
          (org-todo keyword))
        (revere-routines--save)))))

(defun revere-routines--prompt (routine)
  "What ROUTINE should do: a prompt, a job its kind already started, or nil."
  (let* ((kind (plist-get routine :kind))
         (function (and kind (cdr (assoc kind revere-routines-kinds)))))
    (cond
     (function (funcall function routine))
     (kind (error "Unknown routine kind %s" kind))
     (t (plist-get routine :prompt)))))

(defun revere-routines-start (routine)
  "Start a job for ROUTINE, a plist from `revere-routines--at-point'.
Return the job, or nil if the routine had nothing to do this time."
  (let ((work (revere-routines--prompt routine))
        (id (plist-get routine :id)))
    (cond
     ((revere-job-p work)
      (revere-routines--mark id "RUNNING"
                             (list (cons "LAST_JOB" (number-to-string (revere-job-number work)))))
      (unless (revere-job-report-to work)
        (setf (revere-job-report-to work) (plist-get routine :notify)))
      (revere-routines--watch work id)
      work)
     ((or (null work) (string-empty-p (string-trim work)))
      (revere-routines--mark id "DONE" (list (cons "LAST_RESULT" "nothing to do")))
      nil)
     (t
      (let* ((directory (expand-file-name (or (plist-get routine :directory) "~/")))
             (job (revere-job-create work directory (list 'routine id))))
        (when (plist-get routine :model)
          (setf (revere-job-model job) (plist-get routine :model)))
        (setf (revere-job-report-to job) (plist-get routine :notify))
        (setf (revere-job-instructions job) (revere-routines-instructions routine))
        (when (and (eq (plist-get routine :mode) 'worktree)
                   (revere-worktree-repo-p directory))
          (revere-worktree-create job))
        (revere-routines--mark id "RUNNING"
                               (list (cons "LAST_JOB" (number-to-string (revere-job-number job)))))
        (revere-loop-start job)
        job)))))

(defun revere-routines-instructions (routine)
  "The standing instructions ROUTINE's PROMPT_FILE holds, or nil."
  (let ((file (plist-get routine :prompt-file)))
    (when (and file (file-readable-p (expand-file-name file)))
      (with-temp-buffer
        (insert-file-contents (expand-file-name file))
        (string-trim (buffer-string))))))

(defun revere-routines--report (job)
  "Tell JOB's NOTIFY channel how it ended."
  (let ((key (revere-job-report-to job)))
    (when (and key (not (string-empty-p key)))
      (revere-channel-send
       key
       (concat (format "%s: %s%s\n"
                       (car (split-string (revere-job-prompt job) "\n"))
                       (revere-job-state-label job)
                       (if (revere-job-detail job) (format " (%s)" (revere-job-detail job)) ""))
               (let ((said (cl-find 'said (revere-job-events job) :key (lambda (e) (plist-get e :kind)))))
                 (if said (concat (plist-get said :text) "\n") ""))
               (if (eq (revere-job-state job) 'review)
                   (concat (revere-channel-changes-summary job) "\nReply /keep or /discard.")
                 ""))))))

(defvar revere-routines--watched nil
  "Alist of job id to routine id, for jobs a routine kind started itself.")

(defun revere-routines--watch (job routine-id)
  "Mark the routine ROUTINE-ID done when JOB ends."
  (push (cons (revere-job-id job) routine-id) revere-routines--watched))

(defun revere-routines--routine-of (job)
  "The id of the routine behind JOB, or nil."
  (or (and (eq (car (revere-job-origin job)) 'routine) (cadr (revere-job-origin job)))
      (cdr (assoc (revere-job-id job) revere-routines--watched))))

(defun revere-routines--on-update (job)
  "When a routine's JOB ends, mark the routine done so Org reschedules it."
  (let ((routine-id (revere-routines--routine-of job)))
    (when (and routine-id
               (memq (revere-job-state job) '(review done discarded failed))
               (not (member (revere-job-id job) revere-routines--settled)))
      (push (revere-job-id job) revere-routines--settled)
      (revere-routines--mark routine-id "DONE"
                             (list (cons "LAST_RESULT" (symbol-name (revere-job-state job)))))
      (revere-routines--report job)
      (revere-notify (format "Revere routine finished: %s" (revere-job-state-label job))
                     (car (split-string (revere-job-prompt job) "\n"))))))

(defun revere-routines-tick ()
  "Start a job for every routine that is due."
  (condition-case err
      (dolist (routine (revere-routines-due))
        (revere-routines-start routine))
    (error (message "Revere routines: %s" (error-message-string err)))))

(defun revere-routines-enable ()
  "Start looking for due routines every `revere-routine-tick' seconds."
  (add-hook 'revere-job-update-hook #'revere-routines--on-update)
  (unless revere-routines--timer
    (setq revere-routines--timer
          (run-with-timer revere-routine-tick revere-routine-tick #'revere-routines-tick))))

(defun revere-routines-disable ()
  "Stop looking for due routines."
  (remove-hook 'revere-job-update-hook #'revere-routines--on-update)
  (when revere-routines--timer
    (cancel-timer revere-routines--timer)
    (setq revere-routines--timer nil)))

;;;; Commands

;;;###autoload
(defun revere-routines ()
  "Open the routines file."
  (interactive)
  (pop-to-buffer (revere-routines--buffer (revere-routines-file) revere-routines--header)))

;;;###autoload
(defun revere-routine-add (title prompt directory when repeat)
  "Add a routine TITLE doing PROMPT in DIRECTORY at WHEN, repeating every REPEAT."
  (interactive
   (list (read-string "Routine name: ")
         (read-string "What should it do: ")
         (read-directory-name "Work in: " nil nil t)
         (org-read-date t t nil "First run: ")
         (read-string "Repeat (+1d, ++1w, or empty for once): ")))
  (with-current-buffer (revere-routines--buffer (revere-routines-file) revere-routines--header)
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert (format "* ROUTINE %s\nSCHEDULED: <%s%s>\n:PROPERTIES:\n:ID: %s\n:DIRECTORY: %s\n:END:\n%s\n"
                    title
                    (format-time-string "%Y-%m-%d %a %H:%M" when)
                    (if (string-empty-p repeat) "" (concat " " repeat))
                    (revere-job--new-id)
                    (expand-file-name directory)
                    prompt))
    (revere-routines--save)
    (message "Revere: routine %s added" title)))

;;;###autoload
(defun revere-routine-run-now ()
  "Start the routine at point in the routines file now."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Use this in the routines file"))
  (org-back-to-heading t)
  (let ((job (revere-routines-start (revere-routines--at-point))))
    (if job
        (message "Revere: started job %d" (revere-job-number job))
      (message "Revere: that routine had nothing to do"))))

;;;; Check-in

(defun revere-check-in--notes ()
  "The notes in the check-in file, and its directory, as (NOTES . DIRECTORY)."
  (with-current-buffer (revere-routines--buffer (revere-check-in-file) revere-check-in--header)
    (save-excursion
      (goto-char (point-min))
      (let ((directory (if (re-search-forward "^#\\+DIRECTORY: *\\(.+\\)$" nil t)
                           (match-string 1)
                         "~/"))
            (end (save-excursion (goto-char (point-min))
                                 (if (re-search-forward "^\\* " nil t) (match-beginning 0) (point-max)))))
        (goto-char (point-min))
        (let ((lines nil))
          (while (< (point) end)
            (let ((line (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
              (unless (or (string-prefix-p "#" line) (string-empty-p (string-trim line)))
                (push line lines)))
            (forward-line 1))
          (cons (string-join (nreverse lines) "\n") directory))))))

(defun revere-check-in--file-notes (job)
  "Move the handled notes under a heading naming JOB."
  (with-current-buffer (revere-routines--buffer (revere-check-in-file) revere-check-in--header)
    (save-excursion
      (goto-char (point-min))
      (let ((end (if (re-search-forward "^\\* " nil t) (match-beginning 0) (point-max)))
            (kept nil) (notes nil))
        (goto-char (point-min))
        (while (< (point) end)
          (let ((line (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
            (if (or (string-prefix-p "#" line) (string-empty-p (string-trim line)))
                (push line kept)
              (push line notes)))
          (forward-line 1))
        (delete-region (point-min) end)
        (goto-char (point-min))
        (insert (string-join (nreverse kept) "\n") "\n\n"
                (format "* Handled %s (job %d)\n%s\n\n"
                        (format-time-string "[%Y-%m-%d %a %H:%M]")
                        (revere-job-number job)
                        (string-join (nreverse notes) "\n")))))
    (revere-routines--save)))

(defun revere-check-in-tick ()
  "Start a job with whatever the check-in file holds."
  (condition-case err
      (let* ((found (revere-check-in--notes))
             (notes (car found)))
        (unless (string-empty-p notes)
          (let* ((directory (expand-file-name (cdr found)))
                 (job (revere-job-create (concat "Notes from my check-in file:\n\n" notes)
                                         directory '(check-in))))
            (when (and (eq revere-unattended-mode 'worktree)
                       (revere-worktree-repo-p directory))
              (revere-worktree-create job))
            (revere-check-in--file-notes job)
            (revere-loop-start job)
            job)))
    (error (message "Revere check-in: %s" (error-message-string err)))))

(defun revere-check-in-enable ()
  "Start reading the check-in file every `revere-check-in-interval' seconds."
  (unless revere-check-in--timer
    (setq revere-check-in--timer
          (run-with-timer revere-check-in-interval revere-check-in-interval
                          #'revere-check-in-tick))))

(defun revere-check-in-disable ()
  "Stop reading the check-in file."
  (when revere-check-in--timer
    (cancel-timer revere-check-in--timer)
    (setq revere-check-in--timer nil)))

;;;###autoload
(defun revere-check-in ()
  "Open the check-in file."
  (interactive)
  (pop-to-buffer (revere-routines--buffer (revere-check-in-file) revere-check-in--header)))

(provide 'revere-routines)
;;; revere-routines.el ends here
