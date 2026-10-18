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

;; Binds `key` to `command` in `mode`. A command is a procedure, or the
;; name (a symbol) of one made with define-command!; a name is looked up
;; each time the key is pressed, so redefining the command changes every
;; key bound to it. What arguments a command takes is up to the mode that
;; calls it; Vim's modes pass the count.
(define (define-key! mode key command)
  (set! *keymaps* (hash-insert *keymaps* mode (hash-insert (keymap mode) key command))))

;; The procedure `key` runs in `mode`, or #f.
(define (lookup-key mode key)
  (let ([binding (hash-try-get (keymap mode) key)])
    (if (symbol? binding) (command-proc binding) binding)))

;; What `key` is bound to as written: a command name or a procedure.
(define (key-binding mode key) (hash-try-get (keymap mode) key))

;;; Named commands
;;;
;;; (define-command! 'name proc) gives a procedure a name that keys, the
;;; leader menu and M-x can refer to. Commands take a count (1 by default).

(define *commands* (hash))

(define (define-command! name proc)
  (set! *commands* (hash-insert *commands* name proc)))

(define (command-proc name) (hash-try-get *commands* name))

(define (command-names) (hash-keys->list *commands*))

;; Runs command `name` (with a count of 1 unless given).
(define (run-command name . count)
  (let ([proc (command-proc name)])
    (if proc
        (proc (if (null? count) 1 (car count)))
        (set-status! (string-append "no command " (symbol->string name))))))

;;; Messages: the status line, with a history for :messages.

(define *messages* '())

(define (message text)
  (set-status! text)
  (set! *messages* (cons text (if (> (length *messages*) 199) (reverse (cdr (reverse *messages*))) *messages*))))

;;; Evaluating code while the editor runs
;;;
;;; In Steel, define-ing a name that already exists makes a new binding
;;; that code compiled earlier never sees; set! changes the binding everyone
;;; uses. So user code (init.scm, :eval, eval-region, packages) is evaluated
;;; through imp-eval-form, which turns a define of an existing name into a
;;; set!. That is what lets init.scm or a live :eval redefine any function
;;; in the runtime and have the whole editor use the new one.

(define (bound? name)
  (with-handler (lambda (e) #f) (begin (eval name) #t)))

;; `form` with a top-level define of an existing name made into a set!.
;; (begin ...) forms are rewritten inside, as at top level.
(define (redefinition form)
  (cond
    [(not (pair? form)) form]
    [(eq? (car form) 'begin) (cons 'begin (map redefinition (cdr form)))]
    [(and (eq? (car form) 'define) (pair? (cdr form)))
     (let ([target (cadr form)])
       (cond
         ;; (define (name . params) body ...)
         [(and (pair? target) (symbol? (car target)) (bound? (car target)))
          (list 'set! (car target) (cons 'lambda (cons (cdr target) (cddr form))))]
         ;; (define name value)
         [(and (symbol? target) (bound? target) (pair? (cddr form)))
          (list 'set! target (caddr form))]
         [else form]))]
    [else form]))

(define (imp-eval-form form) (eval (redefinition form)))

;; Evaluates every form in `text`, returning the last value.
(define (imp-eval-string text)
  (let ([problem (parse-error text)])
    (when problem (error problem)))
  (let ([port (open-input-string text)])
    (let loop ([form (read port)] [last void])
      (if (eof-object? form)
          last
          (let ([value (imp-eval-form form)])
            (loop (read port) value))))))

;; Loads a Scheme file the same way, and remembers its source so
;; describe-function and find-definition can show it.
(define (imp-load-file path)
  (let ([text (read-file path)])
    (record-source! path path text)
    (imp-eval-string text)))

;;; Hooks
;;;
;;; A hook is a named list of procedures that run when something happens:
;;; (add-hook! 'after-save (lambda () ...)). An error in one hook is shown
;;; and the others still run. Hooks run by the editor: after-change,
;;; before-save, after-save, post-command, insert-enter, insert-leave,
;;; mode-change, buffer-enter, buffer-open, option-change.

(define *hooks* (hash))

(define (hook-procs name) (or (hash-try-get *hooks* name) '()))

(define (add-hook! name proc)
  (unless (memq proc (hook-procs name))
    (set! *hooks* (hash-insert *hooks* name (append (hook-procs name) (list proc))))))

(define (remove-hook! name proc)
  (set! *hooks* (hash-insert *hooks* name (filter (lambda (p) (not (eq? p proc))) (hook-procs name)))))

;; Runs hook `name`, passing `args` to each procedure.
(define (run-hooks name . args)
  (for-each (lambda (proc)
              (with-handler
               (lambda (e)
                 (set-status! (string-append "error in " (symbol->string name) " hook: "
                                             (to-string (error-object-message e)))))
               (apply proc args)))
            (hook-procs name)))

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
      (when watch (watch value)))
    (run-hooks 'option-change name value)))

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
(set-face! "popup" "bg=#262a33")
(set-face! "visual" "bg=#3e4452")
(set-face! "search" "fg=black bg=yellow")
(set-face! "search-current" "fg=black bg=#ff8800")

;; Layers draw in the order they are first used, later over earlier, so
;; declare them here in the order they should stack.
(for-each highlight-clear! '("syntax" "search" "visual"))

;;; Environment

(define (home-dir) (or (getenv "HOME") "/"))

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
