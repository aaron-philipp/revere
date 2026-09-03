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

(defun revere-client-eval (form)
  "Evaluate FORM on the daemon and return its value."
  (let ((server-auth-dir (or revere-client-auth-dir server-auth-dir)))
    (server-eval-at revere-client-server form)))

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
