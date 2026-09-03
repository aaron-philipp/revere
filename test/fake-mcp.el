;;; fake-mcp.el --- A tiny MCP server for the tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with: emacs -Q --batch -l test/fake-mcp.el
;; Speaks just enough JSON-RPC over stdio: initialize, tools/list with one
;; echo tool, and tools/call.

;;; Code:

(require 'json)

(defun fake-mcp--reply (id result)
  "Send RESULT for request ID."
  (send-string-to-terminal
   (concat (json-serialize (list :jsonrpc "2.0" :id id :result result)) "\n")))

(defun fake-mcp--handle (message)
  "Answer MESSAGE, a parsed request."
  (let ((id (gethash "id" message))
        (method (gethash "method" message))
        (params (gethash "params" message)))
    (pcase method
      ("initialize"
       (fake-mcp--reply id (list :protocolVersion "2024-11-05"
                                 :capabilities (list :tools (make-hash-table))
                                 :serverInfo (list :name "fake" :version "0"))))
      ("tools/list"
       (fake-mcp--reply
        id (list :tools
                 (vector (list :name "echo"
                               :description "Echo text back"
                               :inputSchema (list :type "object"
                                                  :properties (list :text (list :type "string"
                                                                                :description "What to echo"))
                                                  :required (vector "text")))))))
      ("tools/call"
       (let* ((arguments (gethash "arguments" params))
              (text (and (hash-table-p arguments) (gethash "text" arguments))))
         (fake-mcp--reply id (list :content (vector (list :type "text" :text (concat "echo: " text)))))))
      (_ nil))))

(let ((running t))
  (while running
    (condition-case nil
        (let ((line (read-from-minibuffer "")))
          (unless (string-empty-p (string-trim line))
            (fake-mcp--handle (json-parse-string line :object-type 'hash-table :array-type 'list
                                                 :null-object nil :false-object nil))))
      (error (setq running nil)))))

;;; fake-mcp.el ends here
