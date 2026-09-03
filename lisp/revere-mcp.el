;;; revere-mcp.el --- MCP servers as tools -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A small Model Context Protocol client over stdio: JSON-RPC lines to a
;; subprocess.  Each tool a server offers is registered as a Revere tool
;; named mcp-SERVER-TOOL, so the model, the rules and the chat treat it like
;; any other.  Servers are described in `revere-mcp-servers'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'revere-config)
(require 'revere-tools)

(defcustom revere-mcp-servers nil
  "MCP servers to run: an alist of NAME to a plist (:command CMD :args LIST).
For example:
  ((\"fs\" :command \"npx\"
          :args (\"-y\" \"@modelcontextprotocol/server-filesystem\" \"D:/proj\")))"
  :type '(alist :key-type string :value-type plist)
  :group 'revere)

(defcustom revere-mcp-rule 'check
  "The rule for tools from MCP servers, unless `revere-rules' says otherwise."
  :type '(choice (const go-ahead) (const check) (const never))
  :group 'revere)

(cl-defstruct (revere-mcp-server (:constructor revere-mcp-server--make) (:copier nil))
  name process
  (pending (make-hash-table))
  (next-id 1)
  (partial "")
  tools ready)

(defvar revere-mcp--servers nil
  "Alist of server name to `revere-mcp-server'.")

;;;; Wire

(defun revere-mcp--write (server object)
  "Send OBJECT, a plist, to SERVER as one JSON line."
  (let ((process (revere-mcp-server-process server)))
    (when (process-live-p process)
      (process-send-string process (concat (json-serialize object) "\n")))))

(defun revere-mcp--request (server method params callback)
  "Send METHOD with PARAMS to SERVER; CALLBACK gets (RESULT ERROR)."
  (let ((id (revere-mcp-server-next-id server)))
    (cl-incf (revere-mcp-server-next-id server))
    (puthash id callback (revere-mcp-server-pending server))
    (revere-mcp--write server (list :jsonrpc "2.0" :id id :method method
                                    :params (or params (make-hash-table))))))

(defun revere-mcp--notify (server method)
  "Send the notification METHOD to SERVER."
  (revere-mcp--write server (list :jsonrpc "2.0" :method method)))

(defun revere-mcp--filter (server chunk)
  "Handle CHUNK of output from SERVER."
  (let* ((text (concat (revere-mcp-server-partial server) chunk))
         (lines (split-string text "\n")))
    (setf (revere-mcp-server-partial server) (car (last lines)))
    (dolist (line (butlast lines))
      (unless (string-empty-p (string-trim line))
        (condition-case err
            (revere-mcp--message server
                                 (json-parse-string line :object-type 'hash-table :array-type 'list
                                                    :null-object nil :false-object nil))
          (error (message "Revere MCP %s: %s" (revere-mcp-server-name server)
                          (error-message-string err))))))))

(defun revere-mcp--message (server message)
  "Dispatch MESSAGE, a parsed JSON-RPC object, from SERVER."
  (let* ((id (gethash "id" message))
         (callback (and id (gethash id (revere-mcp-server-pending server)))))
    (when callback
      (remhash id (revere-mcp-server-pending server))
      (funcall callback (gethash "result" message) (gethash "error" message)))))

;;;; Lifecycle

