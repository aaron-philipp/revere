;;; revere-worktree.el --- Unattended jobs work on a branch -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A job nobody is watching cannot leave its work in buffers, so it gets a
;; git worktree on its own branch.  Tools work there as usual; when the
;; model stops, the buffers are saved and committed.  Review is the diff of
;; the branch against its base; keep merges it into the project, discard
;; drops the worktree and the branch.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'revere-config)
(require 'revere-job)
(require 'revere-ws)

(defun revere-worktree-directory ()
  "Where worktrees live."
  (file-name-as-directory (expand-file-name "wt" revere-directory)))

(defun revere-worktree--git (directory &rest args)
  "Run git with ARGS in DIRECTORY.  Return (STATUS . OUTPUT)."
  (with-temp-buffer
    (let* ((default-directory (file-name-as-directory directory))
           (status (apply #'call-process "git" nil t nil args)))
      (cons status (string-trim (buffer-string))))))

(defun revere-worktree--must (directory &rest args)
  "Run git with ARGS in DIRECTORY and return its output, or signal an error."
  (let ((result (apply #'revere-worktree--git directory args)))
    (unless (eql (car result) 0)
      (error "git %s failed: %s" (string-join args " ") (cdr result)))
    (cdr result)))

(defun revere-worktree-repo-p (directory)
  "Non-nil if DIRECTORY is inside a git work tree."
  (and (executable-find "git")
       (file-directory-p directory)
       (eql (car (revere-worktree--git directory "rev-parse" "--is-inside-work-tree")) 0)))

(defun revere-worktree-create (job)
  "Give JOB a worktree on a new branch and make it JOB's directory."
  (let* ((root (revere-job-root job))
         (base (revere-worktree--must root "rev-parse" "HEAD"))
         (branch (concat "revere/" (revere-job-id job)))
         (path (file-name-as-directory
                (expand-file-name (revere-job-id job) (revere-worktree-directory)))))
    (make-directory (revere-worktree-directory) t)
    (revere-worktree--must root "worktree" "add" (directory-file-name path) "-b" branch)
    (setf (revere-job-mode job) 'worktree)
    (setf (revere-job-worktree job) path)
    (setf (revere-job-branch job) branch)
    (setf (revere-job-base job) base)
    (setf (revere-job-directory job) path)
    path))

(defun revere-worktree--identity (directory)
  "Extra git arguments giving an identity if DIRECTORY has none configured."
  (if (eql (car (revere-worktree--git directory "config" "user.email")) 0)
      nil
    (list "-c" "user.name=Revere" "-c" "user.email=revere@localhost")))

(defun revere-worktree-commit (job)
  "Save JOB's buffers and commit whatever changed.  Return non-nil if it did."
  (let ((path (revere-job-worktree job)))
    (revere-ws-keep-all job)
    (unless (string-empty-p (revere-worktree--must path "status" "--porcelain"))
      (revere-worktree--must path "add" "-A")
      (apply #'revere-worktree--must path
             (append (revere-worktree--identity path)
                     (list "commit" "-q" "-m"
                           (format "Revere job %d: %s" (revere-job-number job)
                                   (car (split-string (revere-job-prompt job) "\n"))))))
      t)))

(defun revere-worktree-has-changes-p (job)
  "Non-nil if JOB's branch has commits its base does not."
  (let ((count (revere-worktree--git (revere-job-worktree job) "rev-list" "--count"
                                     (format "%s..HEAD" (revere-job-base job)))))
    (and (eql (car count) 0) (> (string-to-number (cdr count)) 0))))

(defun revere-worktree-diff (job)
  "The diff of JOB's branch against its base, working tree included."
  (revere-worktree--must (revere-job-worktree job) "diff" (revere-job-base job)))

(defun revere-worktree-numstat (job)
  "Changed files on JOB's branch as (ADDED REMOVED FILE) triples."
  (let ((output (revere-worktree--must (revere-job-worktree job) "diff" "--numstat"
                                       (revere-job-base job))))
    (cl-loop for line in (split-string output "\n" t)
             for parts = (split-string line "\t")
             when (= (length parts) 3)
             collect (list (string-to-number (nth 0 parts))
                           (string-to-number (nth 1 parts))
                           (nth 2 parts)))))

(defun revere-worktree--drop (job)
  "Remove JOB's worktree and branch."
  (let ((root (revere-job-root job)))
    (ignore-errors
      (revere-worktree--must root "worktree" "remove" "--force"
                             (directory-file-name (revere-job-worktree job))))
    (ignore-errors (revere-worktree--must root "branch" "-D" (revere-job-branch job)))))

(defun revere-worktree-keep (job)
  "Merge JOB's branch into the project, then drop the worktree."
  (let ((root (revere-job-root job)))
    (revere-worktree--must root "merge" "--no-edit" (revere-job-branch job))
    (revere-worktree--drop job)
    (revere-job-set-state job 'done)))

(defun revere-worktree-discard (job)
  "Drop JOB's worktree and branch, keeping nothing."
  (revere-worktree--drop job)
  (revere-job-set-state job 'discarded))

(provide 'revere-worktree)
;;; revere-worktree.el ends here
