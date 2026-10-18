;;; core.scm -- the editor-wide pieces every mode builds on.
;;;
;;; The Rust side only provides primitives (see crates/imp-server/src/api.rs):
;;; buffer access, the cursor, the status line. Keymaps, modes and commands
;;; are all defined here and in the files loaded after this one, and any of
;;; them can be redefined from ~/.config/imp/init.scm.

;;; Keymaps

;; mode (a symbol) -> hash of key string -> command
(define *keymaps* (hash))

(define (keymap mode)
  (let ([m (hash-try-get *keymaps* mode)])
    (if m m (hash))))

;; Binds `key` to `command` in `mode`. Commands are ordinary procedures; what
;; arguments they take is up to the mode that calls them.
(define (define-key! mode key command)
  (set! *keymaps* (hash-insert *keymaps* mode (hash-insert (keymap mode) key command))))

(define (lookup-key mode key)
  (hash-try-get (keymap mode) key))

;;; Faces and highlight layers
;;;
;;; A face is a named style; its spec is a string like "fg=#ff8800 bold"
;;; (colors are #rrggbb, ANSI names such as bright-blue, or 0-255). Redefine
;;; a face in init.scm to restyle everything that uses it.

(set-face! "status" "reverse")
(set-face! "nontext" "fg=blue")
(set-face! "visual" "bg=#3e4452")
(set-face! "search" "fg=black bg=yellow")
(set-face! "search-current" "fg=black bg=#ff8800")

;; Layers draw in the order they are first used, later over earlier, so
;; declare them here in the order they should stack.
(for-each highlight-clear! '("syntax" "search" "visual"))

;;; Buffer helpers built from the primitives

(define (clamp n lo hi) (max lo (min n hi)))

(define (current-line) (offset->line (cursor)))
(define (current-col) (offset->col (cursor)))

(define (line-start line) (line-col->offset line 0))
(define (line-end line) (+ (line-start line) (buffer-line-length line)))
(define (last-line) (- (buffer-line-count) 1))

;; Offset of the first non-blank char on `line`, or its end if it is blank.
(define (line-first-nonblank line)
  (let ([end (line-end line)])
    (let loop ([p (line-start line)])
      (if (and (< p end) (char-whitespace? (buffer-char-at p)))
          (loop (+ p 1))
          p))))

;;; Entry points called by the server

;; Called once after init.scm has loaded. Modes redefine it.
(define (imp-init) #t)

;; Called for every key from the client. Modes redefine it.
(define (imp-handle-key key)
  (set-status! (string-append "no mode loaded; got " key)))
