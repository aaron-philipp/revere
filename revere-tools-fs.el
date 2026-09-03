;;; revere-tools-fs.el --- File, search and shell tools -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; read, edit and write work on buffers through the workspace, so nothing
;; touches disk until the user keeps the changes.  glob and grep search the
;; tree, using ripgrep when it is installed.  shell runs a command
;; asynchronously and reports its exit code and output.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'revere-config)
(require 'revere-job)
(require 'revere-ws)
(require 'revere-tools)

(defun revere-tools-fs--expand (path job)
  "PATH made absolute against JOB's directory."
  (expand-file-name path (revere-job-directory job)))

;;;; read

(revere-deftool read ((path string "File to read, absolute or relative to the job directory")
                      (start_line integer "First line to return, counting from 1" :optional t)
                      (line_count integer "How many lines to return" :optional t))
  "Read a file as numbered lines.
Page long files with start_line and line_count.  Reads the live buffer if
the file is open, so it sees unsaved edits."
  (let* ((job (revere-tools-job))
         (full (revere-tools-fs--expand path job)))
    (unless (or (file-readable-p full) (revere-ws-entry job full))
      (error "read: no such file: %s" path))
    (let ((buffer (revere-ws-visit job full)))
      (revere-ws-mark-seen job buffer)
      (with-current-buffer buffer
        (revere-tools-fs--numbered-lines (or start_line 1)
                                         (or line_count revere-read-limit))))))

(defun revere-tools-fs--numbered-lines (start count)
  "Return COUNT lines of the current buffer from line START, numbered."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- start))
    (let ((total (count-lines (point-min) (point-max)))
          (lines nil)
          (n start))
      (while (and (not (eobp)) (< (- n start) count))
        (push (format "%d\t%s" n (buffer-substring-no-properties
                                  (line-beginning-position) (line-end-position)))
              lines)
        (cl-incf n)
        (forward-line 1))
      (let ((text (string-join (nreverse lines) "\n"))
            (left (- total (1- n))))
        (if (> left 0)
            (format "%s\n... %d more line%s" text left (if (= left 1) "" "s"))
          text)))))

;;;; edit

(revere-deftool edit ((path string "File to change")
                      (old_string string "Exact text to find, including enough context to be unique")
                      (new_string string "Text to put in its place")
                      (replace_all boolean "Replace every match instead of requiring exactly one" :optional t))
  "Replace text in a file.
The change stays in the buffer; the user keeps or discards it later.  Fails
if old_string is missing, or matches more than once without replace_all."
  (when (string-empty-p old_string)
    (error "edit: old_string is empty"))
  (let* ((job (revere-tools-job))
         (full (revere-tools-fs--expand path job)))
    (unless (or (file-exists-p full) (revere-ws-entry job full))
      (error "edit: no such file: %s" path))
    (let ((buffer (revere-ws-visit job full)))
      (revere-ws-check-fresh job buffer)
      (with-current-buffer buffer
        (let ((count (revere-tools-fs--count-matches old_string)))
          (cond
           ((zerop count)
            (error "edit: old_string not found in %s" path))
           ((and (> count 1) (not replace_all))
            (error "edit: old_string matches %d times in %s; add context or set replace_all"
                   count path)))
          (let ((n (revere-tools-fs--replace old_string new_string replace_all)))
            (revere-ws-touch job buffer)
            (format "Edited %s: %d replacement%s (unsaved)" path n (if (= n 1) "" "s"))))))))

(defun revere-tools-fs--count-matches (text)
  "How many times TEXT occurs literally in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search nil) (n 0))
      (while (search-forward text nil t)
        (cl-incf n))
      n)))

(defun revere-tools-fs--replace (old new all)
  "Replace OLD with NEW in the current buffer, every match if ALL.
Return how many replacements were made."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search nil) (n 0))
      (while (search-forward old nil t)
        (replace-match new t t)
        (cl-incf n)
        (unless all (goto-char (point-max))))
      n)))

;;;; write

(revere-deftool write ((path string "File to create or overwrite")
                       (content string "The complete new content"))
  "Create or overwrite a file with content.
It stays in the buffer until the user keeps it.  Prefer edit for changes
to an existing file."
  (let* ((job (revere-tools-job))
         (full (revere-tools-fs--expand path job))
         (buffer (revere-ws-visit job full)))
    (revere-ws-check-fresh job buffer)
    (with-current-buffer buffer
      (erase-buffer)
      (insert content))
    (revere-ws-touch job buffer)
    (format "Wrote %d characters to %s (unsaved)" (length content) path)))

;;;; glob

