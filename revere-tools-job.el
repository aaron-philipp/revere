;;; revere-tools-job.el --- A plan for the job, and helpers to delegate to -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; `plan' keeps a checklist on the job that the chat shows and the model
;; ticks off.  `delegate' runs a self-contained task as a helper job with
;; its own context and waits for its answer; the helper's changes join the
;; parent's, so there is still one review.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'revere-config)
(require 'revere-job)
(require 'revere-ws)
(require 'revere-tools)
(require 'revere-loop)

;;;; plan

(revere-deftool plan ((items (array string)
                             "The whole plan, one item per string; start done items with [x] and open ones with [ ]"))
  "Keep a checklist for this job.
Send the whole list each time; it replaces the last one and the user sees it."
  (let* ((job (revere-tools-job))
         (items (mapcar (lambda (item)
                          (if (string-match-p "\\`\\[[ xX]\\]" item) item (concat "[ ] " item)))
                        items))
         (done (cl-count-if (lambda (item) (string-match-p "\\`\\[[xX]\\]" item)) items)))
    (setf (revere-job-plan job) items)
    (revere-job-changed job)
    (format "Plan: %d item%s, %d done" (length items) (if (= 1 (length items)) "" "s") done)))

;;;; delegate

(defvar revere-tools-job--waiting nil
  "Alist of helper job id to (PARENT . CALLBACK) for helpers still running.")

(defun revere-tools-job--fold (parent child)
  "Make CHILD's changes part of PARENT's."
  (dolist (entry (revere-ws-changes child))
    (let ((existing (revere-ws-entry parent (revere-change-file entry)))
          (buffer (revere-change-buffer entry)))
      (cond
       ((and existing (buffer-live-p buffer))
        (setf (revere-change-seen-tick existing) (buffer-chars-modified-tick buffer))
        (setf (revere-change-status existing) 'pending))
       (t (push entry (revere-job-changes parent))))))
  (revere-job-changed parent))

(defun revere-tools-job--answer (child)
  "What CHILD ended up saying, for its parent."
  (let ((said (cl-find 'said (revere-job-events child) :key (lambda (e) (plist-get e :kind)))))
    (concat (if said (plist-get said :text) "(the helper said nothing)")
            (pcase (revere-job-state child)
              ('failed (format "\n\nThe helper failed: %s" (or (revere-job-detail child) "")))
              (_ ""))
            (let ((n (length (revere-ws-pending child))))
              (if (> n 0)
                  (format "\n\n%d changed file%s from the helper now count as this job's."
                          n (if (= n 1) "" "s"))
                "")))))

(defun revere-tools-job--on-update (job)
  "When a helper JOB ends, answer its parent."
  (let ((cell (assoc (revere-job-id job) revere-tools-job--waiting)))
    (when (and cell (not (revere-job-active-p job)))
      (setq revere-tools-job--waiting (delq cell revere-tools-job--waiting))
      (let ((parent (cadr cell))
            (callback (cddr cell)))
        (revere-tools-job--fold parent job)
        (when (eq (revere-job-state job) 'review)
          (revere-job-set-state job 'done "folded into the parent job"))
        (funcall callback (revere-tools-job--answer job))))))

(add-hook 'revere-job-update-hook #'revere-tools-job--on-update)

(revere-deftool delegate ((task string "What the helper should do, in full; it knows nothing about this conversation")
                          (directory string "Where the helper works; default this job's directory" :optional t))
  "Hand a self-contained task to a helper job and wait for its answer.
The helper has its own context and tools; its changes join this job's, so
you review everything in one place.  Use it for work that is separate from
what you are doing now."
  :async t
  (let* ((parent (revere-tools-job))
         (where (if directory (expand-file-name directory (revere-job-directory parent))
                  (revere-job-directory parent)))
         (child (revere-job-create task where (list 'parent (revere-job-id parent)))))
    (setf (revere-job-model child) (revere-job-model parent))
    (setf (revere-job-thinking child) (revere-job-thinking parent))
    (setf (revere-job-instructions child) (revere-job-instructions parent))
    (push (cons (revere-job-id child) (cons parent callback)) revere-tools-job--waiting)
    (revere-job-record parent 'note :text (format "Delegated to helper job %d." (revere-job-number child)))
    (revere-job-notify parent 'note :text (format "Delegated to helper job %d." (revere-job-number child)))
    (revere-loop-start child)
    child))

(provide 'revere-tools-job)
;;; revere-tools-job.el ends here
