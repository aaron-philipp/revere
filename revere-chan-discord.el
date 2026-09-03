;;; revere-chan-discord.el --- Discord as a channel -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A Discord bot over the gateway (websocket) for receiving messages and
;; the REST API for sending them.  Needs the `websocket' package and a bot
;; token, kept in `auth-source':
;;
;;   machine discord.com login revere-bot password YOUR-TOKEN
;;
;; In the developer portal the bot needs the Message Content intent.  Set
;; `revere-discord-channels' to the channel ids it should listen in, then
;; `revere-discord-connect'.  The daemon connects by itself.
;;
;; Gateway handling is a small state machine over the payloads, tested
;; without a network.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'url)
(require 'url-http)
(require 'auth-source)
(require 'revere-config)
(require 'revere-channel)
(require 'websocket nil t)

(declare-function websocket-open "websocket")
(declare-function websocket-send-text "websocket")
(declare-function websocket-close "websocket")
(declare-function websocket-frame-text "websocket")
(declare-function websocket-openp "websocket")

(defcustom revere-discord-token nil
  "The bot token, a function returning it, or nil to use `auth-source'.
With nil the entry is: machine discord.com login revere-bot password TOKEN."
  :type '(choice (const :tag "Use auth-source" nil) string function)
  :group 'revere)

(defcustom revere-discord-channels nil
  "Ids of the channels Revere listens in.  Messages elsewhere are ignored."
  :type '(repeat string)
  :group 'revere)

(defcustom revere-discord-users nil
  "Ids of the users allowed to talk to Revere.  Empty means anyone in the channels."
  :type '(repeat string)
  :group 'revere)

(defcustom revere-discord-autoconnect t
  "Connect to Discord when the daemon starts, if a token is available."
  :type 'boolean
  :group 'revere)

(defconst revere-discord--gateway "wss://gateway.discord.gg/?v=10&encoding=json")
(defconst revere-discord--api "https://discord.com/api/v10")
(defconst revere-discord--intents
  (logior (ash 1 0) (ash 1 9) (ash 1 12) (ash 1 15))
  "GUILDS, GUILD_MESSAGES, DIRECT_MESSAGES and MESSAGE_CONTENT.")

(cl-defstruct (revere-discord-state (:constructor revere-discord-state--make) (:copier nil))
  socket seq session-id resume-url heartbeat interval user-id ready
  (reconnects 0))

(defvar revere-discord--state nil
  "The live connection, or nil.")

;;;; Token and JSON

(defun revere-discord-token ()
  "The bot token, or nil."
  (let ((token (if (functionp revere-discord-token) (funcall revere-discord-token) revere-discord-token)))
    (if (and (stringp token) (not (string-empty-p token)))
        token
      (let* ((found (car (auth-source-search :host "discord.com" :user "revere-bot" :max 1)))
             (secret (and found (plist-get found :secret))))
        (if (functionp secret) (funcall secret) secret)))))

(defun revere-discord--parse (text)
  "Parse JSON TEXT into hash tables and lists."
  (json-parse-string text :object-type 'hash-table :array-type 'list
                     :null-object nil :false-object nil))

;;;; Gateway

(defun revere-discord--send-op (op data)
  "Send opcode OP with DATA over the gateway."
  (let ((socket (and revere-discord--state (revere-discord-state-socket revere-discord--state))))
    (when (and socket (websocket-openp socket))
      (websocket-send-text socket (json-serialize (list :op op :d data))))))

(defun revere-discord--identify ()
  "Introduce the bot to the gateway."
  (revere-discord--send-op
   2 (list :token (revere-discord-token)
           :intents revere-discord--intents
           :properties (list :os (symbol-name system-type) :browser "revere" :device "emacs"))))

(defun revere-discord--resume ()
  "Pick the previous session back up."
  (let ((state revere-discord--state))
    (revere-discord--send-op
     6 (list :token (revere-discord-token)
             :session_id (revere-discord-state-session-id state)
             :seq (or (revere-discord-state-seq state) :null)))))

(defun revere-discord--heartbeat ()
  "Send a heartbeat."
  (revere-discord--send-op 1 (or (and revere-discord--state (revere-discord-state-seq revere-discord--state))
                                 :null)))

(defun revere-discord--stop-heartbeat ()
  "Cancel the heartbeat timer."
  (when (and revere-discord--state (revere-discord-state-heartbeat revere-discord--state))
    (cancel-timer (revere-discord-state-heartbeat revere-discord--state))
    (setf (revere-discord-state-heartbeat revere-discord--state) nil)))

(defun revere-discord--hello (data)
  "Handle HELLO: start heartbeats at the interval in DATA, then identify or resume."
  (let ((state revere-discord--state)
        (seconds (/ (or (gethash "heartbeat_interval" data) 41250) 1000.0)))
    (revere-discord--stop-heartbeat)
    (setf (revere-discord-state-interval state) seconds)
    (setf (revere-discord-state-heartbeat state)
          (run-with-timer seconds seconds #'revere-discord--heartbeat))
    (if (and (revere-discord-state-session-id state) (revere-discord-state-resume-url state))
        (revere-discord--resume)
      (revere-discord--identify))))

(defun revere-discord--handle (payload)
  "Act on one gateway PAYLOAD."
  (let ((state revere-discord--state)
        (op (gethash "op" payload))
        (data (gethash "d" payload))
        (seq (gethash "s" payload))
        (type (gethash "t" payload)))
    (when (and state (numberp seq))
      (setf (revere-discord-state-seq state) seq))
    (pcase op
      (10 (revere-discord--hello data))
      (11 nil)
      (1 (revere-discord--heartbeat))
      (7 (revere-discord--reconnect t))
      (9 (revere-discord--reconnect (eq data t)))
      (0 (revere-discord--dispatch type data)))))

(defun revere-discord--dispatch (type data)
  "Handle a dispatch event of TYPE with DATA."
  (let ((state revere-discord--state))
    (pcase type
      ("READY"
       (let ((user (gethash "user" data)))
         (setf (revere-discord-state-session-id state) (gethash "session_id" data))
         (setf (revere-discord-state-resume-url state) (gethash "resume_gateway_url" data))
         (setf (revere-discord-state-user-id state) (and user (gethash "id" user)))
         (setf (revere-discord-state-ready state) t)
         (setf (revere-discord-state-reconnects state) 0)
         (message "Revere: connected to Discord as %s" (and user (gethash "username" user)))))
      ("RESUMED" (setf (revere-discord-state-ready state) t))
      ("MESSAGE_CREATE" (revere-discord--message data)))))

(defun revere-discord--message (data)
  "Route a MESSAGE_CREATE DATA to the channel layer if it is for us."
  (let* ((author (gethash "author" data))
         (channel (gethash "channel_id" data))
         (content (gethash "content" data))
         (self (and revere-discord--state (revere-discord-state-user-id revere-discord--state))))
    (when (and (hash-table-p author)
               (not (eq (gethash "bot" author) t))
               (not (equal (gethash "id" author) self))
               (member channel revere-discord-channels)
               (or (null revere-discord-users) (member (gethash "id" author) revere-discord-users))
               (stringp content))
      (revere-channel-inbound (concat "discord:" channel) content))))

;;;; Connection

(defun revere-discord--receive (text)
  "Handle TEXT from the socket, never letting an error kill the connection."
  (condition-case err
      (revere-discord--handle (revere-discord--parse text))
    (error (message "Revere Discord: %s" (error-message-string err)))))

(defun revere-discord--open (url)
  "Open the gateway at URL."
  (setf (revere-discord-state-socket revere-discord--state)
        (websocket-open
         url
         :on-open (lambda (_socket) (message "Revere: Discord gateway open"))
         :on-message (lambda (_socket frame) (revere-discord--receive (websocket-frame-text frame)))
         :on-close (lambda (_socket) (revere-discord--closed))
         :on-error (lambda (_socket kind err) (message "Revere Discord %s: %S" kind err)))))

(defun revere-discord--closed ()
  "The socket closed: reconnect with backoff unless we disconnected."
  (let ((state revere-discord--state))
    (when state
      (revere-discord--stop-heartbeat)
      (setf (revere-discord-state-ready state) nil)
      (when (< (revere-discord-state-reconnects state) 10)
        (cl-incf (revere-discord-state-reconnects state))
        (run-at-time (min 60 (* 2 (revere-discord-state-reconnects state))) nil
                     (lambda ()
                       (when (eq revere-discord--state state)
                         (revere-discord--open (or (revere-discord-state-resume-url state)
                                                   revere-discord--gateway)))))))))

(defun revere-discord--reconnect (resumable)
  "Close the socket so it reconnects; forget the session unless RESUMABLE."
  (let ((state revere-discord--state))
    (when state
      (unless resumable
        (setf (revere-discord-state-session-id state) nil))
      (let ((socket (revere-discord-state-socket state)))
        (when (and socket (websocket-openp socket))
          (websocket-close socket))))))

;;;###autoload
(defun revere-discord-connect ()
  "Connect the bot to Discord."
  (interactive)
  (unless (featurep 'websocket)
    (user-error "Install the websocket package first (M-x package-install RET websocket)"))
  (unless (revere-discord-token)
    (user-error "No Discord token; see revere-discord-token"))
  (when revere-discord--state
    (revere-discord-disconnect))
  (setq revere-discord--state (revere-discord-state--make))
  (revere-discord--open revere-discord--gateway)
  (message "Revere: connecting to Discord…"))

;;;###autoload
(defun revere-discord-disconnect ()
  "Disconnect the bot from Discord."
  (interactive)
  (let ((state revere-discord--state))
    (setq revere-discord--state nil)
    (when state
      (when (revere-discord-state-heartbeat state)
        (cancel-timer (revere-discord-state-heartbeat state)))
      (let ((socket (revere-discord-state-socket state)))
        (when (and socket (fboundp 'websocket-openp) (websocket-openp socket))
          (websocket-close socket)))
      (message "Revere: disconnected from Discord"))))

(defun revere-discord-connected-p ()
  "Non-nil if the bot is connected and ready."
  (and revere-discord--state (revere-discord-state-ready revere-discord--state)))

;;;; Sending

(defun revere-discord--rest (method path body)
  "Call the Discord API: METHOD on PATH with BODY, a plist or nil."
  (let ((url-request-method method)
        (url-request-extra-headers
         (list (cons "Authorization" (concat "Bot " (revere-discord-token)))
               (cons "Content-Type" "application/json")
               (cons "User-Agent" "DiscordBot (Revere for Emacs, 0.2)")))
        (url-request-data (and body (encode-coding-string (json-serialize body) 'utf-8))))
    (url-retrieve (concat revere-discord--api path)
                  (lambda (status)
                    (let ((problem (plist-get status :error)))
                      (when problem
                        (message "Revere Discord: %S" problem)))
                    (kill-buffer (current-buffer)))
                  nil t t)))

(defun revere-discord-chunks (text &optional limit)
  "Split TEXT into pieces of at most LIMIT characters, at line ends when possible."
  (let ((limit (or limit 2000))
        (pieces nil)
        (rest text))
    (while (> (length rest) limit)
      (let* ((cut (or (cl-position ?\n rest :from-end t :end limit) limit))
             (cut (if (zerop cut) limit cut)))
        (push (substring rest 0 cut) pieces)
        (setq rest (string-trim-left (substring rest cut)))))
    (push rest pieces)
    (cl-remove-if #'string-empty-p (nreverse pieces))))

(defun revere-discord-send (key text)
  "Send TEXT to the Discord channel behind KEY."
  (let ((channel (substring key (length "discord:"))))
    (dolist (chunk (revere-discord-chunks text))
      (revere-discord--rest "POST" (format "/channels/%s/messages" channel)
                            (list :content chunk)))))

(revere-channel-register "discord" 'revere-discord-send)

(provide 'revere-chan-discord)
;;; revere-chan-discord.el ends here
