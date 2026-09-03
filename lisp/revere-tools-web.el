;;; revere-tools-web.el --- Fetch pages and search the web -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Revere contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; `fetch' gets a URL with Emacs's own url library and renders HTML to text
;; with shr, the engine behind eww.  `search' asks a SearXNG instance or
;; Brave, whichever `revere-search-provider' names.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'url-util)
(require 'shr)
(require 'dom)
(require 'auth-source)
(require 'revere-config)
(require 'revere-tools)

;;;; fetch

(defun revere-tools-web--problem (status)
  "A readable message for the :error in a `url-retrieve' STATUS, or nil."
  (let ((problem (plist-get status :error)))
    (when problem
      (let ((data (if (eq (car-safe problem) 'error) (cdr problem) problem)))
        (pcase (car-safe data)
          ('connection-failed (format "could not connect to %s"
                                      (or (plist-get (cddr data) :host) (cadr data))))
          (_ (mapconcat (lambda (part) (format "%s" part)) (if (listp data) data (list data)) " ")))))))

(defconst revere-tools-web--user-agent
  "Mozilla/5.0 (compatible; Revere/0.2; Emacs)"
  "How Revere introduces itself to web servers.")

(defun revere-tools-web--body-start ()
  "Position where the response body starts in the current buffer."
  (or (and (boundp 'url-http-end-of-headers) url-http-end-of-headers
           (marker-position url-http-end-of-headers))
      (save-excursion
        (goto-char (point-min))
        (if (re-search-forward "^HTTP/" (line-end-position) t)
            (or (and (re-search-forward "^\r?$" nil t) (1+ (point))) (point-min))
          (point-min)))))

(defun revere-tools-web--html-p ()
  "Non-nil if the current response looks like HTML."
  (save-excursion
    (goto-char (point-min))
    (or (re-search-forward "^Content-Type: *text/html" nil t)
        (let ((start (revere-tools-web--body-start)))
          (goto-char start)
          (re-search-forward "<\\(html\\|!doctype\\|body\\|head\\)" (min (point-max) (+ start 2000)) t)))))

(defun revere-tools-web-render (html)
  "HTML as readable text."
  (with-temp-buffer
    (insert html)
    (let ((dom (if (fboundp 'libxml-parse-html-region)
                   (libxml-parse-html-region (point-min) (point-max))
                 nil)))
      (erase-buffer)
      (if dom
          (let ((shr-width 100) (shr-use-fonts nil) (shr-inhibit-images t))
            (shr-insert-document dom))
        (insert (replace-regexp-in-string "<[^>]+>" " " html))))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (string-trim (replace-regexp-in-string "\n\\{3,\\}" "\n\n" text)))))

(defun revere-tools-web--response-text ()
  "The current response buffer as text, rendered if it is HTML."
  (let* ((start (revere-tools-web--body-start))
         (body (decode-coding-string (buffer-substring-no-properties start (point-max)) 'utf-8 t)))
    (if (revere-tools-web--html-p)
        (revere-tools-web-render body)
      (string-trim body))))

(defun revere-tools-web--limit (text)
  "TEXT cut to `revere-fetch-limit' characters."
  (if (> (length text) revere-fetch-limit)
      (concat (substring text 0 revere-fetch-limit)
              (format "\n… truncated; %d more characters" (- (length text) revere-fetch-limit)))
    text))

(revere-deftool fetch ((url string "An http, https or file URL"))
  "Fetch a web page or file and return its text.
HTML is rendered to plain text; long pages are truncated."
  :async t
  (condition-case err
      (let ((url-request-extra-headers (list (cons "User-Agent" revere-tools-web--user-agent))))
        (url-retrieve url
                      (lambda (status)
                        (let ((problem (revere-tools-web--problem status)))
                          (funcall callback
                                   (if problem
                                       (format "fetch failed: %s" problem)
                                     (revere-tools-web--limit (revere-tools-web--response-text)))))
                        (kill-buffer (current-buffer)))
                      nil t t))
    (error (funcall callback (format "fetch failed: %s" (error-message-string err))))))

;;;; search

(defun revere-tools-web--get-json (url headers callback)
  "GET URL with HEADERS; call CALLBACK with the parsed JSON, or (:error TEXT)."
  (let ((url-request-extra-headers (cons (cons "Accept" "application/json") headers)))
    (url-retrieve url
                  (lambda (status)
                    (let ((problem (revere-tools-web--problem status))
                          (result nil))
                      (setq result
                            (if problem
                                (list :error problem)
                              (condition-case err
                                  (json-parse-string
                                   (decode-coding-string
                                    (buffer-substring-no-properties (revere-tools-web--body-start) (point-max))
                                    'utf-8 t)
                                   :object-type 'hash-table :array-type 'list
                                   :null-object nil :false-object nil)
                                (error (list :error (error-message-string err))))))
                      (kill-buffer (current-buffer))
                      (funcall callback result)))
                  nil t t)))

(defun revere-tools-web--format-results (results count)
  "Format RESULTS, a list of (TITLE URL SNIPPET), at most COUNT of them."
  (if (null results)
      "No results"
    (mapconcat (lambda (result)
                 (format "%s\n  %s\n  %s" (nth 0 result) (nth 1 result)
                         (truncate-string-to-width (or (nth 2 result) "") 300 nil nil "…")))
               (seq-take results count) "\n\n")))

(defun revere-tools-web--searxng (query count callback)
  "Search a SearXNG instance for QUERY; CALLBACK gets COUNT results as text."
  (revere-tools-web--get-json
   (format "%s/search?q=%s&format=json" (string-trim-right revere-search-url "/+")
           (url-hexify-string query))
   nil
   (lambda (object)
     (funcall callback
              (cond
               ((and (listp object) (plist-get object :error))
                (format "search failed: SearXNG at %s: %s (set revere-search-url, or another revere-search-provider)"
                        revere-search-url (plist-get object :error)))
               ((hash-table-p object)
                (revere-tools-web--format-results
                 (mapcar (lambda (r) (list (gethash "title" r) (gethash "url" r) (gethash "content" r)))
                         (cl-remove-if-not #'hash-table-p (gethash "results" object)))
                 count))
               (t "search failed: unexpected reply"))))))

(defun revere-tools-web--brave-key ()
  "The Brave Search API key from `auth-source', or nil."
  (let* ((found (car (auth-source-search :host "api.search.brave.com" :max 1)))
         (secret (and found (plist-get found :secret))))
    (if (functionp secret) (funcall secret) secret)))

(defun revere-tools-web--brave (query count callback)
  "Search Brave for QUERY; CALLBACK gets COUNT results as text."
  (let ((key (revere-tools-web--brave-key)))
    (if (null key)
        (funcall callback "search failed: no Brave API key in auth-source for api.search.brave.com")
      (revere-tools-web--get-json
       (format "https://api.search.brave.com/res/v1/web/search?q=%s&count=%d"
               (url-hexify-string query) count)
       (list (cons "X-Subscription-Token" key))
       (lambda (object)
         (funcall callback
                  (cond
                   ((and (listp object) (plist-get object :error))
                    (format "search failed: %s" (plist-get object :error)))
                   ((hash-table-p object)
                    (let ((web (gethash "web" object)))
                      (revere-tools-web--format-results
                       (mapcar (lambda (r) (list (gethash "title" r) (gethash "url" r) (gethash "description" r)))
                               (cl-remove-if-not #'hash-table-p (and (hash-table-p web) (gethash "results" web))))
                       count)))
                   (t "search failed: unexpected reply"))))))))

(defun revere-tools-web--duckduckgo-url (href)
  "The real URL behind a DuckDuckGo result HREF."
  (if (string-match "uddg=\\([^&]+\\)" href)
      (url-unhex-string (match-string 1 href))
    href))

(defun revere-tools-web--text (node)
  "The text inside DOM NODE."
  (if (fboundp 'dom-inner-text)
      (dom-inner-text node)
    (with-no-warnings (dom-texts node))))

(defun revere-tools-web-duckduckgo-parse (html)
  "Results in DuckDuckGo's HTML search page, as (TITLE URL SNIPPET) lists."
  (if (not (fboundp 'libxml-parse-html-region))
      nil
    (let* ((dom (with-temp-buffer
                  (insert html)
                  (libxml-parse-html-region (point-min) (point-max))))
           (links (dom-by-class dom "\\`result__a\\'"))
           (snippets (mapcar (lambda (node) (string-trim (revere-tools-web--text node)))
                             (dom-by-class dom "\\`result__snippet\\'")))
           (results nil))
      (cl-loop for link in links
               for i from 0
               for href = (dom-attr link 'href)
               when href
               do (push (list (string-trim (revere-tools-web--text link))
                              (revere-tools-web--duckduckgo-url href)
                              (nth i snippets))
                        results))
      (nreverse results))))

(defun revere-tools-web--duckduckgo (query count callback)
  "Search DuckDuckGo for QUERY; CALLBACK gets COUNT results as text."
  (let ((url-request-extra-headers (list (cons "User-Agent" revere-tools-web--user-agent))))
    (url-retrieve
     (format "https://html.duckduckgo.com/html/?q=%s" (url-hexify-string query))
     (lambda (status)
       (let ((problem (revere-tools-web--problem status))
             (text nil))
         (unless problem
           (setq text (decode-coding-string
                       (buffer-substring-no-properties (revere-tools-web--body-start) (point-max))
                       'utf-8 t)))
         (kill-buffer (current-buffer))
         (funcall callback
                  (cond
                   (problem (format "search failed: %s" problem))
                   (t (let ((results (revere-tools-web-duckduckgo-parse text)))
                        (if results
                            (revere-tools-web--format-results results count)
                          "No results (DuckDuckGo returned a page without results; try again or set revere-search-provider)")))))))
     nil t t)))

(revere-deftool search ((query string "What to search for")
                        (count integer "How many results, default 8" :optional t))
  "Search the web.  Returns titles, URLs and snippets; fetch a URL to read it."
  :async t
  (let ((count (or count 8)))
    (pcase revere-search-provider
      ('brave (revere-tools-web--brave query count callback))
      ('searxng (revere-tools-web--searxng query count callback))
      (_ (revere-tools-web--duckduckgo query count callback)))))

(provide 'revere-tools-web)
;;; revere-tools-web.el ends here