(revere-deftool glob ((pattern string "Glob such as src/**/*.el, matched against paths relative to path")
                      (path string "Directory to search; default is the job directory" :optional t))
  "List files matching a glob pattern.
Skips version-control and dependency directories."
  (let* ((job (revere-tools-job))
         (root (file-name-as-directory (revere-tools-fs--expand (or path ".") job)))
         (regexp (revere-tools-fs--glob-regexp pattern))
         (hits nil))
    (dolist (file (revere-tools-fs--walk root))
      (let ((relative (file-relative-name file root)))
        (when (string-match-p regexp relative)
          (push relative hits))))
    (if hits
        (string-join (seq-take (sort hits #'string<) revere-glob-limit) "\n")
      "No matches")))

(defun revere-tools-fs--walk (root)
  "Every regular file under ROOT, skipping `revere-glob-skip' directories."
  (directory-files-recursively
   root "" nil
   (lambda (dir)
     (not (member (file-name-nondirectory (directory-file-name dir)) revere-glob-skip)))))

(defun revere-tools-fs--glob-regexp (pattern)
  "Translate glob PATTERN into an anchored regexp on relative paths."
  (let ((parts nil) (i 0) (n (length pattern)))
    (while (< i n)
      (cond
       ((string-prefix-p "**/" (substring pattern i))
        (push "\\(?:.*/\\)?" parts) (cl-incf i 3))
       ((string-prefix-p "**" (substring pattern i))
        (push ".*" parts) (cl-incf i 2))
       ((eq (aref pattern i) ?*)
        (push "[^/]*" parts) (cl-incf i))
       ((eq (aref pattern i) ??)
        (push "[^/]" parts) (cl-incf i))
       (t
        (push (regexp-quote (string (aref pattern i))) parts) (cl-incf i))))
    (concat "\\`" (apply #'concat (nreverse parts)) "\\'")))

;;;; grep

(revere-deftool grep ((pattern string "Regular expression to search for")
                      (path string "Directory or file to search; default is the job directory" :optional t)
                      (include string "Only search files matching this glob, such as *.el" :optional t))
  "Search file contents with a regular expression.
Returns file:line:text lines, at most `revere-grep-limit' of them."
  (let* ((job (revere-tools-job))
         (root (revere-tools-fs--expand (or path ".") job))
         (local (file-local-name root)))
    (if (executable-find "rg" (file-remote-p root))
        (revere-tools-fs--search "rg"
                                 (append (list "--no-heading" "--line-number" "--color" "never"
                                               "--no-messages" "-e" pattern)
                                         (when include (list "-g" include))
                                         (list local))
                                 root)
      (revere-tools-fs--search "grep"
                               (append (list "-rnE" "-e" pattern)
                                       (when include (list (concat "--include=" include)))
                                       (list local))
                               root))))

(defun revere-tools-fs--search (program args root)
  "Run PROGRAM with ARGS where ROOT is and return matches relative to ROOT."
  (with-temp-buffer
    (let* ((default-directory (file-name-as-directory root))
           (status (apply #'process-file program nil t nil args)))
      (pcase status
        (0 (revere-tools-fs--limit-matches (buffer-string) root))
        (1 "No matches")
        (_ (error "grep failed (%s): %s" status (string-trim (buffer-string))))))))

(defun revere-tools-fs--limit-matches (output root)
  "Trim OUTPUT to `revere-grep-limit' lines with paths relative to ROOT."
  (let* ((lines (split-string output "\n" t))
         (shown (seq-take lines revere-grep-limit))
         (prefix (file-name-as-directory (file-local-name root)))
         (relative (mapcar (lambda (line)
                             (if (string-prefix-p prefix line t)
                                 (substring line (length prefix))
                               line))
                           shown)))
    (concat (string-join relative "\n")
            (if (> (length lines) revere-grep-limit)
                (format "\n... %d more matching lines" (- (length lines) revere-grep-limit))
              ""))))

;;;; shell

(revere-deftool shell ((command string "Command line to run with the system shell")
                       (cwd string "Working directory; default is the job directory" :optional t)
                       (timeout integer "Seconds before the command is killed" :optional t))
  "Run a shell command and return its exit code and output.
Long output is truncated.  The command is killed after the timeout."
  :async t
  (let* ((job (revere-tools-job))
         (default-directory (file-name-as-directory
                             (revere-tools-fs--expand (or cwd ".") job)))
         (buffer (generate-new-buffer " *revere-shell*"))
         (process (start-file-process-shell-command "revere-shell" buffer command))
         (timer nil))
    (set-process-query-on-exit-flag process nil)
    (setq timer (run-at-time (or timeout revere-shell-timeout) nil
                             #'revere-tools-fs--kill-timed-out process))
    (set-process-sentinel
     process
     (lambda (proc _event)
       (unless (process-live-p proc)
         (cancel-timer timer)
         (funcall callback (revere-tools-fs--shell-report proc buffer)))))
    process))

(defun revere-tools-fs--kill-timed-out (process)
  "Kill PROCESS because its timeout passed."
  (when (process-live-p process)
    (process-put process :timed-out t)
    (delete-process process)))

(defun revere-tools-fs--shell-report (process buffer)
  "Build the result text for finished PROCESS whose output is in BUFFER."
  (let ((output (with-current-buffer buffer (buffer-string)))
        (code (process-exit-status process)))
    (kill-buffer buffer)
    (format "exit=%d%s\n%s"
            code
            (if (process-get process :timed-out) " (timed out)" "")
            (if (string-empty-p (string-trim output)) "(no output)" output))))

(provide 'revere-tools-fs)
;;; revere-tools-fs.el ends here
