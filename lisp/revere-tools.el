;;; revere-tools.el --- Tools: definition, schema, rules, dispatch -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A tool is an ordinary Emacs command.  `revere-deftool' defines the
;; function, makes it interactive, and registers it with the description
;; and argument schema the model sees.  `describe-function' on the command
;; shows exactly what the model is told.
;;
;; `revere-tools-call' is the one entry point the job loop uses: it looks
;; up the rule for the tool, parses the model's JSON arguments, runs the
;; function, and hands the result string to a callback.  Tools declared
;; `:async t' receive that callback as their first argument.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'revere-config)
(require 'revere-job)

(cl-defstruct (revere-tool (:constructor revere-tool--make) (:copier nil))
  name symbol function description args async
  (rule nil))

(defvar revere-tools--registry (make-hash-table :test 'equal)
  "Tool name (string) to `revere-tool'.")

(defvar revere-tools-check-function #'revere-tools--ask-in-minibuffer
  "Function called as (TOOL ARGS-JSON CONTINUE) when a tool's rule is `check'.
It must eventually call CONTINUE with non-nil to let the tool run, or nil
to decline it.  The default asks in the minibuffer; revere-approve.el
replaces it with an approval the user answers in the chat.")

(defvar revere-tools--manual-job nil
  "Job used when a tool is run by hand with no job current.")

;;;; Definition

(eval-and-compile
  (defun revere-tools--split-options (body)
    "Split leading keyword options off BODY.  Return (PLIST . REST)."
    (let (plist)
      (while (and (keywordp (car body)) (cdr body))
        (push (pop body) plist)
        (push (pop body) plist))
      (cons (nreverse plist) body)))

  (defun revere-tools--normalize-arg (spec)
    "Turn an argument SPEC (SYM TYPE DESCRIPTION &key optional) into a plist."
    (let ((sym (nth 0 spec))
          (type (nth 1 spec))
          (description (nth 2 spec))
          (options (nthcdr 3 spec)))
      (list :name (symbol-name sym)
            :type type
            :description description
            :optional (plist-get options :optional)))))

(defmacro revere-deftool (name args docstring &rest body)
  "Define tool NAME as the command revere-tool-NAME and register it.
ARGS is a list of (SYMBOL TYPE DESCRIPTION [:optional t]) where TYPE is
one of string, integer, number, boolean or (array string).  DOCSTRING's
first paragraph is the description the model sees.  BODY may start with
`:async t', in which case the function receives a CALLBACK first and must
call it with the result instead of returning it."
  (declare (indent defun) (doc-string 3))
  (let* ((split (revere-tools--split-options body))
         (options (car split))
         (body (cdr split))
         (async (plist-get options :async))
         (fn (intern (format "revere-tool-%s" name)))
         (params (mapcar #'car args))
         (lambda-list (if async (cons 'callback params) params)))
    `(progn
       (defun ,fn ,lambda-list
         ,docstring
         (interactive (revere-tools--read-args ,(symbol-name name)))
         ,@body)
       (revere-tools-register
        (revere-tool--make :name ,(symbol-name name)
                           :symbol ',name
                           :function #',fn
                           :description ,(replace-regexp-in-string
                                          "\n" " " (car (split-string docstring "\n\n")))
                           :args ',(mapcar #'revere-tools--normalize-arg args)
                           :async ,async))
       ',fn)))

(defun revere-tools-register (tool)
  "Add TOOL to the registry, replacing any tool of the same name."
  (puthash (revere-tool-name tool) tool revere-tools--registry)
  tool)

(defun revere-tools-get (name)
  "Return the tool called NAME, or nil."
  (gethash name revere-tools--registry))

(defun revere-tools-all ()
  "All registered tools, sorted by name."
  (let (tools)
    (maphash (lambda (_name tool) (push tool tools)) revere-tools--registry)
    (sort tools (lambda (a b) (string< (revere-tool-name a) (revere-tool-name b))))))

;;;; Schema

(defun revere-tools--schema-type (type)
  "JSON schema plist for argument TYPE."
  (pcase type
    ('string (list :type "string"))
    ('integer (list :type "integer"))
    ('number (list :type "number"))
    ('boolean (list :type "boolean"))
    (`(array ,item) (list :type "array" :items (revere-tools--schema-type item)))
    (_ (error "Unknown tool argument type: %S" type))))

(defun revere-tools-schema (tool)
  "OpenAI function-calling schema for TOOL, as a plist."
  (let (properties required)
    (dolist (arg (revere-tool-args tool))
      (let ((name (plist-get arg :name)))
        (setq properties
              (append properties
                      (list (intern (concat ":" name))
                            (append (revere-tools--schema-type (plist-get arg :type))
                                    (list :description (plist-get arg :description))))))
        (unless (plist-get arg :optional)
          (push name required))))
    (list :type "function"
          :function (list :name (revere-tool-name tool)
                          :description (revere-tool-description tool)
                          :parameters (list :type "object"
                                            :properties (or properties (make-hash-table))
                                            :required (vconcat (nreverse required)))))))

(defun revere-tools-schemas ()
  "Schemas for every tool the rules allow at all, in name order."
  (cl-loop for tool in (revere-tools-all)
           unless (eq (revere-tools-rule tool) 'never)
           collect (revere-tools-schema tool)))

;;;; Rules

(defun revere-tools-rule (tool)
  "The rule for TOOL: `go-ahead', `check' or `never'.
`revere-rules' wins; then the rule the tool was registered with; then the
default entry in `revere-rules'."
  (let ((entry (assq (revere-tool-symbol tool) revere-rules)))
    (cond
     (entry (cdr entry))
     ((revere-tool-rule tool))
     ((assq t revere-rules) (cdr (assq t revere-rules)))
     (t 'never))))

(defun revere-tools--ask-in-minibuffer (tool args-json continue)
  "Ask in the minibuffer whether TOOL may run with ARGS-JSON; call CONTINUE."
  (funcall continue
           (y-or-n-p (format "Revere wants to run %s %s.  Go ahead? "
                             (revere-tool-name tool)
                             (truncate-string-to-width args-json 100 nil nil "...")))))

;;;; Arguments

(defun revere-tools-parse-args (args-json)
  "Decode ARGS-JSON, a JSON object string, into a hash table."
  (let ((text (string-trim (or args-json ""))))
    (if (string-empty-p text)
        (make-hash-table :test 'equal)
      (condition-case nil
          (let ((obj (json-parse-string text :object-type 'hash-table
                                        :array-type 'list
                                        :null-object nil :false-object nil)))
            (if (hash-table-p obj) obj (make-hash-table :test 'equal)))
        (error (make-hash-table :test 'equal))))))

(defun revere-tools--positional (tool table)
  "Return TOOL's arguments from hash TABLE in declared order."
  (let (values missing)
    (dolist (arg (revere-tool-args tool))
      (let* ((name (plist-get arg :name))
             (value (gethash name table)))
        (when (and (null value) (not (plist-get arg :optional)))
          (push name missing))
        (push value values)))
    (when missing
      (error "Missing argument%s: %s"
             (if (cdr missing) "s" "")
             (string-join (nreverse missing) ", ")))
    (nreverse values)))

(defun revere-tools--read-args (name)
  "Read the arguments of tool NAME interactively.  For `interactive' specs."
  (let* ((tool (or (revere-tools-get name) (error "No tool called %s" name)))
         (values (mapcar #'revere-tools--read-arg (revere-tool-args tool))))
    (if (revere-tool-async tool)
        (cons (lambda (result) (message "%s" result)) values)
      values)))

(defun revere-tools--read-arg (arg)
  "Read one argument described by plist ARG from the minibuffer."
  (let* ((name (plist-get arg :name))
         (prompt (format "%s%s: " name (if (plist-get arg :optional) " (optional)" "")))
         (type (plist-get arg :type)))
    (pcase type
      ('boolean (y-or-n-p prompt))
      ((or 'integer 'number)
       (let ((text (read-string prompt)))
         (unless (string-empty-p text) (string-to-number text))))
      (`(array ,_)
       (let ((text (read-string prompt)))
         (unless (string-empty-p text) (split-string text "[ ,]+" t))))
      (_ (let ((text (read-string prompt)))
           (unless (string-empty-p text) text))))))

;;;; Dispatch

(defun revere-tools-job ()
  "The job a tool is running for: the current job, or a standing manual one."
  (or revere-current-job
      (and revere-tools--manual-job
           (revere-job-active-p revere-tools--manual-job)
           revere-tools--manual-job)
      (setq revere-tools--manual-job
            (let ((job (revere-job-create "manual")))
              (revere-job-set-state job 'working "by hand")
              job))))

(defun revere-tools-command-rule (command)
  "The rule `revere-command-rules' gives shell COMMAND, or nil if none matches."
  (let ((case-fold-search nil))
    (cdr (cl-find-if (lambda (entry) (string-match-p (car entry) command))
                     revere-command-rules))))

(defun revere-tools-rule-for (tool args-json)
  "The rule for running TOOL with ARGS-JSON: by command pattern for shell."
  (or (and (eq (revere-tool-symbol tool) 'shell)
           (let ((command (gethash "command" (revere-tools-parse-args args-json))))
             (and (stringp command) (revere-tools-command-rule (string-trim command)))))
      (revere-tools-rule tool)))

(defun revere-tools--once (callback)
  "CALLBACK wrapped so that it runs at most once.
A tool must not be able to continue the job twice, however many times its
own machinery reports back."
  (let ((done nil))
    (lambda (result)
      (unless done
        (setq done t)
        (funcall callback result)))))

(defun revere-tools-call (name args-json callback)
  "Run tool NAME with ARGS-JSON, then call CALLBACK with the result string.
CALLBACK is called exactly once."
  (let ((tool (revere-tools-get name))
        (callback (revere-tools--once callback)))
    (cond
     ((null tool)
      (funcall callback (format "error: no tool called %s" name)))
     (t
      (pcase (revere-tools-rule-for tool args-json)
        ('never
         (funcall callback (format "not allowed: the rules say never for %s%s" name
                                   (if (eq (revere-tool-symbol tool) 'shell) " with that command" ""))))
        ('check
         (funcall revere-tools-check-function tool args-json
                  (lambda (granted)
                    (if granted
                        (revere-tools--run tool args-json callback)
                      (funcall callback "declined by the user")))))
        (_ (revere-tools--run tool args-json callback)))))))

(defun revere-tools--run (tool args-json callback)
  "Run TOOL with ARGS-JSON and pass the result to CALLBACK."
  (condition-case err
      (let* ((table (revere-tools-parse-args args-json))
             (values (revere-tools--positional tool table))
             (finish (lambda (result)
                       (funcall callback (revere-tools--coerce result)))))
        (if (revere-tool-async tool)
            (apply (revere-tool-function tool) finish values)
          (funcall finish (apply (revere-tool-function tool) values))))
    (error
     (funcall callback (format "tool %s failed: %s"
                               (revere-tool-name tool)
                               (error-message-string err))))))

(defun revere-tools--coerce (result)
  "Turn RESULT into the string sent to the model, within the size limit."
  (let ((text (cond ((stringp result) result)
                    ((null result) "(no output)")
                    (t (format "%S" result)))))
    (if (> (length text) revere-tool-result-limit)
        (concat (substring text 0 revere-tool-result-limit)
                (format "\n... truncated; %d more characters"
                        (- (length text) revere-tool-result-limit)))
      text)))

(provide 'revere-tools)
;;; revere-tools.el ends here
