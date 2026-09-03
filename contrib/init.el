;;; init.el --- Emacs configuration -*- lexical-binding: t; -*-

;;; Commentary:
;; The user's configuration with the swaps agreed in DESIGN.md section 2.10:
;; treemacs for neotree, magit and diff-hl added, eglot and flymake for
;; lsp-mode and flycheck, vertico/consult/embark for ivy, project.el for
;; projectile, doom-modeline for spaceline.  Look unchanged: zenburn,
;; nerd-icons, dashboard.  Revere loads at the end.
;;
;; Install: copy to %APPDATA%\.emacs.d\init.el.  First start installs the
;; packages from MELPA; run M-x nerd-icons-install-fonts once afterwards.

;;; Code:

;; ============================================================================
;; Package management
;; ============================================================================

(require 'package)
(setq package-archives '(("melpa" . "https://melpa.org/packages/")
                         ("gnu" . "https://elpa.gnu.org/packages/")
                         ("nongnu" . "https://elpa.nongnu.org/nongnu/")))
(package-initialize)

(unless (package-installed-p 'use-package)
  (package-refresh-contents)
  (package-install 'use-package))

(require 'use-package)
(setq use-package-always-ensure t)

(add-hook 'emacs-startup-hook
          (lambda () (setq gc-cons-threshold (* 16 1024 1024))))

(use-package auto-package-update
  :defer t
  :config
  (setq auto-package-update-delete-old-versions t)
  (setq auto-package-update-hide-results t))

;; ============================================================================
;; General settings
;; ============================================================================

(setq inhibit-startup-screen t)
(tool-bar-mode -1)

(set-frame-parameter nil 'alpha 99)
(add-to-list 'default-frame-alist '(alpha . 99))
(set-frame-size (selected-frame) 100 50)

(global-display-line-numbers-mode t)
(global-hl-line-mode t)
(show-paren-mode t)
(global-auto-revert-mode t)

(setq-default indent-tabs-mode nil)
(setq-default tab-width 4)

(set-language-environment "UTF-8")
(prefer-coding-system 'utf-8)
(set-default-coding-systems 'utf-8)
(set-terminal-coding-system 'utf-8)
(set-keyboard-coding-system 'utf-8)

(set-face-attribute 'default nil :height 120)

;; Emoji render natively since Emacs 28; this picks the font.
(when (display-graphic-p)
  (set-fontset-font t 'emoji
                    (cond
                     ((eq system-type 'windows-nt) "Segoe UI Emoji")
                     ((eq system-type 'darwin) "Apple Color Emoji")
                     (t "Noto Color Emoji"))
                    nil 'prepend))

;; ============================================================================
;; Theme and icons
;; ============================================================================

(use-package zenburn-theme
  :config
  (load-theme 'zenburn t))

;; Run M-x nerd-icons-install-fonts on first use.
(use-package nerd-icons
  :if (display-graphic-p))

(use-package nerd-icons-dired
  :after nerd-icons
  :hook (dired-mode . nerd-icons-dired-mode))

;; ============================================================================
;; Dashboard
;; ============================================================================

(use-package dashboard
  :after nerd-icons
  :config
  (let ((banner (expand-file-name "banner.txt" user-emacs-directory)))
    (setq dashboard-startup-banner (if (file-exists-p banner) banner 'logo)))
  (setq dashboard-center-content t)
  (setq dashboard-banner-logo-title "Take Dead Aim")
  (setq dashboard-icon-type 'nerd-icons)
  ;; The layout list replaced the old navigator and footer switches.
  (setq dashboard-startupify-list
        '(dashboard-insert-banner
          dashboard-insert-newline
          dashboard-insert-banner-title
          dashboard-insert-newline
          dashboard-insert-navigator
          dashboard-insert-newline
          dashboard-insert-init-info
          dashboard-insert-items))
  (setq dashboard-set-heading-icons t)
  (setq dashboard-set-file-icons t)
  (setq dashboard-items '((recents . 5)
                          (agenda . 5)
                          (projects . 5)))
  (setq dashboard-projects-backend 'project-el)
  (setq dashboard-navigator-buttons
        `(((,(nerd-icons-faicon "nf-fa-github" :height 1.0 :v-adjust 0.0)
            "Repos" "GitHub Repos"
            (lambda (&rest _) (browse-url "https://github.com/")))
           (,(nerd-icons-faicon "nf-fa-building" :height 1.0 :v-adjust 0.0)
            "Jira" "Atlassian"
            (lambda (&rest _) (browse-url "https://start.atlassian.com/")))
           (,(nerd-icons-faicon "nf-fa-envelope" :height 1.0 :v-adjust 0.0)
            "Gmail" "Email"
            (lambda (&rest _) (browse-url "https://mail.google.com/")))
           (,(nerd-icons-faicon "nf-fa-bullseye" :height 1.0 :v-adjust 0.0)
            "Revere" "Start a job"
            (lambda (&rest _) (call-interactively #'revere-new))))))
  (dashboard-setup-startup-hook))

;; ============================================================================
;; Projects: project.el (built in; what eglot, xref, consult and Revere use)
;; ============================================================================

(use-package project
  :ensure nil
  :bind-keymap ("C-c p" . project-prefix-map))

;; ============================================================================
;; Completion: vertico, orderless, marginalia, consult, embark
;; ============================================================================

(use-package vertico
  :init (vertico-mode))

(use-package orderless
  :custom
  (completion-styles '(orderless basic))
  (completion-category-overrides '((file (styles basic partial-completion)))))

(use-package marginalia
  :init (marginalia-mode))

(use-package consult
  :bind (("C-s" . consult-line)
         ("C-x b" . consult-buffer)
         ("C-c g" . consult-git-grep)
         ("C-c j" . consult-ripgrep)
         ("M-y" . consult-yank-pop)
         ("M-g g" . consult-goto-line)
         ("M-g f" . consult-flymake)))

(use-package embark
  :bind (("C-." . embark-act)
         ("C-;" . embark-dwim)
         ("C-h B" . embark-bindings)))

(use-package embark-consult
  :after (embark consult)
  :hook (embark-collect-mode . consult-preview-at-point-mode))

;; ============================================================================
;; File tree: treemacs
;; ============================================================================

(use-package treemacs
  :bind (("<f8>" . treemacs))
  :config
  (treemacs-follow-mode 1)
  (treemacs-git-mode 'deferred))

(use-package treemacs-nerd-icons
  :after (treemacs nerd-icons)
  :config (treemacs-load-theme "nerd-icons"))

(use-package treemacs-magit
  :after (treemacs magit))

;; ============================================================================
;; Git: magit and diff-hl
;; ============================================================================

(use-package magit
  :bind ("C-x g" . magit-status))

(use-package diff-hl
  :config
  (global-diff-hl-mode)
  (diff-hl-flydiff-mode)
  :hook ((magit-pre-refresh . diff-hl-magit-pre-refresh)
         (magit-post-refresh . diff-hl-magit-post-refresh)))

;; ============================================================================
;; In-buffer completion
;; ============================================================================

(use-package company
  :diminish company-mode
  :hook (after-init . global-company-mode)
  :config
  (setq company-idle-delay 0.2)
  (setq company-minimum-prefix-length 2)
  (setq company-selection-wrap-around t))

;; ============================================================================
;; Programming: eglot and flymake (built in)
;; ============================================================================

(use-package flymake
  :ensure nil
  :hook (prog-mode . flymake-mode))

(use-package eglot
  :ensure nil
  :hook ((python-mode python-ts-mode web-mode) . eglot-ensure))

(use-package rainbow-identifiers
  :hook (prog-mode . rainbow-identifiers-mode))

(use-package hideshow
  :ensure nil
  :hook (prog-mode . hs-minor-mode))

;; ============================================================================
;; Programming: web
;; ============================================================================

(use-package web-mode
  :mode (("\\.html?\\'" . web-mode)
         ("\\.css\\'" . web-mode)
         ("\\.jsx?\\'" . web-mode)
         ("\\.tsx?\\'" . web-mode))
  :config
  (setq web-mode-markup-indent-offset 2)
  (setq web-mode-css-indent-offset 2)
  (setq web-mode-code-indent-offset 2))

(use-package npm-mode
  :hook (web-mode . npm-mode))

(use-package web-beautify
  :defer t)

;; ============================================================================
;; Org
;; ============================================================================

(use-package org
  :ensure nil
  :defer t
  :config
  (setq org-startup-indented t)
  (setq org-hide-leading-stars t))

(use-package org-timeline
  :hook (org-agenda-finalize . org-timeline-insert-timeline))

;; ============================================================================
;; Mode line
;; ============================================================================

(use-package doom-modeline
  :init (doom-modeline-mode 1)
  :config
  (setq doom-modeline-icon t))

;; ============================================================================
;; Other agents (kept from the previous configuration)
;; ============================================================================

;; Requires:
;;   npm install -g @anthropic-ai/claude-code
;;   npm install -g @zed-industries/claude-code-acp
(use-package agent-shell
  :vc (:url "https://github.com/xenodium/agent-shell" :rev :newest)
  :bind (("C-c c c" . agent-shell)
         ("C-c c n" . agent-shell-new))
  :config
  (setq agent-shell-default-agent "claude-code-acp"))

;; ============================================================================
;; Fun
;; ============================================================================

(use-package chess
  :defer t)

;; ============================================================================
;; Revere
;; ============================================================================

;; The Discord channel needs websocket; the token lives in auth-source.
(use-package websocket :defer t)

(add-to-list 'load-path "~/src/revere/lisp")
(require 'revere)
(setq revere-base-url "http://localhost:4000"
      revere-model    "qwen-3.8")

;; Let the byte compiler check Revere's own files through flymake.
(when (boundp 'trusted-content)
  (add-to-list 'trusted-content "~/src/revere/"))

;; Routines show up in the agenda (and on the dashboard) once the file exists.
(with-eval-after-load 'org
  (let ((routines (expand-file-name "routines.org" revere-directory)))
    (when (file-exists-p routines)
      (add-to-list 'org-agenda-files routines))))

;; ============================================================================
;; Custom file
;; ============================================================================

(setq custom-file (expand-file-name "custom.el" user-emacs-directory))
(when (file-exists-p custom-file)
  (load custom-file))

;;; init.el ends here
