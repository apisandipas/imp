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

;; Keymaps checked before `mode`'s own, given `mode`: modes.scm sets this
;; so a buffer's minor and major modes can override keys.
(define *local-keymaps* (lambda (mode) '()))

;; The procedure `key` runs in `mode`, or #f.
(define (lookup-key mode key)
  (let ([binding (key-binding mode key)])
    (if (symbol? binding) (command-proc binding) binding)))

;; The procedure `key` runs in the buffer's mode keymaps for `mode` only,
;; or #f. Insert mode checks these before its own keys (<ret>, <tab>).
(define (local-key-proc mode key)
  (let loop ([maps (*local-keymaps* mode)])
    (cond [(null? maps) #f]
          [(hash-try-get (keymap (car maps)) key)
           => (lambda (b) (if (symbol? b) (command-proc b) b))]
          [else (loop (cdr maps))])))

;; What `key` is bound to as written: a command name or a procedure,
;; looking in the buffer's mode keymaps first.
(define (key-binding mode key)
  (let loop ([maps (append (*local-keymaps* mode) (list mode))])
    (cond [(null? maps) #f]
          [(hash-try-get (keymap (car maps)) key) => (lambda (b) b)]
          [else (loop (cdr maps))])))

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

;; When this is a procedure, keys go to it instead of the editor (describe-
;; key uses it to read the keys it describes). Runtime files extend each
;; other through variables like this and hooks: a define in a later file
;; would add a new binding that earlier files never see.
(define *key-interceptor* #f)

;;; Messages: the status line, with a history for :messages.

(define *messages* '())

(define (message text)
  (set-status! text)
  (set! *messages* (cons text (if (> (length *messages*) 199) (reverse (cdr (reverse *messages*))) *messages*))))

;;; Evaluating code while the editor runs
;;;
;;; Two things about Steel shape this. Re-define-ing a name that already
;;; exists makes a new binding that code compiled earlier never sees, while
;;; set! changes the binding everyone uses. And within one compilation unit,
;;; a call to a function that is never set! there is compiled as a direct
;;; call that later redefinitions can't reach.
;;;
;;; So user code (init.scm, :eval, eval-region, packages) is evaluated as
;;; one unit, (begin ...), in which a define of an existing name becomes a
;;; set!, and every new definition is followed by (set! name name) to keep
;;; it redefinable. That is what lets init.scm or a live :eval replace any
;;; function and have the whole editor use the new one, while forward
;;; references inside a file still work. The runtime's own files get the
;;; same markers from the server (with_mutable_globals in lib.rs).

(define (bound? name)
  (with-handler (lambda (e) #f) (begin (eval name) #t)))

;; The name a top-level define form defines, or #f.
(define (define-target form)
  (and (pair? form) (eq? (car form) 'define) (pair? (cdr form))
       (let ([target (cadr form)])
         (cond [(symbol? target) target]
               [(and (pair? target) (symbol? (car target))) (car target)]
               [else #f]))))

;; `form` with a top-level define of an existing name made into a set!.
;; (begin ...) forms are rewritten inside, as at top level.
(define (redefinition form)
  (cond
    [(not (pair? form)) form]
    [(eq? (car form) 'begin) (cons 'begin (map redefinition (cdr form)))]
    [(and (define-target form) (bound? (define-target form)))
     (let ([target (cadr form)])
       (if (pair? target)
           ;; (define (name . params) body ...)
           (list 'set! (car target) (cons 'lambda (cons (cdr target) (cddr form))))
           ;; (define name value)
           (list 'set! target (if (pair? (cddr form)) (caddr form) #f))))]
    [else form]))

;; The forms to evaluate for `form`: itself (rewritten), and for a new
;; definition a set! that keeps it redefinable.
(define (unit-forms form)
  (let ([rewritten (redefinition form)])
    (if (define-target rewritten)
        (list rewritten (list 'set! (define-target rewritten) (define-target rewritten)))
        (list rewritten))))

(define (imp-eval-form form) (imp-eval-forms (list form)))

;; Evaluates `forms` as one unit, returning the last one's value. Macro
;; definitions go first, each on its own: inside a (begin ...) a macro
;; isn't defined yet for the forms after it.
(define (imp-eval-forms forms)
  (let* ([macro? (lambda (f) (and (pair? f) (eq? (car f) 'define-syntax)))]
         [macros (filter macro? forms)]
         [others (filter (lambda (f) (not (macro? f))) forms)])
    (for-each eval macros)
    (if (null? others)
        void
        ;; A definition's own value is void, so a marker after the last
        ;; form doesn't change the result that matters.
        (eval-allowing-later-definitions (cons 'begin (apply append (map unit-forms others))) 100))))

;; Steel won't compile a reference to a global that doesn't exist yet. But
;; init.scm routinely names functions a package will define when it loads
;; (in a use-package! 'config, say). So a missing global is defined as a
;; placeholder that complains if called before the real definition, which
;; (being a define of an existing name) then replaces it everywhere.
(define (eval-allowing-later-definitions form tries)
  (let ([outcome (with-handler (lambda (e) (list 'failed e)) (list 'ok (eval form)))])
    (if (eq? (car outcome) 'ok)
        (cadr outcome)
        (let ([name (missing-identifier (cadr outcome))])
          (if (and name (> tries 0))
              (begin
                (eval (list 'define (string->symbol name) (list 'not-defined-yet name)))
                (eval-allowing-later-definitions form (- tries 1)))
              (raise-error (cadr outcome)))))))

;; The name in a "Cannot reference an identifier before its definition"
;; error, or #f for any other error.
(define (missing-identifier e)
  (let* ([m (error-object-message e)] [m (if (string? m) m (to-string m))]
         [marker "before its definition: "])
    (and (string-contains? m marker)
         (let loop ([i 0])
           (cond [(> (+ i (string-length marker)) (string-length m)) #f]
                 [(equal? (substring m i (+ i (string-length marker))) marker)
                  (let ([name (substring m (+ i (string-length marker)) (string-length m))])
                    (substring name 0 (let end ([j 0]) (if (and (< j (string-length name))
                                                                (not (char-whitespace? (string-ref name j))))
                                                           (end (+ j 1)) j))))]
                 [else (loop (+ i 1))])))))

(define (not-defined-yet name)
  (lambda args (error (string-append name " is not defined (yet)"))))

;; Evaluates every form in `text` as one unit, returning the last value.
(define (imp-eval-string text)
  (let ([problem (parse-error text)])
    (when problem (error problem)))
  (let ([port (open-input-string text)])
    (let loop ([form (read port)] [forms '()])
      (if (eof-object? form)
          (imp-eval-forms (reverse forms))
          (loop (read port) (cons form forms))))))

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
;;; and the others still run. Hooks run by the editor: startup (after
;;; init.scm), after-change, before-save, after-save, post-command,
;;; insert-enter, insert-leave, mode-change (Vim states), major-mode,
;;; buffer-enter, buffer-open, buffer-kill (with the id, before it goes),
;;; option-change.

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

;;; Advice
;;;
;;; (advice-add! 'name 'before proc) runs proc with the same arguments
;;; before every call to the function `name`; 'after runs it after; 'around
;;; calls (proc original arg ...) instead, so it decides whether and how to
;;; call the original. advice-remove! takes it off again. The function is
;;; replaced with set!, so every caller sees the advice.

(define *advice* (hash))  ; name -> (original befores afters arounds)

(define (advised name) (hash-try-get *advice* name))

(define (advice-original name) (car (advised name)))

;; Calls `name` with `args` through its advice.
(define (apply-advised name args)
  (let* ([a (advised name)] [original (car a)])
    (for-each (lambda (p) (apply p args)) (cadr a))
    (let ([result (wrap-call (cadddr a) original args)])
      (for-each (lambda (p) (apply p args)) (caddr a))
      result)))

;; Calls `original` through `arounds`, the first added outermost: each gets
;; a procedure that calls the rest of the chain.
(define (wrap-call arounds original args)
  (if (null? arounds)
      (apply original args)
      (apply (car arounds) (cons (lambda more (wrap-call (cdr arounds) original more)) args))))

(define (advice-add! name where proc)
  (unless (advised name)
    (set! *advice* (hash-insert *advice* name (list (eval name) '() '() '())))
    (eval (list 'set! name (list 'lambda 'args (list 'apply-advised (list 'quote name) 'args)))))
  (let* ([a (advised name)]
         [add (lambda (lst) (if (memq proc lst) lst (append lst (list proc))))]
         [a (cond [(eq? where 'before) (list (car a) (add (cadr a)) (caddr a) (cadddr a))]
                  [(eq? where 'after) (list (car a) (cadr a) (add (caddr a)) (cadddr a))]
                  [(eq? where 'around) (list (car a) (cadr a) (caddr a) (add (cadddr a)))]
                  [else (error (string-append "advice must be before, after or around, not "
                                              (symbol->string where)))])])
    (set! *advice* (hash-insert *advice* name a))))

(define (advice-remove! name proc)
  (let ([a (advised name)])
    (when a
      (let* ([drop (lambda (lst) (filter (lambda (p) (not (eq? p proc))) lst))]
             [a (list (car a) (drop (cadr a)) (drop (caddr a)) (drop (cadddr a)))])
        (if (and (null? (cadr a)) (null? (caddr a)) (null? (cadddr a)))
            ;; No advice left: put the original back.
            (begin
              (eval (list 'set! name (list 'advice-original (list 'quote name))))
              (set! *advice* (hash-remove *advice* name)))
            (set! *advice* (hash-insert *advice* name a)))))))

;;; Timers and jobs
;;;
;;; Background work reports back on the editor's thread, so these
;;; procedures can do anything a key can.
;;;
;;;   (run-after! 500 (lambda () ...))     ; once, after 500 ms
;;;   (run-every! 2000 (lambda () ...))    ; until (cancel-timer! id)
;;;   (start-job! "make" ""                ; a process, its output streamed;
;;;                                        ;   input #f keeps stdin open for
;;;                                        ;   job-send! (and job-close-input!)
;;;     (lambda (text stream) ...)         ;   stream: "stdout" or "stderr"
;;;     (lambda (code) ...))               ;   when it exits

(define *timers* (hash))  ; id -> (thunk repeat?)
(define *jobs* (hash))    ; id -> (on-output on-exit)

(define (start-timer ms thunk repeat?)
  (let ([id (timer-start! ms repeat?)])
    (when id (set! *timers* (hash-insert *timers* id (list thunk repeat?))))
    id))

(define (run-after! ms thunk) (start-timer ms thunk #f))
(define (run-every! ms thunk) (start-timer ms thunk #t))

(define (cancel-timer! id)
  (timer-cancel! id)
  (set! *timers* (hash-remove *timers* id)))

;; Called by the server when timer `id` fires.
(define (imp-timer-fired id)
  (let ([t (hash-try-get *timers* id)])
    (when t
      (timer-done! id (cadr t))
      (unless (cadr t) (set! *timers* (hash-remove *timers* id)))
      (with-handler (lambda (e) (set-status! (string-append "error in timer: " (to-string (error-object-message e)))))
                    ((car t))))))

;; Starts `command` (run by sh). A string `input` is written to its stdin,
;; which is then closed; #f leaves stdin open for job-send!. Returns the
;; job id, or #f after showing why it couldn't start.
(define (start-job! command input on-output on-exit)
  (let ([id (job-start! command input)])
    (if (string? id)
        (begin (set-status! id) #f)
        (begin (set! *jobs* (hash-insert *jobs* id (list on-output on-exit))) id))))

(define (imp-job-output id stream text)
  (let ([j (hash-try-get *jobs* id)])
    (when (and j (car j))
      (with-handler (lambda (e) (set-status! (string-append "error in job output: " (to-string (error-object-message e)))))
                    ((car j) text stream)))))

(define (imp-job-exit id code)
  (let ([j (hash-try-get *jobs* id)])
    (set! *jobs* (hash-remove *jobs* id))
    (when (and j (cadr j))
      (with-handler (lambda (e) (set-status! (string-append "error in job exit: " (to-string (error-object-message e)))))
                    ((cadr j) code)))))

;;; Sockets
;;;
;;; (listen-socket! path on-open on-line on-close) listens on a Unix socket
;;; only this user can reach; each connection gets an id, passed to the
;;; procedures: (on-open conn), (on-line conn line), (on-close conn).
;;; (socket-send! conn text) writes to one; (socket-stop! id) stops.

(define *listeners* (hash))    ; listener id -> (on-open on-line on-close)
(define *connections* (hash))  ; connection id -> listener id

;; Returns the listener id, or #f after showing why it couldn't listen.
(define (listen-socket! path on-open on-line on-close)
  (let ([id (socket-listen! path)])
    (if (string? id)
        (begin (set-status! id) #f)
        (begin (set! *listeners* (hash-insert *listeners* id (list on-open on-line on-close))) id))))

(define (socket-handlers conn)
  (let ([listener (hash-try-get *connections* conn)])
    (and listener (hash-try-get *listeners* listener))))

(define (socket-call what conn proc . args)
  (when proc
    (with-handler (lambda (e) (set-status! (string-append "error in socket " what ": " (to-string (error-object-message e)))))
                  (apply proc args))))

(define (imp-socket-opened listener conn)
  (set! *connections* (hash-insert *connections* conn listener))
  (let ([h (hash-try-get *listeners* listener)])
    (when h (socket-call "open" conn (car h) conn))))

(define (imp-socket-line conn line)
  (let ([h (socket-handlers conn)])
    (when h (socket-call "line" conn (cadr h) conn line))))

(define (imp-socket-closed conn)
  (let ([h (socket-handlers conn)])
    (set! *connections* (hash-remove *connections* conn))
    (when h (socket-call "close" conn (caddr h) conn))))

;;; Buffer-local values
;;;
;;; Each buffer has its own table of values, for its major and minor modes
;;; and options set just for it.

(define *buffer-locals* (hash))  ; buffer id -> hash of name -> value

(define (buffer-locals) (or (hash-try-get *buffer-locals* (current-buffer)) (hash)))

(define (buffer-local name) (hash-try-get (buffer-locals) name))

(define (buffer-local? name) (hash-contains? (buffer-locals) name))

(define (set-buffer-local! name value)
  (set! *buffer-locals*
        (hash-insert *buffer-locals* (current-buffer) (hash-insert (buffer-locals) name value))))

(define (kill-buffer-locals! id) (set! *buffer-locals* (hash-remove *buffer-locals* id)))

;;; Options
;;;
;;; Named settings, read with (option 'name) and changed with set-option!
;;; or :set. A buffer can have its own value (set-local-option!, :setlocal),
;;; which wins over the global one. An option can have a watcher that runs
;;; when its value changes, for settings Rust needs to know about (tabstop).

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

;; Options whose value lives elsewhere (the buffer's file format, in Rust):
;; name -> (getter setter).
(define *computed-options* (hash))

(define (define-computed-option! name aliases getter setter)
  (set! *computed-options* (hash-insert *computed-options* name (list getter setter)))
  (define-option! name #f aliases))

(define (option name)
  (let ([computed (hash-try-get *computed-options* name)])
    (if computed
        ((car computed))
        (let ([local (buffer-locals)] [key (list 'option name)])
          (if (hash-contains? local key) (hash-ref local key) (hash-ref *options* name))))))

(define (set-local-option! name value)
  (let ([name (or (option-name name) (error (string-append "unknown option: " (symbol->string name))))])
    (let ([computed (hash-try-get *computed-options* name)])
      (when computed ((cadr computed) value)))
    (set-buffer-local! (list 'option name) value)
    (let ([watch (hash-try-get *option-watchers* name)])
      (when watch (watch value)))
    (run-hooks 'option-change name value)))

;; Runs every watcher with the current buffer's values; after switching
;; buffers, Rust's copies (tab width, line numbers) follow the buffer.
(define (refresh-option-watchers!)
  (for-each (lambda (name) ((hash-ref *option-watchers* name) (option name)))
            (hash-keys->list *option-watchers*)))

(define (set-option! name value)
  (let ([name (or (option-name name) (error (string-append "unknown option: " (symbol->string name))))])
    (let ([computed (hash-try-get *computed-options* name)])
      (when computed ((cadr computed) value)))
    (set! *options* (hash-insert *options* name value))
    (let ([watch (hash-try-get *option-watchers* name)])
      (when watch (watch (option name))))
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

;; Line numbers: number, relativenumber, or both for hybrid (as in Vim).
(define-option! 'number #f '(nu))
(define-option! 'relativenumber #f '(rnu))
(define-option! 'cursorline #f '(cul))
;; Long lines continue on the next screen rows; off, they scroll sideways.
(define-option! 'wrap #t '())
(watch-option! 'wrap set-wrap!)

(define (update-line-numbers! value)
  (set-line-numbers!
   (cond [(and (option 'number) (option 'relativenumber)) "hybrid"]
         [(option 'number) "absolute"]
         [(option 'relativenumber) "relative"]
         [else "off"])))

(watch-option! 'number update-line-numbers!)
(watch-option! 'relativenumber update-line-numbers!)
(watch-option! 'cursorline set-cursorline!)

;;; Faces and highlight layers
;;;
;;; A face is a named style; its spec is a string like "fg=#ff8800 bold"
;;; (colors are #rrggbb, ANSI names such as bright-blue, or 0-255). Redefine
;;; a face in init.scm to restyle everything that uses it.

;; theme.scm, loaded last, sets every face the editor uses.

;; Layers draw in the order they are first used, later over earlier, so
;; declare them here in the order they should stack.
(for-each highlight-clear! '("syntax" "diagnostics" "debug" "search" "visual"))

;;; Gutter signs
;;;
;;; Several things want the sign column (diagnostics, breakpoints, the
;;; debugger's current line), so each sets its own signs for the current
;;; buffer and the one with the highest priority shows on each line.

(define (set-sign-source! source priority signs)
  (set-buffer-local! (list 'signs source) (cons priority signs))
  (let* ([sources (filter (lambda (k) (and (pair? k) (eq? (car k) 'signs))) (hash-keys->list (buffer-locals)))]
         [sets (sort (map (lambda (k) (buffer-local k)) sources) (lambda (a b) (< (car a) (car b))))]
         ;; Lowest priority first, so higher ones overwrite them.
         [merged (foldl (lambda (set acc)
                          (foldl (lambda (sign acc) (hash-insert acc (car sign) sign)) acc (cdr set)))
                        (hash) sets)])
    (set-signs! (map (lambda (line) (hash-ref merged line)) (hash-keys->list merged)))))

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
