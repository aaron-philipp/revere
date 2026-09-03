;;; revere-client.el --- Talk to the Revere daemon from another Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Load this in your daily Emacs when Revere runs as a separate daemon.
;; It sends forms to the daemon with `server-eval-at' and can open a client
;; frame on it.  Nothing else from Revere needs to be loaded here.

;;; Code:

(require 'server)
(require 'project)

;; Loaded only when a TLS connection is actually asked for; declared here
;; so let-binding them below is a dynamic binding, not a lexical one.
(defvar gnutls-trustfiles)
(defvar gnutls-verify-error)
(defvar nsm-noninteractive)

(defgroup revere-client nil
  "Talking to a Revere daemon."
  :group 'tools
  :prefix "revere-client-")

(defcustom revere-client-server "revere"
  "Name of the daemon's server."
  :type 'string)

(defcustom revere-client-auth-dir nil
  "Where the daemon's server file is, when it is not in `server-auth-dir'.
A daemon on another machine writes its address and key to a file named
after its server.  Point this at that folder, a mounted share for
instance, and the key is always the current one; nil uses your own
`server-auth-dir', where you would have copied the file by hand."
  :type '(choice (const :tag "Your own server-auth-dir" nil) directory))

(defcustom revere-client-tls nil
  "Non-nil to reach the daemon over TLS with a certificate of your own.
Emacs's own server authentication is a shared key sent in the clear, which
is only safe on a socket or a trusted wire.  With this on, the daemon sits
behind a proxy that speaks TLS and demands a client certificate, so the
key never crosses the network in the open and a caller without the
certificate never gets far enough to try one."
  :type 'boolean)

(defcustom revere-client-host nil
  "Host the daemon answers on, or nil to use the address in its server file.
Set this when what you dial is not what the daemon believes it is, which
is the case behind a TLS proxy."
  :type '(choice (const :tag "From the server file" nil) string))

(defcustom revere-client-port nil
  "Port the daemon answers on, or nil to use the one in its server file."
  :type '(choice (const :tag "From the server file" nil) integer))

(defcustom revere-client-certificate nil
  "The certificate you present, as a list of the key file then the cert file."
  :type '(choice (const :tag "None" nil) (list file file)))

(defcustom revere-client-ca nil
  "File holding the authority that signed the daemon's certificate.
Nil trusts whatever `gnutls-trustfiles' already does, which will not
include an authority of your own making."
  :type '(choice (const :tag "System trust" nil) file))

(defcustom revere-client-timeout 30
  "Seconds to wait for the daemon to answer."
  :type 'integer)

(defun revere-client--server-file ()
  "The daemon's server file: its address on one line, its key on the next."
  (expand-file-name revere-client-server
                    (or revere-client-auth-dir server-auth-dir)))

(defun revere-client--credentials ()
  "Where to dial the daemon and what key to greet it with, as (HOST PORT KEY)."
  (let ((file (revere-client--server-file)))
    (unless (file-exists-p file)
      (error "No server file for %s at %s" revere-client-server file))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (let ((coding-system-for-read 'no-conversion))
        (insert-file-contents file))
      (goto-char (point-min))
      (unless (looking-at "\\([0-9.]+\\):\\([0-9]+\\)")
        (error "%s does not begin with an address" file))
      (let ((host (match-string 1))
            (port (string-to-number (match-string 2))))
        (forward-line 1)
        (list (or revere-client-host host)
              (or revere-client-port port)
              (buffer-substring-no-properties (point) (line-end-position)))))))

(defun revere-client--open (host port buffer)
  "Connect to the daemon at HOST and PORT, with output going to BUFFER."
  (if (not revere-client-tls)
      (make-network-process :name "revere-client" :buffer buffer
                            :host host :service port :family 'ipv4 :noquery t)
    (require 'gnutls)
    (require 'nsm)
    (let ((gnutls-trustfiles (if revere-client-ca
                                 (list (expand-file-name revere-client-ca))
                               gnutls-trustfiles))
          (gnutls-verify-error t)
          (nsm-noninteractive t))
      (open-network-stream
       "revere-client" buffer host port
       :type 'tls
       :noquery t
       :client-certificate (and revere-client-certificate
                                (mapcar #'expand-file-name revere-client-certificate))))))

(defun revere-client--answer ()
  "The daemon's reply, read from the current buffer."
  (goto-char (point-min))
  (when (re-search-forward "\\(?:\\`\\|\n\\)-error " nil t)
    (error "Revere daemon: %s"
           (server-unquote-arg
            (buffer-substring (point) (line-end-position)))))
  (goto-char (point-min))
  (let ((answer ""))
    (while (re-search-forward "\\(?:\\`\\|\n\\)-print\\(-nonl\\)? " nil t)
      (setq answer (concat answer (buffer-substring
                                   (point)
                                   (progn (skip-chars-forward "^\n") (point))))))
    (unless (equal answer "")
      (read (decode-coding-string (server-unquote-arg answer) 'emacs-internal)))))

(defun revere-client--eval-over-tls (form)
  "Evaluate FORM on the daemon over TLS, speaking the Emacs server protocol."
  (pcase-let ((`(,host ,port ,key) (revere-client--credentials)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (let* ((coding-system-for-read 'binary)
             (coding-system-for-write 'binary)
             (process (revere-client--open host port (current-buffer))))
        (unless process
          (error "Cannot reach the Revere daemon at %s:%s" host port))
        (unwind-protect
            (let ((deadline (+ (float-time) revere-client-timeout)))
              (process-send-string process (concat "-auth " key "\n"))
              (process-send-string
               process (concat "-eval " (server-quote-arg (format "%S" form)) " \n"))
              (while (and (memq (process-status process) '(open run connect))
                          (< (float-time) deadline))
                (accept-process-output process 0.05))
              (revere-client--answer))
          (when (process-live-p process) (delete-process process)))))))

(defun revere-client-eval (form)
  "Evaluate FORM on the daemon and return its value."
  (if revere-client-tls
      (revere-client--eval-over-tls form)
    (let ((server-auth-dir (or revere-client-auth-dir server-auth-dir)))
      (server-eval-at revere-client-server form))))

;;;###autoload
(defun revere-client-new (prompt)
  "Start a job for PROMPT on the daemon, working in the current project."
  (interactive "sRevere (daemon), job: ")
  (let* ((directory (let ((project (project-current)))
                      (if project (project-root project) default-directory)))
         (number (revere-client-eval
                  `(progn (require 'revere)
                          (revere-job-number (revere-new ,prompt ,(expand-file-name directory)))))))
    (message "Revere: job %s started on the daemon" number)))

;;;###autoload
(defun revere-client-status ()
  "List the daemon's jobs."
  (interactive)
  (let ((jobs (revere-client-eval
               '(progn (require 'revere)
                       (mapcar (lambda (job)
                                 (list (revere-job-number job)
                                       (revere-job-state-label job)
                                       (car (split-string (revere-job-prompt job) "\n"))))
                               revere-job-list)))))
    (with-help-window "*Revere daemon*"
      (if (null jobs)
          (princ "No jobs on the daemon.\n")
        (dolist (job jobs)
          (princ (format "%3d  %-20s %s\n" (nth 0 job) (nth 1 job) (nth 2 job))))))))

;;;###autoload
(defun revere-client-frame ()
  "Open a frame on the daemon."
  (interactive)
  (start-process "revere-client" nil
                 (if (eq system-type 'windows-nt) "emacsclientw" "emacsclient")
                 "-s" revere-client-server "-c"))

(provide 'revere-client)
;;; revere-client.el ends here
