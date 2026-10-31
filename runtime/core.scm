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
  "The keymap for `mode`: a hash of key string -> command.
   An empty hash when nothing is bound in `mode` yet."
  (let ([m (hash-try-get *keymaps* mode)])
    (if m m (hash))))

(define (define-key! mode key command . label)
  "Binds `key` to `command` in `mode`. A command is a procedure, or the
   name (a symbol) of one made with define-command!; a name is looked up
   each time the key is pressed, so redefining the command changes every
   key bound to it. What arguments a command takes is up to the mode that
   calls it; Vim's modes pass the count. An optional last argument is the
   label which-key shows beside the key:

     (define-key! 'normal \"gb\" 'switch-buffer \"switch buffer\")"
  (set! *keymaps* (hash-insert *keymaps* mode (hash-insert (keymap mode) key command)))
  (set-binding-label! mode key (and (pair? label) (car label)))
  void)

;; table (a keymap name, or 'motion or 'operator) -> hash of key -> the
;; label which-key shows. Binding a key without a label forgets its old one.
(define *binding-labels* (hash))

(define (set-binding-label! table key label)
  "Sets the which-key label of `key` in `table` to `label`, or forgets it
   when `label` is #f. `table` is a keymap name, 'motion or 'operator."
  (let ([labels (or (hash-try-get *binding-labels* table) (hash))])
    (set! *binding-labels*
          (hash-insert *binding-labels* table
                       (if label (hash-insert labels key label) (hash-remove labels key)))))
  void)

(define (binding-label-in table key)
  "The which-key label of `key` in `table`, or #f."
  (let ([labels (hash-try-get *binding-labels* table)])
    (and labels (hash-try-get labels key))))

;; Keymaps checked before `mode`'s own, given `mode`: modes.scm sets this
;; so a buffer's minor and major modes can override keys.
(define *local-keymaps* (lambda (mode) '()))

(define (lookup-key mode key)
  "The procedure `key` runs in `mode`, or #f."
  (let ([binding (key-binding mode key)])
    (if (symbol? binding) (command-proc binding) binding)))

(define (local-key-binding mode key)
  "What `key` is bound to as written in the buffer's mode keymaps for
   `mode` only, or #f. Insert mode checks these before its own keys (<ret>,
   <tab>)."
  (let loop ([maps (*local-keymaps* mode)])
    (cond [(null? maps) #f]
          [(hash-try-get (keymap (car maps)) key) => (lambda (b) b)]
          [else (loop (cdr maps))])))

(define (local-key-proc mode key)
  "The procedure `key` runs in the buffer's mode keymaps for `mode` only,
   or #f."
  (let ([b (local-key-binding mode key)])
    (if (symbol? b) (command-proc b) b)))

(define (key-binding mode key)
  "What `key` is bound to as written: a command name or a procedure,
   looking in the buffer's mode keymaps first."
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
  "Gives procedure `proc` the name `name`, for keys, SPC and M-x.
   The procedure takes a count (1 when none was typed). Redefining a
   name replaces it for every key bound to that name. Its docstring,
   first in the lambda, is what M-x and help show:

     (define-command! 'hello
       (lambda (count) \"Say hello.\" (message \"hello\")))"
  (set! *commands* (hash-insert *commands* name proc))
  void)

(define (command-proc name)
  "The procedure of the command named `name`, or #f."
  (hash-try-get *commands* name))

(define (command-names)
  "The names (symbols) of every defined command."
  (hash-keys->list *commands*))

(define (run-command name . count)
  "Runs command `name` (with a count of 1 unless given)."
  (let ([proc (command-proc name)])
    (if proc
        (proc (if (null? count) 1 (car count)))
        (set-status! (string-append "no command " (symbol->string name)))))
  ;; Commands run for their effect; whatever the last one returned would
  ;; only be printed by the REPL and :eval.
  void)

;; When this is a procedure, keys go to it instead of the editor (describe-
;; key uses it to read the keys it describes). Runtime files extend each
;; other through variables like this and hooks: a define in a later file
;; would add a new binding that earlier files never see.
(define *key-interceptor* #f)

;;; Messages: the status line, with a history for :messages.

(define *messages* '())

(define (message text)
  "Shows `text` in the status line and adds it to :messages.
   The history keeps the last 200. An empty `text` clears the status
   line without being kept; echoes of keys being typed use set-status!,
   which isn't kept either."
  (set-status! text)
  (unless (equal? text "")
    (set! *messages* (cons text (if (> (length *messages*) 199) (reverse (cdr (reverse *messages*))) *messages*))))
  void)

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
  "Whether `name` (a symbol) is defined as a global."
  (with-handler (lambda (e) #f) (begin (eval name) #t)))

(define (define-target form)
  "The name a top-level define form defines, or #f."
  (and (pair? form) (eq? (car form) 'define) (pair? (cdr form))
       (let ([target (cadr form)])
         (cond [(symbol? target) target]
               [(and (pair? target) (symbol? (car target))) (car target)]
               [else #f]))))

(define (redefinition form)
  "`form` with a top-level define of an existing name made into a set!.
   (begin ...) forms are rewritten inside, as at top level."
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

(define (unit-forms form)
  "The forms to evaluate for `form`: itself (rewritten), and for a new
   definition a set! that keeps it redefinable."
  (let ([rewritten (redefinition form)])
    (if (define-target rewritten)
        (list rewritten (list 'set! (define-target rewritten) (define-target rewritten)))
        (list rewritten))))

(define (imp-eval-form form)
  "Evaluates the single form `form` as imp-eval-forms does."
  (imp-eval-forms (list form)))

(define (imp-eval-forms forms)
  "Evaluates `forms` as one unit, returning the last one's value, or the
   name it defines if it is a definition, as in Emacs. Macro definitions
   go first, each on its own: inside a (begin ...) a macro isn't defined
   yet for the forms after it."
  (let* ([macro? (lambda (f) (and (pair? f) (eq? (car f) 'define-syntax)))]
         [macros (filter macro? forms)]
         [others (filter (lambda (f) (not (macro? f))) forms)])
    (for-each eval macros)
    (if (null? others)
        void
        (let ([value (eval-allowing-later-definitions (cons 'begin (apply append (map unit-forms others))) 100)])
          ;; A definition ends in a set! (its own, or the marker after it),
          ;; which returns the old value: show the name instead.
          (or (define-target (last others)) value)))))

(define (eval-allowing-later-definitions form tries)
  "Evaluates `form`, defining placeholders for globals it names early.
   Steel won't compile a reference to a global that doesn't exist yet. But
   init.scm routinely names functions a package will define when it loads
   (in a use-package! 'config, say). So a missing global is defined as a
   placeholder that complains if called before the real definition, which
   (being a define of an existing name) then replaces it everywhere."
  (let ([outcome (with-handler (lambda (e) (list 'failed e)) (list 'ok (eval form)))])
    (if (eq? (car outcome) 'ok)
        (cadr outcome)
        (let ([name (missing-identifier (cadr outcome))])
          (if (and name (> tries 0))
              (begin
                (eval (list 'define (string->symbol name) (list 'not-defined-yet name)))
                (eval-allowing-later-definitions form (- tries 1)))
              (raise-error (cadr outcome)))))))

(define (missing-identifier e)
  "The name in a \"Cannot reference an identifier before its definition\"
   error, or #f for any other error."
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
  "A placeholder procedure for `name`, a global not defined yet.
   Calling it raises an error saying so; the real definition, when it
   comes, replaces it everywhere."
  (lambda args (error (string-append name " is not defined (yet)"))))

(define (imp-eval-string text)
  "Evaluates every form in `text` as one unit, returning the last value."
  (let ([problem (parse-error text)])
    (when problem (error problem)))
  (let ([port (open-input-string text)])
    (let loop ([form (read port)] [forms '()])
      (if (eof-object? form)
          (imp-eval-forms (reverse forms))
          (loop (read port) (cons form forms))))))

(define (imp-load-file path)
  "Evaluates the Scheme file at `path` as one unit, like imp-eval-string.
   Its source is remembered so describe-function and find-definition
   can show it."
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

(define (hook-procs name)
  "The procedures on hook `name`, in the order they run."
  (or (hash-try-get *hooks* name) '()))

(define (add-hook! name proc)
  "Adds `proc` to the end of hook `name`, unless it's already there.
   It is called with the hook's arguments each time the hook runs:

     (add-hook! 'after-save (lambda () (message \"saved\")))"
  (unless (memq proc (hook-procs name))
    (set! *hooks* (hash-insert *hooks* name (append (hook-procs name) (list proc)))))
  void)

(define (remove-hook! name proc)
  "Takes `proc` off hook `name`. Pass the same procedure that was
   added, so a hook to be removed later needs a name of its own."
  (set! *hooks* (hash-insert *hooks* name (filter (lambda (p) (not (eq? p proc))) (hook-procs name))))
  void)

(define (run-hooks name . args)
  "Runs hook `name`, passing `args` to each procedure."
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

(define (advised name)
  "The advice on function `name`, as (original befores afters
   arounds), or #f when it has none."
  (hash-try-get *advice* name))

(define (advice-original name)
  "The function `name` was before any advice was added to it."
  (car (advised name)))

(define (apply-advised name args)
  "Calls `name` with `args` through its advice."
  (let* ([a (advised name)] [original (car a)])
    (for-each (lambda (p) (apply p args)) (cadr a))
    (let ([result (wrap-call (cadddr a) original args)])
      (for-each (lambda (p) (apply p args)) (caddr a))
      result)))

(define (wrap-call arounds original args)
  "Calls `original` through `arounds`, the first added outermost: each gets
   a procedure that calls the rest of the chain."
  (if (null? arounds)
      (apply original args)
      (apply (car arounds) (cons (lambda more (wrap-call (cdr arounds) original more)) args))))

(define (advice-add! name where proc)
  "Adds `proc` as advice on the function named `name`.
   `where` is 'before or 'after (proc gets the same arguments), or
   'around (proc gets the original, then the arguments, and decides
   whether to call it). Adding the same proc twice does nothing.

     (advice-add! 'save-buffer 'before (lambda (count) ...))"
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
    (set! *advice* (hash-insert *advice* name a)))
  void)

(define (advice-remove! name proc)
  "Takes `proc` off the advice on `name`. With none left, the original
   function is put back."
  (let ([a (advised name)])
    (when a
      (let* ([drop (lambda (lst) (filter (lambda (p) (not (eq? p proc))) lst))]
             [a (list (car a) (drop (cadr a)) (drop (caddr a)) (drop (cadddr a)))])
        (if (and (null? (cadr a)) (null? (caddr a)) (null? (cadddr a)))
            ;; No advice left: put the original back.
            (begin
              (eval (list 'set! name (list 'advice-original (list 'quote name))))
              (set! *advice* (hash-remove *advice* name)))
            (set! *advice* (hash-insert *advice* name a))))))
  void)

;;; Floating boxes: lines in a border at a corner or the middle of an
;;; edge, over the windows and under popups (docs/specs/showkeys.md).
;;;
;;;   (float-show! "clock" (list (list (list "12:00" "bold"))) 'top-right)
;;;   (float-hide! "clock")

(define (float-show! name lines position . border)
  "Shows the box named `name` holding `lines` (each a list of (text face)
   runs, as popups take) at `position`: 'bottom-right, 'bottom-left,
   'bottom-center, 'top-right, 'top-left or 'top-center. Showing a name
   again replaces its box. An optional face for the border; the
   float.border face by default.

     (float-show! \"note\" (list (list (list \"saved\" \"\"))) 'bottom-right)"
  (float-put! name lines position (and (pair? border) (car border))))

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
  "Starts a timer that calls `thunk` after `ms` milliseconds, again
   and again if `repeat?`. Returns its id, or #f if it didn't start."
  (let ([id (timer-start! ms repeat?)])
    (when id (set! *timers* (hash-insert *timers* id (list thunk repeat?))))
    id))

(define (run-after! ms thunk)
  "Calls `thunk` once, `ms` milliseconds from now. Returns the timer
   id, for cancel-timer!.

     (run-after! 500 (lambda () (message \"half a second\")))"
  (start-timer ms thunk #f))
(define (run-every! ms thunk)
  "Calls `thunk` every `ms` milliseconds until (cancel-timer! id).
   Returns the timer id."
  (start-timer ms thunk #t))

(define (cancel-timer! id)
  "Stops timer `id`, from run-after! or run-every!."
  (timer-cancel! id)
  (set! *timers* (hash-remove *timers* id))
  void)

(define (imp-resized)
  "Called by the server when the client's screen changes size: runs the
   resize hook, for screens drawn to fit (the start screen)."
  (run-hooks 'resize))

(define (imp-timer-fired id)
  "Called by the server when timer `id` fires."
  (let ([t (hash-try-get *timers* id)])
    (when t
      (timer-done! id (cadr t))
      (unless (cadr t) (set! *timers* (hash-remove *timers* id)))
      (with-handler (lambda (e) (set-status! (string-append "error in timer: " (to-string (error-object-message e)))))
                    ((car t))))))

(define (start-job! command input on-output on-exit)
  "Starts `command` (run by sh). A string `input` is written to its stdin,
   which is then closed; #f leaves stdin open for job-send!. Returns the
   job id, or #f after showing why it couldn't start."
  (let ([id (job-start! command input)])
    (if (string? id)
        (begin (set-status! id) #f)
        (begin (set! *jobs* (hash-insert *jobs* id (list on-output on-exit))) id))))

(define (imp-job-output id stream text)
  "Called by the server with output `text` from job `id`.
   `stream` is \"stdout\" or \"stderr\"; the job's on-output gets both."
  (let ([j (hash-try-get *jobs* id)])
    (when (and j (car j))
      (with-handler (lambda (e) (set-status! (string-append "error in job output: " (to-string (error-object-message e)))))
                    ((car j) text stream)))))

(define (imp-job-exit id code)
  "Called by the server when job `id` exits with `code`.
   Forgets the job, then calls its on-exit with the code."
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
;;; (connect-socket! path on-line on-close) connects to one, as a client.

(define *listeners* (hash))    ; listener id -> (on-open on-line on-close)
(define *connections* (hash))  ; connection id -> listener id

(define (listen-socket! path on-open on-line on-close)
  "Listens on the Unix socket at `path`, calling the procedures given.
   (on-open conn) for each connection, (on-line conn line) for each
   line read, (on-close conn) when it closes. Returns the listener id,
   or #f after showing why it couldn't listen."
  (let ([id (socket-listen! path)])
    (if (string? id)
        (begin (set-status! id) #f)
        (begin (set! *listeners* (hash-insert *listeners* id (list on-open on-line on-close))) id))))

(define *client-sockets* (hash))  ; connection id -> (#f on-line on-close)

(define (connect-socket! path on-line on-close)
  "Connects to the Unix socket at `path` as a client.
   (on-line conn line) gets each line read, (on-close conn) the end.
   Returns the connection id, or #f after showing why it couldn't
   connect."
  (let ([conn (socket-connect! path)])
    (if (string? conn)
        (begin (set-status! conn) #f)
        (begin (set! *client-sockets* (hash-insert *client-sockets* conn (list #f on-line on-close))) conn))))

(define (socket-handlers conn)
  "The (on-open on-line on-close) procedures for connection `conn`,
   whether it is a client socket or one a listener accepted, or #f."
  (or (hash-try-get *client-sockets* conn)
      (let ([listener (hash-try-get *connections* conn)])
        (and listener (hash-try-get *listeners* listener)))))

(define (socket-call what conn proc . args)
  "Calls `proc` with `args`, if there is one, showing any error as
   an error in socket `what` (\"open\", \"line\", \"close\")."
  (when proc
    (with-handler (lambda (e) (set-status! (string-append "error in socket " what ": " (to-string (error-object-message e)))))
                  (apply proc args))))

(define (imp-socket-opened listener conn)
  "Called by the server when `listener` accepts connection `conn`.
   Remembers which listener it belongs to and calls its on-open."
  (set! *connections* (hash-insert *connections* conn listener))
  (let ([h (hash-try-get *listeners* listener)])
    (when h (socket-call "open" conn (car h) conn))))

(define (imp-socket-line conn line)
  "Called by the server with each `line` read from connection `conn`."
  (let ([h (socket-handlers conn)])
    (when h (socket-call "line" conn (cadr h) conn line))))

(define (imp-socket-closed conn)
  "Called by the server when connection `conn` closes.
   Forgets it, then calls its on-close."
  (let ([h (socket-handlers conn)])
    (set! *connections* (hash-remove *connections* conn))
    (set! *client-sockets* (hash-remove *client-sockets* conn))
    (when h (socket-call "close" conn (caddr h) conn))))

;;; Buffer-local values
;;;
;;; Each buffer has its own table of values, for its major and minor modes
;;; and options set just for it.

(define *buffer-locals* (hash))  ; buffer id -> hash of name -> value

(define (buffer-locals)
  "The current buffer's table of buffer-local values (a hash)."
  (or (hash-try-get *buffer-locals* (current-buffer)) (hash)))

(define (buffer-local name)
  "The current buffer's value for `name`, or #f if it has none."
  (hash-try-get (buffer-locals) name))

(define (buffer-local? name)
  "Whether the current buffer has a value of its own for `name`."
  (hash-contains? (buffer-locals) name))

(define (set-buffer-local! name value)
  "Sets the current buffer's own value for `name` to `value`."
  (set! *buffer-locals*
        (hash-insert *buffer-locals* (current-buffer) (hash-insert (buffer-locals) name value)))
  void)

(define (buffer-local-of buf name)
  "Buffer `buf`'s value for `name`, or #f if it has none."
  (hash-try-get (or (hash-try-get *buffer-locals* buf) (hash)) name))

(define (set-buffer-local-of! buf name value)
  "Sets buffer `buf`'s own value for `name` to `value`."
  (set! *buffer-locals*
        (hash-insert *buffer-locals* buf
                     (hash-insert (or (hash-try-get *buffer-locals* buf) (hash)) name value)))
  void)

(define (kill-buffer-locals! id)
  "Forgets every buffer-local value of buffer `id`, when it goes."
  (set! *buffer-locals* (hash-remove *buffer-locals* id))
  void)

;;; Options
;;;
;;; Named settings, read with (option 'name) and changed with set-option!
;;; or :set. A buffer can have its own value (set-local-option!, :setlocal),
;;; which wins over the global one. An option can have a watcher that runs
;;; when its value changes, for settings Rust needs to know about (tabstop).

(define *options* (hash))
;; The options set globally (set-option!, :set) since the editor started.
(define *options-set* (hash))
(define *option-watchers* (hash))
(define *option-aliases* (hash))

(define (define-option! name default aliases)
  "Defines option `name` (a symbol) with a default value and short names
   for :set, e.g. (define-option! 'shiftwidth 4 '(sw))."
  (set! *options* (hash-insert *options* name default))
  (for-each (lambda (a) (set! *option-aliases* (hash-insert *option-aliases* a name))) aliases))

(define (option-name name)
  "The option `name` refers to, itself or the option it is a short
   name for (sw -> shiftwidth); #f if there is no such option."
  (cond [(hash-contains? *options* name) name]
        [(hash-try-get *option-aliases* name) => (lambda (n) n)]
        [else #f]))

(define (known-option-name name)
  "The option `name` refers to, as option-name gives it; an unknown
   name is an error saying so."
  (or (option-name name)
      (error (string-append "unknown option: " (if (symbol? name) (symbol->string name) (to-string name))))))

;; Options whose value lives elsewhere (the buffer's file format, in Rust):
;; name -> (getter setter).
(define *computed-options* (hash))

(define (define-computed-option! name aliases getter setter)
  "Defines option `name` whose value lives elsewhere (in Rust, say).
   (option 'name) calls `getter`; setting it calls `setter` with the
   new value. `aliases` are short names for :set, as in define-option!."
  (set! *computed-options* (hash-insert *computed-options* name (list getter setter)))
  (define-option! name #f aliases))

(define (option name)
  "The value of option `name` for the current buffer.
   A value set with set-local-option! wins over the global one. `name`
   may be an alias, (option 'sw); an unknown one is an error."
  (let* ([name (known-option-name name)]
         [computed (hash-try-get *computed-options* name)])
    (if computed
        ((car computed))
        (let ([local (buffer-locals)] [key (list 'option name)])
          (if (hash-contains? local key) (hash-ref local key) (hash-ref *options* name))))))

(define (set-local-option! name value)
  "Sets option `name` to `value` for the current buffer only (:setlocal).
   `name` may be an alias; an unknown one is an error. Runs the
   option's watcher and the option-change hook.

     (set-local-option! 'shiftwidth 2)"
  (let ([name (known-option-name name)])
    (let ([computed (hash-try-get *computed-options* name)])
      (when computed ((cadr computed) value)))
    (set-buffer-local! (list 'option name) value)
    (let ([watch (hash-try-get *option-watchers* name)])
      (when watch (watch value)))
    (run-hooks 'option-change name value)))

(define (refresh-option-watchers!)
  "Runs every watcher with the current buffer's values; after switching
   buffers, Rust's copies (tab width, line numbers) follow the buffer."
  (for-each (lambda (name) ((hash-ref *option-watchers* name) (option name)))
            (hash-keys->list *option-watchers*)))

(define (set-option! name value)
  "Sets option `name` globally to `value` (:set).
   `name` may be an alias; an unknown one is an error. A buffer with
   its own value keeps it. Runs the option's watcher and the
   option-change hook.

     (set-option! 'relativenumber #t)"
  (let ([name (known-option-name name)])
    (let ([computed (hash-try-get *computed-options* name)])
      (when computed ((cadr computed) value)))
    (set! *options* (hash-insert *options* name value))
    (set! *options-set* (hash-insert *options-set* name #t))
    (let ([watch (hash-try-get *option-watchers* name)])
      (when watch (watch (option name))))
    (run-hooks 'option-change name value)))

(define (option-set? name)
  "Whether option `name` was set globally, with set-option! or :set,
   rather than left at its default."
  (hash-contains? *options-set* (known-option-name name)))

(define (watch-option! name proc)
  "Makes `proc` the watcher of option `name`, and calls it now.
   It gets the new value each time the option changes and whenever
   the current buffer changes. One watcher per option: a second
   replaces the first."
  (set! *option-watchers* (hash-insert *option-watchers* (known-option-name name) proc))
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
;; With wrap, rows end between words rather than inside one.
(define-option! 'linebreak #f '(lbr))
(watch-option! 'linebreak set-linebreak!)

(define (line-numbers-mode number relative)
  "The line numbers Rust draws for `number` and `relativenumber`."
  (cond [(and number relative) "hybrid"]
        [number "absolute"]
        [relative "relative"]
        [else "off"]))

(define (update-line-numbers! value)
  "Tells Rust which line numbers to draw: everyone's from the global
   number and relativenumber, and the current buffer's own if it sets
   either locally, so each window keeps its buffer's whichever is
   focused. The watcher of both options; `value` is ignored."
  (set-line-numbers! (line-numbers-mode (hash-ref *options* 'number) (hash-ref *options* 'relativenumber)))
  (let ([local (buffer-locals)])
    (set-buffer-line-numbers!
     (and (or (hash-contains? local '(option number)) (hash-contains? local '(option relativenumber)))
          (line-numbers-mode (option 'number) (option 'relativenumber))))))

(watch-option! 'number update-line-numbers!)
(watch-option! 'relativenumber update-line-numbers!)
(watch-option! 'cursorline set-cursorline!)
;; The sign column before the line numbers (diagnostics, breakpoints):
;; "yes" always, so text doesn't shift as signs come and go while you
;; type; "auto" only while the buffer has signs; "no" never.
(define-option! 'signcolumn "auto" '(scl))
(watch-option! 'signcolumn set-sign-column!)

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
  "Sets the current buffer's gutter signs from `source` (a symbol).
   `signs` is a list of (line text face). On each line the sign from
   the source with the highest `priority` shows; an empty list clears
   this source's signs."
  (set-buffer-local! (list 'signs source) (cons priority signs))
  (let* ([sources (filter (lambda (k) (and (pair? k) (eq? (car k) 'signs))) (hash-keys->list (buffer-locals)))]
         [sets (sort (map (lambda (k) (buffer-local k)) sources) (lambda (a b) (< (car a) (car b))))]
         ;; Lowest priority first, so higher ones overwrite them.
         [merged (foldl (lambda (set acc)
                          (foldl (lambda (sign acc) (hash-insert acc (car sign) sign)) acc (cdr set)))
                        (hash) sets)])
    (set-signs! (map (lambda (line) (hash-ref merged line)) (hash-keys->list merged)))))

;;; Environment

(define (home-dir)
  "The user's home directory, from $HOME (\"/\" if unset)."
  (or (getenv "HOME") "/"))

;;; Buffer helpers built from the primitives

(define (clamp n lo hi)
  "`n` limited to the range `lo` to `hi`."
  (max lo (min n hi)))

(define (current-line)
  "The line the cursor is on, counting from 0."
  (offset->line (cursor)))
(define (current-col)
  "The column the cursor is on, counting from 0."
  (offset->col (cursor)))

(define (line-start line)
  "The offset where `line` starts."
  (line-col->offset line 0))
(define (line-end line)
  "The offset of the end of `line`, before its newline."
  (+ (line-start line) (buffer-line-length line)))
(define (last-line)
  "The number of the buffer's last line, counting from 0."
  (- (buffer-line-count) 1))

(define (line-first-nonblank line)
  "Offset of the first non-blank char on `line`, or its end if it is blank."
  (let ([end (line-end line)])
    (let loop ([p (line-start line)])
      (if (and (< p end) (char-whitespace? (buffer-char-at p)))
          (loop (+ p 1))
          p))))

;;; Entry points called by the server

(define (imp-init)
  "Called once after init.scm has loaded. Modes redefine it."
  #t)

(define (imp-handle-key key)
  "Called for every key from the client. Modes redefine it."
  (set-status! (string-append "no mode loaded; got " key)))