(defun revere-mcp-start (name)
  "Start the MCP server NAME from `revere-mcp-servers' and register its tools."
  (interactive (list (completing-read "MCP server: " (mapcar #'car revere-mcp-servers) nil t)))
  (let ((spec (cdr (assoc name revere-mcp-servers))))
    (unless spec
      (user-error "No MCP server called %s in revere-mcp-servers" name))
    (revere-mcp-stop name)
    (let* ((server (revere-mcp-server--make :name name))
           (process (make-process
                     :name (concat "revere-mcp-" name)
                     :buffer nil
                     :command (cons (plist-get spec :command) (plist-get spec :args))
                     :connection-type 'pipe
                     :coding 'utf-8
                     :noquery t
                     :filter (lambda (_process chunk) (revere-mcp--filter server chunk))
                     :sentinel (lambda (process _event)
                                 (unless (process-live-p process)
                                   (message "Revere MCP %s stopped" name))))))
      (setf (revere-mcp-server-process server) process)
      (setf (alist-get name revere-mcp--servers nil nil #'equal) server)
      (revere-mcp--request
       server "initialize"
       (list :protocolVersion "2024-11-05"
             :capabilities (make-hash-table)
             :clientInfo (list :name "revere" :version "0.2.0"))
       (lambda (_result error)
         (if error
             (message "Revere MCP %s: initialize failed: %S" name error)
           (revere-mcp--notify server "notifications/initialized")
           (revere-mcp--request server "tools/list" nil
                                (lambda (result error)
                                  (if error
                                      (message "Revere MCP %s: tools/list failed: %S" name error)
                                    (revere-mcp--register server (gethash "tools" result))
                                    (setf (revere-mcp-server-ready server) t)
                                    (message "Revere MCP %s: %d tool%s" name
                                             (length (revere-mcp-server-tools server))
                                             (if (= 1 (length (revere-mcp-server-tools server))) "" "s"))))))))
      server)))

(defun revere-mcp-stop (name)
  "Stop the MCP server NAME and drop its tools."
  (interactive (list (completing-read "MCP server: " (mapcar #'car revere-mcp--servers) nil t)))
  (let ((server (cdr (assoc name revere-mcp--servers))))
    (when server
      (dolist (tool (revere-mcp-server-tools server))
        (remhash tool revere-tools--registry))
      (let ((process (revere-mcp-server-process server)))
        (when (process-live-p process)
          (delete-process process)))
      (setq revere-mcp--servers (cl-remove name revere-mcp--servers :key #'car :test #'equal)))))

(defun revere-mcp-start-all ()
  "Start every server in `revere-mcp-servers'."
  (interactive)
  (dolist (spec revere-mcp-servers)
    (condition-case err
        (revere-mcp-start (car spec))
      (error (message "Revere MCP %s: %s" (car spec) (error-message-string err))))))

(defun revere-mcp-ready-p (name)
  "Non-nil once server NAME has listed its tools."
  (let ((server (cdr (assoc name revere-mcp--servers))))
    (and server (revere-mcp-server-ready server))))

;;;; Tools

(defun revere-mcp--arg-type (schema)
  "Revere's argument type for a JSON SCHEMA table."
  (pcase (gethash "type" schema)
    ("integer" 'integer)
    ("number" 'number)
    ("boolean" 'boolean)
    ("array" '(array string))
    (_ 'string)))

(defun revere-mcp--args (input-schema)
  "Revere argument plists for an MCP INPUT-SCHEMA table."
  (let ((required (and (hash-table-p input-schema) (gethash "required" input-schema)))
        (properties (and (hash-table-p input-schema) (gethash "properties" input-schema)))
        (args nil))
    (when (hash-table-p properties)
      (maphash (lambda (name schema)
                 (push (list :name name
                             :type (revere-mcp--arg-type schema)
                             :description (or (and (hash-table-p schema) (gethash "description" schema)) "")
                             :optional (not (member name required))
                             :object (equal (and (hash-table-p schema) (gethash "type" schema)) "object"))
                       args))
               properties))
    (nreverse args)))

(defun revere-mcp--result-text (result)
  "The text in an MCP tools/call RESULT."
  (let ((content (and (hash-table-p result) (gethash "content" result))))
    (string-join
     (delq nil (mapcar (lambda (item)
                         (and (hash-table-p item)
                              (or (gethash "text" item)
                                  (format "[%s]" (gethash "type" item)))))
                       content))
     "\n")))

(defun revere-mcp--make-function (server tool-name args)
  "A Revere tool function calling TOOL-NAME on SERVER with ARGS specs."
  (lambda (callback &rest values)
    (let ((arguments (make-hash-table :test 'equal)))
      (cl-loop for arg in args
               for value in values
               when value
               do (puthash (plist-get arg :name)
                           (if (and (plist-get arg :object) (stringp value))
                               (condition-case nil
                                   (json-parse-string value :object-type 'hash-table)
                                 (error value))
                             value)
                           arguments))
      (revere-mcp--request server "tools/call"
                           (list :name tool-name :arguments arguments)
                           (lambda (result error)
                             (funcall callback
                                      (if error
                                          (format "MCP error: %s" (or (and (hash-table-p error) (gethash "message" error)) error))
                                        (let ((text (revere-mcp--result-text result)))
                                          (if (eq (and (hash-table-p result) (gethash "isError" result)) t)
                                              (concat "MCP tool error: " text)
                                            text)))))))))

(defun revere-mcp--register (server tools)
  "Register TOOLS, a list of tables from tools/list, for SERVER."
  (dolist (tool tools)
    (when (hash-table-p tool)
      (let* ((tool-name (gethash "name" tool))
             (name (format "mcp-%s-%s" (revere-mcp-server-name server) tool-name))
             (args (revere-mcp--args (gethash "inputSchema" tool))))
        (revere-tools-register
         (revere-tool--make :name name
                            :symbol (intern name)
                            :function (revere-mcp--make-function server tool-name args)
                            :description (or (gethash "description" tool) tool-name)
                            :args args
                            :async t
                            :rule revere-mcp-rule))
        (push name (revere-mcp-server-tools server))))))

(provide 'revere-mcp)
;;; revere-mcp.el ends here
