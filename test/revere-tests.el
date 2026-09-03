;;; revere-tests.el --- Offline tests for Revere -*- lexical-binding: t; -*-

;;; Commentary:

;; No network.  The model is faked where the loop is under test.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'revere)

;; The chat tests type on the input line; minibuffer input has its own test.
(setq revere-chat-input 'buffer)

;; Keep the tests away from the user's real ~/.revere.
(defvar revere-tests--home (file-name-as-directory (make-temp-file "revere-tests-home-" t))
  "A throwaway `revere-directory' for the whole test run.")
(setq revere-directory revere-tests--home)

;;;; Helpers

(defun revere-tests--cleanup (dir)
  "Kill buffers visiting files under DIR, then delete DIR."
  (let ((prefix (downcase (file-truename dir))))
    (dolist (buffer (buffer-list))
      (let ((file (buffer-file-name buffer)))
        (when (and file (string-prefix-p prefix (downcase (file-truename file))))
          (with-current-buffer buffer
            (set-buffer-modified-p nil))
          (kill-buffer buffer)))))
  ;; On Windows a just-finished shell can still hold the directory open.
  (let ((tries 0))
    (while (and (file-directory-p dir) (< tries 20))
      (condition-case nil
          (delete-directory dir t)
        (error (cl-incf tries)
               (accept-process-output nil 0.25))))))

(defmacro revere-tests--with-dir (dir &rest body)
  "Run BODY with DIR bound to a fresh temporary directory."
  (declare (indent 1))
  `(let ((,dir (file-name-as-directory (make-temp-file "revere-test-" t))))
     (unwind-protect
         (progn ,@body)
       (revere-tests--cleanup ,dir))))

(defun revere-tests--write (dir name content)
  "Write CONTENT to NAME under DIR and return the path."
  (let ((file (expand-file-name name dir)))
    (make-directory (file-name-directory file) t)
    (write-region content nil file nil 'silent)
    file))

(defun revere-tests--read (file)
  "The contents of FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun revere-tests--wait (predicate &optional seconds)
  "Let timers and processes run until PREDICATE is true or SECONDS pass."
  (let ((deadline (+ (float-time) (or seconds 10))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall predicate)))

(defun revere-tests--fresh-file (file)
  "Forget any buffer visiting FILE so a test can rewrite it from scratch."
  (let ((buffer (find-buffer-visiting file)))
    (when buffer
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer)))
  (when (file-exists-p file) (delete-file file)))

(defun revere-tests--lines (n)
  "N lines reading `line K'."
  (concat (mapconcat (lambda (i) (format "line %d" i)) (number-sequence 1 n) "\n") "\n"))

(defun revere-tests--usage (in out)
  "A usage table with IN prompt tokens and OUT completion tokens."
  (let ((table (make-hash-table :test 'equal)))
    (puthash "prompt_tokens" in table)
    (puthash "completion_tokens" out table)
    table))

(defun revere-tests--job (dir)
  "A job working in DIR."
  (revere-job-create "test" dir))

;;;; Workspace

(ert-deftest revere-ws/edit-stays-in-buffer ()
  "An edit changes the buffer, not the disk, until it is kept."
  (revere-tests--with-dir dir
    (let ((file (revere-tests--write dir "a.txt" "hello world\n"))
          (job (revere-tests--job dir)))
      (let ((revere-current-job job))
        (should (string-match-p "1 replacement" (revere-tool-edit "a.txt" "hello" "hi" nil))))
      (should (string= (revere-tests--read file) "hello world\n"))
      (let ((entries (revere-ws-pending job)))
        (should (= (length entries) 1))
        (with-current-buffer (revere-change-buffer (car entries))
          (should (string= (buffer-string) "hi world\n")))
        (let ((diff (revere-ws-diff (car entries))))
          (should (string-match-p "^-hello world" diff))
          (should (string-match-p "^\\+hi world" diff))
          (should (equal (revere-ws--count-diff diff) '(1 . 1))))
        (revere-ws-keep-file job (car entries)))
      (should (string= (revere-tests--read file) "hi world\n"))
      (should (null (revere-ws-pending job))))))

(ert-deftest revere-ws/discard-restores-buffer ()
  "Discarding undoes the job's edits and leaves the buffer unmodified."
  (revere-tests--with-dir dir
    (let ((file (revere-tests--write dir "a.txt" "hello world\n"))
          (job (revere-tests--job dir)))
      (let ((revere-current-job job))
        (revere-tool-edit "a.txt" "hello" "hi" nil))
      (let ((entry (car (revere-ws-pending job))))
        (revere-ws-discard-file job entry)
        (with-current-buffer (revere-change-buffer entry)
          (should (string= (buffer-string) "hello world\n"))
          (should-not (buffer-modified-p))))
      (should (string= (revere-tests--read file) "hello world\n"))
      (should (null (revere-ws-pending job))))))

(ert-deftest revere-ws/stale-buffer-is-refused ()
  "An edit after the user typed in the buffer fails until it is read again."
  (revere-tests--with-dir dir
    (revere-tests--write dir "a.txt" "hello world\n")
    (let ((job (revere-tests--job dir)))
      (let ((revere-current-job job))
        (revere-tool-edit "a.txt" "hello" "hi" nil)
        (with-current-buffer (revere-change-buffer (car (revere-ws-pending job)))
          (goto-char (point-max))
          (insert "typed by the user\n"))
        (should-error (revere-tool-edit "a.txt" "world" "there" nil) :type 'error)
        (revere-tool-read "a.txt" nil nil)
        (should (string-match-p "1 replacement" (revere-tool-edit "a.txt" "world" "there" nil)))))))

(ert-deftest revere-ws/new-file-keep-and-discard ()
  "Writing a new file creates it on keep and leaves nothing on discard."
  (revere-tests--with-dir dir
    (let ((job (revere-tests--job dir)))
      (let ((revere-current-job job))
        (revere-tool-write "new/b.txt" "brand new\n")
        (revere-tool-write "c.txt" "never kept\n"))
      (let ((entries (revere-ws-pending job)))
        (should (= (length entries) 2))
        (should (revere-change-created-p (car entries)))
        (should (string-match-p "^\\+brand new" (revere-ws-diff (car entries))))
        (revere-ws-keep-file job (car entries))
        (revere-ws-discard-file job (cadr entries)))
      (should (string= (revere-tests--read (expand-file-name "new/b.txt" dir)) "brand new\n"))
      (should-not (file-exists-p (expand-file-name "c.txt" dir)))
      (should (null (revere-ws-pending job))))))

;;;; Changes buffer

(ert-deftest revere-changes/discard-one-hunk-keep-the-rest ()
  "k reverts one hunk in the live buffer; C-c C-c saves what remains."
  (skip-unless (executable-find diff-command))
  (revere-tests--with-dir dir
    (let ((file (revere-tests--write dir "long.txt" (revere-tests--lines 30)))
          (job (revere-tests--job dir)))
      (let ((revere-current-job job))
        (revere-tool-edit "long.txt" "line 2\n" "LINE 2\n" nil)
        (revere-tool-edit "long.txt" "line 28\n" "LINE 28\n" nil))
      (let ((buffer (revere-changes-buffer job)))
        (revere-changes-render buffer)
        (with-current-buffer buffer
          (should (= (count-matches "^@@" (point-min) (point-max)) 2))
          (goto-char (point-min))
          (re-search-forward "^@@")
          (forward-line 1)
          (revere-changes-discard-hunk)
          (should (= (count-matches "^@@" (point-min) (point-max)) 1)))
        (with-current-buffer (revere-change-buffer (car (revere-ws-pending job)))
          (should (string-match-p "^line 2$" (buffer-string)))
          (should (string-match-p "^LINE 28$" (buffer-string))))
        (revere-job-set-state job 'review)
        (with-current-buffer buffer
          (revere-changes-keep-all))
        (should (eq (revere-job-state job) 'done))
        (let ((disk (revere-tests--read file)))
          (should (string-match-p "^line 2$" disk))
          (should (string-match-p "^LINE 28$" disk)))))))

;;;; Tools

(ert-deftest revere-tools/schema-shape ()
  "A tool's schema names required arguments and serializes to JSON."
  (let* ((schema (revere-tools-schema (revere-tools-get "edit")))
         (function (plist-get schema :function))
         (parameters (plist-get function :parameters))
         (required (append (plist-get parameters :required) nil)))
    (should (equal (plist-get function :name) "edit"))
    (should (member "path" required))
    (should (member "old_string" required))
    (should-not (member "replace_all" required))
    (should (string-match-p "\"replace_all\"" (json-serialize schema)))))

(ert-deftest revere-tools/parse-args ()
  "JSON arguments decode to a table; garbage decodes to an empty one."
  (let ((table (revere-tools-parse-args "{\"a\":1,\"b\":true,\"c\":null}")))
    (should (= (gethash "a" table) 1))
    (should (eq (gethash "b" table) t))
    (should (null (gethash "c" table))))
  (should (= (hash-table-count (revere-tools-parse-args "not json")) 0)))

(ert-deftest revere-tools/rules-gate-calls ()
  "A tool ruled never is refused; an unknown tool is reported."
  (let (result)
    (let ((revere-rules '((t . never))))
      (revere-tools-call "read" "{}" (lambda (r) (setq result r))))
    (should (string-match-p "not allowed" result))
    (revere-tools-call "nope" "{}" (lambda (r) (setq result r)))
    (should (string-match-p "no tool called nope" result))))

(ert-deftest revere-tools/missing-argument-is-an-error-result ()
  "A call without a required argument returns an error string, not a signal."
  (let (result)
    (let ((revere-rules '((t . go-ahead))))
      (revere-tools-call "read" "{}" (lambda (r) (setq result r))))
    (should (string-match-p "Missing argument: path" result))))

(ert-deftest revere-tools-fs/glob-regexp ()
  "Globs translate with ** crossing directories and * staying inside one."
  (let ((deep (revere-tools-fs--glob-regexp "**/*.el"))
        (flat (revere-tools-fs--glob-regexp "*.el")))
    (should (string-match-p deep "a.el"))
    (should (string-match-p deep "src/b.el"))
    (should-not (string-match-p deep "src/b.txt"))
    (should (string-match-p flat "a.el"))
    (should-not (string-match-p flat "src/a.el"))))

(ert-deftest revere-tools-fs/read-glob-grep ()
  "read numbers lines; glob and grep find files and matches."
  (skip-unless (or (executable-find "rg") (executable-find "grep")))
  (revere-tests--with-dir dir
    (revere-tests--write dir "a.el" "(defun foo ()\n  (bar 1))\n")
    (revere-tests--write dir "src/b.el" "(baz 2)\n")
    (revere-tests--write dir "node_modules/x.el" "(bar 3)\n")
    (let ((revere-current-job (revere-tests--job dir)))
      (should (string= (revere-tool-read "src/b.el" nil nil) "1\t(baz 2)"))
      (let ((files (revere-tool-glob "**/*.el" nil)))
        (should (string-match-p "^a\\.el$" files))
        (should (string-match-p "^src/b\\.el$" files))
        (should-not (string-match-p "node_modules" files)))
      (let ((hits (revere-tool-grep "bar" nil "*.el")))
        (should (string-match-p "a\\.el:2:" hits))))))

(ert-deftest revere-tools-fs/shell-reports-exit-and-output ()
  "shell runs asynchronously and reports the exit code and output."
  (revere-tests--with-dir dir
    (let ((revere-current-job (revere-tests--job dir))
          (result nil))
      (revere-tool-shell (lambda (r) (setq result r)) "echo revere-marker" nil nil)
      (should (revere-tests--wait (lambda () result)))
      (should (string-match-p "exit=0" result))
      (should (string-match-p "revere-marker" result)))))

;;;; Transport

(ert-deftest revere-llm/sse-text-usage-and-done ()
  "Text fragments accumulate, usage is kept, [DONE] finishes once."
  (let ((state (revere-llm-state--make))
        (deltas nil) (done nil))
    (let ((opts (list :on-delta (lambda (text) (push text deltas))
                      :on-done (lambda (text calls usage) (setq done (list text calls usage))))))
      (revere-llm--feed state "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n" opts)
      (revere-llm--feed state "data: {\"choices\":[{\"delta\":{\"con" opts)
      (revere-llm--feed state "tent\":\"lo\"}}]}\r\n\r\n" opts)
      (revere-llm--feed state "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5}}\n" opts)
      (revere-llm--feed state "data: [DONE]\n" opts)
      (revere-llm--feed state "data: [DONE]\n" opts))
    (should (equal (apply #'concat (reverse deltas)) "Hello"))
    (should (equal (nth 0 done) "Hello"))
    (should (null (nth 1 done)))
    (should (= (gethash "prompt_tokens" (nth 2 done)) 10))))

(ert-deftest revere-llm/sse-merges-tool-call-fragments ()
  "Fragments of one tool call are merged by index."
  (let ((state (revere-llm-state--make))
        (done nil))
    (let ((opts (list :on-done (lambda (text calls usage) (setq done (list text calls usage))))))
      (revere-llm--feed state "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"pa\"}}]}}]}\n" opts)
      (revere-llm--feed state "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"th\\\":\\\"/x\\\"}\"}}]}}]}\n" opts)
      (revere-llm--feed state "data: [DONE]\n" opts))
    (let ((calls (nth 1 done)))
      (should (= (length calls) 1))
      (should (equal (plist-get (car calls) :id) "c1"))
      (should (equal (plist-get (car calls) :name) "read"))
      (should (equal (plist-get (car calls) :arguments) "{\"path\":\"/x\"}")))))

(ert-deftest revere-llm/error-body-is-reported ()
  "A non-SSE JSON error body becomes an error message."
  (let ((state (revere-llm-state--make)))
    (revere-llm--feed state "{\"error\":{\"message\":\"bad key\"}}\n" nil)
    (should (equal (revere-llm--error-in-raw state) "bad key"))))

(ert-deftest revere-llm/build-request ()
  "The request body streams, asks for usage, and carries tools and effort."
  (let* ((messages (list (list :role "user" :content "hi")))
         (tools (list (list :type "function" :function (list :name "t"))))
         (revere-thinking-level 'medium)
         (body (revere-llm-build-request "m" messages tools)))
    (should (string-match-p "\"stream\":true" body))
    (should (string-match-p "\"include_usage\":true" body))
    (should (string-match-p "\"tools\":\\[" body))
    (should (string-match-p "\"reasoning_effort\":\"medium\"" body)))
  (let ((revere-thinking-level 'off))
    (should-not (string-match-p "reasoning_effort"
                                (revere-llm-build-request "m" (list (list :role "user" :content "hi")) nil)))))

;;;; Chat

(ert-deftest revere-chat/send-starts-job-and-shows-reply ()
  "Typing in the chat starts a job; the reply streams under the message."
  (revere-tests--with-dir dir
    (cl-letf (((symbol-function 'revere-llm-stream)
               (revere-tests--fake-stream (list (list "Sure thing." nil nil)))))
      (let ((buffer (revere-chat-create dir)))
        (unwind-protect
            (with-current-buffer buffer
              (goto-char (point-max))
              (insert "add a comment")
              (revere-chat-send)
              (let ((job revere-chat--job))
                (should job)
                (should (equal (revere-job-prompt job) "add a comment"))
                (should (string-empty-p (revere-chat--input)))
                (should (revere-tests--wait (lambda () (not (revere-job-active-p job)))))
                (should (eq (revere-job-state job) 'done))
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (should (string-match-p "You › add a comment" text))
                  (should (string-match-p "Revere › Sure thing\\." text)))))
          (kill-buffer buffer))))))

(ert-deftest revere-chat/tool-lines-and-changes-block ()
  "Tool calls show with their results; pending changes get a block with buttons."
  (revere-tests--with-dir dir
    (revere-tests--write dir "a.txt" "hello world\n")
    (cl-letf (((symbol-function 'revere-llm-stream)
               (revere-tests--fake-stream
                (list (list "" (list (list :id "c1" :name "edit"
                                           :arguments "{\"path\":\"a.txt\",\"old_string\":\"hello\",\"new_string\":\"hi\"}"))
                            nil)
                      (list "Changed it." nil nil)))))
      (let ((buffer (revere-chat-create dir))
            (revere-rules '((t . go-ahead))))
        (unwind-protect
            (with-current-buffer buffer
              (goto-char (point-max))
              (insert "change hello to hi")
              (revere-chat-send)
              (let ((job revere-chat--job))
                (should (revere-tests--wait (lambda () (not (revere-job-active-p job)))))
                (revere-chat--refresh)
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (should (string-match-p "✎ edit +a\\.txt → Edited a\\.txt: 1 replacement" text))
                  (should (string-match-p "Changes  1 file  \\+1 -1" text))
                  (should (string-match-p "Keep all" text))
                  (should (string-match-p "^Changed it\\.$" text)))
                (should (eq (revere-job-state job) 'review))
                (revere-chat-keep-all)
                (should (eq (revere-job-state job) 'done))
                (should (string= (revere-tests--read (expand-file-name "a.txt" dir)) "hi world\n"))))
          (kill-buffer buffer))))))

(ert-deftest revere-chat/slash-help-does-not-start-a-job ()
  "A slash command is handled by the chat itself."
  (revere-tests--with-dir dir
    (let ((buffer (revere-chat-create dir)))
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-max))
            (insert "/help")
            (revere-chat-send)
            (should-not revere-chat--job)
            (should (string-match-p "/changes" (buffer-substring-no-properties (point-min) (point-max)))))
        (kill-buffer buffer)))))

;;;; Review in the source buffer

(ert-deftest revere-review/parse-hunks ()
  "Hunks come out with the lines they add and the text they remove."
  (let ((hunks (revere-review-parse
                (concat "--- f\tdisk\n+++ f\tbuffer\n"
                        "@@ -1,3 +1,3 @@\n line 1\n-line 2\n+LINE 2\n line 3\n"
                        "@@ -27,3 +27,3 @@\n line 27\n-line 28\n+LINE 28\n line 29\n"))))
    (should (= (length hunks) 2))
    (should (equal (plist-get (car hunks) :added) '(2)))
    (should (equal (plist-get (car hunks) :removed) '((2 . "line 2"))))
    (should (= (plist-get (cadr hunks) :start) 28))))

(ert-deftest revere-review/discard-hunk-in-source-buffer ()
  "The minor mode marks hunks in the file and can discard one in place."
  (skip-unless (executable-find diff-command))
  (revere-tests--with-dir dir
    (revere-tests--write dir "long.txt" (revere-tests--lines 30))
    (let ((job (revere-tests--job dir)))
      (let ((revere-current-job job))
        (revere-tool-edit "long.txt" "line 2\n" "LINE 2\n" nil)
        (revere-tool-edit "long.txt" "line 28\n" "LINE 28\n" nil))
      (revere-review-sync job)
      (with-current-buffer (revere-change-buffer (car (revere-ws-pending job)))
        (should revere-review-mode)
        (should (= (length revere-review--hunks) 2))
        (should (= (length revere-review--overlays) 4))
        (goto-char (point-min))
        (forward-line 1)
        (revere-review-discard-hunk)
        (should (string-match-p "^line 2$" (buffer-string)))
        (should (string-match-p "^LINE 28$" (buffer-string)))
        (should (= (length revere-review--hunks) 1))
        (revere-review-keep-file)
        (should-not revere-review-mode))
      (should (string-match-p "^LINE 28$" (revere-tests--read (expand-file-name "long.txt" dir)))))))

;;;; Models, thinking and context

(ert-deftest revere-models/parse-and-limits ()
  "Model info gives context windows; settings fill the gaps."
  (let ((records (revere-models-parse
                  (revere-llm--parse
                   "{\"data\":[{\"model_name\":\"big\",\"model_info\":{\"max_input_tokens\":200000,\"supports_reasoning\":true}},{\"model_name\":\"small\",\"litellm_params\":{\"max_input_tokens\":8192}}]}"))))
    (should (= (length records) 2))
    (revere-models-store records)
    (should (= (revere-models-context-limit "big") 200000))
    (should (revere-models-thinking-p "big"))
    (should (= (revere-models-context-limit "small") 8192))
    (let ((revere-context-limits '(("small" . 4096))))
      (should (= (revere-models-context-limit "small") 4096)))
    (let ((revere-context-limit nil))
      (should (null (revere-models-context-limit "unknown-model"))))))

(ert-deftest revere-llm/build-request-thinking-argument ()
  "The thinking argument overrides the setting, and off omits the field."
  (let ((revere-thinking-level 'off)
        (messages (list (list :role "user" :content "hi"))))
    (should (string-match-p "\"reasoning_effort\":\"high\""
                            (revere-llm-build-request "m" messages nil 'high)))
    (should (string-match-p "\"reasoning_effort\":\"low\""
                            (revere-llm-build-request "m" messages nil "low")))
    (should-not (string-match-p "reasoning_effort"
                                (revere-llm-build-request "m" messages nil 'off)))))

(ert-deftest revere-chat/header-shows-thinking-and-context ()
  "The header carries the thinking level and context use of the job."
  (revere-tests--with-dir dir
    (let ((usage (revere-tests--usage 1500 40)))
      (cl-letf (((symbol-function 'revere-llm-stream)
                 (revere-tests--fake-stream (list (list "Hi." nil usage))))
                ((symbol-function 'revere-models-ensure) #'ignore))
        (let ((buffer (revere-chat-create dir))
              (revere-context-limits '(("qwen-3.8" . 10000))))
          (unwind-protect
              (with-current-buffer buffer
                (setq revere-chat--model "qwen-3.8")
                (revere-chat-thinking "medium")
                (should (string-match-p "think medium" (revere-chat--header-wide)))
                (goto-char (point-max))
                (insert "hello")
                (revere-chat-send)
                (let ((job revere-chat--job))
                  (should (eq (revere-job-thinking job) 'medium))
                  (should (revere-tests--wait (lambda () (not (revere-job-active-p job)))))
                  (should (= (revere-job-context-tokens job) 1500))
                  (let ((header (substring-no-properties (revere-chat--header-wide))))
                    (should (string-match-p "think medium" header))
                    (should (string-match-p "ctx 1\\.5k/10\\.0k 15%" header)))))
            (kill-buffer buffer)))))))

;;;; Loop

(defun revere-tests--fake-stream (replies)
  "A stand-in for `revere-llm-stream' that plays REPLIES in order.
Each reply is (TEXT CALLS USAGE)."
  (lambda (_model _messages _tools opts)
    (let ((reply (pop replies)))
      (run-at-time 0 nil
                   (lambda ()
                     (when (nth 0 reply)
                       (funcall (plist-get opts :on-delta) (nth 0 reply)))
                     (funcall (plist-get opts :on-done) (nth 0 reply) (nth 1 reply) (nth 2 reply)))))
    nil))

(ert-deftest revere-loop/tool-call-then-finish ()
  "A tool call is run, its result goes back to the model, and the job finishes."
  (revere-tests--with-dir dir
    (revere-tests--write dir "a.txt" "hello world\n")
    (let ((job (revere-tests--job dir))
          (revere-rules '((t . go-ahead)))
          (revere-max-turns 5))
      (cl-letf (((symbol-function 'revere-llm-stream)
                 (revere-tests--fake-stream
                  (list (list "" (list (list :id "c1" :name "read" :arguments "{\"path\":\"a.txt\"}"))
                              (revere-tests--usage 12 4))
                        (list "Read it." nil (revere-tests--usage 20 8))))))
        (revere-loop-start job)
        (should (revere-tests--wait (lambda () (not (revere-job-active-p job))))))
      (should (eq (revere-job-state job) 'done))
      (should (= (revere-job-turns job) 1))
      (should (= (revere-job-tokens-in job) 32))
      (should (= (revere-job-tokens-out job) 12))
      (let ((tool-message (cl-find "tool" (revere-job-messages job)
                                   :key (lambda (m) (plist-get m :role)) :test #'equal)))
        (should tool-message)
        (should (string-match-p "hello world" (plist-get tool-message :content))))
      (let ((call (cl-find 'tool-call (revere-job-history job)
                           :key (lambda (e) (plist-get e :kind)))))
        (should (string-match-p "hello world" (plist-get call :result))))
      (should (equal (plist-get (car (last (revere-job-messages job))) :content) "Read it.")))))

(ert-deftest revere-loop/edit-leaves-job-in-review ()
  "A job that changed a file stops in review, not done."
  (revere-tests--with-dir dir
    (revere-tests--write dir "a.txt" "hello world\n")
    (let ((job (revere-tests--job dir))
          (revere-rules '((t . go-ahead))))
      (cl-letf (((symbol-function 'revere-llm-stream)
                 (revere-tests--fake-stream
                  (list (list "" (list (list :id "c1" :name "edit"
                                             :arguments "{\"path\":\"a.txt\",\"old_string\":\"hello\",\"new_string\":\"hi\"}"))
                              nil)
                        (list "Changed it." nil nil)))))
        (revere-loop-start job)
        (should (revere-tests--wait (lambda () (not (revere-job-active-p job))))))
      (should (eq (revere-job-state job) 'review))
      (should (= (length (revere-ws-pending job)) 1)))))

(ert-deftest revere-loop/stops-at-max-turns ()
  "A model that never stops calling tools is cut off."
  (revere-tests--with-dir dir
    (revere-tests--write dir "a.txt" "x\n")
    (let ((job (revere-tests--job dir))
          (revere-rules '((t . go-ahead)))
          (revere-max-turns 2)
          (calls 0))
      (cl-letf (((symbol-function 'revere-llm-stream)
                 (lambda (_model _messages _tools opts)
                   (cl-incf calls)
                   (run-at-time 0 nil (plist-get opts :on-done) ""
                                (list (list :id "c" :name "read" :arguments "{\"path\":\"a.txt\"}"))
                                nil)
                   nil)))
        (revere-loop-start job)
        (should (revere-tests--wait (lambda () (not (revere-job-active-p job))))))
      (should (eq (revere-job-state job) 'failed))
      (should (string-match-p "stopped after 2 turns" (revere-job-detail job)))
      (should (= calls 2)))))

;;;; Approvals

(ert-deftest revere-approve/check-rule-parks-the-job-until-granted ()
  "A tool ruled check waits for an approval; granting it runs the tool."
  (revere-tests--with-dir dir
    (let ((job (revere-tests--job dir))
          (revere-rules '((shell . check) (t . go-ahead)))
          (revere-approvals nil))
      (cl-letf (((symbol-function 'revere-llm-stream)
                 (revere-tests--fake-stream
                  (list (list "" (list (list :id "c1" :name "shell"
                                             :arguments "{\"command\":\"echo approved-marker\"}"))
                              nil)
                        (list "Ran it." nil nil)))))
        (revere-loop-start job)
        (should (revere-tests--wait (lambda () (eq (revere-job-state job) 'waiting))))
        (let ((approval (car (revere-approve-pending job))))
          (should approval)
          (should (string-match-p "shell" (revere-approve-description approval)))
          (revere-approve-decide approval t))
        (should (revere-tests--wait (lambda () (not (revere-job-active-p job)))))
        (should (eq (revere-job-state job) 'done))
        (should (cl-some (lambda (m) (and (equal (plist-get m :role) "tool")
                                          (string-match-p "approved-marker" (plist-get m :content))))
                         (revere-job-messages job)))))))

(ert-deftest revere-approve/declined-tool-tells-the-model ()
  "Declining an approval sends a refusal as the tool result."
  (revere-tests--with-dir dir
    (let ((job (revere-tests--job dir))
          (revere-rules '((shell . check) (t . go-ahead)))
          (revere-approvals nil))
      (cl-letf (((symbol-function 'revere-llm-stream)
                 (revere-tests--fake-stream
                  (list (list "" (list (list :id "c1" :name "shell" :arguments "{\"command\":\"echo no\"}")) nil)
                        (list "Understood." nil nil)))))
        (revere-loop-start job)
        (should (revere-tests--wait (lambda () (eq (revere-job-state job) 'waiting))))
        (revere-approve-decide (car (revere-approve-pending job)) nil)
        (should (revere-tests--wait (lambda () (not (revere-job-active-p job)))))
        (should (cl-some (lambda (m) (and (equal (plist-get m :role) "tool")
                                          (string-match-p "declined" (plist-get m :content))))
                         (revere-job-messages job)))))))

(ert-deftest revere-chat/approval-shows-buttons-then-clears ()
  "The chat shows an approval with buttons and removes it once answered."
  (revere-tests--with-dir dir
    (cl-letf (((symbol-function 'revere-llm-stream)
               (revere-tests--fake-stream
                (list (list "" (list (list :id "c1" :name "shell" :arguments "{\"command\":\"echo chat-ok\"}")) nil)
                      (list "Done." nil nil)))))
      (let ((buffer (revere-chat-create dir))
            (revere-rules '((shell . check) (t . go-ahead)))
            (revere-approvals nil))
        (unwind-protect
            (with-current-buffer buffer
              (goto-char (point-max))
              (insert "run it")
              (revere-chat-send)
              (let ((job revere-chat--job))
                (should (revere-tests--wait (lambda () (eq (revere-job-state job) 'waiting))))
                (should (string-match-p "needs your OK: shell" (buffer-string)))
                (should (string-match-p "Go ahead" (buffer-string)))
                (revere-chat--answer t)
                (should (revere-tests--wait (lambda () (not (revere-job-active-p job)))))
                (should-not (string-match-p "needs your OK" (buffer-string)))
                (should (string-match-p "exit=0" (buffer-string)))))
          (kill-buffer buffer))))))

;;;; Logbook

(ert-deftest revere-logbook/save-and-load-round-trip ()
  "A job written to the logbook reads back the same."
  (revere-tests--with-dir dir
    (let ((job (revere-job-create "write *stars* and #+lines\nsecond line" dir)))
      (revere-job-append-message job (list :role "user" :content "hi\nthere"))
      (revere-job-append-message
       job (list :role "assistant" :content ""
                 :tool_calls (vector (list :id "c1" :type "function"
                                           :function (list :name "read" :arguments "{\"path\":\"a\"}")))))
      (revere-job-record job 'tool-call :id "c1" :name "read" :args "{}" :result "1\tx")
      (setf (revere-job-tokens-in job) 12)
      (revere-job-set-state job 'done)
      (revere-logbook-save job)
      (let ((revere-job-list nil)
            (revere-job--counter 0))
        (should (>= (revere-logbook-load) 1))
        (let ((loaded (revere-job-by-id (revere-job-id job))))
          (should loaded)
          (should (equal (revere-job-prompt loaded) (revere-job-prompt job)))
          (should (eq (revere-job-state loaded) 'done))
          (should (= (revere-job-tokens-in loaded) 12))
          (should (equal (revere-job-messages loaded) (revere-job-messages job)))
          (should (equal (plist-get (car (revere-job-history loaded)) :result) "1\tx"))
          (should (>= revere-job--counter (revere-job-number job))))))))

(ert-deftest revere-logbook/interrupted-jobs-are-settled-on-load ()
  "A job that was working when Emacs stopped loads as failed."
  (revere-tests--with-dir dir
    (let ((job (revere-job-create "unfinished" dir)))
      (setf (revere-job-state job) 'working)
      (revere-logbook-save job)
      (let ((revere-job-list nil)
            (revere-job--counter 0))
        (revere-logbook-load)
        (let ((loaded (revere-job-by-id (revere-job-id job))))
          (should (eq (revere-job-state loaded) 'failed))
          (should (string-match-p "restarted" (revere-job-detail loaded))))))))

;;;; Worktrees

(defun revere-tests--git (dir &rest args)
  "Run git with ARGS in DIR."
  (with-temp-buffer
    (let ((default-directory dir))
      (apply #'call-process "git" nil t nil args))))

(ert-deftest revere-worktree/branch-commit-and-merge ()
  "An unattended job edits on a branch; keeping merges it into the project."
  (skip-unless (executable-find "git"))
  (revere-tests--with-dir dir
    (revere-tests--git dir "init" "-q")
    (revere-tests--git dir "config" "user.email" "tests@example.com")
    (revere-tests--git dir "config" "user.name" "Tests")
    (revere-tests--write dir "a.txt" "hello world\n")
    (revere-tests--git dir "add" "a.txt")
    (revere-tests--git dir "commit" "-q" "-m" "start")
    (let ((job (revere-job-create "change it" dir '(routine "r1"))))
      (revere-worktree-create job)
      (should (eq (revere-job-mode job) 'worktree))
      (should (file-directory-p (revere-job-worktree job)))
      (let ((revere-current-job job))
        (revere-tool-edit "a.txt" "hello" "hi" nil))
      (should (revere-worktree-commit job))
      (should (revere-worktree-has-changes-p job))
      (should (equal (revere-worktree-numstat job) '((1 1 "a.txt"))))
      (should (string-match-p "^\\+hi world" (revere-worktree-diff job)))
      (should (string= (revere-tests--read (expand-file-name "a.txt" dir)) "hello world\n"))
      (revere-worktree-keep job)
      (should (eq (revere-job-state job) 'done))
      (should (string= (revere-tests--read (expand-file-name "a.txt" dir)) "hi world\n"))
      (should-not (file-directory-p (revere-job-worktree job))))))

;;;; Routines and check-in

(ert-deftest revere-routines/due-routine-runs-and-reschedules ()
  "A routine past its time starts a job; when it ends, Org moves the date on."
  (revere-tests--with-dir dir
    (let ((yesterday (format-time-string "%Y-%m-%d %a %H:%M"
                                         (time-subtract (current-time) (* 24 3600)))))
      (revere-tests--fresh-file (revere-routines-file))
      (with-temp-file (revere-routines-file)
        (insert revere-routines--header
                (format "* ROUTINE Say hi\nSCHEDULED: <%s ++1d>\n:PROPERTIES:\n:ID: r-test\n:DIRECTORY: %s\n:MODE: buffers\n:END:\nSay hi.\n"
                        yesterday dir)))
      (let ((due (revere-routines-due)))
        (should (= (length due) 1))
        (should (equal (plist-get (car due) :id) "r-test"))
        (should (equal (plist-get (car due) :prompt) "Say hi.")))
      (cl-letf (((symbol-function 'revere-llm-stream)
                 (revere-tests--fake-stream (list (list "Hi." nil nil)))))
        (revere-routines-enable)
        (unwind-protect
            (progn
              (revere-routines-tick)
              (let ((job (revere-job-last)))
                (should (equal (revere-job-origin job) '(routine "r-test")))
                (should (revere-tests--wait (lambda () (not (revere-job-active-p job)))))
                (should (eq (revere-job-state job) 'done))))
          (revere-routines-disable)))
      (should (null (revere-routines-due)))
      (with-current-buffer (revere-routines--buffer (revere-routines-file) revere-routines--header)
        (goto-char (point-min))
        (re-search-forward "^\\* ")
        (should (equal (org-get-todo-state) "ROUTINE"))
        (should (time-less-p (current-time) (org-get-scheduled-time (point))))
        (should (equal (org-entry-get nil "LAST_RESULT") "done"))))))

(ert-deftest revere-check-in/notes-start-a-job-and-get-filed ()
  "Notes in the check-in file become a job and move under Handled."
  (revere-tests--with-dir dir
    (revere-tests--fresh-file (revere-check-in-file))
    (with-temp-file (revere-check-in-file)
      (insert (replace-regexp-in-string "^#\\+DIRECTORY: .*$" (concat "#+DIRECTORY: " dir)
                                        revere-check-in--header)
              "buy milk\n"))
    (cl-letf (((symbol-function 'revere-llm-stream)
               (revere-tests--fake-stream (list (list "Noted." nil nil)))))
      (let ((job (revere-check-in-tick)))
        (should job)
        (should (string-match-p "buy milk" (revere-job-prompt job)))
        (should (equal (revere-job-origin job) '(check-in)))
        (should (revere-tests--wait (lambda () (not (revere-job-active-p job)))))))
    (should (string-match-p "^\\* Handled" (revere-tests--read (revere-check-in-file))))
    (should (null (revere-check-in-tick)))))

;;;; Channels and Discord

(ert-deftest revere-channel/commands-answer-approvals-and-report-status ()
  "A message from a channel starts a job; /ok answers its approval; /status reports."
  (revere-tests--with-dir dir
    (let ((posted nil)
          (revere-rules '((shell . check) (t . go-ahead)))
          (revere-approvals nil)
          (revere-channel-directories (list (cons "test:1" dir)))
          (revere-unattended-mode 'buffers))
      (revere-channel-register "test" (lambda (_key text) (push text posted)))
      (cl-letf (((symbol-function 'revere-llm-stream)
                 (revere-tests--fake-stream
                  (list (list "" (list (list :id "c1" :name "shell"
                                             :arguments "{\"command\":\"echo via-channel\"}"))
                              nil)
                        (list "Ran it." nil nil)))))
        (revere-channel-inbound "test:1" "run it")
        (let ((job (revere-channel-job "test:1")))
          (should job)
          (should (equal (revere-job-origin job) '(channel "test:1")))
          (should (revere-tests--wait (lambda () (eq (revere-job-state job) 'waiting))))
          (should (cl-some (lambda (p) (string-match-p "Needs your OK: shell" p)) posted))
          (revere-channel-inbound "test:1" "/ok")
          (should (revere-tests--wait (lambda () (not (revere-job-active-p job)))))
          (should (eq (revere-job-state job) 'done))
          (should (cl-some (lambda (p) (equal p "Ran it.")) posted))
          (revere-channel-inbound "test:1" "/status")
          (should (string-match-p "done" (car posted))))))))

(ert-deftest revere-channel/review-is-announced-and-kept ()
  "When a channel job changes a file, the channel hears about it and can /keep."
  (revere-tests--with-dir dir
    (revere-tests--write dir "a.txt" "hello world\n")
    (let ((posted nil)
          (revere-rules '((t . go-ahead)))
          (revere-channel-directories (list (cons "test:2" dir)))
          (revere-unattended-mode 'buffers))
      (revere-channel-register "test" (lambda (_key text) (push text posted)))
      (cl-letf (((symbol-function 'revere-llm-stream)
                 (revere-tests--fake-stream
                  (list (list "" (list (list :id "c1" :name "edit"
                                             :arguments "{\"path\":\"a.txt\",\"old_string\":\"hello\",\"new_string\":\"hi\"}"))
                              nil)
                        (list "Changed." nil nil)))))
        (revere-channel-inbound "test:2" "change hello to hi")
        (let ((job (revere-channel-job "test:2")))
          (should (revere-tests--wait (lambda () (eq (revere-job-state job) 'review))))
          (should (revere-tests--wait (lambda () (cl-some (lambda (p) (string-match-p "/keep" p)) posted))))
          (revere-channel-inbound "test:2" "/keep")
          (should (eq (revere-job-state job) 'done))
          (should (string= (revere-tests--read (expand-file-name "a.txt" dir)) "hi world\n")))))))

(ert-deftest revere-discord/hello-identifies-and-heartbeats ()
  "HELLO starts the heartbeat and sends IDENTIFY; a heartbeat request is answered."
  (let ((sent nil)
        (revere-discord-token "tok")
        (revere-discord--state (revere-discord-state--make :socket 'fake)))
    (cl-letf (((symbol-function 'websocket-send-text) (lambda (_socket text) (push text sent)))
              ((symbol-function 'websocket-openp) (lambda (_socket) t)))
      (unwind-protect
          (progn
            (revere-discord--handle (revere-discord--parse "{\"op\":10,\"d\":{\"heartbeat_interval\":45000}}"))
            (should (revere-discord-state-heartbeat revere-discord--state))
            (should (string-match-p "\"op\":2" (car sent)))
            (should (string-match-p "\"token\":\"tok\"" (car sent)))
            (should (string-match-p "\"intents\":37377" (car sent)))
            (revere-discord--handle (revere-discord--parse "{\"op\":0,\"s\":7,\"t\":\"READY\",\"d\":{\"session_id\":\"s1\",\"resume_gateway_url\":\"wss://x\",\"user\":{\"id\":\"bot\",\"username\":\"revere\"}}}"))
            (should (equal (revere-discord-state-session-id revere-discord--state) "s1"))
            (should (= (revere-discord-state-seq revere-discord--state) 7))
            (revere-discord--handle (revere-discord--parse "{\"op\":1,\"d\":null}"))
            (should (string-match-p "\"op\":1,\"d\":7" (car sent))))
        (revere-discord--stop-heartbeat)))))

(ert-deftest revere-discord/message-starts-a-job-and-replies ()
  "A message in a listened channel becomes a job; the reply is posted back."
  (revere-tests--with-dir dir
    (let ((posted nil)
          (revere-discord-channels '("CH1"))
          (revere-channel-directories (list (cons "discord:CH1" dir)))
          (revere-unattended-mode 'buffers)
          (revere-discord--state (revere-discord-state--make :socket 'fake :user-id "bot")))
      (cl-letf (((symbol-function 'revere-discord-send) (lambda (key text) (push (cons key text) posted)))
                ((symbol-function 'revere-llm-stream)
                 (revere-tests--fake-stream (list (list "Sure." nil nil)))))
        (revere-discord--handle
         (revere-discord--parse "{\"op\":0,\"s\":5,\"t\":\"MESSAGE_CREATE\",\"d\":{\"channel_id\":\"CH1\",\"content\":\"say hi\",\"author\":{\"id\":\"u1\",\"bot\":false}}}"))
        (let ((job (revere-channel-job "discord:CH1")))
          (should job)
          (should (equal (revere-job-prompt job) "say hi"))
          (should (revere-tests--wait (lambda () (not (revere-job-active-p job))))))
        (should (cl-some (lambda (p) (and (equal (car p) "discord:CH1") (equal (cdr p) "Sure."))) posted))
        (revere-discord--handle
         (revere-discord--parse "{\"op\":0,\"t\":\"MESSAGE_CREATE\",\"d\":{\"channel_id\":\"CH1\",\"content\":\"x\",\"author\":{\"id\":\"bot\",\"bot\":true}}}"))
        (revere-discord--handle
         (revere-discord--parse "{\"op\":0,\"t\":\"MESSAGE_CREATE\",\"d\":{\"channel_id\":\"OTHER\",\"content\":\"x\",\"author\":{\"id\":\"u1\"}}}"))
        (should (= (length (cl-remove-if-not (lambda (j) (equal (revere-job-origin j) '(channel "discord:CH1")))
                                             revere-job-list))
                   1))))))

(ert-deftest revere-discord/long-messages-split-at-lines ()
  "Text longer than Discord's limit is split at line ends."
  (let ((pieces (revere-discord-chunks (concat (make-string 1500 ?a) "\n" (make-string 1500 ?b)) 2000)))
    (should (= (length pieces) 2))
    (should (= (length (car pieces)) 1500))
    (should (string-prefix-p "b" (cadr pieces))))
  (should (equal (revere-discord-chunks "short") '("short"))))

;;;; Tools that look at Emacs

(ert-deftest revere-tools-code/describe-apropos-eval ()
  "describe explains a function, apropos finds symbols, eval returns a value."
  (should (string-match-p "is a function" (revere-tool-describe "car")))
  (should (string-match-p "Nothing is called" (revere-tool-describe "no-such-thing-xyz")))
  (should (string-match-p "revere-ws-visit" (revere-tool-apropos "^revere-ws-visit$" "functions")))
  (should (equal (revere-tool-eval "(+ 1 2) (* 3 4)") "12"))
  (should (string-match-p "^Error:" (revere-tool-eval "(error \"boom\")"))))

(ert-deftest revere-tools-code/define-tool-compiles-and-tests ()
  "A clean tool definition is kept; one with a compiler warning is refused."
  (let ((result (revere-tools-code-define
                 (concat "(revere-deftool hello-test ((name string \"Who\")) \"Greet NAME.\" (format \"hello %s\" name))\n"
                         "(ert-deftest revere-hello-test () (should (equal (revere-tool-hello-test \"x\") \"hello x\")))"))))
    (should (string-match-p "Defined tool hello-test; 1 test passed" result))
    (should (revere-tools-get "hello-test")))
  (should-error (revere-tools-code-define
                 "(revere-deftool bad-test ((a string \"A\")) \"Bad.\" (let ((unused 1)) a))"))
  (should-not (revere-tools-get "bad-test")))

(ert-deftest revere-tools-code/problems-reports-a-warning ()
  "problems runs the checker on a file and reports what it finds."
  (revere-tests--with-dir dir
    (revere-tests--write dir "code.el" ";;; code.el --- x -*- lexical-binding: t -*-\n(defun code-f (x) (let ((unused 1)) x))\n")
    (let ((revere-current-job (revere-tests--job dir))
          (revere-problems-wait 6)
          (result nil))
      (revere-tool-problems (lambda (r) (setq result r)) "code.el")
      (should (revere-tests--wait (lambda () result) 30))
      ;; The byte-compile checker stays off for files Emacs does not trust,
      ;; but checkdoc still reports on the file.
      (should (string-match-p "problems:" result))
      (should (string-match-p "code\\.el:[0-9]+: \\(warning\\|note\\|error\\): " result)))))

(ert-deftest revere-tools/rule-precedence ()
  "revere-rules wins over a tool's own rule, which wins over the default."
  (let ((tool (revere-tool--make :name "x-rule" :symbol 'x-rule :function #'ignore
                                 :description "" :args nil :rule 'check)))
    (let ((revere-rules '((t . never))))
      (should (eq (revere-tools-rule tool) 'check)))
    (let ((revere-rules '((x-rule . go-ahead) (t . never))))
      (should (eq (revere-tools-rule tool) 'go-ahead)))
    (setf (revere-tool-rule tool) nil)
    (let ((revere-rules '((t . never))))
      (should (eq (revere-tools-rule tool) 'never)))))

;;;; Skills

(ert-deftest revere-skills/index-prompt-and-load ()
  "Skills are found, listed in the prompt, and loaded with their skill.el."
  (revere-tests--with-dir dir
    (revere-tests--write dir "myskill/SKILL.md"
                         "---\nname: myskill\ndescription: does things\n---\n\nDo the thing.\n")
    (revere-tests--write dir "myskill/skill.el"
                         ";;; -*- lexical-binding: t -*-\n(revere-deftool myskill-tool () \"A tool from a skill.\" \"from skill\")\n")
    (let ((revere-skill-dirs (list dir)))
      (should (cl-find "myskill" (revere-skills-index) :key (lambda (s) (plist-get s :name)) :test #'equal))
      (should (string-match-p "- myskill: does things" (revere-skills-prompt)))
      (should (string-match-p "Do the thing\\." (revere-tool-skill "myskill")))
      (should (revere-tools-get "myskill-tool"))
      (should-error (revere-tool-skill "nope")))))

;;;; MCP

(ert-deftest revere-mcp/fake-server-round-trip ()
  "An MCP server's tools are registered and can be called."
  (let* ((emacs (expand-file-name invocation-name invocation-directory))
         (script (expand-file-name "fake-mcp.el" (file-name-directory (locate-library "revere-tests"))))
         (revere-mcp-servers (list (list "fake" :command emacs :args (list "-Q" "--batch" "-l" script))))
         (result nil))
    (unwind-protect
        (progn
          (revere-mcp-start "fake")
          (should (revere-tests--wait (lambda () (revere-mcp-ready-p "fake")) 30))
          (should (revere-tools-get "mcp-fake-echo"))
          (should (eq (revere-tools-rule (revere-tools-get "mcp-fake-echo")) 'check))
          (let ((revere-rules '((mcp-fake-echo . go-ahead) (t . never))))
            (revere-tools-call "mcp-fake-echo" "{\"text\":\"hi\"}" (lambda (r) (setq result r))))
          (should (revere-tests--wait (lambda () result) 10))
          (should (equal result "echo: hi")))
      (revere-mcp-stop "fake"))
    (should-not (revere-tools-get "mcp-fake-echo"))))

;;;; Memory and debrief

(ert-deftest revere-memory/add-search-and-prompt ()
  "A remembered fact is found by search, counted, and listed in the prompt."
  (should (string-match-p "Remembered: Use tabs" (revere-tool-memory-add "Use tabs" "Because the user said so." "feedback")))
  (should (string-match-p "Use tabs" (revere-tool-memory-search "tabs")))
  (should (string-match-p "Nothing remembered" (revere-tool-memory-search "zzz-no-such")))
  (should (string-match-p "Use tabs (feedback)" (revere-memory-prompt)))
  (should (string-match-p "Use tabs" (revere-loop-system-prompt))))

(ert-deftest revere-memory/debrief-prompt-covers-recent-jobs ()
  "The debrief prompt lists jobs from the logbook since a time."
  (revere-tests--with-dir dir
    (let ((job (revere-job-create "tidy the readme" dir)))
      (revere-job-set-state job 'discarded)
      (revere-logbook-save job)
      (let ((prompt (revere-debrief-prompt (- (float-time) 60))))
        (should prompt)
        (should (string-match-p (format "Job %d, discarded" (revere-job-number job)) prompt))
        (should (string-match-p "tidy the readme" prompt))))))

;;;; The system prompt

(ert-deftest revere-prompt/assembles-standing-project-and-environment ()
  "The prompt file replaces the default, AGENTS.md is found upward, facts are added."
  (revere-tests--with-dir dir
    (revere-tests--write dir "AGENTS.md" "Always run the tests.\n")
    (make-directory (expand-file-name "sub" dir) t)
    (let ((job (revere-job-create "x" (expand-file-name "sub" dir))))
      (let ((prompt (revere-prompt-assemble job)))
        (should (string-prefix-p (substring revere-system-prompt 0 20) prompt))
        (should (string-match-p "Project instructions, from AGENTS.md:\nAlways run the tests\\." prompt))
        (should (string-match-p "working directory: .*sub/" prompt))
        (should (string-match-p "git repository: no" prompt)))
      (with-temp-file (revere-prompt-file)
        (insert "You are Revere, terse and exact.\n"))
      (unwind-protect
          (let ((prompt (revere-prompt-assemble job)))
            (should (string-prefix-p "You are Revere, terse and exact." prompt))
            (should-not (string-match-p (substring revere-system-prompt 0 20) prompt)))
        (delete-file (revere-prompt-file))))))

(ert-deftest revere-prompt/config-directory-moves-instructions-and-skills ()
  "Standing instructions and your own skills follow `revere-config-directory'."
  ;; Unset, everything stays with the rest of the state.
  (let ((revere-config-directory nil))
    (should (equal (revere-config-directory)
                   (file-name-as-directory (expand-file-name revere-directory))))
    (should (equal (revere-prompt-file)
                   (expand-file-name "prompt.md" revere-directory))))
  ;; Set, the config directory wins, as it does for the container's
  ;; separate volumes.
  (revere-tests--with-dir config
    (let ((revere-config-directory config)
          (revere-skill-dirs nil))
      (should (equal (revere-prompt-file) (expand-file-name "prompt.md" config)))
      (should (equal (revere-skills-new-directory) (expand-file-name "skills" config)))
      (revere-tests--write config "skills/greeting/SKILL.md"
                           "---\nname: greeting\ndescription: say hello\n---\n\nSay hello.\n")
      (should (member "greeting"
                      (mapcar (lambda (s) (plist-get s :name)) (revere-skills-index)))))))

(ert-deftest revere-prompt/job-starts-with-the-assembled-prompt ()
  "A job's first message is the assembled system prompt, not the bare default."
  (revere-tests--with-dir dir
    (revere-tests--write dir "CLAUDE.md" "Prefer tabs.\n")
    (cl-letf (((symbol-function 'revere-llm-stream)
               (revere-tests--fake-stream (list (list "Ok." nil nil)))))
      (let ((job (revere-tests--job dir)))
        (revere-loop-start job)
        (should (revere-tests--wait (lambda () (not (revere-job-active-p job)))))
        (let ((system (plist-get (car (revere-job-messages job)) :content)))
          (should (string-match-p "from CLAUDE.md:\nPrefer tabs\\." system))
          (should (string-match-p "Environment:" system)))))))

;;;; The board

(ert-deftest revere-board/workers-take-their-cards-and-move-them ()
  "A worker takes cards for it or for anyone, in order, and cards follow the jobs."
  (revere-tests--with-dir dir
    (revere-tests--fresh-file (revere-board-file))
    (with-temp-file (revere-board-file)
      (insert revere-board--header
              (format "* TODO Other's card\n:PROPERTIES:\n:ID: c-other\n:FOR: other\n:END:\nNot for coder.\n"
                      )
              (format "* TODO Coder's card\n:PROPERTIES:\n:ID: c-coder\n:FOR: coder\n:DIRECTORY: %s\n:END:\nSay hi.\n" dir)
              (format "* TODO Anyone's card\n:PROPERTIES:\n:ID: c-any\n:DIRECTORY: %s\n:END:\nSay hello.\n" dir)))
    (let ((revere-unattended-mode 'buffers)
          (routine (list :id "w-coder" :kind "board" :worker "coder" :directory dir)))
      (should (equal (plist-get (revere-board-next "coder") :id) "c-coder"))
      (should (equal (plist-get (revere-board-next "nobody") :id) "c-any"))
      (cl-letf (((symbol-function 'revere-llm-stream)
                 (revere-tests--fake-stream (list (list "Hi." nil nil) (list "Hello." nil nil)))))
        (let ((job (revere-routines-start routine)))
          (should job)
          (should (equal (revere-job-origin job) '(board "c-coder")))
          (should (string-match-p "Card: Coder's card" (revere-job-prompt job)))
          (should (equal (plist-get (cl-find "c-coder" (revere-board-cards) :key (lambda (c) (plist-get c :id)) :test #'equal) :state) "DOING"))
          (should (revere-tests--wait (lambda () (not (revere-job-active-p job)))))
          (should (equal (plist-get (cl-find "c-coder" (revere-board-cards) :key (lambda (c) (plist-get c :id)) :test #'equal) :state) "DONE")))
        (let ((job (revere-routines-start routine)))
          (should (equal (revere-job-origin job) '(board "c-any")))
          (should (revere-tests--wait (lambda () (not (revere-job-active-p job))))))
        (should (null (revere-routines-start routine)))
        (should (equal (plist-get (cl-find "c-other" (revere-board-cards) :key (lambda (c) (plist-get c :id)) :test #'equal) :state) "TODO"))))))

(ert-deftest revere-board/tool-posts-a-card ()
  "The board-add tool puts a TODO card on the board for a worker."
  (let ((before (length (revere-board-cards))))
    (should (string-match-p "Card posted .* for tester" (revere-tool-board-add "Write docs" "Document the thing." "tester")))
    (let ((card (car (last (revere-board-cards)))))
      (should (= (length (revere-board-cards)) (1+ before)))
      (should (equal (plist-get card :title) "Write docs"))
      (should (equal (plist-get card :for) "tester"))
      (should (equal (plist-get card :state) "TODO")))))

;;;; Compaction, fallback, cost

(ert-deftest revere-compact/split-keeps-tool-calls-with-results ()
  "The recent tail never starts with a tool result."
  (let ((messages (list (list :role "user" :content "a")
                        (list :role "assistant" :content "" :tool_calls (vector 1))
                        (list :role "tool" :content "r1")
                        (list :role "tool" :content "r2")
                        (list :role "assistant" :content "b")
                        (list :role "user" :content "c")))
        (revere-compact-keep 3))
    (let ((split (revere-compact-split messages)))
      (should (= (length (car split)) 1))
      (should (equal (plist-get (car (cadr split)) :role) "assistant")))))

(ert-deftest revere-compact/long-transcript-is-summarized-before-the-turn ()
  "Past the threshold the older messages become one summary and the job goes on."
  (revere-tests--with-dir dir
    (let ((job (revere-tests--job dir))
          (revere-compact-tokens 100)
          (revere-compact-keep 2)
          (revere-context-limit nil)
          (calls 0))
      (revere-job-append-message job (list :role "system" :content "standing instructions"))
      (dotimes (i 6)
        (revere-job-append-message job (list :role "user" :content (format "message %d" i)))
        (revere-job-append-message job (list :role "assistant" :content (format "reply %d" i))))
      (setf (revere-job-context-tokens job) 500)
      (cl-letf (((symbol-function 'revere-llm-stream)
                 (lambda (_model messages _tools opts)
                   (cl-incf calls)
                   (run-at-time 0 nil
                                (lambda ()
                                  (if (= calls 1)
                                      (progn
                                        (should (string-match-p "Summarize" (plist-get (car messages) :content)))
                                        (funcall (plist-get opts :on-done) "THE SUMMARY" nil nil))
                                    (funcall (plist-get opts :on-done) "Continuing." nil nil))))
                   nil)))
        (revere-loop-start job)
        (should (revere-tests--wait (lambda () (not (revere-job-active-p job))))))
      (should (= calls 2))
      (let ((messages (revere-job-messages job)))
        (should (equal (plist-get (car messages) :role) "system"))
        (should (string-match-p "THE SUMMARY" (plist-get (cadr messages) :content)))
        (should (< (length messages) 8))
        (should (cl-some (lambda (e) (and (eq (plist-get e :kind) 'note)
                                          (string-match-p "Compacted" (plist-get e :text))))
                         (revere-job-events job)))))))

(ert-deftest revere-loop/falls-back-to-the-next-model ()
  "A transport error moves the job to the next model instead of failing."
  (revere-tests--with-dir dir
    (let ((job (revere-tests--job dir))
          (revere-model-fallbacks '("second-model"))
          (seen nil))
      (cl-letf (((symbol-function 'revere-llm-stream)
                 (lambda (model _messages _tools opts)
                   (push model seen)
                   (run-at-time 0 nil
                                (lambda ()
                                  (if (equal model "second-model")
                                      (funcall (plist-get opts :on-done) "Fine now." nil nil)
                                    (funcall (plist-get opts :on-error) "curl exited with status 7"))))
                   nil)))
        (revere-loop-start job)
        (should (revere-tests--wait (lambda () (not (revere-job-active-p job))))))
      (should (eq (revere-job-state job) 'done))
      (should (equal (revere-job-model job) "second-model"))
      (should (equal (reverse seen) (list "qwen-3.8" "second-model"))))))

(ert-deftest revere-models/cost-is-tallied ()
  "Prices from model info give a running cost."
  (revere-models-store (list (cons "priced" (list :context 1000 :cost-in 0.000002 :cost-out 0.00001))))
  (should (< (abs (- (revere-models-cost "priced" 1000 100) 0.003)) 0.0000001))
  (should (null (revere-models-cost "unpriced" 1 1))))

;;;; Shell rules by pattern

(ert-deftest revere-tools/command-rules-by-pattern ()
  "Dangerous commands are refused, safe ones pass, others use the shell rule."
  (let ((shell (revere-tools-get "shell")))
    (let ((revere-rules '((shell . check) (t . never))))
      (should (eq (revere-tools-rule-for shell "{\"command\":\"rm -rf build\"}") 'never))
      (should (eq (revere-tools-rule-for shell "{\"command\":\"git push --force\"}") 'never))
      (should (eq (revere-tools-rule-for shell "{\"command\":\"git status\"}") 'go-ahead))
      (should (eq (revere-tools-rule-for shell "{\"command\":\"npm publish\"}") 'check)))
    (let (result)
      (revere-tools-call "shell" "{\"command\":\"sudo reboot\"}" (lambda (r) (setq result r)))
      (should (string-match-p "not allowed" result)))))

;;;; Logbook search

(ert-deftest revere-logbook/search-finds-past-jobs ()
  "A past job is found by words in its prompt or transcript."
  (revere-tests--with-dir dir
    (let ((job (revere-job-create "rename the frobnicator" dir)))
      (revere-job-record job 'said :text "Renamed frobnicator to widget.")
      (revere-job-set-state job 'done)
      (revere-logbook-save job)
      (let ((found (revere-logbook-search "frobnicator")))
        (should found)
        (should (string-match-p (format "Job %d, done" (revere-job-number job)) (car found))))
      (should (string-match-p "No past job" (revere-tool-logbook-search "zzz-nothing-here" nil))))))

;;;; Web

(ert-deftest revere-tools-web/fetch-renders-html ()
  "A fetched HTML file comes back as text."
  (revere-tests--with-dir dir
    (let ((file (revere-tests--write dir "page.html"
                                     "<html><head><title>T</title></head><body><h1>Hello</h1><p>Some <b>bold</b> text.</p><script>x=1</script></body></html>"))
          (result nil))
      (revere-tool-fetch (lambda (r) (setq result r)) (concat "file://" (if (string-prefix-p "/" file) "" "/") file))
      (should (revere-tests--wait (lambda () result)))
      (should (string-match-p "Hello" result))
      (should (string-match-p "Some bold text\\." result))
      (should-not (string-match-p "<p>" result)))))

(ert-deftest revere-tools-web/search-formats-results ()
  "Search results from the provider are formatted as title, URL, snippet."
  (let ((result nil)
        (revere-search-provider 'searxng))
    (cl-letf (((symbol-function 'revere-tools-web--get-json)
               (lambda (_url _headers callback)
                 (funcall callback (revere-llm--parse
                                    "{\"results\":[{\"title\":\"Emacs\",\"url\":\"https://gnu.org/emacs\",\"content\":\"The editor.\"}]}")))))
      (revere-tool-search (lambda (r) (setq result r)) "emacs" nil))
    (should (string-match-p "Emacs\n  https://gnu.org/emacs\n  The editor\\." result))))

(ert-deftest revere-tools-web/duckduckgo-parse ()
  "Result links and snippets come out of DuckDuckGo's HTML page."
  (skip-unless (fboundp 'libxml-parse-html-region))
  (let ((results (revere-tools-web-duckduckgo-parse
                  (concat "<html><body><div class=\"result\">"
                          "<a class=\"result__a\" href=\"//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.org%2Fa&amp;rut=x\">First hit</a>"
                          "<a class=\"result__snippet\" href=\"#\">About the first.</a></div>"
                          "<div class=\"result\"><a class=\"result__a\" href=\"https://example.org/b\">Second</a>"
                          "<a class=\"result__snippet\" href=\"#\">About the second.</a></div></body></html>"))))
    (should (= (length results) 2))
    (should (equal (car results) '("First hit" "https://example.org/a" "About the first.")))
    (should (equal (nth 1 (cadr results)) "https://example.org/b"))))

(ert-deftest revere-tools/callback-fires-once ()
  "A tool that reports back twice cannot continue the job twice."
  (let ((count 0))
    (revere-tools-register
     (revere-tool--make :name "twice" :symbol 'twice :async t :description "" :args nil
                        :function (lambda (callback) (funcall callback "one") (funcall callback "two"))))
    (unwind-protect
        (let ((revere-rules '((twice . go-ahead) (t . never))))
          (revere-tools-call "twice" "{}" (lambda (_r) (cl-incf count)))
          (should (= count 1)))
      (remhash "twice" revere-tools--registry))))

;;;; Plan and delegate

(ert-deftest revere-tools-job/plan-shows-in-the-chat ()
  "The plan tool keeps a checklist the chat draws with its count."
  (revere-tests--with-dir dir
    (let ((buffer (revere-chat-create dir)))
      (unwind-protect
          (with-current-buffer buffer
            (let ((job (revere-job-create "planned" dir)))
              (setq revere-chat--job job)
              (setf (revere-job-buffer job) buffer)
              (let ((revere-current-job job))
                (should (string-match-p "3 items, 1 done"
                                        (revere-tool-plan (list "[x] read" "write" "[ ] test")))))
              (revere-chat--refresh)
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "Plan  1 of 3 done" text))
                (should (string-match-p "\\[ \\] write" text)))))
        (kill-buffer buffer)))))

(ert-deftest revere-tools-job/delegate-runs-a-helper-and-folds-its-changes ()
  "A helper job answers its parent and its edits join the parent's changes."
  (revere-tests--with-dir dir
    (revere-tests--write dir "a.txt" "hello world\n")
    (let ((parent (revere-tests--job dir))
          (revere-rules '((t . go-ahead)))
          (result nil))
      (cl-letf (((symbol-function 'revere-llm-stream)
                 (revere-tests--fake-stream
                  (list (list "" (list (list :id "h1" :name "edit"
                                             :arguments "{\"path\":\"a.txt\",\"old_string\":\"hello\",\"new_string\":\"hi\"}"))
                              nil)
                        (list "Helper finished." nil nil)))))
        (let ((revere-current-job parent))
          (revere-tool-delegate (lambda (r) (setq result r)) "change hello to hi" nil))
        (should (revere-tests--wait (lambda () result))))
      (should (string-match-p "Helper finished\\." result))
      (should (string-match-p "1 changed file from the helper" result))
      (should (= (length (revere-ws-pending parent)) 1))
      (let ((child (cl-find-if (lambda (j) (equal (revere-job-origin j) (list 'parent (revere-job-id parent))))
                               revere-job-list)))
        (should child)
        (should (eq (revere-job-state child) 'done))))))

;;;; Routine notify and personas

(ert-deftest revere-routines/notify-and-prompt-file ()
  "A routine reports to its NOTIFY channel and runs with its PROMPT_FILE."
  (revere-tests--with-dir dir
    (let ((posted nil)
          (persona (revere-tests--write dir "reviewer.md" "You are the reviewer. Be brief."))
          (yesterday (format-time-string "%Y-%m-%d %a %H:%M" (time-subtract (current-time) (* 24 3600)))))
      (revere-channel-register "test" (lambda (_key text) (push text posted)))
      (revere-tests--fresh-file (revere-routines-file))
      (with-temp-file (revere-routines-file)
        (insert revere-routines--header
                (format "* ROUTINE Review\nSCHEDULED: <%s ++1d>\n:PROPERTIES:\n:ID: r-notify\n:DIRECTORY: %s\n:MODE: buffers\n:NOTIFY: test:7\n:PROMPT_FILE: %s\n:END:\nLook things over.\n"
                        yesterday dir persona)))
      (cl-letf (((symbol-function 'revere-llm-stream)
                 (revere-tests--fake-stream (list (list "All good." nil nil)))))
        (revere-routines-enable)
        (unwind-protect
            (progn
              (revere-routines-tick)
              (let ((job (revere-job-last)))
                (should (string-prefix-p "You are the reviewer." (plist-get (car (revere-job-messages job)) :content)))
                (should (revere-tests--wait (lambda () (not (revere-job-active-p job)))))))
          (revere-routines-disable)))
      (should (cl-some (lambda (p) (string-match-p "Look things over\\.: done\nAll good\\." p)) posted)))))

;;;; Doctor

(ert-deftest revere-doctor/reports ()
  "The doctor writes a report with ticks and crosses."
  (cl-letf (((symbol-function 'revere-doctor--endpoint) (lambda () (cons nil "endpoint faked"))))
    (revere-doctor)
    (with-current-buffer "*Revere doctor*"
      (let ((text (buffer-string)))
        (should (string-match-p "✗ endpoint faked" text))
        (should (string-match-p "✓ curl on the path" text))
        (should (string-match-p "logbook.org" text))))))

;;;; Mascot and minibuffer input

(ert-deftest revere-mascot/moods-and-frames ()
  "The owl's eyes follow the job's state and it animates while working."
  (let ((job (revere-job--make :number 1 :state 'working :detail "writing")))
    (should (eq (revere-mascot-mood nil) 'idle))
    (should (eq (revere-mascot-mood job) 'writing))
    (setf (revere-job-detail job) "running edit")
    (should (eq (revere-mascot-mood job) 'tool))
    ;; Head down when failed: nothing solid on the top line.  Head up when done.
    (setf (revere-job-state job) 'failed)
    (should-not (string-match-p "█" (substring-no-properties (nth 0 (revere-mascot-lines job 0)))))
    (setf (revere-job-state job) 'done)
    (should (string-match-p "██" (substring-no-properties (nth 0 (revere-mascot-lines job 0)))))
    (setf (revere-job-state job) 'working)
    (setf (revere-job-detail job) nil)
    (should (revere-mascot-animated-p job))
    (should (= (length (revere-mascot-lines job 3)) 3))
    (should-not (equal (revere-mascot-lines job 0) (revere-mascot-lines job 1)))))

(ert-deftest revere-chat/minibuffer-mode-has-footer-and-takes-typed-text ()
  "With minibuffer input the chat is read-only with the owl at the bottom, and dispatch sends."
  (revere-tests--with-dir dir
    (let ((revere-chat-input 'minibuffer))
      (cl-letf (((symbol-function 'revere-llm-stream)
                 (revere-tests--fake-stream (list (list "Sure." nil nil)))))
        (let ((buffer (revere-chat-create dir)))
          (unwind-protect
              (with-current-buffer buffer
                (should buffer-read-only)
                (should (null revere-chat--input-start))
                (should (string-match-p " █ █   █ █" (buffer-string)))
                (should (string-match-p "RET or type to talk" (buffer-string)))
                (revere-chat--dispatch "say hi")
                (let ((job revere-chat--job))
                  (should job)
                  (should (revere-tests--wait (lambda () (not (revere-job-active-p job)))))
                  (revere-chat--refresh)
                  (let ((text (buffer-string)))
                    (should (string-match-p "You › say hi" text))
                    (should (string-match-p "Revere › Sure\\." text))
                    (should (string-match-p "▄▄▄██" text))
                    (should (string-match-p "done" text)))))
            (kill-buffer buffer)))))))

;;;; Chat: results fold out

(ert-deftest revere-chat/tool-result-expands-and-collapses ()
  "Clicking a tool result shows the full text under the line, and hides it again."
  (revere-tests--with-dir dir
    (revere-tests--write dir "a.txt" "line one\nline two\n")
    (cl-letf (((symbol-function 'revere-llm-stream)
               (revere-tests--fake-stream
                (list (list "" (list (list :id "c1" :name "read" :arguments "{\"path\":\"a.txt\"}")) nil)
                      (list "Read." nil nil)))))
      (let ((buffer (revere-chat-create dir))
            (revere-rules '((t . go-ahead))))
        (unwind-protect
            (with-current-buffer buffer
              (goto-char (point-max))
              (insert "read it")
              (revere-chat-send)
              (let ((job revere-chat--job))
                (should (revere-tests--wait (lambda () (not (revere-job-active-p job))))))
              (goto-char (point-min))
              (should (search-forward "2 lines" nil t))
              (let ((button (button-at (1- (point)))))
                (should button)
                (revere-chat--toggle-result button)
                (should (string-match-p "      1\tline one" (buffer-string)))
                (revere-chat--toggle-result button)
                (should-not (string-match-p "1\tline one" (buffer-string)))))
          (kill-buffer buffer))))))

(provide 'revere-tests)
;;; revere-tests.el ends here
