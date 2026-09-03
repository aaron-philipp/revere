;;; revere-skills.el --- Skills: SKILL.md folders, loaded on demand -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A skill is a folder holding SKILL.md with YAML frontmatter (name,
;; description) and a Markdown body, the format Claude Code and Hermes
;; share, so published skills install with git clone.  The names and
;; descriptions go into every system prompt; the body is returned by the
;; `skill' tool when the model asks for it.  A skill.el beside SKILL.md is
;; loaded on first use and may define tools with `revere-deftool'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'revere-config)
(require 'revere-tools)
(require 'revere-loop)

(defcustom revere-skill-dirs (list (expand-file-name "skills" revere-directory))
  "Directories holding skill folders.  Revere's own skills folder is added."
  :type '(repeat directory)
  :group 'revere)

(defvar revere-skills--loaded nil
  "Skill directories whose skill.el has been loaded.")

(defconst revere-skills--bundled
  (expand-file-name "skills" (file-name-directory (or load-file-name buffer-file-name "")))
  "The skills folder shipped with Revere.")

;;;; Reading

(defun revere-skills--frontmatter (file)
  "The YAML frontmatter of FILE as an alist of symbols to strings."
  (with-temp-buffer
    (insert-file-contents file nil 0 4096)
    (goto-char (point-min))
    (when (looking-at "---[ \t]*\n")
      (let* ((start (match-end 0))
             (end (save-excursion (goto-char start)
                                  (and (re-search-forward "^---[ \t]*$" nil t) (match-beginning 0))))
             (fields nil))
        (when end
          (goto-char start)
          (while (re-search-forward "^\\([a-zA-Z_-]+\\):[ \t]*\\(.*\\)$" end t)
            (push (cons (intern (downcase (match-string 1)))
                        (string-trim (match-string 2) "[ \t\"']+" "[ \t\"']+"))
                  fields)))
        fields))))

(defun revere-skills--body (file)
  "The Markdown body of FILE, after its frontmatter."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (when (and (looking-at "---[ \t]*\n")
               (re-search-forward "^---[ \t]*$" nil t 2))
      (forward-line 1))
    (string-trim (buffer-substring-no-properties (point) (point-max)))))

(defun revere-skills-dirs ()
  "Every directory to look in, bundled first."
  (cl-remove-duplicates
   (cl-remove-if-not #'file-directory-p (cons revere-skills--bundled revere-skill-dirs))
   :test #'equal))

(defun revere-skills-index ()
  "Every skill as a plist (:name :description :dir :file), later dirs winning."
  (let ((skills nil))
    (dolist (dir (revere-skills-dirs))
      (dolist (file (file-expand-wildcards (expand-file-name "*/SKILL.md" dir)))
        (let* ((fields (revere-skills--frontmatter file))
               (name (or (alist-get 'name fields)
                         (file-name-nondirectory (directory-file-name (file-name-directory file))))))
          (setf (alist-get name skills nil nil #'equal)
                (list :name name
                      :description (or (alist-get 'description fields) "")
                      :dir (file-name-directory file)
                      :file file)))))
    (mapcar #'cdr (sort skills (lambda (a b) (string< (car a) (car b)))))))

(defun revere-skills-find (name)
  "The skill called NAME, or nil."
  (cl-find name (revere-skills-index) :key (lambda (s) (plist-get s :name)) :test #'equal))

(defun revere-skills-prompt (&optional _job)
  "The skills list for the system prompt, or nil when there are none."
  (let ((skills (revere-skills-index)))
    (when skills
      (concat "Skills you can load with the skill tool when they fit the job:\n"
              (mapconcat (lambda (skill)
                           (format "- %s: %s" (plist-get skill :name) (plist-get skill :description)))
                         skills "\n")))))

(add-hook 'revere-loop-system-prompt-functions #'revere-skills-prompt)

;;;; Loading

(defun revere-skills--load-elisp (skill)
  "Load SKILL's skill.el once, if it has one."
  (let ((file (expand-file-name "skill.el" (plist-get skill :dir))))
    (when (and (file-exists-p file) (not (member file revere-skills--loaded)))
      (push file revere-skills--loaded)
      (condition-case err
          (load file nil t)
        (error (message "Revere: skill %s: %s" (plist-get skill :name) (error-message-string err)))))))

(revere-deftool skill ((name string "Skill name, from the list in your instructions"))
  "Load a skill: its full instructions.
Scripts and references it mentions live in the folder it names."
  (let ((skill (revere-skills-find name)))
    (unless skill
      (error "No skill called %s" name))
    (revere-skills--load-elisp skill)
    (format "Skill %s, in %s:\n\n%s"
            name (plist-get skill :dir) (revere-skills--body (plist-get skill :file)))))

;;;; Commands

;;;###autoload
(defun revere-skills ()
  "List the skills Revere knows."
  (interactive)
  (let ((skills (revere-skills-index)))
    (with-help-window "*Revere skills*"
      (if (null skills)
          (princ (format "No skills yet.  M-x revere-skill-new writes one under %s\n"
                         (car revere-skill-dirs)))
        (dolist (skill skills)
          (princ (format "%-24s %s\n    %s\n" (plist-get skill :name)
                         (plist-get skill :description) (plist-get skill :dir))))))))

;;;###autoload
(defun revere-skill-new (name description)
  "Write a new skill NAME with DESCRIPTION and open it."
  (interactive "sSkill name: \nsOne-line description: ")
  (let* ((dir (file-name-as-directory (expand-file-name name (car revere-skill-dirs))))
         (file (expand-file-name "SKILL.md" dir)))
    (when (file-exists-p file)
      (user-error "There is already a skill called %s" name))
    (make-directory dir t)
    (with-temp-file file
      (insert (format "---\nname: %s\ndescription: %s\n---\n\n# %s\n\nWhen to use this skill, and the steps to follow.\n"
                      name description name)))
    (find-file file)))

(provide 'revere-skills)
;;; revere-skills.el ends here
