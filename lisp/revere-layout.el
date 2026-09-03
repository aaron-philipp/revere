;;; revere-layout.el --- Where Revere's buffers go -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; The chat starts in the main window, full width, and docks itself to a
;; side window the first time Revere shows you a file, so the file can take
;; the main window (`revere-chat-dock').  /side and /wide, or C-c C-w, move
;; it by hand.  The changes buffer and tool output open at the bottom.  All
;; of it is ordinary `display-buffer' machinery and can be overridden.

;;; Code:

(require 'revere-config)

(defvar display-line-numbers-type)

(defcustom revere-chat-side 'right
  "Which side of the frame the chat docks to."
  :type '(choice (const right) (const left) (const bottom))
  :group 'revere)

(defcustom revere-chat-window-size 0.4
  "Width (or height, at the bottom) of the docked chat as a fraction."
  :type 'number
  :group 'revere)

(defcustom revere-chat-dock 'on-follow
  "When the chat moves from the main window to the side.
`on-follow': the first time Revere shows you a file it is working on.
`always': as soon as the chat opens.  `never': only when you ask with /side."
  :type '(choice (const on-follow) (const always) (const never))
  :group 'revere)

(defcustom revere-follow t
  "Show the file Revere is reading or editing in the main window as it works."
  :type 'boolean
  :group 'revere)

(defun revere-layout-setup ()
  "Install Revere's window rules for the changes buffer and tool output."
  (setq display-buffer-alist
        (cl-remove-if (lambda (rule) (and (stringp (car rule))
                                          (string-prefix-p "\\`\\*Revere" (car rule))))
                      display-buffer-alist))
  (push '("\\`\\*Revere: changes"
          (display-buffer-reuse-window display-buffer-in-side-window)
          (side . bottom) (slot . 0) (window-height . 0.35))
        display-buffer-alist)
  (push '("\\`\\*Revere: \\(?:grep\\|shell\\|files\\|approvals\\)"
          (display-buffer-reuse-window display-buffer-in-side-window)
          (side . bottom) (slot . 1) (window-height . 0.3))
        display-buffer-alist))

(defun revere-layout-docked-p (buffer)
  "Non-nil if BUFFER is showing in a side window."
  (let ((window (get-buffer-window buffer)))
    (and window (window-parameter window 'window-side))))

(defun revere-layout-dock (buffer)
  "Move BUFFER to its side window and select it.  Return the window."
  (if (revere-layout-docked-p buffer)
      (get-buffer-window buffer)
    (let* ((old (get-buffer-window buffer))
           (window (display-buffer-in-side-window
                    buffer
                    (list (cons 'side revere-chat-side)
                          (cons 'slot 0)
                          (cons (if (eq revere-chat-side 'bottom) 'window-height 'window-width)
                                revere-chat-window-size)))))
      (when (and old window (not (eq old window)) (window-live-p old))
        (switch-to-prev-buffer old))
      (when window (select-window window))
      window)))

(defun revere-layout-undock (buffer)
  "Bring BUFFER out of its side window into the main window and select it."
  (let ((window (get-buffer-window buffer)))
    (when (and window (window-parameter window 'window-side))
      (delete-window window))
    (pop-to-buffer-same-window buffer)))

(defun revere-layout-show-chat (buffer)
  "Show the chat BUFFER where it belongs and select it."
  (cond
   ((revere-layout-docked-p buffer) (select-window (get-buffer-window buffer)))
   ((eq revere-chat-dock 'always) (revere-layout-dock buffer))
   (t (pop-to-buffer-same-window buffer))))

(defun revere-layout-show-file (buffer &optional position)
  "Show BUFFER in a main window without selecting it; move its point to POSITION."
  (let ((window (display-buffer buffer
                                '((display-buffer-reuse-window
                                   display-buffer-use-some-window
                                   display-buffer-pop-up-window)
                                  (inhibit-same-window . t)
                                  (some-window . mru)))))
    (when (and window position)
      (set-window-point window position))
    window))

(defun revere-layout-show-tool-buffer (buffer)
  "Show BUFFER, tool output, at the bottom without selecting it."
  (display-buffer buffer))

(revere-layout-setup)

(defun revere-layout-no-line-numbers ()
  "Keep line numbers out of the current buffer, even under the global mode.
The global mode turns itself on after a major mode's own setup and copies
`display-line-numbers-type', so a buffer-local nil there holds."
  (setq-local display-line-numbers-type nil)
  (setq-local display-line-numbers nil))

(provide 'revere-layout)
;;; revere-layout.el ends here
