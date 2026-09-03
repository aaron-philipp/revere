;;; revere-review.el --- Review changes inside the source buffer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License or (at your option)
;; any later version.

;;; Commentary:

;; A minor mode that turns on in every buffer a job has changed.  Added
;; lines are highlighted, removed lines are shown in place, the header line
;; says how many hunks there are and what the keys do, and a hunk can be
;; discarded, or the file kept or discarded, without leaving the buffer.
;; This is the in-editor half of review; the changes buffer is the other.

;;; Code:

(require 'cl-lib)
(require 'diff-mode)
(require 'revere-job)
(require 'revere-ws)

(defface revere-review-added
  '((t :inherit diff-refine-added :extend t))
  "Lines Revere added."
  :group 'revere)

(defface revere-review-removed
  '((t :inherit diff-refine-removed :extend t))
  "Lines Revere removed, shown in place."
  :group 'revere)

(defvar-local revere-review--job nil
  "The job whose changes this buffer shows.")

(defvar-local revere-review--hunks nil
  "Parsed hunks for the current overlays.")

(defvar-local revere-review--tick nil
  "Buffer tick the overlays were built for.")

(defvar-local revere-review--overlays nil
  "Overlays this mode owns.")

(defvar revere-review-mode-map
  (let ((map (make-sparse-keymap))
        (prefix (make-sparse-keymap)))
    (define-key prefix (kbd "n") #'revere-review-next-hunk)
    (define-key prefix (kbd "p") #'revere-review-previous-hunk)
    (define-key prefix (kbd "k") #'revere-review-discard-hunk)
    (define-key prefix (kbd "K") #'revere-review-discard-file)
    (define-key prefix (kbd "A") #'revere-review-keep-file)
    (define-key prefix (kbd "d") #'revere-review-diff)
    (define-key prefix (kbd "e") #'revere-review-ediff)
    (define-key prefix (kbd "c") #'revere-review-chat)
    (define-key map (kbd "C-c r") prefix)
    map)
  "Keymap for `revere-review-mode', under the C-c r prefix.")

;;;###autoload
(define-minor-mode revere-review-mode
  "Revere changed this buffer; review the changes here.
\\{revere-review-mode-map}"
  :lighter " Revere"
  :keymap revere-review-mode-map
  (if revere-review-mode
      (progn
        (setq-local header-line-format '(:eval (revere-review--header)))
        (revere-review-refresh))
    (revere-review--clear)
    (kill-local-variable 'header-line-format)))

(defun revere-review--header ()
  "Header line text."
  (concat (propertize " Revere changed this file" 'face 'font-lock-keyword-face)
          (format "  %d hunk%s   " (length revere-review--hunks)
                  (if (= (length revere-review--hunks) 1) "" "s"))
          (propertize "C-c r  n/p move · k discard hunk · A keep file · K discard file · d diff · e ediff · c chat"
                      'face 'font-lock-comment-face)))

;;;; Sync with the job

(defun revere-review-sync (job)
  "Turn the mode on in JOB's changed buffers and off where nothing is pending."
  (dolist (entry (revere-ws-changes job))
    (let ((buffer (revere-change-buffer entry)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (cond
           ((revere-ws-changed-p entry)
            (setq revere-review--job job)
            (if revere-review-mode
                (revere-review-refresh)
              (revere-review-mode 1)))
           (revere-review-mode
            (revere-review-mode -1))))))))

(defun revere-review--entry ()
  "This buffer's change entry, or signal a user error."
  (or (and revere-review--job (revere-ws-entry-for-buffer revere-review--job (current-buffer)))
      (user-error "Revere has no changes in this buffer")))

(defun revere-review-refresh ()
  "Rebuild the overlays if the buffer changed since they were built."
  (let ((tick (buffer-chars-modified-tick))
        (entry (and revere-review--job
                    (revere-ws-entry-for-buffer revere-review--job (current-buffer)))))
    (unless (eql tick revere-review--tick)
      (setq revere-review--tick tick)
      (revere-review--clear)
      (when entry
        (setq revere-review--hunks (revere-review-parse (or (revere-ws-diff entry) "")))
        (revere-review--draw)))
    (force-mode-line-update)))

;;;; Diff parsing

(defun revere-review-parse (diff)
  "Parse unified DIFF text into hunks.
Each hunk is a plist with :index, :start and :end (lines in this buffer),
:added (line numbers) and :removed ((LINE . TEXT) shown before LINE)."
  (let ((hunks nil) (index 0))
    (with-temp-buffer
      (insert diff)
      (goto-char (point-min))
      (while (re-search-forward
              "^@@ -[0-9]+\\(?:,[0-9]+\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@" nil t)
        (let ((line (string-to-number (match-string 1)))
              (count (and (match-string 2) (string-to-number (match-string 2))))
              (added nil) (removed nil) (first nil) (last nil))
          (when (eql count 0) (cl-incf line))
          (forward-line 1)
          (while (and (not (eobp)) (not (looking-at "^\\(?:@@\\|--- \\|\\+\\+\\+ \\)")))
            (pcase (char-after)
              (?+ (push line added)
                  (setq first (or first line) last line)
                  (cl-incf line))
              (?- (push (cons line (buffer-substring-no-properties
                                    (1+ (point)) (line-end-position)))
                        removed)
                  (setq first (or first line) last (max (or last line) line)))
              (?\\ nil)
              (_ (cl-incf line)))
            (forward-line 1))
          (push (list :index index :start (or first line) :end (or last line)
                      :added (nreverse added) :removed (nreverse removed))
                hunks)
          (cl-incf index))))
    (nreverse hunks)))

;;;; Overlays

(defun revere-review--line-start (line)
  "Position where LINE begins, or `point-max' past the end."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line))
    (point)))

(defun revere-review--draw ()
  "Create overlays for `revere-review--hunks'."
  (dolist (hunk revere-review--hunks)
    (dolist (line (plist-get hunk :added))
      (let* ((start (revere-review--line-start line))
             (end (min (point-max) (revere-review--line-start (1+ line))))
             (overlay (make-overlay start end)))
        (overlay-put overlay 'face 'revere-review-added)
        (overlay-put overlay 'revere-review t)
        (push overlay revere-review--overlays)))
    (let ((groups nil))
      (dolist (removed (plist-get hunk :removed))
        (let ((group (assq (car removed) groups)))
          (if group
              (setcdr group (append (cdr group) (list (cdr removed))))
            (push (list (car removed) (cdr removed)) groups))))
      (dolist (group groups)
        (let* ((start (revere-review--line-start (car group)))
               (overlay (make-overlay start start)))
          (overlay-put overlay 'before-string
                       (propertize (concat (string-join (cdr group) "\n") "\n")
                                   'face 'revere-review-removed))
          (overlay-put overlay 'revere-review t)
          (push overlay revere-review--overlays))))))

(defun revere-review--clear ()
  "Remove this buffer's review overlays."
  (mapc #'delete-overlay revere-review--overlays)
  (setq revere-review--overlays nil)
  (setq revere-review--hunks nil))

;;;; Commands

(defun revere-review--hunk-at (line)
  "The hunk covering LINE, or nil."
  (cl-find-if (lambda (hunk) (<= (plist-get hunk :start) line (plist-get hunk :end)))
              revere-review--hunks))

(defun revere-review-next-hunk ()
  "Move to the next hunk."
  (interactive)
  (let* ((line (line-number-at-pos))
         (hunk (cl-find-if (lambda (h) (> (plist-get h :start) line)) revere-review--hunks)))
    (if hunk
        (goto-char (revere-review--line-start (plist-get hunk :start)))
      (message "No more hunks"))))

(defun revere-review-previous-hunk ()
  "Move to the previous hunk."
  (interactive)
  (let* ((line (line-number-at-pos))
         (hunk (cl-find-if (lambda (h) (< (plist-get h :start) line))
                           (reverse revere-review--hunks))))
    (if hunk
        (goto-char (revere-review--line-start (plist-get hunk :start)))
      (message "No earlier hunks"))))

(defun revere-review-discard-hunk ()
  "Put the hunk at point back the way it was on disk."
  (interactive)
  (let* ((entry (revere-review--entry))
         (hunk (or (revere-review--hunk-at (line-number-at-pos))
                   (user-error "No hunk here; C-c r n moves to the next one"))))
    (revere-review--apply-reverse entry hunk)
    (revere-review-refresh)
    (revere-job-changed revere-review--job)
    (message "Hunk discarded")))

(defun revere-review--apply-reverse (entry hunk)
  "Apply HUNK of ENTRY's diff in reverse to this buffer."
  (let ((diff (or (revere-ws-diff entry) (user-error "Nothing to discard"))))
    (with-temp-buffer
      (insert diff)
      (diff-mode)
      (goto-char (point-min))
      (dotimes (_ (1+ (plist-get hunk :index)))
        (re-search-forward "^@@" nil t))
      (forward-line 1)
      (diff-apply-hunk t))))

(defun revere-review-keep-file ()
  "Save this file: its changes are kept."
  (interactive)
  (let ((entry (revere-review--entry)))
    (revere-ws-keep-file revere-review--job entry)
    (revere-review-mode -1)
    (message "Kept %s" (buffer-name))))

(defun revere-review-discard-file ()
  "Put this whole file back the way it was on disk."
  (interactive)
  (let ((entry (revere-review--entry)))
    (revere-ws-discard-file revere-review--job entry)
    (when revere-review-mode (revere-review-mode -1))
    (message "Discarded changes to %s" (buffer-name))))

(defun revere-review-diff ()
  "Open the changes buffer at this file."
  (interactive)
  (revere-review--entry)
  (let ((job revere-review--job)
        (file (buffer-file-name)))
    (require 'revere-changes)
    (revere-changes-show job)
    (with-current-buffer (revere-changes-buffer job)
      (let ((pos (revere-changes--find-section file)))
        (when pos (goto-char pos))))))

(defun revere-review-ediff ()
  "Compare this buffer with the file on disk."
  (interactive)
  (revere-review--entry)
  (ediff-current-file))

(defun revere-review-chat ()
  "Go to this job's chat."
  (interactive)
  (let ((buffer (and revere-review--job (revere-job-buffer revere-review--job))))
    (if (buffer-live-p buffer)
        (revere-chat-show buffer)
      (user-error "The chat for this job is gone"))))

(declare-function revere-chat-show "revere-chat")

(provide 'revere-review)
;;; revere-review.el ends here
