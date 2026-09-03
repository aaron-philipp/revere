;;; revere-memory.el --- Memory and the debrief -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Memory is Org: ~/.revere/memory/facts.org holds one heading per fact
;; with type, dates and a hit count; MEMORY.org is the index that goes
;; into every system prompt.  `memory-add' and `memory-search' are the
;; tools.  The debrief reads the day's jobs from the logbook and asks the
;; model to remember what is worth keeping; it runs as a routine of kind
;; debrief, or by hand with `revere-debrief'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'revere-config)
(require 'revere-job)
(require 'revere-tools)
(require 'revere-loop)
(require 'revere-logbook)
(require 'revere-routines)

(defcustom revere-memory-prompt-limit 4000
  "Most characters of the memory index to put in the system prompt."
  :type 'integer
  :group 'revere)

(defun revere-memory-directory ()
  "Where memory lives."
  (file-name-as-directory (expand-file-name "memory" revere-directory)))

(defun revere-memory-index-file ()
  "The index file."
  (expand-file-name "MEMORY.org" (revere-memory-directory)))

(defun revere-memory-facts-file ()
  "The file holding the facts."
  (expand-file-name "facts.org" (revere-memory-directory)))

(defun revere-memory--buffer (file header)
  "The Org buffer for FILE, created with HEADER if new."
  (make-directory (revere-memory-directory) t)
  (let ((buffer (find-file-noselect file t)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'org-mode) (org-mode))
      (when (= (buffer-size) 0)
        (insert header)))
    buffer))

(defun revere-memory--save ()
  "Save the current buffer quietly."
  (let ((save-silently t) (inhibit-message t))
    (save-buffer)))

;;;; Tools

(revere-deftool memory-add ((title string "One line naming the fact")
                            (text string "The fact, why it matters, and how to apply it")
                            (type string "user, feedback, project or reference; default project"
                                  :optional t))
  "Remember something for future jobs.
Use it for durable facts: how the user likes things done, what a project
needs, corrections you were given.  Not for what you did in this job."
  (let ((type (or type "project"))
        (stamp (format-time-string "[%Y-%m-%d %a %H:%M]")))
    (with-current-buffer (revere-memory--buffer (revere-memory-facts-file) "#+TITLE: Revere memory\n\n")
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert (format "* %s\n:PROPERTIES:\n:TYPE: %s\n:CREATED: %s\n:LAST_USED: %s\n:HITS: 0\n:END:\n%s\n\n"
                      title type stamp stamp (string-trim text)))
      (revere-memory--save))
    (with-current-buffer (revere-memory--buffer (revere-memory-index-file)
                                                "#+TITLE: What Revere remembers\n\n")
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert (format "- %s (%s)\n" title type))
      (revere-memory--save))
    (format "Remembered: %s" title)))

(defun revere-memory--bump (marker)
  "Count a use of the fact at MARKER."
  (org-with-point-at marker
    (let ((hits (string-to-number (or (org-entry-get nil "HITS") "0"))))
      (org-entry-put nil "HITS" (number-to-string (1+ hits)))
      (org-entry-put nil "LAST_USED" (format-time-string "[%Y-%m-%d %a %H:%M]")))))

(defun revere-memory-search (query)
  "Facts whose heading or text matches QUERY, as strings; use is counted."
  (if (not (file-exists-p (revere-memory-facts-file)))
      nil
    (with-current-buffer (revere-memory--buffer (revere-memory-facts-file) "")
      (let ((found nil)
            (case-fold-search t))
        (org-map-entries
         (lambda ()
           (let* ((end (save-excursion (org-end-of-subtree t t) (point)))
                  (text (buffer-substring-no-properties (point) end)))
             (when (string-match-p query text)
               (revere-memory--bump (point-marker))
               (push (concat "* " (org-get-heading t t t t) "\n"
                             (string-trim (save-excursion
                                            (org-end-of-meta-data t)
                                            (buffer-substring-no-properties (point) end))))
                     found))))
         "LEVEL=1")
        (revere-memory--save)
        (nreverse found)))))

(revere-deftool memory-search ((query string "Words or a regular expression"))
  "Search what Revere remembers from earlier jobs."
  (let ((found (revere-memory-search query)))
    (if found
        (string-join (seq-take found 10) "\n\n")
      "Nothing remembered about that.")))

;;;; The system prompt

(defun revere-memory-prompt (&optional _job)
  "The memory index for the system prompt, or nil."
  (when (file-exists-p (revere-memory-index-file))
    (let ((index (with-temp-buffer
                   (insert-file-contents (revere-memory-index-file))
                   (goto-char (point-min))
                   (while (looking-at "^#\\+\\|^$") (forward-line 1))
                   (string-trim (buffer-substring-no-properties (point) (point-max))))))
      (unless (string-empty-p index)
        (concat "What you remember (memory-search gives details):\n"
                (truncate-string-to-width index revere-memory-prompt-limit nil nil "…"))))))

(add-hook 'revere-loop-system-prompt-functions #'revere-memory-prompt)

;;;; Debrief

(defun revere-debrief-prompt (&optional since)
  "The debrief prompt covering jobs started after SINCE, default a day ago."
  (let* ((since (or since (- (float-time) (* 24 3600))))
         (jobs (cl-remove-if-not (lambda (job) (and (revere-job-started job)
                                                    (> (revere-job-started job) since)
                                                    (not (eq (car (revere-job-origin job)) 'debrief))
                                                    (not (string-prefix-p "Debrief." (revere-job-prompt job)))))
                                 (revere-logbook-read))))
    (if (null jobs)
        nil
      (concat
       "Debrief.  Below are the jobs since the last debrief.  Look for durable lessons:
corrections the user gave, things that were discarded and why, tools that
failed, facts about the projects or the user's preferences.  Use memory-add
for each lesson worth keeping in future jobs, with why it matters and how to
apply it.  Skip anything already remembered (check with memory-search).  If
there is nothing worth keeping, say so and stop.\n\n"
       (mapconcat
        (lambda (job)
          (format "Job %d, %s%s\nPrompt: %s\nDiscarded: %s\nErrors: %s\n"
                  (revere-job-number job)
                  (revere-job-state-label job)
                  (if (revere-job-detail job) (format " (%s)" (revere-job-detail job)) "")
                  (truncate-string-to-width (revere-job-prompt job) 300 nil nil "…")
                  (or (mapconcat #'identity
                                 (cl-loop for event in (revere-job-history job)
                                          when (eq (plist-get event :kind) 'error)
                                          collect (plist-get event :text))
                                 "; ")
                      "none")
                  (if (eq (revere-job-state job) 'discarded) "all changes" "none")))
        (sort jobs (lambda (a b) (< (revere-job-number a) (revere-job-number b))))
        "\n")))))

;;;###autoload
(defun revere-debrief ()
  "Start a job that reads the day's jobs and remembers what matters."
  (interactive)
  (let ((prompt (revere-debrief-prompt)))
    (if (null prompt)
        (message "Revere: nothing to debrief")
      (let ((job (revere-job-create prompt (expand-file-name revere-directory) '(debrief))))
        (revere-loop-start job)
        (message "Revere: debrief started as job %d" (revere-job-number job))
        job))))

(setf (alist-get "debrief" revere-routines-kinds nil nil #'equal)
      (lambda (_routine) (revere-debrief-prompt)))

;;;###autoload
(defun revere-debrief-routine-add ()
  "Add a routine that debriefs every morning at six."
  (interactive)
  (with-current-buffer (revere-routines--buffer (revere-routines-file) revere-routines--header)
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert (format "* ROUTINE Debrief\nSCHEDULED: <%s 06:00 +1d>\n:PROPERTIES:\n:ID: %s\n:KIND: debrief\n:DIRECTORY: %s\n:MODE: buffers\n:END:\nReads the day's jobs and remembers what matters.\n"
                    (format-time-string "%Y-%m-%d %a" (time-add (current-time) (* 24 3600)))
                    (revere-job--new-id)
                    (expand-file-name revere-directory)))
    (revere-routines--save)
    (message "Revere: the debrief will run every morning at 06:00")))

;;;###autoload
(defun revere-memory ()
  "Open the memory index."
  (interactive)
  (pop-to-buffer (revere-memory--buffer (revere-memory-index-file)
                                        "#+TITLE: What Revere remembers\n\n")))

(provide 'revere-memory)
;;; revere-memory.el ends here
