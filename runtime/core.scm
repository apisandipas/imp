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

;;; Options
;;;
;;; Named settings, read with (option 'name) and changed with set-option!
;;; or :set. An option can have a watcher that runs when it changes, for
;;; settings Rust needs to know about (tabstop).

(define *options* (hash))
(define *option-watchers* (hash))
(define *option-aliases* (hash))

;; Defines option `name` (a symbol) with a default value and short names
;; for :set, e.g. (define-option! 'shiftwidth 4 '(sw)).
(define (define-option! name default aliases)
  (set! *options* (hash-insert *options* name default))
  (for-each (lambda (a) (set! *option-aliases* (hash-insert *option-aliases* a name))) aliases))

(define (option-name name)
  (cond [(hash-contains? *options* name) name]
        [(hash-try-get *option-aliases* name) => (lambda (n) n)]
        [else #f]))

(define (option name) (hash-ref *options* name))

(define (set-option! name value)
  (let ([name (or (option-name name) (error (string-append "unknown option: " (symbol->string name))))])
    (set! *options* (hash-insert *options* name value))
    (let ([watch (hash-try-get *option-watchers* name)])
      (when watch (watch value)))))

(define (watch-option! name proc)
  (set! *option-watchers* (hash-insert *option-watchers* name proc))
  (proc (option name)))

(define-option! 'tabstop 4 '(ts))
(define-option! 'shiftwidth 4 '(sw))
(define-option! 'expandtab #t '(et))
(define-option! 'autoindent #t '(ai))
(define-option! 'wrapscan #t '(ws))
(define-option! 'hlsearch #t '(hls))
(define-option! 'incsearch #t '(is))
;; "unnamedplus" makes the unnamed register the system clipboard.
(define-option! 'clipboard "" '(cb))
(watch-option! 'tabstop set-tab-width!)

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
