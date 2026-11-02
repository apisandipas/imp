;;; cloak.scm -- secret values drawn as ****, after Emacs's cloak-mode and
;;; Neovim's cloak.nvim.
;;;
;;;   (use-package! 'cloak)
;;;
;;; cloak-mode turns on in every buffer whose file name matches one of
;;; cloak-file-patterns (.env, .env.local, prod.env, .envrc...). While
;;; it is on, what cloak-pattern's groups match (everything after the
;;; first = on a line) is drawn as cloak-mask-char, one per cell, so a
;;; screen share or a screencast doesn't show it. Only the drawing
;;; changes: the text, what :w saves and what y yanks are the real values.
;;;
;;;   SPC t c, M-x cloak-mode   cloak this buffer, or show it plain
;;;   M-x cloak-reveal-line     show the cursor's line plain until the
;;;                             cursor leaves it
;;;
;;; A cloaked buffer's words are kept out of completion (completion-words
;;; off), so its values never show in a menu either.

;; Globs of file names (without their directory) whose buffers turn
;; cloak-mode on when they open: * is any run of chars, ? any one.
(define-option! 'cloak-file-patterns '(".env" ".env.*" "*.env" ".envrc") '())
;; A Vim pattern: what its groups match (all of a match without groups)
;; is drawn masked. The default masks everything after a line's first =.
(define-option! 'cloak-pattern "=\\(.\\+\\)" '())
;; The char drawn in place of each cell of a masked value.
(define-option! 'cloak-mask-char "*" '())
;; Draw the cursor's line plain, as cloak.nvim's cloak_reveal_cursor_line.
(define-option! 'cloak-reveal-cursor-line #f '())

;; The buffer whose cursor line cloak-reveal-line shows, and the line, as
;; (buffer line), or #f.
(define *cloak-revealed* #f)

(define (cloak-glob-match? glob name)
  "Whether file name `name` matches `glob`, where * matches any run of
   chars and ? any one char."
  (let loop ([g (string->list glob)] [n (string->list name)])
    (cond [(null? g) (null? n)]
          [(equal? (car g) #\*)
           (or (loop (cdr g) n) (and (pair? n) (loop g (cdr n))))]
          [(null? n) #f]
          [(or (equal? (car g) #\?) (equal? (car g) (car n))) (loop (cdr g) (cdr n))]
          [else #f])))

(define (cloak-file?)
  "Whether the current buffer visits a file whose name matches one of
   cloak-file-patterns."
  (let ([path (buffer-path)])
    (and path
         (let ([name (file-name-of path)])
           (let loop ([globs (option 'cloak-file-patterns)])
             (cond [(null? globs) #f]
                   [(cloak-glob-match? (car globs) name) #t]
                   [else (loop (cdr globs))]))))))

(define (cloak-apply!)
  "Draws the current buffer's values masked as the options say, the
   cursor's line plain while cloak-reveal-line shows it."
  (let ([revealed? (and *cloak-revealed* (= (car *cloak-revealed*) (current-buffer)))])
    (buffer-mask-pattern! "cloak" (option 'cloak-pattern) (option 'cloak-mask-char)
                          (or revealed? (and (option 'cloak-reveal-cursor-line) #t)))))

(define (cloak-setup!)
  "Masks the buffer's values and keeps its words out of completion,
   remembering whether completion-words was set for it before."
  (set-buffer-local! 'cloak-words-was
                     (list (hash-contains? (buffer-locals) (list 'option 'completion-words))
                           (option 'completion-words)))
  (set-local-option! 'completion-words #f)
  (cloak-apply!))

(define (cloak-teardown!)
  "Draws the buffer plain again and gives completion its words back."
  (buffer-mask-pattern! "cloak" "" "*" #f)
  (when (and *cloak-revealed* (= (car *cloak-revealed*) (current-buffer)))
    (set! *cloak-revealed* #f))
  (let ([was (buffer-local 'cloak-words-was)])
    ;; A value of its own goes back; without one, the buffer follows the
    ;; global value again.
    (if (and was (car was))
        (set-local-option! 'completion-words (cadr was))
        (set! *buffer-locals*
              (hash-insert *buffer-locals* (current-buffer)
                           (hash-remove (buffer-locals) (list 'option 'completion-words)))))
    (set-buffer-local! 'cloak-words-was #f)))

(define-minor-mode! 'cloak-mode cloak-setup! cloak-teardown!)

(define-command! 'cloak-mode
  (lambda (count)
    "Turn cloak-mode on or off: this buffer's values drawn as a mask."
    (toggle-minor-mode! 'cloak-mode)))

(define-command! 'cloak-reveal-line
  (lambda (count)
    "Show the cursor's line plain until the cursor leaves it, for a quick
     look at one value."
    (if (memq 'cloak-mode (minor-modes))
        (begin
          (cloak-hide-revealed!)
          (set! *cloak-revealed* (list (current-buffer) (current-line)))
          (cloak-apply!))
        (message "cloak-mode is off"))))

(define (cloak-hide-revealed!)
  "Masks the line cloak-reveal-line showed again, if any."
  (let ([shown *cloak-revealed*])
    (set! *cloak-revealed* #f)
    (when (and shown (member (car shown) (buffer-list)))
      (with-buffer (car shown)
                   (lambda () (when (memq 'cloak-mode (minor-modes)) (cloak-apply!))))))
  void)

(define (cloak-start!)
  "Turns cloak-mode on in the current buffer if its file name matches
   cloak-file-patterns."
  (when (cloak-file?) (minor-mode-on! 'cloak-mode)))

(define-leader! "tc" 'cloak-mode "cloak")

;; Matching buffers cloak themselves as they open or take a new name,
;; and the ones already open when the package loads do now.
(add-hook! 'buffer-open cloak-start!)
(add-hook! 'buffer-renamed (lambda (from) (cloak-start!)))
(add-hook! 'startup (lambda () (for-each (lambda (id) (with-buffer id cloak-start!)) (buffer-list))))
(for-each (lambda (id) (with-buffer id cloak-start!)) (buffer-list))

;; A revealed line is masked again once the cursor leaves it or its buffer.
(add-hook! 'post-command
  (lambda ()
    (when (and *cloak-revealed*
               (not (and (= (car *cloak-revealed*) (current-buffer))
                         (= (cadr *cloak-revealed*) (current-line)))))
      (cloak-hide-revealed!))))

;; The options take effect at once wherever cloak-mode is on.
(add-hook! 'option-change
  (lambda (name value)
    (when (memq name '(cloak-pattern cloak-mask-char cloak-reveal-cursor-line))
      (for-each (lambda (id)
                  (with-buffer id (lambda () (when (memq 'cloak-mode (minor-modes)) (cloak-apply!)))))
                (buffer-list)))))
