;;; revere-tree.el --- Changed files marked in treemacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; When treemacs is around, files a job has changed get a diffstat suffix
;; and a face in the tree, removed again once they are kept or discarded.
;; Nothing here requires treemacs to be installed.

;;; Code:

(require 'revere-job)
(require 'revere-ws)

(declare-function treemacs-set-annotation-suffix "treemacs-annotations")
(declare-function treemacs-remove-annotation-suffix "treemacs-annotations")
(declare-function treemacs-set-annotation-face "treemacs-annotations")
(declare-function treemacs-remove-annotation-face "treemacs-annotations")
(declare-function treemacs-apply-annotations "treemacs-annotations")
(declare-function treemacs-get-local-buffer "treemacs-scope")

(defface revere-tree-changed
  '((t :inherit success))
  "Files in the tree that a job has changed."
  :group 'revere)

(defconst revere-tree--source "revere"
  "The annotation source name Revere uses in treemacs.")

(defvar revere-tree--annotated nil
  "Paths currently carrying a Revere annotation.")

(defun revere-tree-available-p ()
  "Non-nil if treemacs with its annotation API is loaded."
  (and (featurep 'treemacs) (fboundp 'treemacs-set-annotation-suffix)))

(defun revere-tree--apply (path)
  "Redraw PATH's node if a tree is showing."
  (ignore-errors
    (when (treemacs-get-local-buffer)
      (treemacs-apply-annotations path))))

(defun revere-tree-sync (job)
  "Mark JOB's pending changes in the tree and clear marks that no longer apply."
  (when (revere-tree-available-p)
    (let ((current nil))
      (dolist (entry (revere-ws-pending job))
        (let ((path (revere-change-file entry))
              (stat (revere-ws-diffstat entry)))
          (push path current)
          (treemacs-set-annotation-suffix path (format " +%d -%d" (car stat) (cdr stat))
                                          revere-tree--source)
          (treemacs-set-annotation-face path 'revere-tree-changed revere-tree--source)
          (revere-tree--apply path)))
      (dolist (path revere-tree--annotated)
        (unless (member path current)
          (treemacs-remove-annotation-suffix path revere-tree--source)
          (treemacs-remove-annotation-face path revere-tree--source)
          (revere-tree--apply path)))
      (setq revere-tree--annotated current))))

(provide 'revere-tree)
;;; revere-tree.el ends here
