;;; A starter ~/.config/imp/init.scm. Everything here is ordinary Scheme
;;; evaluated after the runtime loads, so any of it can be changed live:
;;; edit, then SPC e b (eval buffer) or :source %. Look things up with
;;; SPC h (describe key/function/option) and :help.

;;; Options (:set works too, e.g. :set rnu)
(set-option! 'number #t)
(set-option! 'relativenumber #t)
(set-option! 'cursorline #t)
(set-option! 'tabstop 4)
(set-option! 'shiftwidth 4)
(set-option! 'clipboard "unnamedplus")   ; y and p use the system clipboard
(set-option! 'which-key-delay 200)
(set-option! 'mouse-scroll 5)

;;; Look: one-dark (default), gruvbox-dark, everforest-dark, one-light, or your own
(load-theme! 'gruvbox-dark)

;; A theme of your own: start from one, change a few colors and faces.
(define-theme! 'midnight 'one-dark
  (hash 'bg "#1a1b26" 'bg-alt "#16161e" 'blue "#7aa2f7")
  (list (list "syntax.comment" "fg=#565f89 italic")))
;; (load-theme! 'midnight)

;; The window: font, space around the text, and a see-through background.
;; (set-option! 'font "JetBrains Mono")
;; (set-option! 'font-size 16)
(set-option! 'window-padding 40)
;; (set-option! 'background-opacity 0.9)
;; In a terminal, leave the background to the terminal (and its opacity).
;; (set-option! 'terminal-background #f)

;;; Where generated buffers open: a name prefix, then 'side ('bottom, 'top,
;;; 'left, 'right), 'size (part of the frame), 'select and 'quit (q closes).
(define-popup-rule! "*grep*" 'side 'right 'size 0.3)
;; (remove-popup-rule! "*git")  ; git status takes over the window again

;;; Packages that come with imp, off until you ask (:packages lists them).
;; (use-package! 'olivetti                    ; SPC t o: a centred column of text
;;   'config (lambda ()
;;             (set-option! 'olivetti-body-width 80)
;;             (set-option! 'olivetti-modes '(org-mode markdown-mode))))
;; (use-package! 'posframe)                   ; M-x, find-file... in a centred box
;; (use-package! 'org-babel)                  ; C-c C-c runs Org source blocks
;; (use-package! 'move-lines)                 ; J and K move lines selected with V
;; (use-package! 'nerd-icons)                 ; icons (needs a Nerd Font, set with 'font)

;;; Claude Code (M-a, SPC a): the program it runs, and where its window goes.
;; (set-option! 'claude-command "claude --model opus")
;; (define-popup-rule! "*claude" 'side 'right 'size 0.4)

;;; Completion in insert state (C-n / C-p, or by itself as you type in code)
;; (set-option! 'completion-keys 'tab)          ; vim (C-y), tab or enter accepts
;; (set-option! 'completion-auto-min 2)         ; open after this many chars
;; (set-option! 'completion-menu-columns '(icon label detail source))
;; (set-completion-sources! 'markdown-mode '(file words))  ; groups, tried in turn

;;; Keys
(define-key! 'normal "C-s" 'save-buffer)
;; Tab cycles buffers (it replaces C-i, which is the same key in a terminal).
(define-key! 'normal "<tab>" 'next-buffer)
(define-key! 'normal "<s-tab>" 'previous-buffer)

;; Your own command, on the leader and in M-x.
(define-command! 'insert-date
  (lambda (count)
    "Insert today's date at the cursor."  ; a docstring: M-x and SPC h f show it
    (begin-change!)
    (buffer-insert! (cursor) (without-final-newline (cadr (run-shell "date +%F" ""))))))
(define-leader! "id" 'insert-date "insert date")

;;; Per-language settings
(add-hook! 'major-mode
  (lambda (mode)
    (when (member mode '(typescript-mode javascript-mode))
      (set-local-option! 'tabstop 2)
      (set-local-option! 'shiftwidth 2))))

;;; Trim trailing whitespace on save, keeping the cursor where it was
(add-hook! 'before-save
  (lambda ()
    (let ([line (current-line)] [col (current-col)])
      (run-ex! "%s/\\s\\+$//e")
      (set-cursor! (line-col->offset line col)))))
