;;; revere-approve.el --- Approvals: check with me before running a tool -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; When a tool's rule is `check', the job parks in the `waiting' state and
;; an approval is created.  The chat shows it with Go ahead and No buttons,
;; the approvals list shows every pending one across jobs, and a desktop
;; notification goes out.  Deciding it resumes the job.
;;
;; This file installs itself as `revere-tools-check-function'.

;;; Code:

(require 'cl-lib)
(require 'tabulated-list)
(require 'revere-config)
(require 'revere-job)
(require 'revere-tools)

(declare-function w32-notification-notify "w32fns.c")
(declare-function notifications-notify "notifications")
(defvar display-line-numbers-type)

(cl-defstruct (revere-approval (:constructor revere-approval--make) (:copier nil))
  id job tool args
  (state 'pending)
  continue created decided)

(defvar revere-approvals nil
  "Approvals requested this session, newest first.")

(defvar revere-approval--counter 0
  "Number given to the next approval.")

(defvar revere-approval-hook nil
  "Run with the approval when one is requested or decided.")

;;;; Requesting and deciding

(defun revere-approve--short (text &optional width)
  "TEXT on one line, at most WIDTH columns."
  (truncate-string-to-width (replace-regexp-in-string "\n" " " (or text ""))
                            (or width 70) nil nil "…"))

(defun revere-approve-request (tool args-json continue)
  "Ask the user whether TOOL may run with ARGS-JSON; call CONTINUE with the answer.
Installed as `revere-tools-check-function'."
  (let* ((job (revere-tools-job))
         (approval (revere-approval--make
                    :id (cl-incf revere-approval--counter)
                    :job job :tool tool :args args-json
                    :continue continue :created (float-time))))
    (push approval revere-approvals)
    (revere-job-set-state job 'waiting
                          (format "needs your OK to run %s" (revere-tool-name tool)))
    (revere-job-notify job 'approval :approval approval)
    (run-hook-with-args 'revere-approval-hook approval)
    (revere-notify (format "Revere job %d needs your OK" (revere-job-number job))
                   (format "%s %s" (revere-tool-name tool) (revere-approve--short args-json)))
    approval))

(defun revere-approve-decide (approval granted)
  "Settle APPROVAL: run its tool if GRANTED, else decline it."
  (when (eq (revere-approval-state approval) 'pending)
    (let ((job (revere-approval-job approval))
          (interrupted (not (eq (revere-job-state (revere-approval-job approval)) 'waiting))))
      (setf (revere-approval-state approval) (if (and granted (not interrupted)) 'granted 'denied))
      (setf (revere-approval-decided approval) (float-time))
      (unless interrupted
        (revere-job-set-state job 'working
                              (if granted
                                  (format "running %s" (revere-tool-name (revere-approval-tool approval)))
                                "declined")))
      (revere-job-notify job 'approval :approval approval)
      (run-hook-with-args 'revere-approval-hook approval)
      (let ((revere-current-job job))
        (funcall (revere-approval-continue approval) (and granted (not interrupted)))))))

(defun revere-approve-pending (&optional job)
  "Pending approvals, oldest first; only JOB's if given."
  (cl-remove-if-not (lambda (approval)
                      (and (eq (revere-approval-state approval) 'pending)
                           (or (null job) (eq (revere-approval-job approval) job))))
                    (reverse revere-approvals)))

(defun revere-approve-description (approval)
  "One line saying what APPROVAL is for."
  (format "%s %s"
          (revere-tool-name (revere-approval-tool approval))
          (revere-approve--short (revere-approval-args approval))))

;;;; Notifications

(defun revere-notify (title body)
  "Tell the user TITLE and BODY outside Emacs if possible, and in the echo area."
  (cond
   ((and (eq system-type 'windows-nt) (fboundp 'w32-notification-notify))
    (ignore-errors (w32-notification-notify :title title :body body)))
   ((and (featurep 'dbusbind) (require 'notifications nil t))
    (ignore-errors (notifications-notify :title title :body body))))
  (message "%s: %s" title body))

;;;; The approvals list

(defvar revere-approvals-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "y") #'revere-approvals-go-ahead)
    (define-key map (kbd "n") #'revere-approvals-no)
    (define-key map (kbd "RET") #'revere-approvals-chat)
    (define-key map (kbd "g") #'revere-approvals-refresh)
    map)
  "Keymap for `revere-approvals-mode'.")

(define-derived-mode revere-approvals-mode tabulated-list-mode "Revere-Approvals"
  "Every pending approval.  y goes ahead, n declines, RET opens the job."
  (setq tabulated-list-format [("Job" 5 t) ("Tool" 8 t) ("Request" 60 nil) ("Age" 8 nil)])
  (setq tabulated-list-padding 1)
  (setq-local display-line-numbers-type nil)
  (setq-local display-line-numbers nil)
  (setq mode-line-process "  y go ahead · n no · RET chat · g refresh")
  (tabulated-list-init-header))

(defun revere-approvals--age (approval)
  "How long APPROVAL has waited."
  (let ((seconds (round (- (float-time) (revere-approval-created approval)))))
    (cond ((< seconds 60) (format "%ds" seconds))
          ((< seconds 3600) (format "%dm" (/ seconds 60)))
          (t (format "%dh" (/ seconds 3600))))))

(defun revere-approvals--entries ()
  "Rows for `tabulated-list-entries'."
  (mapcar (lambda (approval)
            (list approval
                  (vector (number-to-string (revere-job-number (revere-approval-job approval)))
                          (revere-tool-name (revere-approval-tool approval))
                          (revere-approve--short (revere-approval-args approval) 60)
                          (revere-approvals--age approval))))
          (revere-approve-pending)))

(defun revere-approvals-refresh ()
  "Redraw the approvals list."
  (interactive)
  (setq tabulated-list-entries (revere-approvals--entries))
  (tabulated-list-print t))

;;;###autoload
(defun revere-approvals ()
  "Show everything waiting for your OK."
  (interactive)
  (let ((buffer (get-buffer-create "*Revere: approvals*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'revere-approvals-mode)
        (revere-approvals-mode))
      (revere-approvals-refresh))
    (pop-to-buffer buffer)))

(defun revere-approvals--at-point ()
  "The approval on this row, or signal a user error."
  (or (tabulated-list-get-id) (user-error "No approval here")))

(defun revere-approvals-go-ahead ()
  "Let the tool on this row run."
  (interactive)
  (revere-approve-decide (revere-approvals--at-point) t)
  (revere-approvals-refresh))

(defun revere-approvals-no ()
  "Decline the tool on this row."
  (interactive)
  (revere-approve-decide (revere-approvals--at-point) nil)
  (revere-approvals-refresh))

(defun revere-approvals-chat ()
  "Open the chat of the job on this row."
  (interactive)
  (let ((job (revere-approval-job (revere-approvals--at-point))))
    (require 'revere-chat)
    (revere-chat-show (revere-chat-buffer job))))

(declare-function revere-chat-buffer "revere-chat")
(declare-function revere-chat-show "revere-chat")

(defun revere-approvals--on-change (_approval)
  "Keep the list current."
  (let ((buffer (get-buffer "*Revere: approvals*")))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (revere-approvals-refresh)))))

(add-hook 'revere-approval-hook #'revere-approvals--on-change)

(setq revere-tools-check-function #'revere-approve-request)

(provide 'revere-approve)
;;; revere-approve.el ends here
