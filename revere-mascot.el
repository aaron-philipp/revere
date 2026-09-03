;;; revere-mascot.el --- The horse at the bottom of the chat -*- lexical-binding: t; coding: utf-8; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; An Atari 2600 style horse, twelve pixels wide and six tall, drawn with
;; half-block characters so it fits three lines.  Head down when there is
;; nothing to do or something failed; head up while it works or waits for
;; you; legs galloping while a job is active.  The sprite is rows of # and
;; . so it can be redrawn by anyone who has drawn a sprite before.

;;; Code:

(require 'cl-lib)
(require 'revere-config)
(require 'revere-job)

(defconst revere-mascot--heads
  '((up   . ("..........##"
             ".......#####"
             "..########.."
             ".#########.."))
    (down . ("............"
             "..#######..."
             ".#########.."
             ".#.#...###..")))
  "The body with the head up or down: pixel rows 0 to 3.")

(defconst revere-mascot--legs
  '((standing . (".#.#...#.#.."
                 ".#.#...#.#.."))
    (stretch  . (".#.#...#.#.."
                 "#.........#."))
    (tuck     . ("..#.....#..."
                 ".#.#...#.#..")))
  "Leg positions: pixel rows 4 and 5.")

(defun revere-mascot--pair (top bottom)
  "The half-block character for a TOP pixel over a BOTTOM pixel."
  (cond ((and top bottom) ?█)
        (top ?▀)
        (bottom ?▄)
        (t ?\s)))

(defun revere-mascot--line (upper lower)
  "One text line from pixel rows UPPER and LOWER."
  (apply #'string
         (cl-loop for i from 0 below (length upper)
                  collect (revere-mascot--pair (eq (aref upper i) ?#)
                                               (eq (aref lower i) ?#)))))

(defun revere-mascot-render (head legs)
  "Three lines of the horse with its HEAD up or down and LEGS in a position."
  (let ((rows (append (alist-get head revere-mascot--heads)
                      (alist-get legs revere-mascot--legs))))
    (list (revere-mascot--line (nth 0 rows) (nth 1 rows))
          (revere-mascot--line (nth 2 rows) (nth 3 rows))
          (revere-mascot--line (nth 4 rows) (nth 5 rows)))))

(defun revere-mascot--frames (head &rest positions)
  "Frames with the HEAD up or down, one per leg position in POSITIONS."
  (mapcar (lambda (legs) (revere-mascot-render head legs)) positions))

(defcustom revere-mascot-frames
  (list (cons 'idle (revere-mascot--frames 'down 'standing))
        (cons 'working (revere-mascot--frames 'up 'stretch 'standing 'tuck 'standing))
        (cons 'writing (revere-mascot--frames 'up 'stretch 'tuck))
        (cons 'tool (revere-mascot--frames 'up 'stretch 'tuck))
        (cons 'waiting (revere-mascot--frames 'up 'standing))
        (cons 'review (revere-mascot--frames 'up 'standing))
        (cons 'done (revere-mascot--frames 'up 'standing))
        (cons 'failed (revere-mascot--frames 'down 'standing)))
  "The mascot: for each mood, one or more frames of three lines each.
Moods are idle, working, writing, tool, waiting, review, done and failed.
Moods with more than one frame animate while the job is active.  Built
from the sprite in this file; replace it with any three-line drawing."
  :type '(alist :key-type symbol :value-type (repeat (list string string string)))
  :group 'revere)

(defcustom revere-mascot-interval 0.3
  "Seconds between animation frames while a job is active."
  :type 'number
  :group 'revere)

(defun revere-mascot-mood (job)
  "The mood JOB puts the mascot in."
  (cond
   ((null job) 'idle)
   (t (pcase (revere-job-state job)
        ('working (let ((detail (or (revere-job-detail job) "")))
                    (cond ((equal detail "writing") 'writing)
                          ((string-prefix-p "running " detail) 'tool)
                          (t 'working))))
        ('waiting 'waiting)
        ('review 'review)
        ('done 'done)
        ('failed 'failed)
        (_ 'idle)))))

(defun revere-mascot-face (mood)
  "The face the horse is drawn in for MOOD."
  (pcase mood
    ((or 'working 'writing 'tool 'waiting) 'revere-state-working)
    ((or 'review 'done) 'revere-state-good)
    ('failed 'revere-state-bad)
    (_ 'revere-dim)))

(defun revere-mascot-lines (job frame)
  "The mascot's three lines for JOB at animation FRAME, with faces."
  (let* ((mood (revere-mascot-mood job))
         (frames (or (alist-get mood revere-mascot-frames)
                     (alist-get 'idle revere-mascot-frames)))
         (lines (nth (mod frame (max 1 (length frames))) frames))
         (face (revere-mascot-face mood)))
    (mapcar (lambda (line) (propertize (copy-sequence line) 'face face)) lines)))

(defun revere-mascot-animated-p (job)
  "Non-nil if JOB's mood has more than one frame."
  (> (length (alist-get (revere-mascot-mood job) revere-mascot-frames)) 1))

(provide 'revere-mascot)
;;; revere-mascot.el ends here
