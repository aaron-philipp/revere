;;; revere-loop.el --- The job loop: model turns and tool calls -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; prompt -> model turn -> tool calls? -> run them -> model turn ... -> stop.
;;
;; Everything is driven by callbacks from the transport and the tools, so
;; the main loop never blocks.  Tool calls and the next turn are scheduled
;; with a zero-delay timer rather than run inside a process filter, so a
;; tool that needs to ask the user a question can do so safely.
;;
;; Progress is reported two ways: `revere-job-record' keeps the history on
;; the job, and `revere-job-notify' tells live listeners such as the chat.

;;; Code:

(require 'cl-lib)
(require 'revere-config)
(require 'revere-job)
(require 'revere-ws)
(require 'revere-tools)
(require 'revere-llm)
(require 'revere-models)
(require 'revere-compact)
(require 'revere-worktree)

(defvar revere-loop-system-prompt-functions nil
  "Functions called with the job, returning extra system message text or nil.
Skills and memory add themselves here.")

(defvar revere-loop-system-prompt-function nil
  "Function called with the job to build the whole system message.
When nil, the standing instructions plus the hook functions are used;
revere-prompt.el installs the full assembly.")

(defun revere-loop-system-prompt (&optional job)
  "The system message for JOB."
  (if revere-loop-system-prompt-function
      (funcall revere-loop-system-prompt-function job)
    (string-join (cons revere-system-prompt
                       (delq nil (mapcar (lambda (fn) (condition-case nil (funcall fn job) (error nil)))
                                         revere-loop-system-prompt-functions)))
                 "\n\n")))

(defun revere-loop-start (job)
  "Send JOB's prompt and keep going until the model stops or fails."
  (when (null (revere-job-messages job))
    (revere-job-append-message job (list :role "system" :content (revere-loop-system-prompt job))))
  (revere-loop--say job (revere-job-prompt job)))

(defun revere-loop-reply (job text)
  "Continue JOB with a follow-up TEXT from the user."
  (when (revere-job-active-p job)
    (user-error "Job %d is still working" (revere-job-number job)))
  (revere-loop--say job text))

(defun revere-loop--say (job text)
  "Add the user's TEXT to JOB and take a turn."
  (revere-job-append-message job (list :role "user" :content text))
  (revere-job-record job 'prompt :text text)
  (revere-job-notify job 'prompt :text text)
  (revere-loop--turn job))

(defun revere-loop-interrupt (job)
  "Stop JOB now.  Changes made so far stay pending for review."
  (revere-job-set-state job (if (revere-ws-pending job) 'review 'discarded) "interrupted")
  (let ((process (revere-job-process job)))
    (setf (revere-job-process job) nil)
    (when (and process (process-live-p process))
      (delete-process process))))

;;;; Turns

(defun revere-loop--turn (job)
  "Ask the model for its next reply to JOB's transcript.
Compacts the transcript first when it has grown too long."
  (if (>= (revere-job-turns job) revere-max-turns)
      (revere-job-set-state job 'failed (format "stopped after %d turns" revere-max-turns))
    (revere-job-set-state job 'working "thinking")
    (setf (revere-job-progress job) "")
    (if (revere-compact-needed-p job)
        (progn
          (setf (revere-job-detail job) "compacting")
          (revere-job-changed job)
          (revere-compact job (lambda () (when (revere-loop--live-p job) (revere-loop--request job)))))
      (revere-loop--request job))))

(defun revere-loop--request (job)
  "Send JOB's transcript to the model."
  (setf (revere-job-process job)
        (revere-llm-stream
           (revere-job-model job)
           (revere-job-messages job)
           (revere-tools-schemas)
         (list :thinking (revere-job-thinking job)
               :on-delta (lambda (text) (revere-loop--on-delta job text))
               :on-done (lambda (text calls usage) (revere-loop--on-done job text calls usage))
               :on-error (lambda (message) (revere-loop--on-error job message))))))

(defun revere-loop--live-p (job)
  "Non-nil while JOB still wants callbacks."
  (eq (revere-job-state job) 'working))

(defun revere-loop--on-delta (job text)
  "Append streamed TEXT to JOB's progress and tell listeners."
  (when (revere-loop--live-p job)
    (setf (revere-job-progress job) (concat (revere-job-progress job) text))
    (setf (revere-job-detail job) "writing")
    (revere-job-notify job 'delta :text text)
    (revere-job-changed job)))

(defun revere-loop--on-done (job text calls usage)
  "Handle the end of a model reply to JOB: TEXT, tool CALLS and USAGE."
  (when (revere-loop--live-p job)
    (setf (revere-job-process job) nil)
    (revere-loop--count-usage job usage)
    (when (and text (not (string-empty-p text)))
      (revere-job-record job 'said :text text)
      (revere-job-notify job 'said :text text))
    (cond
     (calls
      (revere-job-append-message job (revere-loop--call-message text calls))
      (run-at-time 0 nil #'revere-loop--run-calls job calls))
     (t
      (when (and text (not (string-empty-p text)))
        (revere-job-append-message job (list :role "assistant" :content text)))
      (revere-loop--finish job)))))

(defun revere-loop--next-model (job)
  "The next model in `revere-model-fallbacks' JOB has not tried, or nil."
  (cl-find-if (lambda (model)
                (not (or (equal model (revere-job-model job))
                         (member model (revere-job-tried job)))))
              revere-model-fallbacks))

(defun revere-loop--on-error (job message)
  "Try the next fallback model for JOB, or record MESSAGE and mark it failed."
  (when (revere-loop--live-p job)
    (setf (revere-job-process job) nil)
    (let ((next (revere-loop--next-model job)))
      (cond
       (next
        (let ((note (format "%s; trying %s instead" message next)))
          (push (revere-job-model job) (revere-job-tried job))
          (setf (revere-job-model job) next)
          (revere-job-record job 'note :text note)
          (revere-job-notify job 'note :text note)
          (revere-loop--request job)))
       (t
        (revere-job-record job 'error :text message)
        (revere-job-notify job 'error :text message)
        (revere-job-set-state job 'failed message))))))

(defun revere-loop--finish (job)
  "The model stopped: JOB needs review if it changed anything, else it is done.
A worktree job commits first; its changes are then on the branch."
  (if (eq (revere-job-mode job) 'worktree)
      (progn
        (condition-case err
            (revere-worktree-commit job)
          (error (revere-job-record job 'error :text (error-message-string err))))
        (revere-job-set-state job (if (revere-worktree-has-changes-p job) 'review 'done)))
    (revere-job-set-state job (if (revere-ws-pending job) 'review 'done))))

(defun revere-loop--count-usage (job usage)
  "Add the token counts in USAGE to JOB."
  (when (hash-table-p usage)
    (let ((in (gethash "prompt_tokens" usage))
          (out (gethash "completion_tokens" usage)))
      (when (numberp in)
        (cl-incf (revere-job-tokens-in job) in)
        (setf (revere-job-context-tokens job) in))
      (when (numberp out) (cl-incf (revere-job-tokens-out job) out))
      (let ((cost (revere-models-cost (revere-job-model job)
                                      (if (numberp in) in 0) (if (numberp out) out 0))))
        (when cost (cl-incf (revere-job-cost job) cost))))))

(defun revere-loop--call-message (text calls)
  "The assistant transcript message carrying TEXT and tool CALLS."
  (list :role "assistant"
        :content (or text "")
        :tool_calls (vconcat
                     (mapcar (lambda (call)
                               (list :id (plist-get call :id)
                                     :type "function"
                                     :function (list :name (plist-get call :name)
                                                     :arguments (plist-get call :arguments))))
                             calls))))

;;;; Tool calls

(defun revere-loop--run-calls (job calls)
  "Run CALLS for JOB one at a time, then take the next turn."
  (when (revere-loop--live-p job)
    (if (null calls)
        (progn
          (cl-incf (revere-job-turns job))
          (revere-loop--turn job))
      (let* ((call (car calls))
             (name (plist-get call :name))
             (arguments (plist-get call :arguments))
             (id (plist-get call :id))
             (event (revere-job-record job 'tool-call :id id :name name :args arguments)))
        (setf (revere-job-detail job) (format "running %s" name))
        (revere-job-notify job 'tool-call :id id :name name :args arguments :event event)
        (revere-job-changed job)
        (let ((revere-current-job job))
          (revere-tools-call
           name arguments
           (lambda (result)
             (plist-put event :result result)
             (revere-job-append-message job (list :role "tool" :tool_call_id id :content result))
             (revere-job-notify job 'tool-result :id id :name name :args arguments
                                :result result :event event)
             (revere-job-changed job)
             (run-at-time 0 nil #'revere-loop--run-calls job (cdr calls)))))))))

(provide 'revere-loop)
;;; revere-loop.el ends here
