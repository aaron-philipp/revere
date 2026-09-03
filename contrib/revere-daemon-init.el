;;; revere-daemon-init.el --- Init file for the Revere daemon -*- lexical-binding: t; -*-

;;; Commentary:
;; Copy to ~/.revere/init.el and start the daemon with:
;;   Windows:  runemacs --daemon=revere -Q -l %USERPROFILE%\.revere\init.el
;;   Others:   emacs --daemon=revere -Q -l ~/.revere/init.el
;; Connect with: emacsclient -s revere -c   (emacsclientw on Windows)
;; From your daily Emacs: (require 'revere-client) then M-x revere-client-new.

;;; Code:

(setq server-use-tcp (eq system-type 'windows-nt))

(add-to-list 'load-path "~/src/revere")
(require 'revere)

(setq revere-base-url "http://localhost:4000"
      revere-model    "qwen-3.8")

;; Unattended jobs get no minibuffer; approvals wait in the list and in the
;; chat until a client connects.
(revere-daemon-start)

;;; revere-daemon-init.el ends here
