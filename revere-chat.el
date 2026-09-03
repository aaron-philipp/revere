;;; revere-chat.el --- The conversation, and the hub of the workspace -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; You talk to Revere here, and from here it reaches into the rest of
;; Emacs.  As it works, the file it is reading or editing appears in the
;; main window with the changed lines marked.  Every tool call in the
;; transcript is a link to what it touched: a file at the edited spot, a
;; grep buffer you can jump from, a dired listing, the shell output.  The
;; changes block links each file to its buffer, its diff and ediff, and
;; keeps or discards it in one click.  Slash commands do the rest.
;;
;; Layout of the buffer: transcript, then the changes block, a rule, and
;; the input line.  Everything above the input is read-only.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'grep)
(require 'dired)
(require 'revere-config)
(require 'revere-job)
(require 'revere-ws)
(require 'revere-tools)
(require 'revere-loop)
(require 'revere-changes)
(require 'revere-review)
(require 'revere-layout)
(require 'revere-approve)
(require 'revere-worktree)
(require 'revere-tree)
(require 'revere-models)
(require 'revere-mascot)

(declare-function revere-new "revere")
(declare-function revere-jobs "revere")

;;;; Faces

(defface revere-heading
  '((t :inherit font-lock-keyword-face :weight bold))
  "Headings."
  :group 'revere)

(defface revere-dim
  '((t :inherit font-lock-comment-face))
  "Secondary text: arguments, counts, hints."
  :group 'revere)

(defface revere-tool-name
  '((t :inherit font-lock-function-name-face))
  "Tool names."
  :group 'revere)

(defface revere-you
  '((t :inherit font-lock-keyword-face :weight bold))
  "The prefix of what you said."
  :group 'revere)

(defface revere-me
  '((t :inherit font-lock-function-name-face :weight bold))
  "The prefix of what Revere said."
  :group 'revere)

(defface revere-link
  '((t :inherit link :underline nil))
  "Clickable things in the chat."
  :group 'revere)

(defface revere-state-working
  '((t :inherit warning))
  "State glyph while working or waiting."
  :group 'revere)

(defface revere-state-good
  '((t :inherit success))
  "State glyph when done or ready to review."
  :group 'revere)

(defface revere-state-bad
  '((t :inherit error))
  "State glyph when failed or discarded."
  :group 'revere)

;;;; State

(defconst revere-chat--prompt "› ")

(defconst revere-chat-help
  "Type what you want done and press RET.  Commands:
  /changes    review everything Revere changed, as one diff
  /keep       keep every change (save the files)
  /discard    discard every change
  /stop       stop the job
  /new        start another job
  /dir PATH   work somewhere else (before the first message)
  /model M    use model M
  /think L    thinking level: off, low, medium or high
  /jobs       switch to another job
  /ok  /no    answer the approval Revere is waiting on
  /prompt     show the system message this job runs with
  /side /wide dock the chat to the side, or bring it back full width
  /help       this list
Keys: RET or any letter starts a message in the minibuffer (M-p recalls
earlier ones, C-q C-j adds a line), TAB moves between links, C-c C-k stops,
C-c C-w moves the chat between the side and the main window.
Click a tool line to open what it touched.  In a file Revere changed:
C-c r n/p move between hunks, C-c r k discards one, C-c r A keeps the file,
C-c r K discards it, C-c r d shows the diff.")

(defvar-local revere-chat--job nil "The job this chat drives, once started.")
(defvar-local revere-chat--directory nil "Where a new job will work.")
(defvar-local revere-chat--model nil "Model for a new job.")
(defvar-local revere-chat--thinking nil "Thinking level for a new job.")
(defvar-local revere-chat--transcript-end nil "Marker: end of the transcript.")
(defvar-local revere-chat--changes-start nil "Marker: start of the changes block.")
(defvar-local revere-chat--changes-end nil "Marker: end of the changes block.")
(defvar-local revere-chat--input-start nil "Marker: where the input begins.")
(defvar-local revere-chat--prefixed nil "Non-nil once this reply has its Revere prefix.")
(defvar-local revere-chat--streamed nil "Non-nil once this turn streamed text.")
(defvar-local revere-chat--last nil "What was appended last: prompt, text or tool.")
(defvar-local revere-chat--result-markers nil "Alist of tool-call id to result marker.")
(defvar-local revere-chat--approval-regions nil "Alist of approval id to (START . END) markers.")
(defvar-local revere-chat--expanded nil "Alist of tool event to (START . END) of its shown result.")
(defvar-local revere-chat--footer-start nil "Marker: where the footer begins, in minibuffer input mode.")
(defvar-local revere-chat--frame 0 "Animation frame of the mascot.")
(defvar revere-chat-history nil "What you have typed to Revere, for the minibuffer.")
(defvar revere-chat--mascot-timer nil "Animation timer while a job is active.")
(defvar-local revere-chat--timer nil "Pending refresh timer.")
(defvar-local revere-chat--signature nil "Ticks of pending changes at the last refresh.")

;;;; Mode

(defvar revere-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'revere-chat-return)
    (define-key map (kbd "<S-return>") #'revere-chat-newline)
    (define-key map (kbd "C-j") #'revere-chat-newline)
    (define-key map (kbd "C-c C-c") #'revere-chat-send)
    (define-key map (kbd "C-c C-k") #'revere-chat-stop)
    (define-key map (kbd "C-c c") #'revere-chat-changes)
    (define-key map (kbd "C-c C-w") #'revere-chat-dock-toggle)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map [remap self-insert-command] #'revere-chat-type)
    map)
  "Keymap for `revere-chat-mode'.")

(define-derived-mode revere-chat-mode text-mode "Revere"
  "Talk to Revere.  Type below the line and press RET; /help lists commands."
  (setq-local header-line-format '(:eval (revere-chat--header)))
  (revere-layout-no-line-numbers)
  (visual-line-mode 1)
  (when (fboundp 'visual-wrap-prefix-mode)
    (visual-wrap-prefix-mode 1)))

(defun revere-chat-show (buffer)
  "Show the chat BUFFER where it belongs and select it."
  (revere-layout-show-chat buffer))

(defun revere-chat-dock-toggle ()
  "Move the chat between the main window and its side window."
  (interactive)
  (if (revere-layout-docked-p (current-buffer))
      (revere-layout-undock (current-buffer))
    (revere-layout-dock (current-buffer))))

(defun revere-chat--buffer-input-p ()
  "Non-nil when this chat takes input on its own last line."
  (and revere-chat--input-start t))

(defun revere-chat--setup (directory)
  "Lay out the current buffer as a fresh chat working in DIRECTORY."
  (revere-chat-mode)
  (setq revere-chat--directory (file-name-as-directory (expand-file-name directory)))
  (setq default-directory revere-chat--directory)
  (setq revere-chat--model revere-model)
  (setq revere-chat--thinking revere-thinking-level)
  (revere-models-ensure)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (format "Working in %s.  %s  /help lists commands.\n"
                                (abbreviate-file-name revere-chat--directory)
                                (if (eq revere-chat-input 'buffer)
                                    "Write what you want done and press RET."
                                  "Press RET, or just start typing, to say what you want done."))
                        'face 'revere-dim))
    (insert "\n")
    (setq revere-chat--transcript-end (copy-marker (1- (point)) t))
    (insert "\n")
    (setq revere-chat--changes-start (copy-marker (1- (point)) nil))
    (setq revere-chat--changes-end (copy-marker (1- (point)) t))
    (cond
     ((eq revere-chat-input 'buffer)
      (insert (propertize (concat (make-string 40 ?─) "\n") 'face 'revere-dim))
      (insert (propertize revere-chat--prompt 'face 'revere-you 'rear-nonsticky t))
      (put-text-property (point-min) (point) 'read-only t)
      (setq revere-chat--input-start (copy-marker (point) nil)))
     (t
      (setq revere-chat--input-start nil)
      (setq revere-chat--footer-start (copy-marker (point) nil))
      (revere-chat--render-footer)
      (put-text-property (point-min) (point-max) 'read-only t)
      (setq buffer-read-only t))))
  (goto-char (point-max)))

;;;; The footer: mascot and status, pinned to the bottom

(defun revere-chat--status-line (job)
  "One line of state for the footer."
  (if job
      (format "%s %s%s · %s · think %s · %s · %s tok%s · %s"
              (revere-chat--glyph job)
              (revere-job-state-label job)
              (if (revere-job-detail job) (format " (%s)" (revere-job-detail job)) "")
              (revere-job-model job)
              (or (revere-job-thinking job) 'off)
              (revere-chat--context job)
              (revere-chat--human (+ (revere-job-tokens-in job) (revere-job-tokens-out job)))
              (if (> (revere-job-cost job) 0) (concat " " (revere-chat--money (revere-job-cost job))) "")
              (revere-chat--elapsed job))
    (format "%s · think %s%s · %s"
            revere-chat--model
            (or revere-chat--thinking 'off)
            (let ((limit (revere-models-context-limit revere-chat--model)))
              (if limit (format " · ctx %s" (revere-chat--human limit)) ""))
            (abbreviate-file-name revere-chat--directory))))

(defconst revere-chat--footer-lines 3
  "How many screen lines the footer takes.")

(defun revere-chat--footer-padding (window)
  "How many blank lines put the footer at the bottom of WINDOW."
  (if (not window)
      0
    (let ((content (count-screen-lines (point-min) revere-chat--footer-start window))
          (height (window-body-height window)))
      (max 0 (- height content revere-chat--footer-lines)))))

(defun revere-chat--render-footer ()
  "Redraw the mascot and status at the end of the buffer."
  (when revere-chat--footer-start
    (let ((inhibit-read-only t)
          (window (get-buffer-window (current-buffer) t))
          (job revere-chat--job))
      (save-excursion
        (goto-char revere-chat--footer-start)
        (delete-region (point) (point-max))
        (insert (make-string (revere-chat--footer-padding window) ?\n))
        (let ((mascot (revere-mascot-lines job revere-chat--frame))
              (status (revere-chat--status-line job))
              (hint (propertize (if (revere-chat--buffer-input-p) "" "RET or type to talk · /help")
                                'face 'revere-dim)))
          (insert (nth 0 mascot) "\n"
                  (nth 1 mascot) "  " status "\n"
                  (nth 2 mascot) "  " hint))
        (add-text-properties revere-chat--footer-start (point-max) '(read-only t)))
      (set-buffer-modified-p nil))))

(defun revere-chat--animate ()
  "Advance the mascot in every visible chat whose job is active."
  (let ((any nil))
    (dolist (buffer (buffer-list))
      (when (and (buffer-live-p buffer)
                 (buffer-local-value 'revere-chat--footer-start buffer)
                 (get-buffer-window buffer t))
        (with-current-buffer buffer
          (let ((job revere-chat--job))
            (when (and job (revere-job-active-p job))
              (setq any t)
              (when (revere-mascot-animated-p job)
                (cl-incf revere-chat--frame)
                (revere-chat--render-footer)))))))
    (unless any
      (when revere-chat--mascot-timer
        (cancel-timer revere-chat--mascot-timer)
        (setq revere-chat--mascot-timer nil)))))

(defun revere-chat--start-animation ()
  "Start the mascot timer if it is not running."
  (unless revere-chat--mascot-timer
    (setq revere-chat--mascot-timer
          (run-with-timer revere-mascot-interval revere-mascot-interval #'revere-chat--animate))))

(defun revere-chat--window-resized (frame-or-window)
  "Keep footers at the bottom after FRAME-OR-WINDOW changed size."
  (dolist (window (if (windowp frame-or-window)
                      (list frame-or-window)
                    (window-list frame-or-window)))
    (with-current-buffer (window-buffer window)
      (when revere-chat--footer-start
        (revere-chat--render-footer)))))

(add-hook 'window-size-change-functions #'revere-chat--window-resized)

(defun revere-chat-create (directory)
  "Return a new chat buffer that will work in DIRECTORY."
  (let ((buffer (generate-new-buffer "*Revere*")))
    (with-current-buffer buffer
      (revere-chat--setup directory))
    buffer))

(defun revere-chat-buffer (job)
  "The chat buffer for JOB, rebuilt from its history if it was killed."
  (let ((buffer (revere-job-buffer job)))
    (unless (and (buffer-live-p buffer) (buffer-local-value 'revere-chat--job buffer))
      (setq buffer (generate-new-buffer (format "*Revere: job %d*" (revere-job-number job))))
      (with-current-buffer buffer
        (revere-chat--setup (revere-job-directory job))
        (setq revere-chat--job job)
        (setf (revere-job-buffer job) buffer)
        (dolist (event (revere-job-history job))
          (revere-chat--render-event event)
          (when (and (eq (plist-get event :kind) 'tool-call) (plist-get event :result))
            (revere-chat--tool-result event)))
        (revere-chat--refresh)))
    buffer))

;;;; Header

(defun revere-chat--header ()
  "Header line.
The job's title when the footer carries the status, else the status."
  (cond
   (revere-chat--footer-start (revere-chat--header-title))
   ((< (window-width) 90) (revere-chat--header-narrow))
   (t (revere-chat--header-wide))))

(defun revere-chat--header-title ()
  "A header naming the job, for chats with a status footer."
  (let ((job revere-chat--job))
    (concat (propertize " Revere" 'face 'revere-heading)
            (if job
                (format "  job %d · %s" (revere-job-number job)
                        (truncate-string-to-width (car (split-string (revere-job-prompt job) "\n"))
                                                  (max 20 (- (window-width) 20)) nil nil "…"))
              (format "  new job in %s" (abbreviate-file-name revere-chat--directory))))))

(defun revere-chat--header-narrow ()
  "The header for a docked, narrow chat."
  (let ((job revere-chat--job))
    (concat
     (propertize " Revere" 'face 'revere-heading)
     (if job
         (format " %d %s %s · %s · %s"
                 (revere-job-number job)
                 (revere-chat--glyph job)
                 (revere-job-state-label job)
                 (revere-chat--context job)
                 (if (> (revere-job-cost job) 0)
                     (revere-chat--money (revere-job-cost job))
                   (concat (revere-chat--human (+ (revere-job-tokens-in job) (revere-job-tokens-out job)))
                           " tok")))
       (format " new job · %s" revere-chat--model)))))

(defun revere-chat--header-wide ()
  "The full header."
  (let ((job revere-chat--job))
    (concat
     (propertize " Revere" 'face 'revere-heading)
     (if job
         (format "  job %d%s · %s %s%s · %s · think %s · %s · %s tok · %s"
                 (revere-job-number job)
                 (pcase (car (revere-job-origin job))
                   ('routine " (routine)")
                   ('check-in " (check-in)")
                   ('board " (board)")
                   ('channel " (channel)")
                   ('parent " (helper)")
                   (_ ""))
                 (revere-chat--glyph job)
                 (revere-job-state-label job)
                 (if (revere-job-detail job) (format " (%s)" (revere-job-detail job)) "")
                 (revere-job-model job)
                 (or (revere-job-thinking job) 'off)
                 (revere-chat--context job)
                 (concat (revere-chat--human (+ (revere-job-tokens-in job) (revere-job-tokens-out job)))
                         (if (> (revere-job-cost job) 0)
                             (concat " " (revere-chat--money (revere-job-cost job)))
                           ""))
                 (revere-chat--elapsed job))
       (format "  new job in %s · %s · think %s%s"
               (abbreviate-file-name revere-chat--directory) revere-chat--model
               (or revere-chat--thinking 'off)
               (let ((limit (revere-models-context-limit revere-chat--model)))
                 (if limit (format " · ctx %s" (revere-chat--human limit)) ""))))
     (propertize "   RET send · /help" 'face 'revere-dim))))

(defun revere-chat--context (job)
  "How full JOB's context is: used of limit with a percentage, or just used."
  (let ((used (revere-job-context-tokens job))
        (limit (revere-models-context-limit (revere-job-model job))))
    (cond
     ((and used limit (> limit 0))
      (let ((percent (/ (* 100 used) limit)))
        (propertize (format "ctx %s/%s %d%%" (revere-chat--human used) (revere-chat--human limit) percent)
                    'face (cond ((>= percent 90) 'revere-state-bad)
                                ((>= percent 70) 'revere-state-working)
                                (t 'default)))))
     (used (format "ctx %s" (revere-chat--human used)))
     (limit (format "ctx 0/%s" (revere-chat--human limit)))
     (t "ctx ?"))))

(defun revere-chat--glyph (job)
  "State glyph for JOB."
  (pcase (revere-job-state job)
    ('queued (propertize "○" 'face 'revere-dim))
    ('working (propertize (if (equal (revere-job-detail job) "writing") "◑" "◔")
                          'face 'revere-state-working))
    ('waiting (propertize "⏸" 'face 'revere-state-working))
    ((or 'review 'done) (propertize "✓" 'face 'revere-state-good))
    (_ (propertize "✗" 'face 'revere-state-bad))))

(defun revere-chat--human (n)
  "N as a short count such as 1.2k."
  (cond ((>= n 1000000) (format "%.1fM" (/ n 1000000.0)))
        ((>= n 1000) (format "%.1fk" (/ n 1000.0)))
        (t (number-to-string n))))

(defun revere-chat--money (amount)
  "AMOUNT in dollars, as text."
  (if (< amount 0.01) "$<0.01" (format "$%.2f" amount)))

(defun revere-chat--elapsed (job)
  "JOB's running time as minutes and seconds."
  (let ((seconds (round (revere-job-elapsed job))))
    (format "%dm%02ds" (/ seconds 60) (% seconds 60))))

;;;; Appending to the transcript

(defun revere-chat--at-end (thunk)
  "Run THUNK with point at the end of the transcript.
What it inserts becomes read-only."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char revere-chat--transcript-end)
      (let ((start (point)))
        (funcall thunk)
        (add-text-properties start (point) '(read-only t)))))
  (revere-chat--scroll))

(defun revere-chat--append (text)
  "Append TEXT to the transcript."
  (revere-chat--at-end (lambda () (insert text))))

(defun revere-chat--ensure-newline ()
  "Make sure the transcript ends with a newline."
  (unless (eq (char-before revere-chat--transcript-end) ?\n)
    (revere-chat--append "\n")))

(defun revere-chat--scroll ()
  "Keep the end of the chat visible in windows that were looking at it."
  (when revere-chat--footer-start
    (revere-chat--render-footer))
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (when (>= (window-point window) (or revere-chat--input-start revere-chat--footer-start))
      (with-selected-window window
        (let ((where (if revere-chat--input-start (point) (point-max))))
          (goto-char (point-max))
          (recenter -1)
          (goto-char where))))))

(defun revere-chat--note (text)
  "Show TEXT from Revere itself, not the model."
  (revere-chat--ensure-newline)
  (revere-chat--append (concat (propertize text 'face 'revere-dim) "\n"))
  (setq revere-chat--last 'text))

;;;; Events from the job

(defun revere-chat--on-event (job event)
  "Render EVENT of JOB in its chat, and follow it into the workspace."
  (let ((buffer (revere-job-buffer job)))
    (when (and (buffer-live-p buffer) (buffer-local-value 'revere-chat--job buffer))
      (with-current-buffer buffer
        (revere-chat--render-event event)
        (revere-chat--follow event)))))

(defun revere-chat--render-event (event)
  "Append EVENT to the transcript."
  (let ((text (plist-get event :text)))
    (pcase (plist-get event :kind)
      ('prompt
       (revere-chat--append (concat "\n" (propertize "You › " 'face 'revere-you) text "\n"))
       (setq revere-chat--prefixed nil revere-chat--streamed nil revere-chat--last 'prompt))
      ('delta
       (revere-chat--text text)
       (setq revere-chat--streamed t))
      ('said
       (unless revere-chat--streamed
         (revere-chat--text text))
       (revere-chat--ensure-newline)
       (setq revere-chat--streamed nil))
      ('tool-call (revere-chat--tool-line event))
      ('tool-result (revere-chat--tool-result event))
      ('approval (revere-chat--approval (plist-get event :approval)))
      ('note (revere-chat--note text))
      ('error
       (revere-chat--ensure-newline)
       (revere-chat--append (concat (propertize (concat "✗ " text) 'face 'revere-state-bad) "\n"))))))

(defun revere-chat--text (text)
  "Append TEXT the model said, with the Revere prefix once per reply."
  (unless revere-chat--prefixed
    (revere-chat--append (propertize "\nRevere › " 'face 'revere-me))
    (setq revere-chat--prefixed t))
  (when (eq revere-chat--last 'tool)
    (revere-chat--ensure-newline))
  (revere-chat--append text)
  (setq revere-chat--last 'text))

(defun revere-chat--tool-line (event)
  "Append a clickable line for the tool call in EVENT."
  (let ((name (plist-get event :name))
        (args (plist-get event :args))
        (id (plist-get event :id)))
    (unless revere-chat--prefixed
      (revere-chat--append (propertize "\nRevere ›" 'face 'revere-me))
      (setq revere-chat--prefixed t))
    (revere-chat--ensure-newline)
    (revere-chat--at-end
     (lambda ()
       (let ((start (point)))
         (insert "  " (revere-chat--tool-glyph name) " "
                 (propertize (format "%-6s" name) 'face 'revere-tool-name) " "
                 (propertize (revere-chat--args-summary name args) 'face 'revere-dim))
         (make-text-button start (point)
                           'action #'revere-chat--tool-action
                           'revere-event event
                           'follow-link t
                           'face 'revere-link
                           'help-echo "Open what this touched")
         (insert (propertize " → " 'face 'revere-dim))
         (push (cons id (copy-marker (point) nil)) revere-chat--result-markers))))
    (setq revere-chat--last 'tool revere-chat--streamed nil)))

(defun revere-chat--tool-result (event)
  "Fill in the result of the tool call in EVENT."
  (let* ((cell (assoc (plist-get event :id) revere-chat--result-markers))
         (marker (cdr cell)))
    (when (and marker (marker-buffer marker))
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char marker)
          (let ((start (point)))
            (insert (revere-chat--result-summary event))
            (make-text-button start (point)
                              'action #'revere-chat--toggle-result
                              'revere-event event
                              'follow-link t
                              'face 'revere-dim
                              'help-echo "Show or hide the full result")
            (add-text-properties start (point) '(read-only t)))))
      (set-marker marker nil)
      (setq revere-chat--result-markers (delq cell revere-chat--result-markers)))))

(defun revere-chat--toggle-result (button)
  "Show the full result of the tool call behind BUTTON under its line, or hide it."
  (let* ((event (button-get button 'revere-event))
         (cell (assq event revere-chat--expanded))
         (inhibit-read-only t))
    (if cell
        (progn
          (delete-region (cadr cell) (cddr cell))
          (set-marker (cadr cell) nil)
          (set-marker (cddr cell) nil)
          (setq revere-chat--expanded (delq cell revere-chat--expanded)))
      (save-excursion
        (goto-char (button-end button))
        (end-of-line)
        (let* ((start (point-marker))
               (lines (split-string (or (plist-get event :result) "") "\n"))
               (shown (seq-take lines 200)))
          (insert "\n"
                  (propertize (mapconcat (lambda (line) (concat "      " line)) shown "\n")
                              'face 'revere-dim))
          (when (> (length lines) 200)
            (insert (propertize (format "\n      … %d more lines" (- (length lines) 200)) 'face 'revere-dim)))
          (add-text-properties start (point) '(read-only t))
          (push (cons event (cons start (copy-marker (point) t))) revere-chat--expanded))))))

(defun revere-chat--approval (approval)
  "Show APPROVAL with its buttons while pending; take the line out once decided."
  (if (eq (revere-approval-state approval) 'pending)
      (let (start end)
        (revere-chat--ensure-newline)
        (revere-chat--at-end
         (lambda ()
           (setq start (copy-marker (point) nil))
           (insert "  "
                   (propertize (format "⏸ needs your OK: %s  " (revere-approve-description approval))
                               'face 'revere-state-working))
           (revere-chat--button "Go ahead" (lambda (_) (revere-approve-decide approval t)))
           (insert "  ")
           (revere-chat--button "No" (lambda (_) (revere-approve-decide approval nil)))
           (insert "\n")
           (setq end (copy-marker (point) nil))))
        (push (cons (revere-approval-id approval) (cons start end)) revere-chat--approval-regions)
        (setq revere-chat--last 'tool))
    (let ((cell (assoc (revere-approval-id approval) revere-chat--approval-regions)))
      (when cell
        (let ((inhibit-read-only t)
              (start (cadr cell))
              (end (cddr cell)))
          (when (and (marker-buffer start) (marker-buffer end))
            (delete-region start end))
          (set-marker start nil)
          (set-marker end nil))
        (setq revere-chat--approval-regions (delq cell revere-chat--approval-regions))))))

(defun revere-chat--tool-glyph (name)
  "Glyph for the tool called NAME."
  (pcase name
    ((or "edit" "write") "✎")
    ("read" "▤")
    ((or "glob" "grep") "⌕")
    ("shell" "⚙")
    (_ "•")))

(defun revere-chat--short (text &optional width)
  "TEXT on one line, at most WIDTH columns."
  (truncate-string-to-width (replace-regexp-in-string "\n" " " (or text ""))
                            (or width 48) nil nil "…"))

(defun revere-chat--args-summary (name args-json)
  "What to show next to tool NAME for ARGS-JSON."
  (let ((table (revere-tools-parse-args args-json)))
    (pcase name
      ((or "read" "edit" "write") (revere-chat--short (gethash "path" table)))
      ("grep" (concat (format "%S" (or (gethash "pattern" table) ""))
                      (if (gethash "include" table) (format " in %s" (gethash "include" table)) "")))
      ("glob" (format "%s" (or (gethash "pattern" table) "")))
      ("shell" (revere-chat--short (gethash "command" table) 60))
      (_ (revere-chat--short args-json 60)))))

(defun revere-chat--result-summary (event)
  "A few words about the result in EVENT."
  (let ((result (plist-get event :result))
        (name (plist-get event :name)))
    (cond
     ((null result) "…")
     ((string-prefix-p "tool " result) (revere-chat--short result 70))
     (t (pcase name
          ("read" (format "%d lines" (length (split-string result "\n" t))))
          ("grep" (if (string-prefix-p "No matches" result) "no matches"
                    (format "%d matches" (length (split-string result "\n" t)))))
          ("glob" (if (string-prefix-p "No matches" result) "no files"
                    (format "%d files" (length (split-string result "\n" t)))))
          (_ (revere-chat--short (car (split-string result "\n")) 70)))))))

;;;; Reaching into the workspace

(defun revere-chat--event-path (event)
  "The absolute path named by EVENT's arguments, or nil."
  (let ((path (gethash "path" (revere-tools-parse-args (plist-get event :args)))))
    (and path revere-chat--job
         (expand-file-name path (revere-job-directory revere-chat--job)))))

(defun revere-chat--event-buffer (event)
  "The buffer EVENT touched, or nil."
  (let* ((full (revere-chat--event-path event))
         (entry (and full (revere-ws-entry revere-chat--job full))))
    (cond
     ((and entry (buffer-live-p (revere-change-buffer entry))) (revere-change-buffer entry))
     ((and full (file-exists-p full)) (find-file-noselect full))
     (t nil))))

(defun revere-chat--event-position (buffer event)
  "Where in BUFFER the tool call in EVENT did its work, or nil."
  (let* ((table (revere-tools-parse-args (plist-get event :args)))
         (needle (or (gethash "new_string" table) (gethash "content" table)))
         (line (gethash "start_line" table)))
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-min))
        (cond
         ((and needle (not (string-empty-p needle))
               (let ((case-fold-search nil)) (search-forward needle nil t)))
          (match-beginning 0))
         ((numberp line) (forward-line (1- line)) (point))
         (t nil))))))

(defun revere-chat--open-file (event select)
  "Show the file EVENT touched in a main window; select it if SELECT."
  (let ((buffer (revere-chat--event-buffer event)))
    (if (null buffer)
        (message "Revere: that file is not open")
      (let ((window (revere-layout-show-file buffer (revere-chat--event-position buffer event))))
        (when (and select window)
          (select-window window))))))

(defun revere-chat--follow (event)
  "After a file tool ran, show the file in the main window.
The first time, dock the chat to the side so the file has room."
  (when (and revere-follow
             (eq (plist-get event :kind) 'tool-result)
             (member (plist-get event :name) '("read" "edit" "write"))
             (get-buffer-window (current-buffer)))
    (when (and (eq revere-chat-dock 'on-follow)
               (not (revere-layout-docked-p (current-buffer))))
      (revere-layout-dock (current-buffer)))
    (revere-chat--open-file event nil)))

(defun revere-chat--tool-action (button)
  "Open whatever the tool call behind BUTTON touched."
  (let* ((event (button-get button 'revere-event))
         (name (plist-get event :name)))
    (pcase name
      ((or "read" "edit" "write") (revere-chat--open-file event t))
      ("grep" (revere-chat--show-grep event))
      ("glob" (revere-chat--show-files event))
      ("shell" (revere-chat--show-shell event))
      (_ (message "%s" (or (plist-get event :result) "No result yet"))))))

(defun revere-chat--tool-root (event)
  "The directory the search tool in EVENT ran in."
  (let ((path (gethash "path" (revere-tools-parse-args (plist-get event :args)))))
    (file-name-as-directory
     (expand-file-name (or path ".") (revere-job-directory revere-chat--job)))))

(defun revere-chat--show-grep (event)
  "Show the grep result in EVENT in a `grep-mode' buffer you can jump from."
  (let* ((table (revere-tools-parse-args (plist-get event :args)))
         (root (revere-chat--tool-root event))
         (buffer (get-buffer-create (format "*Revere: grep %d*" (revere-job-number revere-chat--job)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq default-directory root)
        (insert (format "grep %S in %s\n\n" (or (gethash "pattern" table) "")
                        (abbreviate-file-name root)))
        (insert (or (plist-get event :result) "(no result yet)") "\n"))
      (grep-mode))
    (select-window (revere-layout-show-tool-buffer buffer))))

(defun revere-chat--show-files (event)
  "Show the files the glob in EVENT found, in dired."
  (let* ((root (revere-chat--tool-root event))
         (result (or (plist-get event :result) ""))
         (files (unless (string-prefix-p "No matches" result)
                  (mapcar (lambda (rel) (expand-file-name rel root))
                          (split-string result "\n" t)))))
    (if (null files)
        (message "Revere: no files to show")
      (let ((buffer (dired-noselect (cons root files))))
        (with-current-buffer buffer
          (rename-buffer (format "*Revere: files %d*" (revere-job-number revere-chat--job)) t))
        (select-window (revere-layout-show-tool-buffer buffer))))))

(defun revere-chat--show-shell (event)
  "Show the shell command and output in EVENT."
  (let* ((table (revere-tools-parse-args (plist-get event :args)))
         (buffer (get-buffer-create (format "*Revere: shell %d*" (revere-job-number revere-chat--job)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (unless (derived-mode-p 'special-mode) (special-mode))
        (goto-char (point-max))
        (insert (propertize (format "$ %s\n" (or (gethash "command" table) "")) 'face 'revere-heading)
                (or (plist-get event :result) "(no result yet)") "\n\n")))
    (select-window (revere-layout-show-tool-buffer buffer))))

;;;; The changes block

(defun revere-chat--button (label action)
  "Insert a button LABEL running ACTION."
  (insert-text-button label 'action action 'follow-link t 'face 'revere-link))

(defun revere-chat--render-changes ()
  "Rebuild the changes block from the job's pending changes."
  (let ((inhibit-read-only t)
        (job revere-chat--job))
    (save-excursion
      (goto-char revere-chat--changes-start)
      (delete-region revere-chat--changes-start revere-chat--changes-end)
      (when job
        (revere-chat--insert-plan job))
      (cond
       ((null job) nil)
       ((eq (revere-job-mode job) 'worktree) (revere-chat--insert-branch-changes job))
       (t (revere-chat--insert-buffer-changes job))))))

(defun revere-chat--insert-plan (job)
  "Insert JOB's plan, if it keeps one."
  (let ((items (revere-job-plan job)))
    (when items
      (let ((start (point))
            (done (cl-count-if (lambda (item) (string-match-p "\\`\\[[xX]\\]" item)) items)))
        (insert (propertize "Plan" 'face 'revere-heading)
                (propertize (format "  %d of %d done\n" done (length items)) 'face 'revere-dim))
        (dolist (item items)
          (insert "  " (if (string-match-p "\\`\\[[xX]\\]" item)
                           (propertize item 'face 'revere-dim)
                         item)
                  "\n"))
        (insert "\n")
        (add-text-properties start (point) '(read-only t))))))

(defun revere-chat--changes-buttons ()
  "Insert the Review, Keep all and Discard all buttons."
  (revere-chat--button "Review" (lambda (_) (revere-chat-changes)))
  (insert "  ")
  (revere-chat--button "Keep all" (lambda (_) (revere-chat-keep-all)))
  (insert "  ")
  (revere-chat--button "Discard all" (lambda (_) (revere-chat-discard-all)))
  (insert "\n"))

(defun revere-chat--insert-buffer-changes (job)
  "Insert the changes block for JOB's unsaved buffers."
  (let ((entries (revere-ws-pending job)))
    (when entries
      (let ((start (point))
            (stats (mapcar #'revere-ws-diffstat entries)))
        (insert (propertize "Changes" 'face 'revere-heading)
                (propertize (format "  %d file%s  +%d -%d   "
                                    (length entries) (if (= 1 (length entries)) "" "s")
                                    (apply #'+ (mapcar #'car stats))
                                    (apply #'+ (mapcar #'cdr stats)))
                            'face 'revere-dim))
        (revere-chat--changes-buttons)
        (cl-loop for entry in entries
                 for stat in stats
                 do (revere-chat--render-change job entry stat))
        (insert "\n")
        (add-text-properties start (point) '(read-only t))))))

(defun revere-chat--insert-branch-changes (job)
  "Insert the changes block for JOB's worktree branch."
  (let ((files (and (revere-job-worktree job)
                    (file-directory-p (revere-job-worktree job))
                    (ignore-errors (revere-worktree-numstat job)))))
    (when files
      (let ((start (point)))
        (insert (propertize "Changes" 'face 'revere-heading)
                (propertize (format " on %s  %d file%s  +%d -%d   "
                                    (revere-job-branch job)
                                    (length files) (if (= 1 (length files)) "" "s")
                                    (apply #'+ (mapcar #'car files))
                                    (apply #'+ (mapcar #'cadr files)))
                            'face 'revere-dim))
        (revere-chat--changes-buttons)
        (dolist (file files)
          (let ((path (expand-file-name (nth 2 file) (revere-job-worktree job))))
            (insert "  " (propertize "●" 'face 'revere-state-good) " ")
            (revere-chat--button (nth 2 file)
                                 (lambda (_)
                                   (select-window (revere-layout-show-file (find-file-noselect path)))))
            (insert (propertize (format "  +%d -%d" (nth 0 file) (nth 1 file)) 'face 'revere-dim) "\n")))
        (insert (propertize "  Keep all merges the branch into the project; Discard all drops it.\n"
                            'face 'revere-dim))
        (insert "\n")
        (add-text-properties start (point) '(read-only t))))))

(defun revere-chat--render-change (job entry stat)
  "Insert the line for ENTRY of JOB with diffstat STAT."
  (insert "  " (propertize "●" 'face 'revere-state-good) " ")
  (revere-chat--button (revere-ws-relative job entry)
                       (lambda (_) (revere-chat--visit-entry entry)))
  (insert (propertize (format "  +%d -%d  " (car stat) (cdr stat)) 'face 'revere-dim))
  (revere-chat--button "diff" (lambda (_) (revere-chat--diff-entry entry)))
  (insert " ")
  (revere-chat--button "ediff" (lambda (_) (revere-chat--ediff-entry entry)))
  (insert " ")
  (revere-chat--button "keep" (lambda (_)
                                (revere-ws-keep-file job entry)
                                (revere-chat--settle job)
                                (revere-chat--refresh)))
  (insert " ")
  (revere-chat--button "discard" (lambda (_)
                                   (revere-ws-discard-file job entry)
                                   (revere-chat--settle job)
                                   (revere-chat--refresh)))
  (insert "\n"))

(defun revere-chat--visit-entry (entry)
  "Show ENTRY's buffer in a main window and go there."
  (let ((buffer (revere-change-buffer entry)))
    (if (buffer-live-p buffer)
        (select-window (revere-layout-show-file buffer))
      (message "Revere: that buffer is gone"))))

(defun revere-chat--diff-entry (entry)
  "Open the changes buffer at ENTRY's file."
  (let ((job revere-chat--job))
    (revere-changes-show job)
    (with-current-buffer (revere-changes-buffer job)
      (let ((pos (revere-changes--find-section (revere-change-file entry))))
        (when pos (goto-char pos))))))

(defun revere-chat--ediff-entry (entry)
  "Compare ENTRY's buffer with its file on disk."
  (if (revere-change-created-p entry)
      (message "Revere: new file; nothing on disk to compare with")
    (revere-chat--visit-entry entry)
    (ediff-current-file)))

(defun revere-chat--settle (job)
  "Once nothing is pending, a job in review is done."
  (when (and (eq (revere-job-state job) 'review) (null (revere-ws-pending job)))
    (revere-job-set-state job 'done)))

;;;; Refresh

(defun revere-chat--on-update (job)
  "Schedule a refresh of JOB's chat."
  (let ((buffer (revere-job-buffer job)))
    (when (and (buffer-live-p buffer) (buffer-local-value 'revere-chat--job buffer))
      (with-current-buffer buffer
        (unless revere-chat--timer
          (setq revere-chat--timer (run-at-time 0.1 nil #'revere-chat--flush buffer)))))))

(defun revere-chat--flush (buffer)
  "Refresh BUFFER now."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq revere-chat--timer nil)
      (revere-chat--refresh))))

(defun revere-chat--refresh ()
  "Redraw the header, the changes block, and the review marks in files."
  (when (and revere-chat--job (revere-job-active-p revere-chat--job) revere-chat--footer-start
             (get-buffer-window (current-buffer) t))
    (revere-chat--start-animation))
  (when revere-chat--footer-start
    (revere-chat--render-footer))
  (when revere-chat--job
    (let ((signature (cons (revere-job-plan revere-chat--job)
                           (if (eq (revere-job-mode revere-chat--job) 'worktree)
                               (list 'branch (revere-job-state revere-chat--job))
                             (mapcar (lambda (entry)
                                       (cons (revere-change-file entry)
                                             (buffer-chars-modified-tick (revere-change-buffer entry))))
                                     (revere-ws-pending revere-chat--job))))))
      (unless (equal signature revere-chat--signature)
        (setq revere-chat--signature signature)
        (revere-chat--render-changes)
        (revere-review-sync revere-chat--job)
        (revere-tree-sync revere-chat--job)
        (let ((changes (get-buffer (format "*Revere: changes %d*"
                                           (revere-job-number revere-chat--job)))))
          (when (and changes (get-buffer-window changes t))
            (revere-changes-render changes))))))
  (force-mode-line-update))

(add-hook 'revere-job-event-hook #'revere-chat--on-event)
(add-hook 'revere-job-update-hook #'revere-chat--on-update)

;;;; Input and commands

(defun revere-chat--input ()
  "What has been typed on the input line, trimmed."
  (if revere-chat--input-start
      (string-trim (buffer-substring-no-properties revere-chat--input-start (point-max)))
    ""))

(defun revere-chat--clear-input ()
  "Empty the input line."
  (when revere-chat--input-start
    (let ((inhibit-read-only t))
      (delete-region revere-chat--input-start (point-max)))
    (goto-char (point-max))))

(defun revere-chat--dispatch (text)
  "Send TEXT: a slash command to the chat, anything else to the job."
  (let ((text (string-trim text)))
    (cond
     ((string-empty-p text) nil)
     ((string-prefix-p "/" text) (revere-chat--command text))
     (t (revere-chat-submit text)))))

(defun revere-chat--minibuffer-prompt ()
  "The prompt for the minibuffer."
  (if revere-chat--job
      (format "Revere (job %d) › " (revere-job-number revere-chat--job))
    "Revere › "))

(defun revere-chat-ask (&optional initial)
  "Ask, in the minibuffer, what to say to Revere, starting with INITIAL."
  (interactive)
  (let ((text (read-from-minibuffer (revere-chat--minibuffer-prompt) initial nil nil
                                    'revere-chat-history)))
    (revere-chat--dispatch text)))

(defun revere-chat-type ()
  "Start a message in the minibuffer with the key just pressed."
  (interactive)
  (if (revere-chat--buffer-input-p)
      (progn (goto-char (point-max)) (self-insert-command 1))
    (revere-chat-ask (this-command-keys))))

(defun revere-chat-return ()
  "Send what you typed; on a link, follow it; elsewhere, start a message."
  (interactive)
  (cond
   ((button-at (point)) (push-button))
   ((revere-chat--buffer-input-p)
    (if (>= (point) revere-chat--input-start)
        (revere-chat-send)
      (goto-char (point-max))))
   (t (revere-chat-ask))))

(defun revere-chat-newline ()
  "Add a line to the input, or start a message."
  (interactive)
  (cond
   ((not (revere-chat--buffer-input-p)) (revere-chat-ask))
   ((>= (point) revere-chat--input-start) (newline))
   (t (goto-char (point-max)))))

(defun revere-chat-send ()
  "Send the input line, or start a message in the minibuffer."
  (interactive)
  (if (not (revere-chat--buffer-input-p))
      (revere-chat-ask)
    (let ((text (revere-chat--input)))
      (if (string-empty-p text)
          (message "Write what you want done, then RET")
        (revere-chat--clear-input)
        (revere-chat--dispatch text)))))

(defun revere-chat-submit (text)
  "Send TEXT to the job, starting one if needed.  Return the job."
  (let ((job revere-chat--job))
    (cond
     ((null job)
      (setq job (revere-job-create text revere-chat--directory))
      (setf (revere-job-model job) revere-chat--model)
      (setf (revere-job-thinking job) revere-chat--thinking)
      (setq revere-chat--job job)
      (setf (revere-job-buffer job) (current-buffer))
      (rename-buffer (format "*Revere: job %d*" (revere-job-number job)) t)
      (revere-loop-start job))
     ((revere-job-active-p job)
      (user-error "Still working; /stop interrupts it"))
     (t (revere-loop-reply job text)))
    job))

(defun revere-chat--command (text)
  "Run the slash command in TEXT."
  (let* ((parts (split-string text))
         (command (car parts))
         (argument (string-join (cdr parts) " ")))
    (pcase command
      ("/help" (revere-chat--note revere-chat-help))
      ((or "/changes" "/review") (revere-chat-changes))
      ("/keep" (revere-chat-keep-all))
      ("/discard" (revere-chat-discard-all))
      ("/stop" (revere-chat-stop))
      ("/new" (call-interactively #'revere-new))
      ("/dir" (revere-chat-directory
               (if (string-empty-p argument)
                   (read-directory-name "Revere, work in: " revere-chat--directory nil t)
                 argument)))
      ("/model" (if (string-empty-p argument)
                    (revere-chat--note (format "Model: %s" (revere-chat--current-model)))
                  (revere-chat-model argument)))
      ("/think" (if (string-empty-p argument)
                    (revere-chat--note (format "Thinking: %s" (revere-chat--current-thinking)))
                  (revere-chat-thinking argument)))
      ("/jobs" (call-interactively #'revere-jobs))
      ("/ok" (revere-chat--answer t))
      ("/no" (revere-chat--answer nil))
      ("/prompt" (revere-chat--show-prompt))
      ("/side" (revere-layout-dock (current-buffer)))
      ("/wide" (revere-layout-undock (current-buffer)))
      (_ (revere-chat--note (format "Unknown command %s.  /help lists them." command))))))

(defun revere-chat--show-prompt ()
  "Show the system message this chat's job uses, or would use."
  (let ((text (if (and revere-chat--job (revere-job-messages revere-chat--job))
                  (plist-get (car (revere-job-messages revere-chat--job)) :content)
                (let ((default-directory revere-chat--directory))
                  (revere-loop-system-prompt revere-chat--job)))))
    (with-help-window "*Revere prompt*"
      (princ text))))

(defun revere-chat--answer (granted)
  "Decide the job's oldest pending approval: GRANTED or not."
  (let ((approval (and revere-chat--job (car (revere-approve-pending revere-chat--job)))))
    (if approval
        (revere-approve-decide approval granted)
      (message "Revere: nothing is waiting for your OK"))))

(defun revere-chat--current-model ()
  "The model this chat uses."
  (if revere-chat--job (revere-job-model revere-chat--job) revere-chat--model))

(defun revere-chat-directory (directory)
  "Make the job written here work in DIRECTORY.  Only before it starts."
  (interactive (list (read-directory-name "Revere, work in: " revere-chat--directory nil t)))
  (if revere-chat--job
      (user-error "This job already works in %s; /new starts one elsewhere"
                  (abbreviate-file-name (revere-job-directory revere-chat--job)))
    (setq revere-chat--directory (file-name-as-directory (expand-file-name directory)))
    (setq default-directory revere-chat--directory)
    (revere-chat--note (format "Working in %s." (abbreviate-file-name revere-chat--directory)))
    (force-mode-line-update)))

(defun revere-chat-model (model)
  "Use MODEL for this chat's job."
  (interactive (list (read-string "Model: " (revere-chat--current-model))))
  (if revere-chat--job
      (setf (revere-job-model revere-chat--job) model)
    (setq revere-chat--model model))
  (revere-chat--note (format "Model: %s" model))
  (force-mode-line-update))

(defun revere-chat--current-thinking ()
  "The thinking level this chat uses."
  (or (if revere-chat--job (revere-job-thinking revere-chat--job) revere-chat--thinking) 'off))

(defun revere-chat-thinking (level)
  "Set the thinking level for this chat's job: off, low, medium or high."
  (interactive (list (completing-read "Thinking: " '("off" "low" "medium" "high") nil t)))
  (let ((level (if (stringp level) (intern level) level)))
    (unless (memq level '(off low medium high))
      (user-error "Thinking is off, low, medium or high"))
    (if revere-chat--job
        (setf (revere-job-thinking revere-chat--job) level)
      (setq revere-chat--thinking level))
    (revere-chat--note (format "Thinking: %s" level))
    (force-mode-line-update)))

(defun revere-chat-stop ()
  "Stop the job."
  (interactive)
  (if (and revere-chat--job (revere-job-active-p revere-chat--job))
      (progn
        (revere-loop-interrupt revere-chat--job)
        (revere-chat--note "Stopped."))
    (message "Revere: nothing is running")))

(defun revere-chat--branch-job-p ()
  "Non-nil if this chat's job works on a worktree branch."
  (and revere-chat--job (eq (revere-job-mode revere-chat--job) 'worktree)))

(defun revere-chat-changes ()
  "Review the job's changes as one diff."
  (interactive)
  (cond
   ((null revere-chat--job) (message "Revere: nothing changed yet"))
   ((or (revere-chat--branch-job-p) (revere-ws-pending revere-chat--job))
    (revere-changes-show revere-chat--job))
   (t (message "Revere: nothing changed yet"))))

(defun revere-chat-keep-all ()
  "Keep every change: save the files, or merge the branch."
  (interactive)
  (cond
   ((null revere-chat--job) (message "Revere: nothing to keep"))
   ((revere-chat--branch-job-p)
    (condition-case err
        (progn
          (revere-worktree-keep revere-chat--job)
          (revere-chat--refresh)
          (revere-chat--note "Merged the branch into the project."))
      (error (revere-chat--note (format "Could not merge: %s" (error-message-string err))))))
   (t
    (let ((n (revere-ws-keep-all revere-chat--job)))
      (revere-chat--settle revere-chat--job)
      (revere-chat--refresh)
      (revere-chat--note (format "Kept %d file%s." n (if (= n 1) "" "s")))))))

(defun revere-chat-discard-all ()
  "Discard every change: revert the buffers, or drop the branch."
  (interactive)
  (cond
   ((null revere-chat--job) (message "Revere: nothing to discard"))
   ((revere-chat--branch-job-p)
    (revere-worktree-discard revere-chat--job)
    (revere-chat--refresh)
    (revere-chat--note "Dropped the branch."))
   (t
    (let ((n (revere-ws-discard-all revere-chat--job)))
      (when (eq (revere-job-state revere-chat--job) 'review)
        (revere-job-set-state revere-chat--job 'discarded))
      (revere-chat--refresh)
      (revere-chat--note (format "Discarded %d file%s." n (if (= n 1) "" "s")))))))

(provide 'revere-chat)
;;; revere-chat.el ends here
