;;; revere-ws.el --- Workspace: buffers as the staging area -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Revere edits buffers, never files.  This file tracks which buffers a job
;; has touched, guards against editing a buffer that changed under it, and
;; turns the buffers back into files (keep) or back into what was on disk
;; (discard).  It also produces the disk-versus-buffer diff the changes
;; buffer displays.
;;
;; Each touched buffer gets a change group when it is first visited, so
;; discarding is an undo back to that point and keeping is a save.

;;; Code:

(require 'cl-lib)
(require 'diff)
(require 'revere-job)

(cl-defstruct (revere-change (:constructor revere-change--make) (:copier nil))
  file buffer base-tick seen-tick created-p
  (status 'pending)
  group
  (stat-tick nil) (stat nil))

;;;; Paths

(defun revere-ws--key (path)
  "Canonical form of PATH for comparing files."
  (file-truename (expand-file-name path)))

(defun revere-ws--same-file-p (a b)
  "Non-nil if paths A and B name the same file."
  (if (memq system-type '(windows-nt ms-dos cygwin))
      (string-equal (downcase a) (downcase b))
    (string-equal a b)))

;;;; Tracking

(defun revere-ws-entry (job path)
  "Return JOB's change entry for PATH, or nil."
  (let ((key (revere-ws--key path)))
    (cl-find-if (lambda (entry) (revere-ws--same-file-p key (revere-change-file entry)))
                (revere-job-changes job))))

(defun revere-ws-entry-for-buffer (job buffer)
  "Return JOB's change entry whose buffer is BUFFER, or nil."
  (cl-find buffer (revere-job-changes job) :key #'revere-change-buffer))

(defun revere-ws-visit (job path)
  "Visit PATH for JOB and return its buffer, tracking it in JOB's changes.
PATH is taken relative to JOB's directory.  The file need not exist yet."
  (let* ((full (revere-ws--key (expand-file-name path (revere-job-directory job))))
         (entry (revere-ws-entry job full)))
    (cond
     ((and entry (buffer-live-p (revere-change-buffer entry)))
      (revere-change-buffer entry))
     (t
      (when entry
        (setf (revere-job-changes job) (delq entry (revere-job-changes job))))
      (revere-ws--track job full)))))

(defun revere-ws--track (job full)
  "Start tracking FULL for JOB and return its buffer.
FULL may be remote, such as a TRAMP path into a container."
  (let* ((created (not (file-exists-p full)))
         (buffer (revere-ws--find-file full))
         (tick (buffer-chars-modified-tick buffer))
         (group (revere-ws--start-group buffer)))
    (push (revere-change--make :file full :buffer buffer
                               :base-tick tick :seen-tick tick
                               :created-p created :group group)
          (revere-job-changes job))
    buffer))

(defun revere-ws--find-file (full)
  "Visit FULL quietly and return its buffer.
A file whose directory does not exist yet comes back read-only from
`find-file-noselect'; the directory is created when the file is kept, so
the buffer is made writable here."
  (let* ((enable-local-variables :safe)
         (large-file-warning-threshold nil)
         (buffer (find-file-noselect full t)))
    (unless (file-exists-p full)
      (with-current-buffer buffer
        (setq buffer-read-only nil)))
    buffer))

(defun revere-ws--start-group (buffer)
  "Open a change group on BUFFER and return its handle."
  (with-current-buffer buffer
    (when (eq buffer-undo-list t)
      (buffer-enable-undo))
    (let ((group (prepare-change-group buffer)))
      (activate-change-group group)
      group)))

(defun revere-ws--restart-group (entry)
  "Give ENTRY a fresh change group from its buffer's current state."
  (let ((buffer (revere-change-buffer entry)))
    (when (buffer-live-p buffer)
      (setf (revere-change-group entry) (revere-ws--start-group buffer))
      (setf (revere-change-base-tick entry) (buffer-chars-modified-tick buffer))
      (setf (revere-change-seen-tick entry) (buffer-chars-modified-tick buffer)))))

;;;; Freshness

(defun revere-ws-check-fresh (job buffer)
  "Signal an error if BUFFER changed since JOB last read or edited it."
  (let ((entry (revere-ws-entry-for-buffer job buffer)))
    (when (and entry
               (/= (revere-change-seen-tick entry) (buffer-chars-modified-tick buffer)))
      (error "Stale: %s changed since it was last read; read it again"
             (buffer-name buffer)))))

(defun revere-ws-mark-seen (job buffer)
  "Record that JOB has just read BUFFER."
  (let ((entry (revere-ws-entry-for-buffer job buffer)))
    (when entry
      (setf (revere-change-seen-tick entry) (buffer-chars-modified-tick buffer)))))

(defun revere-ws-touch (job buffer)
  "Record that JOB edited BUFFER."
  (let ((entry (revere-ws-entry-for-buffer job buffer)))
    (when entry
      (setf (revere-change-status entry) 'pending)
      (setf (revere-change-seen-tick entry) (buffer-chars-modified-tick buffer))))
  (revere-job-changed job))

;;;; Queries

(defun revere-ws-changed-p (entry)
  "Non-nil if ENTRY's buffer holds changes not on disk."
  (let ((buffer (revere-change-buffer entry)))
    (and (buffer-live-p buffer)
         (eq (revere-change-status entry) 'pending)
         (with-current-buffer buffer
           (if (revere-change-created-p entry)
               (> (buffer-size) 0)
             (buffer-modified-p))))))

(defun revere-ws-changes (job)
  "JOB's change entries in the order first touched."
  (reverse (revere-job-changes job)))

(defun revere-ws-pending (job)
  "JOB's change entries that still hold unsaved changes."
  (cl-remove-if-not #'revere-ws-changed-p (revere-ws-changes job)))

(defun revere-ws-relative (job entry)
  "ENTRY's file name relative to JOB's root."
  (file-relative-name (revere-change-file entry) (revere-job-root job)))

;;;; Keep and discard

(defun revere-ws-keep-file (job entry)
  "Save ENTRY's buffer for JOB: its changes are kept."
  (let ((buffer (revere-change-buffer entry)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((dir (file-name-directory (revere-change-file entry))))
          (unless (file-directory-p dir)
            (make-directory dir t)))
        (ignore-errors (accept-change-group (revere-change-group entry)))
        (save-buffer))
      (setf (revere-change-created-p entry) nil)
      (revere-ws--restart-group entry))
    (setf (revere-change-status entry) 'kept)
    (revere-job-changed job)))

(defun revere-ws-discard-file (job entry)
  "Undo JOB's changes to ENTRY's file."
  (let ((buffer (revere-change-buffer entry)))
    (when (buffer-live-p buffer)
      (if (revere-change-created-p entry)
          (with-current-buffer buffer
            (set-buffer-modified-p nil)
            (kill-buffer buffer))
        (with-current-buffer buffer
          (condition-case nil
              (cancel-change-group (revere-change-group entry))
            (error (revert-buffer t t t)))
          (when (revere-ws--matches-disk-p buffer)
            (set-buffer-modified-p nil)))
        (revere-ws--restart-group entry)))
    (setf (revere-change-status entry) 'discarded)
    (revere-job-changed job)))

(defun revere-ws--matches-disk-p (buffer)
  "Non-nil if BUFFER's text equals its file on disk."
  (let ((file (buffer-file-name buffer)))
    (and file (file-exists-p file)
         (string= (with-current-buffer buffer
                    (buffer-substring-no-properties (point-min) (point-max)))
                  (with-temp-buffer
                    (insert-file-contents file)
                    (buffer-string))))))

(defun revere-ws-keep-all (job)
  "Keep every pending change of JOB.  Return how many files were saved."
  (let ((entries (revere-ws-pending job)))
    (dolist (entry entries)
      (revere-ws-keep-file job entry))
    (length entries)))

(defun revere-ws-discard-all (job)
  "Discard every pending change of JOB.  Return how many files were reverted."
  (let ((entries (revere-ws-pending job)))
    (dolist (entry entries)
      (revere-ws-discard-file job entry))
    (length entries)))

;;;; Diffs

(defun revere-ws-diff (entry)
  "Unified diff of ENTRY's file on disk against its buffer, or nil if equal.
Both header lines name the real file so `diff-mode' can find the buffer."
  (let* ((buffer (revere-change-buffer entry))
         (file (revere-change-file entry))
         (created (revere-change-created-p entry))
         (remote (and (not created) (file-remote-p file)))
         (old (cond (created (make-temp-file "revere-empty-"))
                    (remote (file-local-copy file))
                    (t file)))
         (new (make-temp-file "revere-buffer-")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (write-region (point-min) (point-max) new nil 'silent))
          (revere-ws--run-diff file old new))
      (delete-file new)
      (when (or created remote) (delete-file old)))))

(defun revere-ws--run-diff (file old new)
  "Run `diff-command' on OLD and NEW, labelling both as FILE."
  (with-temp-buffer
    (let ((status (call-process diff-command nil t nil
                                "-u"
                                "--label" (concat file "\tdisk")
                                "--label" (concat file "\tbuffer")
                                old new)))
      (pcase status
        (0 nil)
        (1 (buffer-string))
        (_ (error "Diff failed (%s): %s" status (string-trim (buffer-string))))))))

(defun revere-ws-diffstat (entry)
  "Return (ADDED . REMOVED) line counts for ENTRY, cached per buffer tick."
  (let* ((buffer (revere-change-buffer entry))
         (tick (and (buffer-live-p buffer) (buffer-chars-modified-tick buffer))))
    (if (and tick (eql tick (revere-change-stat-tick entry)))
        (revere-change-stat entry)
      (let ((stat (revere-ws--count-diff (and tick (revere-ws-diff entry)))))
        (setf (revere-change-stat-tick entry) tick)
        (setf (revere-change-stat entry) stat)
        stat))))

(defun revere-ws--count-diff (diff)
  "Count added and removed lines in DIFF text."
  (let ((added 0) (removed 0))
    (when diff
      (dolist (line (split-string diff "\n"))
        (cond ((string-prefix-p "+++" line))
              ((string-prefix-p "---" line))
              ((string-prefix-p "+" line) (cl-incf added))
              ((string-prefix-p "-" line) (cl-incf removed)))))
    (cons added removed)))

(provide 'revere-ws)
;;; revere-ws.el ends here
