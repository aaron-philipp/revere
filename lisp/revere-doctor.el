;;; revere-doctor.el --- Check that everything Revere needs is there -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; `revere-doctor' reports on the endpoint, the programs on the path, the
;; optional packages, the token for Discord, and the files under
;; `revere-directory', each with a tick or a cross and what to do about it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'revere-config)
(require 'revere-llm)
(require 'revere-models)

(declare-function revere-discord-token "revere-chan-discord")

(defun revere-doctor--line (ok text)
  "A report line: OK's tick or cross, then TEXT."
  (format "%s %s\n" (if ok "✓" "✗") text))

(defun revere-doctor--endpoint ()
  "Check the model endpoint synchronously.  Return (OK . TEXT)."
  (let ((url (concat (revere-llm-root) "/v1/models"))
        (key (revere-llm-key)))
    (with-temp-buffer
      (let ((status (apply #'call-process "curl" nil t nil
                           (append (list "-sS" "--max-time" "5" "-o" "-" "-w" "\n%{http_code}")
                                   (when key (list "-H" (format "Authorization: Bearer %s" key)))
                                   (list url)))))
        (goto-char (point-max))
        (let ((code (string-trim (buffer-substring-no-properties (line-beginning-position) (point-max)))))
          (cond
           ((/= status 0)
            (cons nil (format "endpoint %s not reachable (curl exit %d)" (revere-llm-root) status)))
           ((string-prefix-p "2" code)
            (let ((models (condition-case nil
                              (length (gethash "data" (revere-llm--parse
                                                       (buffer-substring-no-properties (point-min) (line-beginning-position)))))
                            (error nil))))
              (cons t (format "endpoint %s answers%s" (revere-llm-root)
                              (if models (format " with %d models" models) "")))))
           (t (cons nil (format "endpoint %s returned HTTP %s%s" (revere-llm-root) code
                                (if (equal code "401") "; check the key" ""))))))))))

;;;###autoload
(defun revere-doctor ()
  "Check what Revere needs and report."
  (interactive)
  (let ((endpoint (condition-case err
                      (revere-doctor--endpoint)
                    (error (cons nil (format "endpoint check failed: %s" (error-message-string err))))))
        (context (revere-models-context-limit revere-model)))
    (with-help-window "*Revere doctor*"
      (princ (format "Revere doctor, %s\n\n" (format-time-string "%Y-%m-%d %H:%M")))
      (princ (revere-doctor--line (car endpoint) (cdr endpoint)))
      (princ (revere-doctor--line t (format "model %s%s" revere-model
                                            (if context (format ", context %d tokens" context)
                                              ", context window unknown (set revere-context-limits)"))))
      (dolist (program '(("curl" . "the model transport") ("diff" . "the review")
                         ("git" . "worktrees and unattended jobs") ("rg" . "faster grep; optional")))
        (princ (revere-doctor--line (executable-find (car program))
                                    (format "%s on the path: %s" (car program) (cdr program)))))
      (princ (revere-doctor--line (featurep 'websocket) "websocket package, for Discord"))
      (princ (revere-doctor--line (and (fboundp 'revere-discord-token)
                                       (ignore-errors (revere-discord-token)))
                                  "Discord token in auth-source (machine discord.com login revere-bot)"))
      (princ (revere-doctor--line (featurep 'treemacs) "treemacs, for badges in the tree; optional"))
      (princ (revere-doctor--line (file-directory-p (expand-file-name revere-directory))
                                  (format "%s exists" (abbreviate-file-name revere-directory))))
      (dolist (file '("logbook.org" "routines.org" "check-in.org" "board.org" "prompt.md"))
        (princ (revere-doctor--line (file-exists-p (expand-file-name file revere-directory))
                                    (format "%s (created on first use)" file))))
      (princ (revere-doctor--line (and (boundp 'trusted-content) trusted-content)
                                  "trusted-content set, so the byte-compile checker runs on your files"))
      (princ (format "\nEmacs %s on %s\n" emacs-version system-type)))))

(provide 'revere-doctor)
;;; revere-doctor.el ends here
