;;; git-blame.scm -- the cursor's line's last commit after the line, as
;;; GitLens, gitsigns' current_line_blame and blamer.el show it.
;;;
;;;   (use-package! 'git-blame)
;;;
;;; git-blame-mode turns on in every buffer visiting a file in a git
;;; repository. SPC g b or :GitBlame turns it off and on in a buffer.

(define (git-blame-file?)
  "Whether the current buffer visits a file in a git repository."
  (and (buffer-path) (git-root-of (directory-of (expand-path (buffer-path)))) #t))

(define-minor-mode! 'git-blame-mode #f #f)

(define-command! 'git-blame-mode
  (lambda (count)
    "Turn git-blame-mode on or off: the cursor's line's last commit after it."
    (toggle-minor-mode! 'git-blame-mode)))

(define-leader! "gb" 'git-blame-mode "blame")
(define-ex! '("GitBlame") (lambda (ex) (run-command 'git-blame-mode)))

(define (git-blame-start!)
  "Turns git-blame-mode on in the current buffer if it visits a file in
   a git repository."
  (when (git-blame-file?) (minor-mode-on! 'git-blame-mode)))

;; Files opened from now on, and those open as the package loads.
(add-hook! 'buffer-open git-blame-start!)
(for-each (lambda (id) (with-buffer id git-blame-start!)) (buffer-list))
