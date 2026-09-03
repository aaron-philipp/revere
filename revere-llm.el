;;; revere-llm.el --- Model transport: curl and SSE -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A curl subprocess speaking OpenAI-compatible chat completions with
;; server-sent events.  `revere-llm-stream' sends one request and calls
;; back with text fragments as they arrive, then once with the full text,
;; any tool calls and the token usage.  The request body goes through a
;; temp file so long transcripts do not hit command-line length limits.
;;
;; The SSE parser works on strings and is tested without a network.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'auth-source)
(require 'url-parse)
(require 'revere-config)

(cl-defstruct (revere-llm-state (:constructor revere-llm-state--make) (:copier nil))
  (partial "")
  (text "")
  (calls (make-hash-table))
  usage
  finished
  (raw ""))

;;;; Endpoint

(defun revere-llm--resolve (value)
  "VALUE itself, or its result if it is a function."
  (if (functionp value) (funcall value) value))

(defun revere-llm-root ()
  "`revere-base-url' without a trailing slash."
  (string-trim-right (revere-llm--resolve revere-base-url) "/+"))

(defun revere-llm-chat-url ()
  "URL of the chat completions endpoint."
  (concat (revere-llm-root) "/v1/chat/completions"))

(defun revere-llm-key ()
  "The bearer token to send, or nil."
  (let ((key (revere-llm--resolve revere-api-key)))
    (cond
     ((and (stringp key) (not (string-empty-p key))) key)
     (t (revere-llm--auth-source-key)))))

(defun revere-llm--auth-source-key ()
  "Look the token up in `auth-source' by the endpoint's host."
  (let* ((host (url-host (url-generic-parse-url (revere-llm-root))))
         (found (and host (car (auth-source-search :host host :max 1))))
         (secret (and found (plist-get found :secret))))
    (if (functionp secret) (funcall secret) secret)))

(defun revere-llm-curl-args (url body-file)
  "Arguments for a streaming POST of BODY-FILE to URL."
  (let ((key (revere-llm-key)))
    (append (list "-sS" "-N"
                  "--max-time" (number-to-string revere-llm-timeout)
                  "-H" "Content-Type: application/json"
                  "-H" "Accept: text/event-stream")
            (when key (list "-H" (format "Authorization: Bearer %s" key)))
            (list "-X" "POST" "--data-binary" (concat "@" body-file) url))))

;;;; Request

(defun revere-llm-build-request (model messages tools &optional thinking)
  "JSON body for a streaming request of MESSAGES to MODEL offering TOOLS.
THINKING is the reasoning effort, default `revere-thinking-level'."
  (let ((body (list :model model
                    :messages (vconcat messages)
                    :stream t
                    :stream_options (list :include_usage t)))
        (level (or thinking revere-thinking-level)))
    (when tools
      (setq body (append body (list :tools (vconcat tools)))))
    (when (stringp level) (setq level (intern level)))
    (unless (memq level '(off nil))
      (setq body (append body (list :reasoning_effort (symbol-name level)))))
    (json-serialize body)))

(defun revere-llm-get (url callback)
  "GET URL in the background; call CALLBACK with the parsed JSON, or nil."
  (let ((buffer (generate-new-buffer " *revere-get*"))
        (key (revere-llm-key)))
    (make-process
     :name "revere-get"
     :buffer buffer
     :command (append (list "curl" "-sS" "--max-time" "20" "-H" "Accept: application/json")
                      (when key (list "-H" (format "Authorization: Bearer %s" key)))
                      (list url))
     :coding 'utf-8
     :noquery t
     :sentinel (lambda (proc _event)
                 (unless (process-live-p proc)
                   (let ((text (if (buffer-live-p buffer)
                                   (with-current-buffer buffer (buffer-string))
                                 "")))
                     (when (buffer-live-p buffer) (kill-buffer buffer))
                     (funcall callback
                              (condition-case nil (revere-llm--parse text) (error nil)))))))))

(defun revere-llm-stream (model messages tools opts)
  "Send MESSAGES to MODEL with TOOLS and stream the reply through OPTS.
OPTS is a plist of callbacks, plus :thinking for the reasoning effort:
  :on-delta (fn TEXT)              a fragment of assistant text
  :on-done  (fn TEXT CALLS USAGE)  end of reply; CALLS is a list of
                                   (:id ID :name NAME :arguments JSON)
  :on-error (fn MESSAGE)
Return the process."
  (let* ((body-file (make-temp-file "revere-request-" nil ".json"))
         (state (revere-llm-state--make))
         (buffer (generate-new-buffer " *revere-llm*")))
    (let ((coding-system-for-write 'utf-8))
      (write-region (revere-llm-build-request model messages tools (plist-get opts :thinking))
                    nil body-file nil 'silent))
    (make-process
     :name "revere-llm"
     :buffer buffer
     :command (cons "curl" (revere-llm-curl-args (revere-llm-chat-url) body-file))
     :coding 'utf-8
     :connection-type 'pipe
     :noquery t
     :filter (lambda (proc chunk)
               (when (buffer-live-p (process-buffer proc))
                 (with-current-buffer (process-buffer proc)
                   (goto-char (point-max))
                   (insert chunk)))
               (revere-llm--feed state chunk opts))
     :sentinel (lambda (proc _event)
                 (unless (process-live-p proc)
                   (ignore-errors (delete-file body-file))
                   (revere-llm--exit state proc opts)
                   (when (buffer-live-p (process-buffer proc))
                     (kill-buffer (process-buffer proc))))))))

;;;; SSE parsing

(defun revere-llm--feed (state chunk opts)
  "Add CHUNK to STATE and handle every complete line."
  (let ((text (concat (revere-llm-state-partial state) chunk)))
    (let ((lines (split-string text "\n")))
      (setf (revere-llm-state-partial state) (car (last lines)))
      (dolist (line (butlast lines))
        (revere-llm--line state (string-trim-right line "\r") opts)))))

(defun revere-llm--line (state line opts)
  "Handle one complete SSE LINE for STATE."
  (cond
   ((string-match "\\`\\s-*data:\\s-*" line)
    (let ((payload (substring line (match-end 0))))
      (cond
       ((string-prefix-p "[DONE]" payload)
        (revere-llm--finish state opts))
       ((string-empty-p (string-trim payload)) nil)
       (t (revere-llm--event state payload opts)))))
   ((string-empty-p (string-trim line)) nil)
   ((string-prefix-p ":" line) nil)
   (t (setf (revere-llm-state-raw state)
            (concat (revere-llm-state-raw state) line "\n")))))

