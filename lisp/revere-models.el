;;; revere-models.el --- What the endpoint knows about its models -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Context windows and reasoning support per model, from a LiteLLM proxy's
;; /model/info when there is one, else from `revere-context-limits'.  Used
;; by the chat header to show how full the context is.

;;; Code:

(require 'cl-lib)
(require 'revere-config)
(require 'revere-llm)

(defcustom revere-context-limits nil
  "Context window per model, in tokens, when the endpoint cannot say."
  :type '(alist :key-type string :value-type integer)
  :group 'revere)

(defcustom revere-context-limit nil
  "Context window, in tokens, for models not otherwise known; nil for unknown."
  :type '(choice (const nil) integer)
  :group 'revere)

(defvar revere-models--table (make-hash-table :test 'equal)
  "Model name to a plist (:context TOKENS :thinking BOOL).")

(defvar revere-models--asked nil
  "Non-nil once the endpoint has been asked this session.")

(defun revere-models--number (value)
  "VALUE as a number, or nil."
  (and (numberp value) value))

(defun revere-models-parse (object)
  "Records from a /model/info or /v1/models OBJECT, as an alist of name to plist."
  (let ((entries (and (hash-table-p object) (gethash "data" object)))
        (records nil))
    (dolist (entry entries)
      (when (hash-table-p entry)
        (let* ((name (or (gethash "model_name" entry) (gethash "id" entry)))
               (info (gethash "model_info" entry))
               (params (gethash "litellm_params" entry))
               (pick (lambda (key)
                       (or (and (hash-table-p info) (revere-models--number (gethash key info)))
                           (and (hash-table-p params) (revere-models--number (gethash key params))))))
               (context (funcall pick "max_input_tokens"))
               (thinking (and (hash-table-p info) (eq (gethash "supports_reasoning" info) t))))
          (when (stringp name)
            (push (cons name (list :context context :thinking thinking
                                   :cost-in (funcall pick "input_cost_per_token")
                                   :cost-out (funcall pick "output_cost_per_token")))
                  records)))))
    (nreverse records)))

(defun revere-models-cost (model tokens-in tokens-out)
  "The price of TOKENS-IN and TOKENS-OUT on MODEL, or nil if unknown."
  (let* ((record (gethash model revere-models--table))
         (in (plist-get record :cost-in))
         (out (plist-get record :cost-out)))
    (when (or in out)
      (+ (* (or in 0) tokens-in) (* (or out 0) tokens-out)))))

(defun revere-models-store (records)
  "Remember RECORDS from `revere-models-parse'."
  (dolist (record records)
    (puthash (car record) (cdr record) revere-models--table)))

(defun revere-models-refresh (&optional callback)
  "Ask the endpoint about its models; call CALLBACK with how many it knows."
  (revere-llm-get (concat (revere-llm-root) "/model/info")
                  (lambda (object)
                    (let ((records (and object (revere-models-parse object))))
                      (when records (revere-models-store records))
                      (when callback (funcall callback (length records)))))))

(defun revere-models-ensure ()
  "Ask the endpoint once per session, in the background."
  (unless revere-models--asked
    (setq revere-models--asked t)
    (condition-case nil
        (revere-models-refresh)
      (error nil))))

(defun revere-models-context-limit (model)
  "The context window of MODEL in tokens, or nil if unknown."
  (or (alist-get model revere-context-limits nil nil #'equal)
      (plist-get (gethash model revere-models--table) :context)
      revere-context-limit))

(defun revere-models-thinking-p (model)
  "Non-nil if MODEL is known to take a reasoning effort."
  (plist-get (gethash model revere-models--table) :thinking))

(provide 'revere-models)
;;; revere-models.el ends here
