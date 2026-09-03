;;; revere-logbook.el --- The logbook: jobs on disk, in Org -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Every job is a heading in ~/.revere/logbook.org: its state as the todo
;; keyword, its numbers as properties, the prompt as an example block, and
;; the transcript and events as Lisp data in source blocks, so they read
;; back exactly.  The file is human-readable and `org-agenda' can show it.
;;
;; Writes are coalesced: a job is saved a couple of seconds after it last
;; changed, and on load jobs that were mid-flight when Emacs stopped are
;; marked accordingly.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'revere-config)
(require 'revere-job)
(require 'revere-ws)

(defvar revere-logbook--timers (make-hash-table :test 'eq)
  "Job to pending save timer.")

(defvar revere-logbook--loaded nil
  "Non-nil once the logbook has been read this session.")

(defconst revere-logbook--header
  "#+TITLE: Revere logbook
#+TODO: QUEUED WORKING WAITING REVIEW | DONE DISCARDED FAILED
#+STARTUP: overview

")

;;;; File

(defun revere-logbook-file ()
  "Path of the logbook."
  (expand-file-name "logbook.org" revere-directory))

(defun revere-logbook--buffer ()
  "The logbook buffer, created with its header if new."
  (make-directory (expand-file-name revere-directory) t)
  (let ((buffer (find-file-noselect (revere-logbook-file) t)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'org-mode)
        (org-mode))
      (when (= (buffer-size) 0)
        (insert revere-logbook--header)
        (org-set-regexps-and-options)))
    buffer))

;;;; Rendering

(defun revere-logbook--keyword (state)
  "Org todo keyword for STATE."
  (upcase (symbol-name state)))

(defun revere-logbook--state (keyword)
  "Job state for Org KEYWORD."
  (let ((state (and keyword (intern (downcase keyword)))))
    (if (memq state '(queued working waiting review done discarded failed))
        state
      'failed)))

(defun revere-logbook--sexp (value)
  "VALUE printed so it reads back, on one line."
  (let ((print-length nil) (print-level nil)
        (print-escape-newlines t) (print-escape-control-characters t))
    (prin1-to-string value)))

(defun revere-logbook--stamp (time)
  "TIME as an Org inactive timestamp, or an empty string."
  (if time (format-time-string "[%Y-%m-%d %a %H:%M]" time) ""))

(defun revere-logbook--render (job)
  "The Org subtree for JOB."
  (concat
   (format "* %s job %d: %s\n"
           (revere-logbook--keyword (revere-job-state job))
           (revere-job-number job)
           (truncate-string-to-width
            (car (split-string (revere-job-prompt job) "\n")) 70 nil nil "…"))
   ":PROPERTIES:\n"
   (format ":ID: %s\n" (revere-job-id job))
   (format ":NUMBER: %d\n" (revere-job-number job))
   (format ":ORIGIN: %s\n" (revere-logbook--sexp (revere-job-origin job)))
   (format ":MODEL: %s\n" (revere-job-model job))
   (format ":ROOT: %s\n" (revere-job-root job))
   (format ":DIRECTORY: %s\n" (revere-job-directory job))
   (format ":MODE: %s\n" (revere-job-mode job))
   (format ":WORKTREE: %s\n" (or (revere-job-worktree job) ""))
   (format ":BRANCH: %s\n" (or (revere-job-branch job) ""))
   (format ":BASE: %s\n" (or (revere-job-base job) ""))
   (format ":TURNS: %d\n" (revere-job-turns job))
   (format ":TOKENS_IN: %d\n" (revere-job-tokens-in job))
   (format ":TOKENS_OUT: %d\n" (revere-job-tokens-out job))
   (format ":STARTED: %s\n" (or (revere-job-started job) ""))
   (format ":ENDED: %s\n" (or (revere-job-ended job) ""))
   (format ":STARTED_AT: %s\n" (revere-logbook--stamp (revere-job-started job)))
   (format ":ENDED_AT: %s\n" (revere-logbook--stamp (revere-job-ended job)))
   (format ":DETAIL: %s\n" (or (revere-job-detail job) ""))
   ":END:\n"
   "** Prompt\n#+begin_example\n"
   (org-escape-code-in-string (revere-job-prompt job))
   "\n#+end_example\n"
   "** Transcript\n#+begin_src emacs-lisp\n"
   (org-escape-code-in-string (revere-logbook--sexp (revere-job-messages job)))
   "\n#+end_src\n"
   "** Events\n#+begin_src emacs-lisp\n"
   (org-escape-code-in-string (revere-logbook--sexp (revere-job-history job)))
   "\n#+end_src\n"
   "** Changes\n"
   (mapconcat (lambda (entry)
                (format "- %s  %s\n" (revere-change-file entry) (revere-change-status entry)))
              (revere-ws-changes job) "")
   "\n"))

;;;; Saving

(defun revere-logbook-save (job)
  "Write JOB's subtree to the logbook, replacing any earlier one."
  (with-current-buffer (revere-logbook--buffer)
    (let ((text (revere-logbook--render job))
          (inhibit-read-only t))
      (save-excursion
        (goto-char (point-min))
        (if (re-search-forward (format "^:ID: +%s$" (regexp-quote (revere-job-id job))) nil t)
            (let ((beg (progn (org-back-to-heading t) (point)))
                  (end (progn (org-end-of-subtree t t) (point))))
              (delete-region beg end)
              (goto-char beg)
              (insert text))
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (insert text)))
      (let ((save-silently t) (inhibit-message t))
        (save-buffer)))))

(defun revere-logbook--schedule (job)
  "Save JOB soon, once, however many changes arrive meanwhile."
  (unless (gethash job revere-logbook--timers)
    (puthash job (run-at-time 2 nil #'revere-logbook--flush job) revere-logbook--timers)))

(defun revere-logbook--flush (job)
  "Save JOB now."
  (remhash job revere-logbook--timers)
  (condition-case err
      (revere-logbook-save job)
    (error (message "Revere: could not write the logbook: %s" (error-message-string err)))))

(defun revere-logbook-flush-all ()
  "Save every job with a pending write.  For shutdown."
  (maphash (lambda (job timer)
             (cancel-timer timer)
             (ignore-errors (revere-logbook-save job)))
           revere-logbook--timers)
  (clrhash revere-logbook--timers))

;;;; Loading

(defun revere-logbook--block (title kind end)
  "The text of the KIND block under the ** TITLE heading before END, or nil."
  (save-excursion
    (when (re-search-forward (format "^\\*\\* %s\n#\\+begin_%s\\(?: [^\n]*\\)?\n" title kind) end t)
      (let ((start (point)))
        (when (re-search-forward "^#\\+end_" end t)
          (org-unescape-code-in-string
           (string-remove-suffix "\n" (buffer-substring-no-properties start (match-beginning 0)))))))))

(defun revere-logbook--read (text)
  "TEXT as Lisp data, or nil."
  (and text (condition-case nil (car (read-from-string text)) (error nil))))

(defun revere-logbook--number (text)
  "TEXT as a number, or nil."
  (and text (not (string-empty-p text)) (string-to-number text)))

(defun revere-logbook--job-at-point ()
  "Build a job from the subtree at point."
  (let* ((props (org-entry-properties nil 'standard))
         (get (lambda (key) (let ((value (cdr (assoc key props))))
                              (and value (not (string-empty-p value)) value))))
         (end (save-excursion (org-end-of-subtree t t) (point)))
         (state (revere-logbook--state (org-get-todo-state))))
    (revere-job--make
     :number (or (revere-logbook--number (funcall get "NUMBER")) 0)
     :id (funcall get "ID")
     :prompt (or (revere-logbook--block "Prompt" "example" end) "")
     :origin (or (revere-logbook--read (funcall get "ORIGIN")) '(user))
     :state state
     :detail (funcall get "DETAIL")
     :model (or (funcall get "MODEL") revere-model)
     :root (funcall get "ROOT")
     :directory (funcall get "DIRECTORY")
     :mode (intern (or (funcall get "MODE") "buffers"))
     :worktree (funcall get "WORKTREE")
     :branch (funcall get "BRANCH")
     :base (funcall get "BASE")
     :messages (revere-logbook--read (revere-logbook--block "Transcript" "src" end))
     :events (reverse (revere-logbook--read (revere-logbook--block "Events" "src" end)))
     :turns (or (revere-logbook--number (funcall get "TURNS")) 0)
     :tokens-in (or (revere-logbook--number (funcall get "TOKENS_IN")) 0)
     :tokens-out (or (revere-logbook--number (funcall get "TOKENS_OUT")) 0)
     :started (or (revere-logbook--number (funcall get "STARTED")) (float-time))
     :ended (revere-logbook--number (funcall get "ENDED")))))

(defun revere-logbook-read ()
  "Every job in the logbook, oldest first."
  (if (not (file-exists-p (revere-logbook-file)))
      nil
    (with-current-buffer (revere-logbook--buffer)
      (let (jobs)
        (org-map-entries (lambda () (push (revere-logbook--job-at-point) jobs)) "LEVEL=1")
        (nreverse jobs)))))

(defun revere-logbook--settle (job)
  "Fix JOB's state for a job that was mid-flight when Emacs stopped."
  (let ((state (revere-job-state job)))
    (cond
     ((and (memq state '(queued working waiting review))
           (eq (revere-job-mode job) 'worktree)
           (revere-job-worktree job)
           (file-directory-p (revere-job-worktree job)))
      (revere-job-set-state job 'review "Emacs restarted; the changes are on the branch"))
     ((memq state '(queued working waiting))
      (revere-job-set-state job 'failed "Emacs restarted while it was working"))
     ((eq state 'review)
      (revere-job-set-state job 'failed "unsaved changes were lost when Emacs stopped")))))

(defun revere-logbook-load ()
  "Read the logbook into this session's job list.  Return how many were added."
  (let ((added 0))
    (dolist (job (revere-logbook-read))
      (unless (or (null (revere-job-id job)) (revere-job-by-id (revere-job-id job)))
        (revere-logbook--settle job)
        (setq revere-job-list (append revere-job-list (list job)))
        (setq revere-job--counter (max revere-job--counter (revere-job-number job)))
        (cl-incf added)))
    (setq revere-job-list (sort revere-job-list (lambda (a b) (> (revere-job-number a) (revere-job-number b)))))
    added))

(defun revere-logbook-enable ()
  "Start writing jobs to the logbook as they change."
  (add-hook 'revere-job-update-hook #'revere-logbook--schedule)
  (add-hook 'kill-emacs-hook #'revere-logbook-flush-all))

(defun revere-logbook-disable ()
  "Stop writing jobs to the logbook."
  (remove-hook 'revere-job-update-hook #'revere-logbook--schedule)
  (remove-hook 'kill-emacs-hook #'revere-logbook-flush-all))

(defun revere-logbook-ensure-loaded ()
  "Read the logbook once and keep it updated from then on."
  (unless revere-logbook--loaded
    (setq revere-logbook--loaded t)
    (revere-logbook-enable)
    (condition-case err
        (revere-logbook-load)
      (error (message "Revere: could not read the logbook: %s" (error-message-string err))))))

;;;###autoload
(defun revere-logbook ()
  "Open the logbook."
  (interactive)
  (pop-to-buffer (revere-logbook--buffer)))

;;;; Searching past jobs

(defun revere-logbook--job-text (job)
  "Everything worth searching in JOB, as one string."
  (concat (revere-job-prompt job) "\n"
          (mapconcat (lambda (event)
                       (concat (or (plist-get event :text) "")
                               (let ((result (plist-get event :result)))
                                 (if (stringp result) (concat "\n" result) ""))))
                     (revere-job-history job) "\n")))

(defun revere-logbook-search (query &optional limit)
  "Past jobs matching QUERY, newest first, at most LIMIT, as strings."
  (let ((found nil)
        (case-fold-search t))
    (dolist (job (reverse (revere-logbook-read)))
      (when (< (length found) (or limit 5))
        (let ((text (revere-logbook--job-text job)))
          (when (string-match query text)
            (let* ((start (max 0 (- (match-beginning 0) 120)))
                   (snippet (replace-regexp-in-string
                             "\n" " " (substring text start (min (length text) (+ (match-end 0) 160))))))
              (push (format "Job %d, %s, %s: %s\n  …%s…"
                            (revere-job-number job)
                            (revere-job-state-label job)
                            (format-time-string "%Y-%m-%d" (revere-job-started job))
                            (truncate-string-to-width (car (split-string (revere-job-prompt job) "\n")) 80 nil nil "…")
                            (string-trim snippet))
                    found))))))
    (nreverse found)))

(require 'revere-tools)

(revere-deftool logbook-search ((query string "Words or a regular expression")
                                (limit integer "Most jobs to return, default 5" :optional t))
  "Search past jobs: their prompts, what was said, and tool results.
Use it to recall how something was done before, or what a file used to be."
  (let ((found (revere-logbook-search query limit)))
    (if found
        (string-join found "\n\n")
      "No past job matches.")))

(provide 'revere-logbook)
;;; revere-logbook.el ends here
