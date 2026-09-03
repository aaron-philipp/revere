;;; revere-changes.el --- The changes buffer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; One `diff-mode' buffer holding the disk-versus-buffer diff of every file
;; a job has changed.  `diff-mode' already gives navigation and hunk
;; application; this file adds keep and discard at hunk, file and job
;; granularity.  Discarding a hunk applies it in reverse to the live buffer,
;; so the view stays truthful without bookkeeping.

;;; Code:

(require 'diff-mode)
(require 'revere-ws)
(require 'revere-worktree)

(defvar display-line-numbers-type)

(defvar-local revere-changes--job nil
  "The job this changes buffer shows.")

(defface revere-changes-file
  '((t :inherit diff-file-header :weight bold))
  "Face for the file line above each diff."
  :group 'revere)

(defface revere-changes-added
  '((t :inherit diff-indicator-added))
  "Face for the added count in a file line."
  :group 'revere)

(defface revere-changes-removed
  '((t :inherit diff-indicator-removed))
  "Face for the removed count in a file line."
  :group 'revere)

(defvar revere-changes-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map diff-mode-shared-map)
    (define-key map (kbd "k") #'revere-changes-discard-hunk)
    (define-key map (kbd "a") #'revere-changes-keep-hunk)
    (define-key map (kbd "K") #'revere-changes-discard-file)
    (define-key map (kbd "A") #'revere-changes-keep-file)
    (define-key map (kbd "e") #'revere-changes-ediff)
    (define-key map (kbd "g") #'revere-changes-refresh)
    (define-key map (kbd "C-c C-c") #'revere-changes-keep-all)
    (define-key map (kbd "C-c C-k") #'revere-changes-discard-all)
    map)
  "Keymap for `revere-changes-mode'.")

(define-derived-mode revere-changes-mode diff-mode "Revere-Changes"
  "Review a job's changes.
\\<revere-changes-mode-map>\\[revere-changes-discard-hunk] discards the hunk at point, \
\\[revere-changes-keep-all] keeps everything."
  (setq buffer-read-only t)
  (setq-local display-line-numbers-type nil)
  (setq-local display-line-numbers nil)
  (setq-local header-line-format
              (substitute-command-keys
               " Revere changes   \\[revere-changes-discard-hunk] discard hunk · \\[revere-changes-keep-hunk] next · \\[revere-changes-discard-file]/\\[revere-changes-keep-file] file · \\[revere-changes-ediff] ediff · RET source · \\[revere-changes-keep-all] keep all · \\[revere-changes-discard-all] discard all · q close"))
  (setq-local diff-advance-after-apply-hunk nil)
  (setq-local diff-update-on-the-fly nil)
  ;; diff-mode installs diff-mode-shared-map over the major mode map in
  ;; read-only buffers; keep that trick but with our map.
  (setq minor-mode-overriding-map-alist
        (cons (cons 'buffer-read-only revere-changes-mode-map)
              (assq-delete-all 'buffer-read-only minor-mode-overriding-map-alist))))

;;;; Buffer

(defun revere-changes-buffer (job)
  "Return the changes buffer for JOB, creating it if needed."
  (let* ((name (format "*Revere: changes %d*" (revere-job-number job)))
         (buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'revere-changes-mode)
        (revere-changes-mode))
      (setq revere-changes--job job)
      (setq default-directory (revere-job-root job)))
    buffer))

(defun revere-changes-show (job)
  "Display the changes buffer for JOB."
  (let ((buffer (revere-changes-buffer job)))
    (revere-changes-render buffer)
    (pop-to-buffer buffer)))

(defun revere-changes-render (buffer)
  "Rebuild BUFFER from its job's pending changes, keeping point where it was."
  (with-current-buffer buffer
    (let ((inhibit-read-only t)
          (job revere-changes--job)
          (where (revere-changes--position)))
      (erase-buffer)
      (if (eq (revere-job-mode job) 'worktree)
          (revere-changes--insert-branch job)
        (let ((entries (revere-ws-pending job)))
          (when entries
            (revere-changes--insert-buttons)
            (dolist (entry entries)
              (revere-changes--insert-entry job entry)))))
      (when (= (point-min) (point-max))
        (insert (propertize "No changes pending.\n" 'font-lock-face 'font-lock-comment-face)))
      (set-buffer-modified-p nil)
      (revere-changes--restore-position where))))

(defun revere-changes--insert-buttons ()
  "Insert the Keep all and Discard all buttons."
  (insert-text-button "Keep all" 'action (lambda (_) (revere-changes-keep-all))
                      'follow-link t)
  (insert "   ")
  (insert-text-button "Discard all" 'action (lambda (_) (revere-changes-discard-all))
                      'follow-link t)
  (insert "\n\n"))

(defun revere-changes--insert-branch (job)
  "Insert the diff of JOB's worktree branch against its base."
  (let ((diff (and (revere-job-worktree job)
                   (file-directory-p (revere-job-worktree job))
                   (ignore-errors (revere-worktree-diff job)))))
    (when (and diff (not (string-empty-p diff)))
      (revere-changes--insert-buttons)
      (insert (propertize (format "Branch %s against %s.  Keep all merges it; Discard all drops it.\n\n"
                                  (revere-job-branch job)
                                  (substring (revere-job-base job) 0 (min 8 (length (revere-job-base job)))))
                          'font-lock-face 'font-lock-comment-face))
      (setq default-directory (revere-job-worktree job))
      (insert diff "\n"))))

(defun revere-changes--buffers-only ()
  "Signal a user error in a worktree job, where hunks cannot be picked."
  (when (eq (revere-job-mode revere-changes--job) 'worktree)
    (user-error "This job works on a branch; keep or discard it as a whole")))

(defun revere-changes--insert-entry (job entry)
  "Insert the file line and diff for ENTRY of JOB at point."
  (let ((diff (revere-ws-diff entry)))
    (when diff
      (let ((start (point))
            (stat (revere-ws--count-diff diff)))
        (insert (propertize (revere-ws-relative job entry) 'font-lock-face 'revere-changes-file)
                "  "
                (propertize (format "+%d" (car stat)) 'font-lock-face 'revere-changes-added)
                " "
                (propertize (format "-%d" (cdr stat)) 'font-lock-face 'revere-changes-removed)
                (if (revere-change-created-p entry) "  (new file)" "")
                "\n")
        (insert diff)
        (unless (bolp) (insert "\n"))
        (insert "\n")
        (put-text-property start (point) 'revere-entry entry)))))

;;;; Point bookkeeping across renders

(defun revere-changes--position ()
  "Return (FILE . HUNK-INDEX) for point, or nil."
  (let ((entry (get-text-property (point) 'revere-entry)))
    (when entry
      (let ((section-start (or (previous-single-property-change (point) 'revere-entry) (point-min)))
            (count 0))
        (save-excursion
          (let ((limit (point)))
            (goto-char section-start)
            (while (re-search-forward "^@@" limit t)
              (cl-incf count))))
        (cons (revere-change-file entry) count)))))

(defun revere-changes--restore-position (where)
  "Move point to the hunk described by WHERE, from `revere-changes--position'."
  (goto-char (point-min))
  (when where
    (let ((pos (revere-changes--find-section (car where))))
      (when pos
        (goto-char pos)
        (let ((n (cdr where)))
          (while (and (> n 0) (re-search-forward "^@@" nil t))
            (cl-decf n)))
        (when (> (cdr where) 0)
          (beginning-of-line))))))

(defun revere-changes--find-section (file)
  "Return the position where FILE's section starts, or nil."
  (let ((pos (point-min)) (found nil))
    (while (and pos (not found))
      (let ((entry (get-text-property pos 'revere-entry)))
        (if (and entry (revere-ws--same-file-p (revere-change-file entry) file))
            (setq found pos)
          (setq pos (next-single-property-change pos 'revere-entry)))))
    found))

;;;; Commands

(defun revere-changes--entry ()
  "The change entry at point, or signal a user error."
  (or (get-text-property (point) 'revere-entry)
      (user-error "No change at point")))

(defun revere-changes--in-hunk-p ()
  "Non-nil if point is inside a hunk."
  (save-excursion
    (condition-case nil
        (progn (diff-beginning-of-hunk t) t)
      (error nil))))

(defun revere-changes-discard-hunk ()
  "Undo the hunk at point in the live buffer and redraw."
  (interactive)
  (revere-changes--buffers-only)
  (let ((entry (revere-changes--entry)))
    (cond
     ((revere-change-created-p entry)
      (revere-changes-discard-file))
     ((not (revere-changes--in-hunk-p))
      (user-error "Move to a hunk first"))
     (t
      (let ((inhibit-read-only t))
        (diff-apply-hunk t))
      (revere-changes-render (current-buffer))
      (message "Hunk discarded")))))

(defun revere-changes-keep-hunk ()
  "Leave the hunk at point as it is and move to the next one."
  (interactive)
  (revere-changes--entry)
  (condition-case nil
      (diff-hunk-next)
    (error (message "Last hunk; C-c C-c keeps everything"))))

(defun revere-changes-discard-file ()
  "Undo every change to the file at point."
  (interactive)
  (revere-changes--buffers-only)
  (let ((entry (revere-changes--entry)))
    (revere-ws-discard-file revere-changes--job entry)
    (revere-changes-render (current-buffer))
    (message "Discarded %s" (revere-ws-relative revere-changes--job entry))))

(defun revere-changes-keep-file ()
  "Save the file at point."
  (interactive)
  (revere-changes--buffers-only)
  (let ((entry (revere-changes--entry)))
    (revere-ws-keep-file revere-changes--job entry)
    (revere-changes-render (current-buffer))
    (message "Kept %s" (revere-ws-relative revere-changes--job entry))))

(defun revere-changes-ediff ()
  "Compare the file at point with its buffer side by side."
  (interactive)
  (let* ((entry (revere-changes--entry))
         (buffer (revere-change-buffer entry)))
    (when (revere-change-created-p entry)
      (user-error "New file; nothing on disk to compare with"))
    (pop-to-buffer buffer)
    (ediff-current-file)))

(defun revere-changes-refresh ()
  "Redraw the changes buffer."
  (interactive)
  (revere-changes-render (current-buffer))
  (message "Changes refreshed"))

(defun revere-changes-keep-all ()
  "Save every pending change of this job, or merge its branch."
  (interactive)
  (let ((job revere-changes--job))
    (if (eq (revere-job-mode job) 'worktree)
        (progn
          (revere-worktree-keep job)
          (revere-changes-render (current-buffer))
          (message "Merged %s into the project" (revere-job-branch job)))
      (let ((n (revere-ws-keep-all job)))
        (revere-changes--settle job 'done)
        (revere-changes-render (current-buffer))
        (message "Kept %d file%s" n (if (= n 1) "" "s"))))))

(defun revere-changes-discard-all ()
  "Undo every pending change of this job, or drop its branch."
  (interactive)
  (let ((job revere-changes--job))
    (if (eq (revere-job-mode job) 'worktree)
        (progn
          (revere-worktree-discard job)
          (revere-changes-render (current-buffer))
          (message "Dropped %s" (revere-job-branch job)))
      (let ((n (revere-ws-discard-all job)))
        (revere-changes--settle job 'discarded)
        (revere-changes-render (current-buffer))
        (message "Discarded %d file%s" n (if (= n 1) "" "s"))))))

(defun revere-changes--settle (job state)
  "Move JOB to STATE if it is only waiting on review."
  (when (eq (revere-job-state job) 'review)
    (revere-job-set-state job state)))

(provide 'revere-changes)
;;; revere-changes.el ends here
