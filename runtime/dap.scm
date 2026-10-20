;;; dap.scm -- debugging through the Debug Adapter Protocol.
;;;
;;; A debug adapter is a job speaking DAP: the same Content-Length framing
;;; and JSON as LSP (lsp-frame, lsp-take-message), with its own messages.
;;; Adapters are configured per major mode, with a procedure that builds
;;; the launch arguments (it may prompt, so it calls `done` with them):
;;;
;;;   (define-debug-adapter! 'python-mode "python3 -m debugpy.adapter" "debugpy"
;;;     (lambda (done) (done (hash "program" (absolute-path (buffer-path))))))
;;;
;;; SPC d b (or <f9>) toggles a breakpoint on the cursor's line; SPC d d
;;; (or <f5>) starts the program, or continues it when stopped. Then SPC d
;;; n / i / o (<f10> <f11>) step over, in and out, SPC d p pauses, SPC d q
;;; stops. Where it stopped is highlighted and marked in the gutter;
;;; SPC d s picks a frame of the stack, SPC d v shows its variables,
;;; SPC d e evaluates an expression there, SPC d O shows program output.
;;;
;;; One session at a time. Adapters that only listen on a TCP port
;;; (codelldb, js-debug) aren't supported yet; lldb-dap and debugpy talk
;;; over stdio.

(define *debug-adapters* (hash))  ; major mode -> (command adapter-id launch)

