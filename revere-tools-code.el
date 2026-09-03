;;; revere-tools-code.el --- Problems, and tools that look at Emacs itself -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; `problems' feeds the editor's own checkers back to the model: flymake,
;; or flycheck where it is on.  `describe', `apropos' and `eval' let the
;; model read and use Emacs directly instead of guessing.  `define-tool'
;; lets it add a tool, gated by the byte compiler and ert.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'flymake)
(require 'bytecomp)
(require 'ert)
(require 'help-fns)
(require 'revere-config)
(require 'revere-job)
(require 'revere-ws)
(require 'revere-tools)

(declare-function flycheck-buffer "flycheck")
(declare-function flycheck-error-line "flycheck")
(declare-function flycheck-error-level "flycheck")
(declare-function flycheck-error-message "flycheck")

(defcustom revere-problems-wait 2
  "Seconds to give the checkers after starting them before reporting."
  :type 'number
  :group 'revere)

;;;; problems

(revere-deftool problems ((path string "One file to check; default is every file changed so far"
                                :optional t))
  "Report errors and warnings in the changed files, from the editor's checkers.
Run it after editing code and before saying you are done.  For Emacs Lisp
the byte compiler only checks files Emacs trusts; see `trusted-content'."
  :async t
  (let* ((job (revere-tools-job))
         (buffers (revere-tools-code--buffers job path)))
    (if (null buffers)
        (funcall callback "No changed files to check.")
      (dolist (buffer buffers)
        (revere-tools-code--start-check buffer))
      (run-at-time revere-problems-wait nil
                   (lambda ()
                     (funcall callback (revere-tools-code--report job buffers)))))))

(defun revere-tools-code--buffers (job path)
  "The buffers to check for JOB: PATH's, or every pending change's."
  (if path
      (list (revere-ws-visit job (expand-file-name path (revere-job-directory job))))
    (cl-remove-if-not #'buffer-live-p
                      (mapcar #'revere-change-buffer (revere-ws-pending job)))))

(defun revere-tools-code--start-check (buffer)
  "Ask BUFFER's checker to run now."
  (with-current-buffer buffer
    (cond
     ((bound-and-true-p flycheck-mode)
      (flycheck-buffer))
     (t
      (unless flymake-mode (flymake-mode 1))
      (flymake-start)))))

(defun revere-tools-code--diagnostics (buffer)
  "Diagnostics in BUFFER as (LINE LEVEL TEXT) triples."
  (with-current-buffer buffer
    (if (bound-and-true-p flycheck-mode)
        (mapcar (lambda (err)
                  (list (flycheck-error-line err)
                        (symbol-name (flycheck-error-level err))
                        (flycheck-error-message err)))
                (symbol-value 'flycheck-current-errors))
      (mapcar (lambda (diagnostic)
                (list (line-number-at-pos (flymake-diagnostic-beg diagnostic))
                      (string-remove-prefix ":" (symbol-name (flymake-diagnostic-type diagnostic)))
                      (flymake-diagnostic-text diagnostic)))
              (flymake-diagnostics)))))

(defun revere-tools-code--report (job buffers)
  "The problems in BUFFERS of JOB as text."
  (let ((lines nil))
    (dolist (buffer buffers)
      (let ((name (file-relative-name (buffer-file-name buffer) (revere-job-root job))))
        (dolist (diagnostic (sort (revere-tools-code--diagnostics buffer)
                                  (lambda (a b) (< (car a) (car b)))))
          (push (format "%s:%d: %s: %s" name (nth 0 diagnostic) (nth 1 diagnostic)
                        (replace-regexp-in-string "\n" " " (nth 2 diagnostic)))
                lines))))
    (if lines
        (format "%d problem%s:\n%s" (length lines) (if (= 1 (length lines)) "" "s")
                (string-join (nreverse lines) "\n"))
      (format "No problems in %d file%s." (length buffers) (if (= 1 (length buffers)) "" "s")))))

;;;; describe and apropos

(defun revere-tools-code--doc (symbol)
  "SYMBOL's documentation, or a note that there is none."
  (or (condition-case nil
          (if (fboundp symbol)
              (documentation symbol t)
            (documentation-property symbol 'variable-documentation t))
        (error nil))
      "(no documentation)"))

(defun revere-tools-code--first-doc-line (symbol)
  "The first line of SYMBOL's documentation."
  (car (split-string (revere-tools-code--doc symbol) "\n")))

(revere-deftool describe ((name string "Function or variable name"))
  "Describe an Emacs function or variable: its arguments and documentation.
Use it instead of guessing an API."
  (let ((symbol (intern-soft name)))
    (cond
     ((null symbol) (format "Nothing is called %s" name))
     ((fboundp symbol)
      (format "%s is a function%s.\nArguments: %S\n\n%s"
              name
              (if (commandp symbol) " and a command" "")
              (help-function-arglist symbol t)
              (revere-tools-code--doc symbol)))
     ((boundp symbol)
      (format "%s is a variable.\nValue: %s\n\n%s"
              name
              (truncate-string-to-width (prin1-to-string (symbol-value symbol)) 200 nil nil "…")
              (revere-tools-code--doc symbol)))
     (t (format "%s is neither a function nor a variable" name)))))

(revere-deftool apropos ((pattern string "Regular expression matched against symbol names")
                         (kind string "functions, variables or all; default all" :optional t))
  "Find Emacs functions and variables by name, with the first line of their docs."
  (let* ((test (pcase kind
                 ("functions" #'fboundp)
                 ("variables" #'boundp)
                 (_ (lambda (symbol) (or (fboundp symbol) (boundp symbol))))))
         (symbols (sort (apropos-internal pattern test)
                        (lambda (a b) (string< (symbol-name a) (symbol-name b)))))
         (limit 60))
    (if (null symbols)
        "No matches"
      (concat (mapconcat (lambda (symbol)
                           (format "%s%s: %s" symbol
                                   (if (fboundp symbol) "" " (variable)")
                                   (revere-tools-code--first-doc-line symbol)))
                         (seq-take symbols limit) "\n")
              (if (> (length symbols) limit)
                  (format "\n... %d more" (- (length symbols) limit))
                "")))))

;;;; eval

(defun revere-tools-code--read-all (source)
  "Every form in SOURCE."
  (with-temp-buffer
    (insert source)
    (goto-char (point-min))
    (let (forms)
      (condition-case nil
          (while t (push (read (current-buffer)) forms))
        (end-of-file nil))
      (nreverse forms))))

(revere-deftool eval ((form string "Emacs Lisp to evaluate; several forms are allowed"))
  "Evaluate Emacs Lisp in the running Emacs and return the printed value.
Use it to inspect or change Emacs itself; prefer the other tools for files."
  (condition-case err
      (let ((value (with-timeout (30 (error "Timed out after 30 seconds"))
                     (eval (cons 'progn (revere-tools-code--read-all form)) t))))
        (let ((print-length 200) (print-level 8))
          (truncate-string-to-width (prin1-to-string value) 4000 nil nil "…")))
    (error (format "Error: %s" (error-message-string err)))))

;;;; define-tool

(defun revere-tools-code--compile-warnings (source)
  "Byte-compile SOURCE in a temp file and return the warnings, or nil."
  (let ((file (make-temp-file "revere-tool-" nil ".el"))
        (log (get-buffer-create "*Compile-Log*")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert ";;; -*- lexical-binding: t -*-\n(require 'revere-tools)\n" source "\n"))
          (with-current-buffer log
            (let ((inhibit-read-only t)) (erase-buffer)))
          (let ((byte-compile-error-on-warn nil)
                (byte-compile-verbose nil)
                (inhibit-message t))
            (byte-compile-file file))
          (with-current-buffer log
            (let ((lines (cl-remove-if-not
                          (lambda (line) (string-match-p "\\(Warning\\|Error\\):" line))
                          (split-string (buffer-string) "\n" t))))
              (and lines (string-join lines "\n")))))
      (ignore-errors (delete-file file))
      (ignore-errors (delete-file (byte-compile-dest-file file))))))

(defun revere-tools-code--run-tests (names)
  "Run the ert tests NAMES; return how many failed."
  (if (null names)
      0
    (let ((stats (ert-run-tests `(member ,@names) (lambda (&rest _) nil))))
      (ert-stats-completed-unexpected stats))))

(defun revere-tools-code-define (source)
  "Define the tool in SOURCE if it compiles cleanly and its tests pass."
  (let* ((forms (revere-tools-code--read-all source))
         (definition (car forms)))
    (unless (and (consp definition) (eq (car definition) 'revere-deftool))
      (error "The source must start with a revere-deftool form"))
    (let ((warnings (revere-tools-code--compile-warnings source)))
      (when warnings
        (error "The compiler complained:\n%s" warnings)))
    (dolist (form forms)
      (eval form t))
    (let* ((name (symbol-name (cadr definition)))
           (tests (mapcar #'cadr (cl-remove-if-not (lambda (form) (eq (car form) 'ert-deftest)) forms)))
           (failed (revere-tools-code--run-tests tests)))
      (if (> failed 0)
          (progn
            (remhash name revere-tools--registry)
            (error "%d of %d test%s failed; the tool was not kept"
                   failed (length tests) (if (= 1 (length tests)) "" "s")))
        (format "Defined tool %s%s" name
                (if tests (format "; %d test%s passed" (length tests) (if (= 1 (length tests)) "" "s")) ""))))))

(revere-deftool define-tool ((source string "Emacs Lisp: one revere-deftool form, then optional ert-deftest forms"))
  "Add a new tool from Emacs Lisp source.
It must byte-compile without warnings and its tests must pass; then it is
available at once, like any other tool."
  (revere-tools-code-define source))

(provide 'revere-tools-code)
;;; revere-tools-code.el ends here
