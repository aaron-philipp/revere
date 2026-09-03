;;; revere-prompt.el --- The system prompt: yours, the project's, and the facts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; The system message a job starts with is assembled from, in order:
;;
;;   1. Standing instructions: ~/.revere/prompt.md if it exists, else
;;      `revere-system-prompt'.  Edit the file to change how Revere works
;;      and who it is.
;;   2. Project instructions: the first of AGENTS.md, CLAUDE.md, .revere.md
;;      or REVERE.md found in the job's directory or a parent, the same
;;      files other assistants read.
;;   3. The environment: directory, platform, Emacs version, date, git.
;;   4. Whatever `revere-loop-system-prompt-functions' adds: skills, memory.
;;
;; `revere-show-prompt' (or /prompt in the chat) shows the result.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'revere-config)
(require 'revere-job)
(require 'revere-loop)

(defcustom revere-project-instruction-files
  '("AGENTS.md" "CLAUDE.md" ".revere.md" "REVERE.md")
  "Files, in order of preference, that hold a project's standing instructions."
  :type '(repeat string)
  :group 'revere)

(defcustom revere-project-instructions-limit 12000
  "Most characters of a project instruction file to include."
  :type 'integer
  :group 'revere)

(defun revere-prompt-file ()
  "Path of the editable standing instructions."
  (expand-file-name "prompt.md" (revere-config-directory)))

(defun revere-prompt-standing (&optional job)
  "The standing instructions for JOB.
Its own if it has any, else the prompt file, else the default."
  (let ((file (revere-prompt-file))
        (own (and job (revere-job-instructions job))))
    (cond
     ((and own (not (string-empty-p (string-trim own)))) (string-trim own))
     ((file-readable-p file)
      (let ((text (with-temp-buffer
                    (insert-file-contents file)
                    (string-trim (buffer-string)))))
        (if (string-empty-p text) revere-system-prompt text)))
     (t revere-system-prompt))))

(defun revere-prompt-project-file (directory)
  "The project instruction file for DIRECTORY, searching upward, or nil."
  (let ((dir (file-name-as-directory (expand-file-name directory)))
        (found nil))
    (while (and dir (not found))
      (setq found (cl-some (lambda (name)
                             (let ((file (expand-file-name name dir)))
                               (and (file-readable-p file) file)))
                           revere-project-instruction-files))
      (let ((parent (file-name-directory (directory-file-name dir))))
        (setq dir (and parent (not (equal parent dir)) parent))))
    found))

(defun revere-prompt-project (job)
  "The project instructions for JOB's root, or nil."
  (let ((file (and job (revere-prompt-project-file (revere-job-root job)))))
    (when file
      (let ((text (with-temp-buffer
                    (insert-file-contents file)
                    (string-trim (buffer-string)))))
        (unless (string-empty-p text)
          (format "Project instructions, from %s:\n%s"
                  (file-name-nondirectory file)
                  (truncate-string-to-width text revere-project-instructions-limit nil nil "…")))))))

(defun revere-prompt-environment (job)
  "Facts about where JOB runs."
  (let ((directory (if job (revere-job-directory job) default-directory)))
    (concat "Environment:\n"
            (format "- working directory: %s\n" (abbreviate-file-name directory))
            (format "- platform: %s, Emacs %s\n" system-type emacs-version)
            (format "- date: %s\n" (format-time-string "%Y-%m-%d %A"))
            (format "- git repository: %s"
                    (if (locate-dominating-file directory ".git") "yes" "no")))))

(defun revere-prompt-assemble (&optional job)
  "The full system message for JOB."
  (string-join
   (delq nil
         (append (list (revere-prompt-standing job)
                       (revere-prompt-project job)
                       (revere-prompt-environment job))
                 (mapcar (lambda (fn)
                           (condition-case nil (funcall fn job) (error nil)))
                         revere-loop-system-prompt-functions)))
   "\n\n"))

;;;###autoload
(defun revere-show-prompt (&optional job)
  "Show the system message a job in this directory would start with."
  (interactive)
  (with-help-window "*Revere prompt*"
    (princ (revere-prompt-assemble job))))

;;;###autoload
(defun revere-edit-prompt ()
  "Edit the standing instructions; created from the default if missing."
  (interactive)
  (let ((file (revere-prompt-file)))
    (unless (file-exists-p file)
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (insert revere-system-prompt "\n")))
    (find-file file)))

(setq revere-loop-system-prompt-function #'revere-prompt-assemble)

(provide 'revere-prompt)
;;; revere-prompt.el ends here
