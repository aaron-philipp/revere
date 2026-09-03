;;; revere-board.el --- The board: cards that workers pick up -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; ~/.revere/board.org is a kanban board in Org: one heading per card, its
;; todo keyword the column.  A worker is a routine of kind `board' with a
;; WORKER name; on its schedule it takes the first TODO card whose FOR
;; property names it or is empty, claims it, and runs it as a job on a
;; branch.  The card follows the job: DOING while it works, REVIEW when it
;; stops with changes, DONE when they are kept, DROPPED when discarded or
;; failed.  Jobs can post cards for other workers with the board-add tool.
;;
;; The file is the interface: edit it, move cards with `org-todo', view it
;; with the agenda, `org-columns', or the org-kanban package.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'revere-config)
(require 'revere-job)
(require 'revere-tools)
(require 'revere-loop)
(require 'revere-worktree)
(require 'revere-routines)

(defconst revere-board--header
  "#+TITLE: Revere board
#+TODO: TODO CLAIMED DOING REVIEW | DONE DROPPED
#+COLUMNS: %40ITEM %8TODO %10FOR %6JOB

# One heading per card.  Properties: FOR (the worker it is for; empty means
# any), DIRECTORY, MODEL, SKILL.  Workers are routines of kind board; see
# M-x revere-board-worker-add.  C-c C-x C-c shows the columns view.

")

(defvar revere-board--states (make-hash-table :test 'equal)
  "Job id to the last state the board was told about.")

;;;; File

(defun revere-board-file ()
  "Path of the board."
  (expand-file-name "board.org" revere-directory))

(defun revere-board--buffer ()
  "The board's Org buffer, created with its header if new."
  (revere-routines--buffer (revere-board-file) revere-board--header))

;;;; Cards

(defun revere-board--card-at-point ()
  "The card at point as a plist."
  (let ((id (or (org-entry-get nil "ID")
                (let ((new (revere-job--new-id)))
                  (org-entry-put nil "ID" new)
                  new))))
    (list :id id
          :title (org-get-heading t t t t)
          :state (org-get-todo-state)
          :for (org-entry-get nil "FOR")
          :directory (org-entry-get nil "DIRECTORY" t)
          :model (org-entry-get nil "MODEL" t)
          :skill (org-entry-get nil "SKILL" t)
          :job (org-entry-get nil "JOB")
          :body (revere-routines--body))))

(defun revere-board-cards (&optional state)
  "Every card on the board, in file order; only those in STATE if given."
  (with-current-buffer (revere-board--buffer)
    (let (cards)
      (org-map-entries
       (lambda ()
         (when (or (null state) (equal (org-get-todo-state) state))
           (push (revere-board--card-at-point) cards)))
       "LEVEL=1")
      (revere-routines--save)
      (nreverse cards))))

(defun revere-board-next (worker)
  "The first TODO card WORKER may take: one for it by name, or for anyone."
  (cl-find-if (lambda (card)
                (let ((for (plist-get card :for)))
                  (or (null for) (string-empty-p for) (equal for worker))))
              (revere-board-cards "TODO")))

(defun revere-board--mark (id keyword &optional properties)
  "Move the card with ID to KEYWORD and set PROPERTIES, an alist."
  (with-current-buffer (revere-board--buffer)
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward (format "^:ID: +%s$" (regexp-quote id)) nil t)
        (org-back-to-heading t)
        (dolist (property properties)
          (org-entry-put nil (car property) (cdr property)))
        (let ((org-log-repeat nil) (org-log-done nil))
          (org-todo keyword))
        (revere-routines--save)))))

(defun revere-board-add (title text &optional for directory)
  "Add a card TITLE with TEXT, FOR a worker, working in DIRECTORY.  Return its id."
  (let ((id (revere-job--new-id)))
    (with-current-buffer (revere-board--buffer)
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert (format "* TODO %s\n:PROPERTIES:\n:ID: %s\n%s%s:END:\n%s\n"
                      title id
                      (if (and for (not (string-empty-p for))) (format ":FOR: %s\n" for) "")
                      (if directory (format ":DIRECTORY: %s\n" (expand-file-name directory)) "")
                      (string-trim (or text ""))))
      (revere-routines--save))
    id))

;;;; Working a card

(defun revere-board--prompt (card)
  "The prompt for CARD."
  (concat (format "Card: %s\n\n%s" (plist-get card :title) (plist-get card :body))
          (if (plist-get card :skill)
              (format "\n\nLoad the %s skill first." (plist-get card :skill))
            "")))

(defun revere-board-start (card worker &optional directory model routine)
  "Run CARD as a job for WORKER, in DIRECTORY with MODEL unless the card says.
ROUTINE, the worker's plist, supplies its NOTIFY channel and PROMPT_FILE."
  (let* ((directory (expand-file-name (or (plist-get card :directory) directory "~/")))
         (job (revere-job-create (revere-board--prompt card) directory
                                 (list 'board (plist-get card :id)))))
    (when (or (plist-get card :model) model)
      (setf (revere-job-model job) (or (plist-get card :model) model)))
    (when routine
      (setf (revere-job-report-to job) (plist-get routine :notify))
      (setf (revere-job-instructions job) (revere-routines-instructions routine)))
    (when (and (eq revere-unattended-mode 'worktree)
               (revere-worktree-repo-p directory))
      (revere-worktree-create job))
    (revere-board--mark (plist-get card :id) "DOING"
                        (list (cons "JOB" (number-to-string (revere-job-number job)))
                              (cons "WORKER" (or worker ""))))
    (puthash (revere-job-id job) 'working revere-board--states)
    (revere-loop-start job)
    job))

(defun revere-board-work (routine)
  "The board kind: take the next card for ROUTINE's worker, or nil if none."
  (let* ((worker (or (plist-get routine :worker) "any"))
         (card (revere-board-next worker)))
    (when card
      (revere-board-start card worker
                          (plist-get routine :directory)
                          (plist-get routine :model)
                          routine))))

(setf (alist-get "board" revere-routines-kinds nil nil #'equal) #'revere-board-work)

(defun revere-board--on-update (job)
  "Move JOB's card as the job changes state."
  (when (eq (car (revere-job-origin job)) 'board)
    (let ((state (revere-job-state job))
          (card-id (cadr (revere-job-origin job))))
      (unless (eq state (gethash (revere-job-id job) revere-board--states))
        (puthash (revere-job-id job) state revere-board--states)
        (pcase state
          ('review (revere-board--mark card-id "REVIEW"))
          ('done (revere-board--mark card-id "DONE"))
          ('discarded (revere-board--mark card-id "DROPPED"))
          ('failed (revere-board--mark card-id "DROPPED"
                                       (list (cons "LAST_ERROR" (or (revere-job-detail job) ""))))))))))

(add-hook 'revere-job-update-hook #'revere-board--on-update)

;;;; Tool

(revere-deftool board-add ((title string "One line naming the card")
                           (text string "What to do, in full; the worker sees only this")
                           (for string "Worker name it is for; leave empty for anyone" :optional t))
  "Post a card on the board for a worker to pick up later.
Use it to hand off work that is separate from this job."
  (let ((id (revere-board-add title text for)))
    (format "Card posted (%s)%s" id (if (and for (not (string-empty-p for))) (format " for %s" for) ""))))

;;;; Commands

;;;###autoload
(defun revere-board ()
  "Open the board."
  (interactive)
  (pop-to-buffer (revere-board--buffer)))

;;;###autoload
(defun revere-board-card-add (title text for directory)
  "Add a card TITLE with TEXT, FOR a worker or empty, working in DIRECTORY."
  (interactive
   (list (read-string "Card: ")
         (read-string "What to do: ")
         (read-string "For which worker (empty for any): ")
         (read-directory-name "Work in: " nil nil t)))
  (revere-board-add title text for directory)
  (message "Revere: card added"))

;;;###autoload
(defun revere-board-worker-add (name directory model minutes)
  "Add a worker NAME that takes cards every MINUTES.
It works in DIRECTORY with MODEL unless a card says otherwise."
  (interactive
   (list (read-string "Worker name: ")
         (read-directory-name "Default directory: " nil nil t)
         (read-string "Model (empty for the default): ")
         (read-number "Look for cards every how many minutes: " 10)))
  (with-current-buffer (revere-routines--buffer (revere-routines-file) revere-routines--header)
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert (format "* ROUTINE Worker %s\nSCHEDULED: <%s .+%dm>\n:PROPERTIES:\n:ID: %s\n:KIND: board\n:WORKER: %s\n:DIRECTORY: %s\n%s:END:\nTakes cards from the board marked for %s, or for anyone.\n"
                    name
                    (format-time-string "%Y-%m-%d %a %H:%M" (time-add (current-time) 60))
                    minutes
                    (revere-job--new-id)
                    name
                    (expand-file-name directory)
                    (if (string-empty-p model) "" (format ":MODEL: %s\n" model))
                    name))
    (revere-routines--save)
    (message "Revere: worker %s will look for cards every %d minutes" name minutes)))

(provide 'revere-board)
;;; revere-board.el ends here