(defun revere-llm--parse (text)
  "Parse JSON TEXT into hash tables and lists."
  (json-parse-string text :object-type 'hash-table :array-type 'list
                     :null-object nil :false-object nil))

(defun revere-llm--event (state payload opts)
  "Fold one JSON PAYLOAD into STATE."
  (condition-case err
      (let ((event (revere-llm--parse payload)))
        (let ((usage (gethash "usage" event)))
          (when (hash-table-p usage)
            (setf (revere-llm-state-usage state) usage)))
        (dolist (choice (gethash "choices" event))
          (let ((delta (gethash "delta" choice)))
            (when (hash-table-p delta)
              (revere-llm--delta state delta opts)))))
    (error
     (when (plist-get opts :on-error)
       (funcall (plist-get opts :on-error)
                (format "Bad event from the model: %s" (error-message-string err)))))))

(defun revere-llm--delta (state delta opts)
  "Apply one DELTA table to STATE."
  (let ((content (gethash "content" delta)))
    (when (and (stringp content) (not (string-empty-p content)))
      (setf (revere-llm-state-text state) (concat (revere-llm-state-text state) content))
      (when (plist-get opts :on-delta)
        (funcall (plist-get opts :on-delta) content))))
  (dolist (fragment (gethash "tool_calls" delta))
    (when (hash-table-p fragment)
      (revere-llm--merge-call state fragment))))

(defun revere-llm--merge-call (state fragment)
  "Merge a streamed tool-call FRAGMENT into STATE by index."
  (let* ((index (or (gethash "index" fragment) 0))
         (calls (revere-llm-state-calls state))
         (call (or (gethash index calls)
                   (puthash index (list :id "" :name "" :arguments "") calls)))
         (id (gethash "id" fragment))
         (function (gethash "function" fragment)))
    (when (and (stringp id) (not (string-empty-p id)))
      (plist-put call :id id))
    (when (hash-table-p function)
      (let ((name (gethash "name" function))
            (arguments (gethash "arguments" function)))
        (when (and (stringp name) (not (string-empty-p name)))
          (plist-put call :name name))
        (when (stringp arguments)
          (plist-put call :arguments (concat (plist-get call :arguments) arguments)))))))

(defun revere-llm--calls (state)
  "The tool calls collected in STATE, in index order."
  (let (pairs)
    (maphash (lambda (index call) (push (cons index call) pairs))
             (revere-llm-state-calls state))
    (mapcar #'cdr (sort pairs (lambda (a b) (< (car a) (car b)))))))

(defun revere-llm--finish (state opts)
  "Report the end of the reply in STATE once, through OPTS."
  (unless (revere-llm-state-finished state)
    (setf (revere-llm-state-finished state) t)
    (when (plist-get opts :on-done)
      (funcall (plist-get opts :on-done)
               (revere-llm-state-text state)
               (revere-llm--calls state)
               (revere-llm-state-usage state)))))

(defun revere-llm--exit (state proc opts)
  "Handle PROC ending for STATE: finish normally, or report an error via OPTS."
  (let ((code (process-exit-status proc))
        (error-text (revere-llm--error-in-raw state)))
    (cond
     ((revere-llm-state-finished state) nil)
     (error-text
      (setf (revere-llm-state-finished state) t)
      (when (plist-get opts :on-error)
        (funcall (plist-get opts :on-error) error-text)))
     ((/= code 0)
      (setf (revere-llm-state-finished state) t)
      (when (plist-get opts :on-error)
        (funcall (plist-get opts :on-error)
                 (format "curl exited with status %d" code))))
     (t (revere-llm--finish state opts)))))

(defun revere-llm--error-in-raw (state)
  "An error message from a non-SSE reply body in STATE, or nil."
  (let ((raw (string-trim (concat (revere-llm-state-raw state)
                                  (revere-llm-state-partial state)))))
    (when (and (not (string-empty-p raw))
               (string-empty-p (revere-llm-state-text state))
               (zerop (hash-table-count (revere-llm-state-calls state))))
      (condition-case nil
          (let* ((obj (revere-llm--parse raw))
                 (err (and (hash-table-p obj) (gethash "error" obj))))
            (cond ((hash-table-p err)
                   (format "%s" (or (gethash "message" err) err)))
                  (err (format "%s" err))
                  (t (format "Unexpected reply: %s"
                             (truncate-string-to-width raw 200 nil nil "...")))))
        (error (format "Unexpected reply: %s"
                       (truncate-string-to-width raw 200 nil nil "...")))))))

(provide 'revere-llm)
;;; revere-llm.el ends here
