;;; revere-compact.el --- Keep long transcripts inside the context window -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; When a job's last request used more than `revere-compact-fraction' of
;; the model's window (or `revere-compact-tokens' when the window is
;; unknown), the older part of the transcript is summarized by the model
;; into one message before the next turn, keeping the last
;; `revere-compact-keep' messages verbatim.  Tool calls and their results
;; are never split from each other.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'revere-config)
(require 'revere-job)
(require 'revere-llm)
(require 'revere-models)

(defconst revere-compact-prompt
  "Summarize the conversation below between a user and Revere, an assistant
working in their editor.  Keep everything a continuation needs: the task
and what the user asked for, decisions made and why, every file touched and
its current state, exact names and identifiers, open problems and what to
do next.  Leave out pleasantries and tool output that no longer matters.
Write the summary only, in plain prose and short lists.")

(defun revere-compact-needed-p (job)
  "Non-nil if JOB's transcript should be compacted before the next turn."
  (let* ((used (revere-job-context-tokens job))
         (limit (revere-models-context-limit (revere-job-model job)))
         (threshold (if limit (* revere-compact-fraction limit) revere-compact-tokens)))
    (and used
         (> used threshold)
         (> (length (revere-job-messages job)) (+ 2 revere-compact-keep)))))

(defun revere-compact-split (messages)
  "Split MESSAGES, without the system message, into (OLD RECENT).
RECENT is the last `revere-compact-keep' messages, extended backwards so it
never starts with a tool result whose call would be lost."
  (let* ((n (length messages))
         (cut (max 0 (- n revere-compact-keep))))
    (while (and (> cut 0)
                (equal (plist-get (nth cut messages) :role) "tool"))
      (cl-decf cut))
    (list (seq-take messages cut) (seq-drop messages cut))))

(defun revere-compact--render (messages)
  "MESSAGES as text for the summarizer."
  (mapconcat
   (lambda (message)
     (let ((role (plist-get message :role))
           (content (or (plist-get message :content) ""))
           (calls (plist-get message :tool_calls)))
       (concat role ": "
               (truncate-string-to-width content 3000 nil nil "…")
               (if calls
                   (concat "\n  called: "
                           (mapconcat (lambda (call)
                                        (format "%s %s"
                                                (plist-get (plist-get call :function) :name)
                                                (truncate-string-to-width
                                                 (plist-get (plist-get call :function) :arguments)
                                                 200 nil nil "…")))
                                      (append calls nil) "; "))
                 ""))))
   messages "\n\n"))

(defun revere-compact (job callback)
  "Compact JOB's transcript, then call CALLBACK.
On any failure the transcript is left as it was and CALLBACK still runs."
  (let* ((messages (revere-job-messages job))
         (system (and (equal (plist-get (car messages) :role) "system") (car messages)))
         (body (if system (cdr messages) messages))
         (split (revere-compact-split body))
         (old (car split))
         (recent (cadr split)))
    (if (null old)
        (funcall callback)
      (revere-llm-stream
       (revere-job-model job)
       (list (list :role "system" :content revere-compact-prompt)
             (list :role "user" :content (revere-compact--render old)))
       nil
       (list :on-done
             (lambda (text _calls usage)
               (when (and text (not (string-empty-p text)))
                 (setf (revere-job-messages job)
                       (append (and system (list system))
                               (list (list :role "user"
                                           :content (concat "Summary of the conversation so far; "
                                                            "older messages were compacted:\n\n" text)))
                               recent))
                 (setf (revere-job-context-tokens job) nil)
                 (when (hash-table-p usage)
                   (let ((in (gethash "prompt_tokens" usage)) (out (gethash "completion_tokens" usage)))
                     (when (numberp in) (cl-incf (revere-job-tokens-in job) in))
                     (when (numberp out) (cl-incf (revere-job-tokens-out job) out))))
                 (let ((note (format "Compacted %d older messages into a summary." (length old))))
                   (revere-job-record job 'note :text note)
                   (revere-job-notify job 'note :text note)))
               (funcall callback))
             :on-error
             (lambda (message)
               (revere-job-record job 'note :text (format "Could not compact: %s" message))
               (funcall callback)))))))

(provide 'revere-compact)
;;; revere-compact.el ends here