(define *dap-job* #f)
(define *dap-session* 0)        ; counts sessions started
(define *dap-input* "")
(define *dap-seq* 0)
(define *dap-pending* (hash))     ; request seq -> callback, given the response
(define *dap-capabilities* (hash))
(define *dap-launch* #f)          ; the launch arguments of the session
(define *dap-thread* #f)          ; the thread that stopped
(define *dap-frames* '())         ; its stack, innermost first
(define *dap-frame* #f)           ; the frame shown: SPC d v and e use it
(define *dap-stopped-at* #f)      ; (buffer-id line) highlighted, or #f
(define *dap-output* '())         ; the program's output, newest first
(define *breakpoint-counter* 0)

(define (define-debug-adapter! mode command adapter-id launch)
  "Sets the debug adapter for major mode `mode`.
   `command` is the shell command that runs the adapter, `adapter-id` the
   adapterID sent in initialize, and `launch` a procedure that gets a
   `done` procedure and calls it with the launch arguments (a hash); it
   may prompt first."
  (set! *debug-adapters* (hash-insert *debug-adapters* mode (list command adapter-id launch))))

;; Faces debug-line, sign.breakpoint and sign.debug come from theme.scm.

;;; Launch configurations that come with imp

(define (cargo-package-name toml)
  "The package name in Cargo.toml file `toml`, or #f."
  (let loop ([lines (split-lines (read-file toml))] [in-package? #f])
    (cond
      [(null? lines) #f]
      [(starts-with? (trim (car lines)) "[") (loop (cdr lines) (equal? (trim (car lines)) "[package]"))]
      [(and in-package? (starts-with? (trim (car lines)) "name"))
       (let ([parts (split-quoted (car lines))]) (and (pair? parts) (car parts)))]
      [else (loop (cdr lines) in-package?)])))

(define (split-quoted text)
  "The \"quoted\" parts of line `text`, without their quotes."
  (let loop ([cs (string->list text)] [cur #f] [out '()])
    (cond [(null? cs) (reverse out)]
          [(and (equal? (car cs) #\") cur) (loop (cdr cs) #f (cons (list->string (reverse cur)) out))]
          [(equal? (car cs) #\") (loop (cdr cs) '() out)]
          [cur (loop (cdr cs) (cons (car cs) cur) out)]
          [else (loop (cdr cs) #f out)])))

(define (native-launch done)
  "Launch arguments for a compiled program, passed to `done`.
   Asks for the program, suggesting Cargo's debug build of the package
   around the current file."
  (let* ([file (absolute-path (or (buffer-path) "."))]
         [root (lsp-root file '("Cargo.toml"))]
         [toml (string-append root "/Cargo.toml")]
         [name (and (file-exists? toml) (cargo-package-name toml))]
         [guess (if name (string-append root "/target/debug/" name) (string-append root "/"))])
    (ask "Program: " guess
         (lambda (program)
           (done (hash "program" (absolute-path program) "args" '() "cwd" root "stopOnEntry" #f))))))

(define lldb-command (if (find-executable "lldb-dap") "lldb-dap" "lldb-vscode"))
(for-each (lambda (mode) (define-debug-adapter! mode lldb-command "lldb" native-launch))
          '(rust-mode c-mode cpp-mode))

(define-debug-adapter! 'python-mode "python3 -m debugpy.adapter" "debugpy"
  (lambda (done)
    (let ([file (absolute-path (buffer-path))])
      (done (hash "program" file "cwd" (lsp-dirname file) "console" "internalConsole" "justMyCode" #t)))))

;;; Breakpoints: marks, so they follow edits, listed per buffer.

(define (breakpoint-marks)
  "The names of the marks holding the current buffer's breakpoints."
  (or (buffer-local 'breakpoints) '()))

(define (breakpoint-lines)
  "The current buffer's breakpoint lines (0-based), in order.
   Breakpoints whose marks are gone are left out."
  (sort (filter (lambda (l) l)
                (map (lambda (m) (let ([p (mark-get m)]) (and p (offset->line p)))) (breakpoint-marks)))
        <))

(define (show-breakpoints!)
  "Puts a sign in the gutter on each of the current buffer's breakpoints."
  (set-sign-source! 'breakpoints 20 (map (lambda (l) (list l "●" "sign.breakpoint")) (breakpoint-lines))))

(define-command! 'toggle-breakpoint
  (lambda (count)
    "Set a breakpoint on the cursor's line, or remove the one there.
     In a debug session the adapter is told at once."
    (let* ([line (current-line)]
           [here (filter (lambda (m) (let ([p (mark-get m)]) (and p (= (offset->line p) line)))) (breakpoint-marks))])
      (if (pair? here)
          (begin
            (for-each mark-delete! here)
            (set-buffer-local! 'breakpoints (filter (lambda (m) (not (member m here))) (breakpoint-marks))))
          (let ([name (string-append "breakpoint" (number->string *breakpoint-counter*))])
            (set! *breakpoint-counter* (+ *breakpoint-counter* 1))
            (mark-set! name (line-start line))
            (set-buffer-local! 'breakpoints (cons name (breakpoint-marks)))))
      (show-breakpoints!)
      (when *dap-job* (send-breakpoints!)))))

(define-command! 'clear-breakpoints
  (lambda (count)
    "Remove every breakpoint in every buffer."
    (for-each (lambda (id)
                (with-buffer id
                  (lambda ()
                    (for-each mark-delete! (breakpoint-marks))
                    (set-buffer-local! 'breakpoints '())
                    (show-breakpoints!)
                    (when *dap-job* (send-breakpoints!)))))
              (buffer-list))
    (message "breakpoints cleared")))

(add-hook! 'after-change (lambda () (when (pair? (breakpoint-marks)) (show-breakpoints!))))

(define (send-breakpoints!)
  "Tells the adapter the current buffer's breakpoints (1-based lines)."
  (when (buffer-path)
    (let ([lines (map (lambda (l) (+ l 1)) (breakpoint-lines))])
      (dap-request! "setBreakpoints"
                    (hash "source" (hash "path" (absolute-path (buffer-path)))
                          "breakpoints" (map (lambda (l) (hash "line" l)) lines)
                          "lines" lines)
                    #f))))

;;; Talking to the adapter

(define (dap-write! msg)
  "Sends `msg` (a hash) to the debug adapter, framed as DAP expects.
   Does nothing without a session."
  (when *dap-job* (job-send! *dap-job* (lsp-frame (json-encode msg)))))

(define (next-dap-seq!)
  "Returns the next sequence number for a message to the adapter."
  (set! *dap-seq* (+ *dap-seq* 1)) *dap-seq*)

(define (dap-request! command arguments on-response)
  "Sends DAP request `command` with `arguments`; returns its seq.
   `on-response`, unless #f, gets the response's body when it succeeds.
   A failure is shown."
  (let ([seq (next-dap-seq!)])
    (when on-response (set! *dap-pending* (hash-insert *dap-pending* seq on-response)))
    (dap-write! (hash "seq" seq "type" "request" "command" command "arguments" arguments))
    seq))

(define (dap-output! text stream)
  "Handles output from the adapter's job on `stream`.
   stdout carries DAP messages, which are framed and dispatched as they
   complete; anything else (stderr) goes to the program output."
  (if (not (equal? stream "stdout"))
      (dap-add-output! text)
      (begin
        (set! *dap-input* (string-append *dap-input* text))
        (let loop ()
          (let ([taken (lsp-take-message *dap-input*)])
            (when taken
              (set! *dap-input* (cadr taken))
              (when (car taken)
                (with-handler (lambda (e) (message (string-append "debug: " (error-message e))))
                              (dap-dispatch! (car taken))))
              (loop)))))))

(define (dap-dispatch! msg)
  "Handles one message `msg` from the debug adapter.
   A response goes to the callback its request left, or is shown if it
   failed; an event goes to dap-event!. Reverse requests
   (runInTerminal, startDebugging) are answered as unsupported."
  (let ([type (jget msg "type")])
    (cond
      [(equal? type "response")
       (let* ([seq (jget msg "request_seq")] [callback (hash-try-get *dap-pending* seq)])
         (set! *dap-pending* (hash-remove *dap-pending* seq))
         (if (jget msg "success")
             (when callback (callback (or (jget msg "body") (hash))))
             (message (string-append "debug: " (or (jget msg "command") "request") " failed: "
                                     (or (jget msg "body" "error" "format") (jget msg "message") "")))))]
      [(equal? type "event") (dap-event! (jget msg "event") (or (jget msg "body") (hash)))]
      ;; Requests from the adapter (runInTerminal, startDebugging): not
      ;; supported, which adapters handle by doing without.
      [(equal? type "request")
       (dap-write! (hash "seq" (next-dap-seq!) "type" "response" "request_seq" (jget msg "seq")
                         "command" (jget msg "command") "success" #f
                         "message" "imp doesn't support this request"))]
      [else #f])))

(define (dap-event! name body)
  "Handles DAP event `name` with `body`.
   initialized sends the breakpoints and configurationDone; stopped
   fetches the stack and shows its innermost frame; continued clears the
   stopped line; output is kept for SPC d O; exited reports the exit
   code; terminated ends the session."
  (cond
    [(equal? name "initialized")
     ;; Now the adapter wants the breakpoints, then configurationDone.
     (for-each (lambda (id) (with-buffer id (lambda () (when (pair? (breakpoint-marks)) (send-breakpoints!)))))
               (buffer-list))
     (dap-request! "setExceptionBreakpoints" (hash "filters" '()) #f)
     (when (jget *dap-capabilities* "supportsConfigurationDoneRequest")
       (dap-request! "configurationDone" (hash) #f))]
    [(equal? name "stopped")
     (set! *dap-thread* (or (jget body "threadId") *dap-thread* 1))
     (let ([reason (or (jget body "reason") "")])
       (dap-request! "stackTrace" (hash "threadId" *dap-thread* "startFrame" 0 "levels" 50)
                     (lambda (result)
                       (set! *dap-frames* (or (jget result "stackFrames") '()))
                       (when (pair? *dap-frames*)
                         (show-frame! (car *dap-frames*))
                         (message (string-append "stopped (" reason ") in " (or (jget (car *dap-frames*) "name") "?")))))))]
    [(equal? name "continued") (clear-stopped!)]
    [(equal? name "output")
     (unless (equal? (jget body "category") "telemetry") (dap-add-output! (or (jget body "output") "")))]
    [(equal? name "exited")
     (message (string-append "program exited (" (to-string (or (jget body "exitCode") "?")) ")"))]
    [(equal? name "terminated") (dap-end!)]
    [else #f]))

(define (dap-add-output! text)
  "Adds `text` to the program's output, keeping the newest 1000 chunks."
  (set! *dap-output* (cons text (if (> (length *dap-output*) 999) (take *dap-output* 999) *dap-output*))))

;;; Where it stopped

(define (clear-stopped!)
  "Removes the mark and highlight of where the program stopped."
  (when *dap-stopped-at*
    (let ([id (car *dap-stopped-at*)])
      (when (memv id (buffer-list)) (with-buffer id (lambda () (set-sign-source! 'debug 30 '()))))))
  (set! *dap-stopped-at* #f)
  (highlight-clear! "debug"))

(define (show-stopped-line!)
  "Highlights the line the program stopped at, if it is in this buffer.
   Run on buffer-enter, as highlights belong to the current buffer."
  (highlight-clear! "debug")
  (when (and *dap-stopped-at* (= (car *dap-stopped-at*) (current-buffer)))
    (let ([line (cadr *dap-stopped-at*)])
      (when (<= line (last-line))
        (highlight-add! "debug" (line-start line) (min (buffer-length) (+ (line-end line) 1)) "debug-line")))))

(add-hook! 'buffer-enter show-stopped-line!)

(define (show-frame! frame)
  "Opens the source of stack frame `frame` at its line and marks it.
   It becomes the frame SPC d v and SPC d e use."
  (set! *dap-frame* (jget frame "id"))
  (let ([path (jget frame "source" "path")]
        [line (max 0 (- (or (jget frame "line") 1) 1))]
        [col (max 0 (- (or (jget frame "column") 1) 1))])
    (if (not path)
        (message (string-append "no source for " (or (jget frame "name") "this frame")))
        (when (or (equal? (and (buffer-path) (absolute-path (buffer-path))) path) (open-file! path))
          (clear-stopped!)
          (set! *dap-stopped-at* (list (current-buffer) line))
          (set-sign-source! 'debug 30 (list (list line "→" "sign.debug")))
          (when (<= line (last-line))
            (set-cursor! (min (+ (line-start line) col) (line-end line))))
          (normal-clamp!)
          (show-stopped-line!)))))

;;; Sessions

(define (dap-end!)
  "Ends the debug session: forgets its state and clears the stopped
   line. The adapter's job is killed a second later, giving it time to
   exit on its own."
  (clear-stopped!)
  (let ([job *dap-job*])
    (set! *dap-job* #f)
    (when job (run-after! 1000 (lambda () (job-kill! job)))))
  (set! *dap-pending* (hash))
  (set! *dap-frames* '())
  (set! *dap-frame* #f)
  (set! *dap-thread* #f)
  (message "debug session ended"))

(define (dap-start! spec arguments)
  "Starts a debug session with adapter `spec` and launch `arguments`.
   `spec` is (command adapter-id launch) from define-debug-adapter!.
   Runs the adapter, sends initialize, then launch once it answers."
  (set! *dap-input* "")
  (set! *dap-pending* (hash))
  (set! *dap-capabilities* (hash))
  (set! *dap-launch* arguments)
  (set! *dap-output* '())
  (set! *dap-session* (+ *dap-session* 1))
  (set! *dap-job*
        (let ([session *dap-session*])
          (start-job! (car spec) #f dap-output!
                      ;; Unless it already ended (terminated), or another began.
                      (lambda (code) (when (and *dap-job* (= session *dap-session*)) (dap-end!))))))
  (when *dap-job*
    (dap-request! "initialize"
                  (hash "clientID" "imp" "clientName" "imp" "adapterID" (cadr spec)
                        "pathFormat" "path" "linesStartAt1" #t "columnsStartAt1" #t
                        "supportsVariableType" #t "supportsRunInTerminalRequest" #f "locale" "en")
                  (lambda (capabilities)
                    (set! *dap-capabilities* capabilities)
                    (dap-request! "launch" arguments #f)))
    (message (string-append "debugging with " (car spec)))))

(define-command! 'debug-continue
  (lambda (count)
    "Start debugging the current buffer's program, or continue it."
    (cond
      [*dap-job*
       (if *dap-thread*
           (begin
             (dap-request! "continue" (hash "threadId" *dap-thread*) #f)
             (clear-stopped!))
           (message "the program is running"))]
      [(hash-try-get *debug-adapters* (major-mode))
       => (lambda (spec)
            (let ([words (split-whitespace (car spec))])
              (if (not (and (pair? words) (find-executable (car words))))
                  (message (string-append "debug adapter not found: " (car spec)))
                  ((caddr spec) (lambda (arguments) (dap-start! spec arguments))))))]
      [else (message (string-append "no debug adapter for " (symbol->string (major-mode))))])))

(define (step-command request)
  "A command that sends step request `request` for the stopped thread.
   `request` is a DAP command: next, stepIn or stepOut."
  (lambda (count)
    (if (and *dap-job* *dap-thread*)
        (begin (dap-request! request (hash "threadId" *dap-thread*) #f) (clear-stopped!))
        (message "not stopped in a debug session"))))

(define-command! 'debug-next (step-command "next"))
(define-command! 'debug-step-in (step-command "stepIn"))
(define-command! 'debug-step-out (step-command "stepOut"))

(define-command! 'debug-pause
  (lambda (count)
    "Pause the program being debugged.
     The adapter is asked for its threads, and the one that last stopped
     (else the first) is paused."
    (if *dap-job*
        (dap-request! "threads" (hash)
                      (lambda (body)
                        (let ([ids (filter (lambda (id) id)
                                           (map (lambda (t) (jget t "id")) (or (jget body "threads") '())))])
                          (cond [(null? ids) (message "the program has no threads to pause")]
                                [(memv *dap-thread* ids) (dap-request! "pause" (hash "threadId" *dap-thread*) #f)]
                                [else (dap-request! "pause" (hash "threadId" (car ids)) #f)]))))
        (message "no debug session"))))

(define-command! 'debug-stop
  (lambda (count)
    "End the debug session, terminating the program."
    (if *dap-job*
        (dap-request! "disconnect" (hash "terminateDebuggee" #t) (lambda (body) (when *dap-job* (dap-end!))))
        (message "no debug session"))))

;;; Looking around while stopped

(define (frame-label f)
  "How stack frame `f` reads in SPC d s: its name, file and line."
  (let ([path (jget f "source" "path")])
    (string-append (or (jget f "name") "?") "  "
                   (if path (relative-path path) "?") ":" (to-string (or (jget f "line") "?")))))

(define-command! 'debug-stack
  (lambda (count)
    "Pick a frame of the stopped program's stack and go to its source.
     SPC d v and SPC d e then use that frame."
    (if (null? *dap-frames*)
        (message "not stopped in a debug session")
        (let ([entries (let loop ([fs *dap-frames*] [i 0] [acc '()])
                         (if (null? fs) (reverse acc)
                             (loop (cdr fs) (+ i 1)
                                   (cons (cons (string-append (number->string i) " " (frame-label (car fs))) (car fs)) acc))))])
          (completing-read "Frame: " (map car entries)
                           (lambda (choice)
                             (let ([hit (assoc choice entries)])
                               (when hit (show-frame! (cdr hit))))))))))

(define-command! 'debug-variables
  (lambda (count)
    "Show the variables of the frame shown, by scope.
     One with children has a ▸ (evaluate it with SPC d e to see inside)."
    (if (not *dap-frame*)
        (message "not stopped in a debug session")
        (dap-request! "scopes" (hash "frameId" *dap-frame*)
                      (lambda (body)
                        (collect-scopes! (filter (lambda (s) (not (or (jget s "expensive")
                                                                      (equal? (jget s "presentationHint") "registers")
                                                                      (equal? (jget s "name") "Registers"))))
                                                (or (jget body "scopes") '()))
                                        '()))))))

(define (collect-scopes! scopes lines)
  "Fetches the variables of each of `scopes` in turn, then shows them.
   `lines` are those collected so far; scopes without variables are left
   out, and a variable with children gets a ▸."
  (if (null? scopes)
      (show-popup! (if (null? lines) (list "no variables") lines))
      (let ([scope (car scopes)])
        (dap-request! "variables" (hash "variablesReference" (jget scope "variablesReference"))
                      (lambda (body)
                        (let ([vars (or (jget body "variables") '())])
                          (collect-scopes!
                           (cdr scopes)
                           (if (null? vars)
                               lines
                               (append lines
                                       (list (string-append (or (jget scope "name") "scope") ":"))
                                       (map (lambda (v)
                                              (string-append "  " (or (jget v "name") "?") " = " (or (jget v "value") "")
                                                             (if (> (or (jget v "variablesReference") 0) 0) " ▸" "")))
                                            vars))))))))))

(define-command! 'debug-eval
  (lambda (count)
    "Evaluate an expression in the frame shown, and show its value.
     The prompt starts with the word at the cursor."
    (if (not *dap-job*)
        (message "no debug session")
        (let ([w (word-at (cursor))])
          (ask "Evaluate: " (if w (buffer-substring (car w) (cadr w)) "")
               (lambda (expression)
                 (dap-request! "evaluate"
                               (let ([args (hash "expression" expression "context" "repl")])
                                 (if *dap-frame* (hash-insert args "frameId" *dap-frame*) args))
                               (lambda (body) (message (or (jget body "result") ""))))))))))

(define-command! 'debug-output
  (lambda (count)
    "Show the last 100 chunks of the debugged program's output."
    (if (null? *dap-output*)
        (message "no program output")
        (show-popup! (apply append (map split-lines (reverse (take *dap-output* (min 100 (length *dap-output*))))))))))

;;; Keys

(define-leader-group! "d" "debug")
(define-leader! "dd" 'debug-continue "start / continue")
(define-leader! "dc" 'debug-continue "continue")
(define-leader! "db" 'toggle-breakpoint "toggle breakpoint")
(define-leader! "dB" 'clear-breakpoints "clear breakpoints")
(define-leader! "dn" 'debug-next "step over")
(define-leader! "di" 'debug-step-in "step in")
(define-leader! "do" 'debug-step-out "step out")
(define-leader! "dp" 'debug-pause "pause")
(define-leader! "dq" 'debug-stop "stop")
(define-leader! "ds" 'debug-stack "stack")
(define-leader! "dv" 'debug-variables "variables")
(define-leader! "de" 'debug-eval "evaluate")
(define-leader! "dO" 'debug-output "program output")

(define-key! 'normal "<f5>" 'debug-continue)
(define-key! 'normal "<f9>" 'toggle-breakpoint)
(define-key! 'normal "<f10>" 'debug-next)
(define-key! 'normal "<f11>" 'debug-step-in)
