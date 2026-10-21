;;; lsp.scm -- language servers: diagnostics, hover, definitions, rename,
;;; code actions, formatting and completion.
;;;
;;; A language server is a job (core.scm) with its stdin kept open. Rust
;;; only frames and decodes the messages (lsp-frame, lsp-read-messages,
;;; json-encode); everything here is Scheme, so any of it can be redefined.
;;;
;;; Servers are configured per major mode:
;;;
;;;   (define-language-server! 'rust-mode "rust-analyzer" '("Cargo.toml" ".git") "rust")
;;;
;;; The command can be a list of commands, of which the first installed is
;;; used.
;;;
;;; A buffer whose major mode has one, and whose file is somewhere, starts
;;; it (once per project root, found by walking up to one of the markers)
;;; if the program is installed and the `lsp` option is on. The buffer then
;;; gets lsp-mode: K hover, gd definition, gr references, SPC c r rename,
;;; SPC c a code actions, SPC c f format. ]d and [d move between
;;; diagnostics, :diagnostics lists them all. Diagnostics are pushed by
;;; the server, or pulled after each change from one that only answers
;;; when asked (TypeScript 7's). The server is complete.scm's first
;;; completion source after file paths, so C-n, C-x C-o and completion as
;;; you type (lsp-auto-complete) ask it.

(define-option! 'lsp #t '())
(define-option! 'lsp-auto-complete #t '())
;; Milliseconds of quiet before changes are sent (completion-delay is
;; complete.scm's, before completing).
(define-option! 'lsp-change-delay 200 '())
;; Whether diagnostics that arrive while you type show at once. Off (as
;; Neovim's update_in_insert), the current buffer keeps the ones it had
;; until you leave insert, so signs and underlines don't flicker as each
;; half-typed word is an error.
(define-option! 'lsp-diagnostics-in-insert #f '())

(define *language-servers* (hash))  ; major mode -> (command(s) markers language-id)
(define *lsp-servers* (hash))       ; "command<tab>root" -> state (a hash, see lsp-start!)
(define *lsp-diagnostics* (hash))   ; uri -> list of diagnostics
(define *lsp-change-timers* (hash)) ; buffer id -> timer of the pending didChange
(define *lsp-log* '())              ; newest first: stderr and logMessage lines
(define *lsp-line-message* #f)      ; the diagnostic shown on the status line
(define *lsp-held-diagnostics* #f)  ; buffer id whose new diagnostics wait for insert to end
(define *lsp-progress-message* #f)  ; the progress shown on the status line
(define *lsp-runs* 0)               ; servers started so far: each one's 'run

(define (define-language-server! mode command markers language-id)
  "Sets the language server for major mode `mode`.
   `command` is a shell command, or a list of them of which the first
   installed is used. The project root is the nearest directory up
   holding one of `markers`; `language-id` is the languageId sent in
   didOpen."
  (set! *language-servers* (hash-insert *language-servers* mode (list command markers language-id))))

(define-language-server! 'rust-mode "rust-analyzer" '("Cargo.toml" ".git") "rust")
;; TypeScript 7's own server, tsgo (`tsc --lsp` once 7 is released), first.
;; typescript-language-server comes before a bare tsc, which before 7 has
;; no --lsp.
(define *typescript-servers*
  '("tsgo --lsp --stdio" "typescript-language-server --stdio" "tsc --lsp --stdio"))
(define-language-server! 'typescript-mode *typescript-servers*
  '("tsconfig.json" "jsconfig.json" "package.json" ".git") "typescript")
(define-language-server! 'javascript-mode *typescript-servers*
  '("jsconfig.json" "tsconfig.json" "package.json" ".git") "javascript")
(define-language-server! 'nix-mode "nil" '("flake.nix" ".git") "nix")
(define-language-server! 'markdown-mode "marksman server" '(".marksman.toml" ".git") "markdown")
(define-language-server! 'python-mode "pyright-langserver --stdio"
  '("pyproject.toml" "setup.py" "setup.cfg" ".git") "python")

;;; JSON helpers. Objects are hashes with string keys; null is 'null.

(define (jget obj . path)
  "The value at keys `path` in JSON `obj`, or #f if missing or null.
   (jget obj \"a\" \"b\") is obj.a.b."
  (let loop ([v obj] [path path])
    (cond [(null? path) (if (equal? v 'null) #f v)]
          [(hash? v) (loop (hash-try-get v (car path)) (cdr path))]
          [else #f])))

(define (lsp-log! text)
  "Adds `text` to the :lsp-log, which keeps the newest 500 entries."
  (set! *lsp-log* (cons text (if (> (length *lsp-log*) 499) (take *lsp-log* 499) *lsp-log*))))

;;; Server state
;;;
;;; Fields: command, root, job, input (bytes not yet a whole message),
;;; next-id, pending (request id -> callback), ready (initialized),
;;; queue (messages held until then), capabilities, encoding ("utf-32" or
;;; "utf-16", what positions count).

(define (lsp-state key)
  "The state hash of the server under `key`, or #f if none is running."
  (hash-try-get *lsp-servers* key))

(define (lsp-get key field)
  "Field `field` of the state of server `key`, or #f."
  (let ([s (lsp-state key)]) (and s (hash-try-get s field))))

(define (lsp-put! key field value)
  "Sets field `field` of the state of server `key` to `value`.
   Does nothing if that server isn't running."
  (let ([s (lsp-state key)])
    (when s (set! *lsp-servers* (hash-insert *lsp-servers* key (hash-insert s field value))))))

(define (shell-quote text)
  "`text` in single quotes, safe to put in a shell command."
  (string-append "'" (apply string-append (map (lambda (c) (if (equal? c #\') "'\\''" (string c)))
                                               (string->list text)))
                 "'"))

(define (lsp-dirname path)
  "The directory part of `path`, without a trailing slash (\"/\" at the top)."
  (let loop ([i (- (string-length path) 1)])
    (cond [(<= i 0) "/"]
          [(equal? (string-ref path i) #\/) (substring path 0 i)]
          [else (loop (- i 1))])))

(define (lsp-root file markers)
  "The project root of `file`: the nearest directory up with a marker.
   That is one holding one of `markers`; with none, the file's own
   directory."
  (let ([start (lsp-dirname file)])
    (let loop ([dir start])
      (cond [(ormap (lambda (m) (file-exists? (string-append dir "/" m))) markers) dir]
            [(equal? dir "/") start]
            [else (loop (lsp-dirname dir))]))))

(define (ormap pred lst)
  "The first true value of (pred x) for the items of `lst`, or #f."
  (and (pair? lst) (or (pred (car lst)) (ormap pred (cdr lst)))))

(define (lsp-start! key command root)
  "Starts `command` in `root` as the server under `key`.
   Sends initialize once it runs. Returns #t, or #f if the job couldn't
   start.
   Its output and exit are only heeded while it is the server under `key`:
   after :lsp-restart the old one's last words don't reach the new one."
  (set! *lsp-runs* (+ *lsp-runs* 1))
  (set! *lsp-servers*
        (hash-insert *lsp-servers* key
                     (hash 'command command 'root root 'next-id 1 'pending (hash)
                           'ready #f 'queue '() 'capabilities (hash) 'encoding "utf-16"
                           'run *lsp-runs*)))
  (let* ([run *lsp-runs*]
         [current? (lambda () (equal? (lsp-get key 'run) run))]
         [job (start-job! (string-append "cd " (shell-quote root) " && exec " command) #f
                          (lambda (text stream) (when (current?) (lsp-output! key text stream)))
                          (lambda (code) (when (current?) (lsp-exited! key code))))])
    (if job
        (begin (lsp-put! key 'job job) (lsp-initialize! key) #t)
        (begin (set! *lsp-servers* (hash-remove *lsp-servers* key)) #f))))

(define (lsp-initialize! key)
  "Sends initialize to server `key`, and finishes starting on the reply.
   The reply's capabilities and position encoding are kept, initialized
   is sent, and the messages queued meanwhile go out."
  (let ([root (lsp-get key 'root)])
    (lsp-request-now! key "initialize"
      (hash "processId" 'null
            "clientInfo" (hash "name" "imp")
            "rootUri" (path->uri root)
            "rootPath" root
            "workspaceFolders" (list (hash "uri" (path->uri root) "name" (file-name-of root)))
            "capabilities" (lsp-client-capabilities))
      (lambda (result)
        (let ([caps (or (jget result "capabilities") (hash))])
          (lsp-put! key 'capabilities caps)
          (lsp-put! key 'encoding (if (equal? (jget caps "positionEncoding") "utf-32") "utf-32" "utf-16"))
          (lsp-put! key 'ready #t)
          (lsp-write! key (hash "jsonrpc" "2.0" "method" "initialized" "params" (hash)))
          (for-each (lambda (msg) (lsp-write! key msg)) (lsp-get key 'queue))
          (lsp-put! key 'queue '())
          (lsp-pull-all! key))))))

(define (lsp-client-capabilities)
  "The capabilities imp tells a server it has, in initialize."
  (hash "general" (hash "positionEncodings" (list "utf-32" "utf-16"))
        "textDocument"
        (hash "synchronization" (hash "didSave" #t)
              "hover" (hash "contentFormat" (list "markdown" "plaintext"))
              "definition" (hash "linkSupport" #t)
              "references" (hash)
              "rename" (hash)
              "formatting" (hash)
              "codeAction" (hash "codeActionLiteralSupport"
                                 (hash "codeActionKind"
                                       (hash "valueSet" (list "" "quickfix" "refactor" "refactor.extract"
                                                              "refactor.inline" "refactor.rewrite" "source"
                                                              "source.organizeImports")))
                                 "resolveSupport" (hash "properties" (list "edit")))
              "completion" (hash "completionItem" (hash "snippetSupport" #t))
              "publishDiagnostics" (hash)
              "diagnostic" (hash))
        "workspace" (hash "applyEdit" #t "workspaceEdit" (hash "documentChanges" #t)
                          "configuration" #t "workspaceFolders" #t
                          "diagnostics" (hash "refreshSupport" #t))
        "window" (hash "workDoneProgress" #t)))

(define (lsp-exited! key code)
  "Forgets server `key` after it exited with `code`, and says so.
   Its buffers lose lsp-mode and its diagnostics but remember the server,
   so :lsp-restart starts it again. It isn't restarted by itself: a server
   that crashes would only crash again."
  (let ([command (lsp-get key 'command)] [ids (buffers-of key)])
    (set! *lsp-servers* (hash-remove *lsp-servers* key))
    (for-each (lambda (id)
                (let ([timer (hash-try-get *lsp-change-timers* id)])
                  (when timer (cancel-timer! timer))
                  (set! *lsp-change-timers* (hash-remove *lsp-change-timers* id)))
                (with-buffer id
                  (lambda ()
                    (when (lsp-uri) (set! *lsp-diagnostics* (hash-remove *lsp-diagnostics* (lsp-uri))))
                    (lsp-show-signs!)
                    (minor-mode-off! 'lsp-mode))))
              ids)
    (when (memv (current-buffer) ids) (lsp-show-diagnostics!))
    (message (string-append "language server " (or command key) " exited (" (to-string code)
                            "); :lsp-restart starts it again"))))

;;; Sending

(define (lsp-write! key msg)
  "Sends `msg` (a hash) to server `key` at once, framed.
   Unlike lsp-send!, it doesn't wait for the server to be initialized."
  (let ([job (lsp-get key 'job)])
    (when job (job-send! job (lsp-frame (json-encode msg))))))

(define (lsp-send! key msg)
  "Sends `msg` to server `key`, or holds it until it is initialized."
  (if (lsp-get key 'ready)
      (lsp-write! key msg)
      (lsp-put! key 'queue (append (or (lsp-get key 'queue) '()) (list msg)))))

(define (lsp-add-request! key on-result)
  "Registers `on-result` for the next request to server `key`.
   Returns the request's id."
  (let ([id (lsp-get key 'next-id)])
    (lsp-put! key 'next-id (+ id 1))
    (lsp-put! key 'pending (hash-insert (lsp-get key 'pending) id on-result))
    id))

(define (lsp-request! key method params on-result)
  "Sends request `method` with `params` to server `key`; returns its id.
   `on-result` gets the result (#f for null) when it succeeds."
  (let ([id (lsp-add-request! key on-result)])
    (lsp-send! key (hash "jsonrpc" "2.0" "id" id "method" method "params" params))
    id))

(define (lsp-request-now! key method params on-result)
  "Sends request `method` to server `key` without waiting for it to be
   initialized, for initialize and shutdown. `on-result` gets the result.
   Returns the request's id, as lsp-request! does."
  (let ([id (lsp-add-request! key on-result)])
    (lsp-write! key (hash "jsonrpc" "2.0" "id" id "method" method "params" params))
    id))

(define (lsp-notify! key method params)
  "Sends notification `method` with `params` to server `key`.
   Held until the server is initialized."
  (lsp-send! key (hash "jsonrpc" "2.0" "method" method "params" params)))

;;; Receiving

(define (lsp-stream key)
  "The name Rust keeps server `key`'s output and completion replies
   under: its key and run, so a restarted server starts afresh."
  (string-append key "\t" (number->string (lsp-get key 'run))))

(define (lsp-output! key text stream)
  "Handles output from server `key`'s job on `stream`.
   stdout carries LSP messages, dispatched as each completes; anything
   else (stderr) goes to the :lsp-log."
  (if (not (equal? stream "stdout"))
      (lsp-log! text)
      ;; Rust collects the output into messages (lsp-read-messages).
      (for-each (lambda (msg)
                  (with-handler (lambda (e) (message (string-append "lsp: " (error-message e))))
                                (lsp-dispatch! key msg)))
                (lsp-read-messages (lsp-stream key) text))))

(define (lsp-dispatch! key msg)
  "Handles one message `msg` from server `key`.
   It is a request from the server (answered), a notification, or a
   response to one of ours."
  (let ([id (hash-try-get msg "id")] [method (hash-try-get msg "method")])
    (cond
      [(and method id) (lsp-reply! key id (lsp-server-request key method (jget msg "params")))]
      [method (lsp-notification! key method (jget msg "params"))]
      [id (lsp-response! key id msg)]
      [else #f])))

(define (lsp-response! key id msg)
  "Hands the result in response `msg` to the callback of request `id`.
   An error is shown, except for cancelled requests (-32800) and content
   modified (-32801), which are routine while typing."
  (let ([callback (hash-try-get (or (lsp-get key 'pending) (hash)) id)])
    (lsp-put! key 'pending (hash-remove (lsp-get key 'pending) id))
    (cond
      [(hash-try-get msg "error")
       ;; -32800 is a request we cancelled; content modified (-32801) is
       ;; routine while typing.
       (unless (member (jget msg "error" "code") '(-32800 -32801))
         (message (string-append "lsp: " (or (jget msg "error" "message") "request failed"))))]
      [callback (callback (jget msg "result"))]
      [else #f])))

(define (lsp-reply! key id result)
  "Answers request `id` from server `key` with `result`.
   A result of (error text) is sent as a -32601 error."
  (lsp-write! key (if (and (pair? result) (eq? (car result) 'error))
                      (hash "jsonrpc" "2.0" "id" id "error" (hash "code" -32601 "message" (cadr result)))
                      (hash "jsonrpc" "2.0" "id" id "result" result))))

(define (lsp-server-request key method params)
  "The answer to request `method` from server `key`, with `params`.
   Returns (error text) for a method imp doesn't handle."
  (cond
    [(equal? method "workspace/configuration")
     (map (lambda (item) 'null) (or (jget params "items") '()))]
    [(member method '("client/registerCapability" "client/unregisterCapability"
                      "window/workDoneProgress/create"))
     'null]
    [(equal? method "workspace/diagnostic/refresh") (lsp-pull-all! key) 'null]
    [(equal? method "workspace/applyEdit")
     (lsp-apply-workspace-edit! (jget params "edit") (lsp-get key 'encoding))
     (hash "applied" #t)]
    [(equal? method "workspace/workspaceFolders")
     (let ([root (lsp-get key 'root)]) (list (hash "uri" (path->uri root) "name" (file-name-of root))))]
    [(equal? method "window/showMessageRequest")
     (message (or (jget params "message") ""))
     'null]
    [else (list 'error (string-append "imp doesn't handle " method))]))

(define (lsp-notification! key method params)
  "Handles notification `method` from server `key` with `params`.
   Handles textDocument/publishDiagnostics, window/showMessage (errors
   and warnings are shown, all are logged), window/logMessage and
   $/progress; others are ignored."
  (cond
    [(equal? method "textDocument/publishDiagnostics")
     (lsp-set-diagnostics! (jget params "uri") (or (jget params "diagnostics") '()))]
    [(equal? method "window/showMessage")
     (lsp-log! (or (jget params "message") ""))
     (when (<= (or (jget params "type") 4) 2) (message (or (jget params "message") "")))]
    [(equal? method "window/logMessage") (lsp-log! (or (jget params "message") ""))]
    [(equal? method "$/progress") (lsp-progress! (jget params "value"))]
    [else #f]))

(define (lsp-progress! value)
  "Shows $/progress `value` on the status line, unless something else is.
   An end clears what it showed."
  (let* ([kind (jget value "kind")]
         [pct (jget value "percentage")]
         [text (string-append (or (jget value "title") "") " " (or (jget value "message") "")
                              (if pct (string-append " " (to-string pct) "%") ""))]
         [ours? (or (equal? (status-text) "") (equal? (status-text) *lsp-progress-message*))])
    (cond
      [(equal? kind "end")
       (when (and *lsp-progress-message* (equal? (status-text) *lsp-progress-message*)) (set-status! ""))
       (set! *lsp-progress-message* #f)]
      [ours? (set! *lsp-progress-message* text) (set-status! text)]
      [else #f])))

;;; Documents

(define (lsp-key)
  "The key of the current buffer's server if it is running, else #f."
  (let ([key (buffer-local 'lsp-server)]) (and key (lsp-state key) key)))

(define (lsp-uri)
  "The URI the current buffer has with its language server, or #f."
  (buffer-local 'lsp-uri))

(define (lsp-language-id id path)
  "The languageId for a file at `path` whose server's is `id`.
   .tsx and .jsx files get typescriptreact and javascriptreact."
  (cond [(and (equal? id "typescript") (ends-with? path ".tsx")) "typescriptreact"]
        [(and (equal? id "javascript") (ends-with? path ".jsx")) "javascriptreact"]
        [else id]))

(define (lsp-attach!)
  "Starts (or joins) the server for the current buffer's major mode."
  (let ([spec (hash-try-get *language-servers* (major-mode))] [path (buffer-path)])
    (when (and spec path (option 'lsp) (not (lsp-key)))
      (let ([command (lsp-installed-command (car spec))])
        (when command
          (let* ([file (absolute-path path)] [root (lsp-root file (cadr spec))]
                 [key (string-append command "\t" root)] [uri (path->uri file)])
            (when (or (lsp-state key) (lsp-start! key command root))
              (set-buffer-local! 'lsp-server key)
              (set-buffer-local! 'lsp-uri uri)
              (set-buffer-local! 'lsp-version 0)
              (minor-mode-on! 'lsp-mode)
              (lsp-notify! key "textDocument/didOpen"
                           (hash "textDocument"
                                 (hash "uri" uri "languageId" (lsp-language-id (caddr spec) file)
                                       "version" 0 "text" (buffer-substring 0 (buffer-length)))))
              (lsp-pull-diagnostics!))))))))

(define (lsp-installed-command commands)
  "The first of `commands` (one command, or a list) whose program is installed."
  (let loop ([commands (if (list? commands) commands (list commands))])
    (cond [(null? commands) #f]
          [(let ([words (split-whitespace (car commands))])
             (and (pair? words) (find-executable (car words))))
           (car commands)]
          [else (loop (cdr commands))])))

(define (lsp-text-document)
  "The current buffer's TextDocumentIdentifier, for requests."
  (hash "uri" (lsp-uri)))

(define (lsp-sync!)
  "Sends the current buffer's text now, if it changed since last sent."
  (let ([key (lsp-key)])
    (when (and key (buffer-local 'lsp-dirty))
      (let ([timer (hash-try-get *lsp-change-timers* (current-buffer))])
        (when timer (cancel-timer! timer))
        (set! *lsp-change-timers* (hash-remove *lsp-change-timers* (current-buffer))))
      (let ([version (+ 1 (or (buffer-local 'lsp-version) 0))])
        (set-buffer-local! 'lsp-version version)
        (set-buffer-local! 'lsp-dirty #f)
        (lsp-notify! key "textDocument/didChange"
                     (hash "textDocument" (hash "uri" (lsp-uri) "version" version)
                           "contentChanges" (list (hash "text" (buffer-substring 0 (buffer-length))))))
        ;; A change can affect other files' diagnostics too.
        (if (jget (lsp-get key 'capabilities) "diagnosticProvider" "interFileDependencies")
            (lsp-pull-all! key)
            (lsp-pull-diagnostics!))))))

(define (lsp-pull-diagnostics!)
  "Asks the server for the current buffer's diagnostics, if it is asked.
   That is a server that has diagnostics pulled (textDocument/diagnostic)
   rather than pushing them. An answer is dropped if the buffer changed
   since; the change asks again."
  (let ([key (lsp-key)] [uri (lsp-uri)] [id (current-buffer)] [version (buffer-local 'lsp-version)])
    (when (and key uri (lsp-get key 'ready) (jget (lsp-get key 'capabilities) "diagnosticProvider"))
      (lsp-request! key "textDocument/diagnostic" (hash "textDocument" (hash "uri" uri))
                    (lambda (result)
                      (when (and (equal? (jget result "kind") "full") (memv id (buffer-list))
                                 (equal? version (with-buffer id (lambda () (buffer-local 'lsp-version)))))
                        (lsp-set-diagnostics! uri (or (jget result "items") '()))))))))

(define (lsp-pull-all! key)
  "Asks server `key` for the diagnostics of each buffer it serves.
   Only a server that has diagnostics pulled answers."
  (for-each (lambda (id) (with-buffer id lsp-pull-diagnostics!)) (buffers-of key)))

(define (lsp-changed!)
  "Notes a change to the current buffer; it is sent after a pause."
  (when (lsp-key)
    (set-buffer-local! 'lsp-dirty #t)
    (let* ([id (current-buffer)] [old (hash-try-get *lsp-change-timers* id)])
      (when old (cancel-timer! old))
      (set! *lsp-change-timers*
            (hash-insert *lsp-change-timers* id
                         (run-after! (option 'lsp-change-delay)
                                     (lambda ()
                                       (set! *lsp-change-timers* (hash-remove *lsp-change-timers* id))
                                       (when (memv id (buffer-list)) (with-buffer id lsp-sync!)))))))))

(add-hook! 'major-mode (lambda (mode) (lsp-attach!)))
(add-hook! 'after-change lsp-changed!)
(add-hook! 'after-save
           (lambda ()
             (let ([key (lsp-key)])
               (when key
                 (lsp-sync!)
                 (lsp-notify! key "textDocument/didSave" (hash "textDocument" (lsp-text-document)))))))
(add-hook! 'buffer-kill
           (lambda (id)
             (with-buffer id
               (lambda ()
                 (let ([key (lsp-key)])
                   (when key
                     (lsp-notify! key "textDocument/didClose" (hash "textDocument" (lsp-text-document)))))))))

;; A renamed file is a new document to its server: close the old one;
;; the major mode, picked again, attaches the new.
(add-hook! 'buffer-renamed
           (lambda (old-path)
             (let ([key (lsp-key)])
               (when key
                 (lsp-notify! key "textDocument/didClose" (hash "textDocument" (lsp-text-document)))
                 (set! *lsp-diagnostics* (hash-remove *lsp-diagnostics* (lsp-uri)))
                 (set-buffer-local! 'lsp-server #f)
                 (set-buffer-local! 'lsp-uri #f)
                 (minor-mode-off! 'lsp-mode)))))

;;; Positions
;;;
;;; imp's offsets count chars, which is LSP's "utf-32". Servers that only
;;; do UTF-16 count chars past U+FFFF twice.

(define (astral? c)
  "Whether `c` is past U+FFFF, so two units in UTF-16."
  (> (char->integer c) #xFFFF))

(define (lsp-character line col encoding)
  "LSP's character for column `col` of `line` (the current buffer)."
  (if (equal? encoding "utf-32")
      col
      (let ([text (buffer-substring (line-start line) (+ (line-start line) col))])
        (+ col (length (filter astral? (string->list text)))))))

(define (lsp-position offset encoding)
  "The LSP position of `offset` in the current buffer, a hash.
   Its character counts in `encoding` (\"utf-16\" or \"utf-32\")."
  (let ([line (offset->line offset)])
    (hash "line" line "character" (lsp-character line (offset->col offset) encoding))))

(define (lsp-offset pos encoding)
  "The offset of LSP position `pos` in the current buffer, clamped to it.
   `pos` counts in `encoding`."
  (let ([line (or (jget pos "line") 0)] [character (or (jget pos "character") 0)])
    (if (> line (last-line))
        (buffer-length)
        (let* ([start (line-start line)] [len (buffer-line-length line)])
          (if (equal? encoding "utf-32")
              (+ start (min character len))
              (let loop ([col 0] [units 0])
                (if (or (>= col len) (>= units character))
                    (+ start col)
                    (loop (+ col 1) (+ units (if (astral? (buffer-char-at (+ start col))) 2 1))))))))))

(define (lsp-range-offsets r encoding)
  "The (start end) offsets of LSP range `r` in the current buffer."
  (list (lsp-offset (jget r "start") encoding) (lsp-offset (jget r "end") encoding)))

(define (lsp-encoding)
  "What the current buffer's server counts positions in.
   \"utf-32\" or \"utf-16\"; \"utf-16\" without a server."
  (or (lsp-get (lsp-key) 'encoding) "utf-16"))

(define (lsp-here)
  "The textDocument and position at the cursor, as most requests take."
  (hash "textDocument" (lsp-text-document) "position" (lsp-position (cursor) (lsp-encoding))))

(define (with-lsp proc)
  "Runs (proc key) with the current buffer's server, its text sent first.
   Says so if the buffer has no server."
  (let ([key (lsp-key)])
    (cond [key (lsp-sync!) (proc key)]
          [(buffer-local 'lsp-server) (message "the language server exited; :lsp-restart starts it again")]
          [else (message "no language server for this buffer")])))

;;; Diagnostics

;; Faces diagnostic.error/warning/info/hint and sign.* come from theme.scm.

(define (severity d)
  "The severity of diagnostic `d`, from 1 (error) to 4 (hint).
   One without a severity counts as an error."
  (or (jget d "severity") 1))

(define (severity-name d)
  "The severity of diagnostic `d` as a word, like \"error\" or \"hint\"."
  (let ([s (severity d)]) (cond [(= s 1) "error"] [(= s 2) "warning"] [(= s 3) "info"] [else "hint"])))

(define (severity-letter d)
  "The severity of diagnostic `d` as a letter: E, W, I or H."
  (let ([s (severity d)]) (cond [(= s 1) "E"] [(= s 2) "W"] [(= s 3) "I"] [else "H"])))

(define (lsp-set-diagnostics! uri diagnostics)
  "Records `diagnostics` for the file at `uri` and shows them.
   If the file is open its signs update, and in the current buffer its
   highlights and the status line too."
  (set! *lsp-diagnostics* (hash-insert *lsp-diagnostics* uri diagnostics))
  (let* ([path (uri->path uri)] [id (and path (buffer-for-path path))])
    (cond [(not id) #f]
          [(and (= id (current-buffer)) (memq *mode* '(insert replace))
                (not (option 'lsp-diagnostics-in-insert)))
           (set! *lsp-held-diagnostics* id)]
          [else
           (with-buffer id lsp-show-signs!)
           (when (= id (current-buffer)) (lsp-show-diagnostics!) (lsp-show-cursor-diagnostic!))])))

(define (lsp-show-held-diagnostics!)
  "Shows the diagnostics that arrived while typing, after insert ends."
  (let ([id *lsp-held-diagnostics*])
    (set! *lsp-held-diagnostics* #f)
    (when (and id (memv id (buffer-list)))
      (with-buffer id lsp-show-signs!)
      (when (= id (current-buffer)) (lsp-show-diagnostics!) (lsp-show-cursor-diagnostic!)))))

(add-hook! 'insert-leave lsp-show-held-diagnostics!)

(define (buffer-diagnostics)
  "The current buffer's diagnostics as (start end diagnostic) lists.
   They are sorted by where they start."
  (let ([uri (lsp-uri)] [encoding (lsp-encoding)])
    (if (not uri)
        '()
        (sort (map (lambda (d) (append (lsp-range-offsets (jget d "range") encoding) (list d)))
                   (or (hash-try-get *lsp-diagnostics* uri) '()))
              (lambda (a b) (< (car a) (car b)))))))

(define (lsp-show-signs!)
  "Puts a sign for the current buffer's diagnostics on their lines.
   Also updates the error and warning counts on the status line."
  ;; The most severe diagnostic on each line wins its sign.
  (let ([signs (foldl (lambda (d acc)
                        (let* ([line (offset->line (car d))] [old (hash-try-get acc line)])
                          (if (and old (<= (severity old) (severity (caddr d))))
                              acc
                              (hash-insert acc line (caddr d)))))
                      (hash) (buffer-diagnostics))])
    (set-sign-source! 'diagnostics 10 (map (lambda (line)
                       (let ([d (hash-ref signs line)])
                         (list line (severity-letter d) (string-append "sign." (severity-name d)))))
                     (hash-keys->list signs))))
  (show-diagnostic-counts!))

(define (show-diagnostic-counts!)
  "Sets %{diagnostics} in the status line to the buffer's counts.
   It shows the errors and warnings, when there are any."
  (let* ([ds (map caddr (buffer-diagnostics))]
         [count (lambda (s) (length (filter (lambda (d) (= (severity d) s)) ds)))]
         [errors (count 1)] [warnings (count 2)])
    (set-status-value! "diagnostics"
                       (string-append (if (> errors 0) (string-append "%#status.error#E" (number->string errors) "%* ") "")
                                      (if (> warnings 0) (string-append "%#status.warning#W" (number->string warnings) "%* ") ""))
                       #f)))

(define (lsp-show-diagnostics!)
  "Highlights the current buffer's diagnostics by severity."
  (highlight-clear! "diagnostics")
  (for-each (lambda (d)
              (let* ([s (car d)] [e (min (buffer-length) (max (cadr d) (+ s 1)))])
                (when (< s e)
                  (highlight-add! "diagnostics" s e (string-append "diagnostic." (severity-name (caddr d)))))))
            (buffer-diagnostics)))

(add-hook! 'buffer-enter lsp-show-diagnostics!)

(define (diagnostic-text d)
  "Diagnostic `d` as one line: \"E: message (source)\"."
  (string-append (severity-letter d) ": " (or (jget d "message") "")
                 (let ([source (jget d "source")]) (if source (string-append " (" source ")") ""))))

(define (diagnostic-at-cursor)
  "The diagnostic to show for the cursor, or #f.
   The most severe one under the cursor, else the most severe on its
   line."
  (let* ([p (cursor)] [line (current-line)]
         [on-line (filter (lambda (d) (= (offset->line (car d)) line)) (buffer-diagnostics))]
         [under (filter (lambda (d) (and (<= (car d) p) (< p (max (cadr d) (+ (car d) 1))))) on-line)]
         [pick (if (pair? under) under on-line)])
    (and (pair? pick)
         (caddr (foldl (lambda (d best) (if (< (severity (caddr d)) (severity (caddr best))) d best))
                       (car pick) (cdr pick))))))

(define (lsp-show-cursor-diagnostic!)
  "Shows the diagnostic at the cursor on the status line, in normal mode.
   Only when nothing else is there; it runs after each command and when
   diagnostics arrive."
  (when (and (eq? *mode* 'normal) (not *popup-shown*))
    (let* ([d (and (lsp-uri) (diagnostic-at-cursor))]
           [status (status-text)]
           [free? (or (equal? status "") (equal? status *lsp-line-message*))])
      (cond [(and d free?)
             (set! *lsp-line-message* (diagnostic-text d))
             (set-status! *lsp-line-message*)]
            [(and (not d) *lsp-line-message* (equal? status *lsp-line-message*))
             (set-status! "")
             (set! *lsp-line-message* #f)]
            [else #f]))))

(add-hook! 'post-command lsp-show-cursor-diagnostic!)

(define (next-diagnostic! count forward?)
  "Moves to the `count`th next diagnostic, or previous, wrapping around.
   For ]d and [d."
  (let* ([starts (map car (buffer-diagnostics))]
         [starts (if forward? starts (reverse starts))])
    (if (null? starts)
        (message "no diagnostics")
        (let loop ([p (cursor)] [n count])
          (if (= n 0)
              (set-cursor! p)
              (let ([next (filter (lambda (s) (if forward? (> s p) (< s p))) starts)])
                (loop (if (pair? next) (car next) (car starts)) (- n 1))))))))

(define-command! 'next-diagnostic (lambda (count)
                                    "Go to the next diagnostic (]d), wrapping around."
                                    (next-diagnostic! count #t)))
(define-command! 'previous-diagnostic (lambda (count)
                                        "Go to the previous diagnostic ([d), wrapping around."
                                        (next-diagnostic! count #f)))
(define-key! 'normal "]d" 'next-diagnostic)
(define-key! 'normal "[d" 'previous-diagnostic)

(define (relative-path path)
  "`path` relative to the current directory, if it is under it."
  (let ([dir (string-append (current-dir) "/")])
    (if (starts-with? path dir) (substring path (string-length dir) (string-length path)) path)))

(define (file-line path line)
  "The text of line `line` of `path`, from its buffer if it is open."
  (let ([id (buffer-for-path path)])
    (if id
        (with-buffer id (lambda () (if (<= line (last-line)) (line-text line) "")))
        (let ([lines (if (file-exists? path) (split-lines (read-file path)) '())])
          (if (< line (length lines)) (list-ref lines line) "")))))

(define-command! 'list-diagnostics
  (lambda (count)
    "Pick a diagnostic from any file's and jump to it (:diagnostics)."
    (let ([entries
           (apply append
                  (map (lambda (uri)
                         (let ([path (uri->path uri)])
                           (map (lambda (d)
                                  (let ([line (or (jget d "range" "start" "line") 0)])
                                    (cons (string-append (relative-path (or path uri)) ":" (number->string (+ line 1))
                                                         ": " (diagnostic-text d))
                                          (list uri (jget d "range")))))
                                (hash-ref *lsp-diagnostics* uri))))
                       (hash-keys->list *lsp-diagnostics*)))])
      (if (null? entries)
          (message "no diagnostics")
          (completing-read "Diagnostic: " (map car entries)
                           (lambda (choice)
                             (let ([hit (assoc choice entries)])
                               (when hit (lsp-jump! (cadr hit) (caddr hit) #f)))))))))

(define-ex! '("diagnostics") (lambda (ex) (run-command 'list-diagnostics)))

;;; Going places

(define (lsp-jump! uri r encoding)
  "Goes to the start of range `r` in `uri`, opening it, as a jump.
   Positions count in `encoding`, or the buffer's server's if #f."
  (let ([path (uri->path uri)] [encoding (or encoding (lsp-encoding))])
    (cond
      [(not path) (message (string-append "can't open " uri))]
      [(equal? (and (buffer-path) (absolute-path (buffer-path))) path)
       (record-jump!)
       (set-cursor! (lsp-offset (jget r "start") encoding))
       (normal-clamp!)]
      [(open-file! path)
       (set-cursor! (lsp-offset (jget r "start") encoding))
       (normal-clamp!)]
      [else #f])))

(define (lsp-locations result)
  "Locations from a definition or references reply, as (uri range)."
  (let ([items (cond [(not result) '()] [(hash? result) (list result)] [else result])])
    (filter (lambda (l) (car l))
            (map (lambda (l)
                   (if (jget l "targetUri")
                       (list (jget l "targetUri") (or (jget l "targetSelectionRange") (jget l "targetRange")))
                       (list (jget l "uri") (jget l "range"))))
                 items))))

(define (location-label l)
  "\"file:line: text\" for a location."
  (let* ([path (or (uri->path (car l)) (car l))] [line (or (jget (cadr l) "start" "line") 0)])
    (string-append (relative-path path) ":" (number->string (+ line 1)) ": " (trim (file-line path line)))))

(define (choose-location! locations what encoding)
  "Goes to the only one of `locations`, or lets you pick one.
   `what` names them in the prompt (\"definition\") and when there are
   none."
  (cond
    [(null? locations) (message (string-append "no " what " found"))]
    [(null? (cdr locations)) (lsp-jump! (car (car locations)) (cadr (car locations)) encoding)]
    [else
     (let ([entries (map (lambda (l) (cons (location-label l) l)) locations)])
       (completing-read (string-append (string-upcase (substring what 0 1))
                                       (substring what 1 (string-length what)) ": ")
                        (map car entries)
                        (lambda (choice)
                          (let ([hit (assoc choice entries)])
                            (when hit (lsp-jump! (cadr hit) (caddr hit) encoding))))))]))

(define-command! 'lsp-definition
  (lambda (count)
    "Go to the definition of the symbol at the cursor (gd).
     With more than one, pick one."
    (with-lsp (lambda (key)
                (lsp-request! key "textDocument/definition" (lsp-here)
                              (lambda (result)
                                (choose-location! (lsp-locations result) "definition" (lsp-get key 'encoding))))))))

(define-command! 'lsp-references
  (lambda (count)
    "Pick a reference to the symbol at the cursor and go to it (gr)."
    (with-lsp (lambda (key)
                (lsp-request! key "textDocument/references"
                              (hash-insert (lsp-here) "context" (hash "includeDeclaration" #t))
                              (lambda (result)
                                (choose-location! (lsp-locations result) "reference" (lsp-get key 'encoding))))))))

;;; Hover

(define (hover-lines contents)
  "Markdown from a hover reply as lines, without code fences."
  (let* ([text (cond [(not contents) ""]
                     [(string? contents) contents]
                     [(hash? contents) (or (jget contents "value") "")]
                     [(list? contents) (string-join (map (lambda (c) (string-join (hover-lines c) "\n")) contents) "\n\n")]
                     [else ""])]
         [lines (filter (lambda (l) (not (starts-with? (trim-left l) "```"))) (split-lines text))])
    ;; Drop blank lines at the ends.
    (let ([strip (lambda (ls) (let loop ([ls ls]) (if (and (pair? ls) (equal? (trim (car ls)) "")) (loop (cdr ls)) ls)))])
      (reverse (strip (reverse (strip lines)))))))

(define-command! 'lsp-hover
  (lambda (count)
    "Show what the language server says about the symbol at the cursor.
     The first 20 lines appear in a popup at the cursor (K)."
    (with-lsp (lambda (key)
                (lsp-request! key "textDocument/hover" (lsp-here)
                              (lambda (result)
                                (let ([lines (hover-lines (jget result "contents"))])
                                  (if (null? lines)
                                      (message "no information here")
                                      (begin
                                        (show-popup! (take lines (min 20 (length lines))))
                                        (set-popup-place! "cursor" 0 ""))))))))))

;;; Changing text from the server

(define (lsp-apply-text-edits! edits encoding)
  "Applies TextEdits `edits` to the current buffer as one undo step.
   They are applied last first, so earlier positions stay valid; edits
   at the same place keep their order."
  (let* ([indexed (let loop ([es edits] [i 0] [acc '()])
                    (if (null? es) acc
                        (loop (cdr es) (+ i 1)
                              (cons (append (lsp-range-offsets (jget (car es) "range") encoding)
                                            (list (or (jget (car es) "newText") "") i))
                                    acc))))]
         [ordered (sort indexed (lambda (a b) (or (> (car a) (car b))
                                                  (and (= (car a) (car b)) (> (cadddr a) (cadddr b))))))])
    (unless (null? ordered)
      (mark-set! "lsp-cursor" (cursor))
      (begin-change!)
      (with-undo-group
       (lambda () (for-each (lambda (c) (replace-range! (car c) (cadr c) (caddr c))) ordered)))
      (set-cursor! (or (mark-get "lsp-cursor") (cursor)))
      (mark-delete! "lsp-cursor")
      (when (eq? *mode* 'normal) (normal-clamp!))
      (lsp-changed!))))

(define (lsp-edit-uri! uri edits encoding)
  "Applies TextEdits to the file at `uri`, opening it if needed."
  (let* ([path (uri->path uri)]
         [id (and path (or (buffer-for-path path)
                           (let ([r (buffer-open! path)]) (if (string? r) (begin (message r) #f) r))))])
    (when id
      (with-buffer id
        (lambda ()
          (unless (buffer-seen? id)
            (mark-buffer-seen! id)
            (run-hooks 'buffer-open))
          (lsp-apply-text-edits! edits encoding)))
      ;; Opening a buffer set its options and mode line; put ours back.
      (refresh-option-watchers!)
      (show-major-mode!))
    id))

(define (lsp-apply-workspace-edit! edit encoding)
  "Applies a WorkspaceEdit; returns how many files it changed."
  (let* ([changes (jget edit "changes")]
         [from-changes (if (hash? changes)
                           (map (lambda (uri) (list uri (hash-ref changes uri))) (hash-keys->list changes))
                           '())]
         [from-documents (filter (lambda (x) x)
                                 (map (lambda (dc)
                                        (if (jget dc "textDocument")
                                            (list (jget dc "textDocument" "uri") (or (jget dc "edits") '()))
                                            (begin (message "lsp: file create/rename/delete isn't supported yet") #f)))
                                      (or (jget edit "documentChanges") '())))]
         [all (if (null? from-documents) from-changes from-documents)])
    (for-each (lambda (c) (lsp-edit-uri! (car c) (cadr c) encoding)) all)
    (length all)))

;;; Rename, code actions, formatting

(define-command! 'lsp-rename
  (lambda (count)
    "Rename the symbol at the cursor everywhere the server knows of it."
    (with-lsp
     (lambda (key)
       (let* ([w (word-at (cursor))] [old (if w (buffer-substring (car w) (cadr w)) "")] [here (lsp-here)])
         (open-cmdline! "Rename to: " old
                        (lambda (name)
                          (unless (or (equal? name "") (equal? name old))
                            (lsp-request! key "textDocument/rename" (hash-insert here "newName" name)
                                          (lambda (result)
                                            (if (not result)
                                                (message "nothing to rename here")
                                                (let ([n (lsp-apply-workspace-edit! result (lsp-get key 'encoding))])
                                                  (message (string-append "renamed in " (number->string n)
                                                                          (if (= n 1) " file" " files")))))))))
                        #f #f))))))

(define (run-code-action! key action)
  "Runs code action `action` from server `key`.
   Applies its edit, then runs its command; one with neither is resolved
   (codeAction/resolve) first."
  (let ([encoding (lsp-get key 'encoding)])
    (cond
      ;; A bare Command.
      [(string? (jget action "command")) (execute-lsp-command! key action)]
      [(or (jget action "edit") (jget action "command"))
       (when (jget action "edit") (lsp-apply-workspace-edit! (jget action "edit") encoding))
       (when (jget action "command") (execute-lsp-command! key (jget action "command")))]
      [(jget (lsp-get key 'capabilities) "codeActionProvider" "resolveProvider")
       (lsp-request! key "codeAction/resolve" action
                     (lambda (resolved) (when (and resolved (or (jget resolved "edit") (jget resolved "command")))
                                          (run-code-action! key resolved))))]
      [else (message "this action does nothing")])))

(define (execute-lsp-command! key command)
  "Asks server `key` to run LSP Command `command`; ignores the result.
   The request is workspace/executeCommand."
  (lsp-request! key "workspace/executeCommand"
                (hash "command" (jget command "command") "arguments" (or (jget command "arguments") '()))
                (lambda (result) #f)))

(define-command! 'lsp-code-action
  (lambda (count)
    "Pick one of the server's code actions for the cursor or selection.
     The diagnostics on those lines are sent with the request."
    (with-lsp
     (lambda (key)
       (let* ([encoding (lsp-encoding)]
              [bounds (if (eq? *mode* 'visual)
                          (let ([r (visual-range)]) (leave-visual!) (list (car r) (cadr r)))
                          (list (cursor) (cursor)))]
              [lines (list (offset->line (car bounds)) (offset->line (cadr bounds)))]
              [diags (filter (lambda (d) (let ([l (offset->line (car d))]) (and (>= l (car lines)) (<= l (cadr lines)))))
                             (buffer-diagnostics))])
         (lsp-request! key "textDocument/codeAction"
                       (hash "textDocument" (lsp-text-document)
                             "range" (hash "start" (lsp-position (car bounds) encoding)
                                           "end" (lsp-position (cadr bounds) encoding))
                             "context" (hash "diagnostics" (map caddr diags)))
                       (lambda (result)
                         (let ([actions (or result '())])
                           (if (null? actions)
                               (message "no code actions here")
                               (let ([entries (map (lambda (a) (cons (or (jget a "title") "?") a)) actions)])
                                 (completing-read "Code action: " (map car entries)
                                                  (lambda (choice)
                                                    (let ([hit (assoc choice entries)])
                                                      (when hit (run-code-action! key (cdr hit))))))))))))))))

(define-command! 'lsp-format
  (lambda (count)
    "Format the buffer with its language server.
     Indents by the shiftwidth and expandtab options."
    (with-lsp
     (lambda (key)
       (let ([id (current-buffer)])
         (lsp-request! key "textDocument/formatting"
                       (hash "textDocument" (lsp-text-document)
                             "options" (hash "tabSize" (option 'shiftwidth) "insertSpaces" (option 'expandtab)))
                       (lambda (edits)
                         (when (and edits (memv id (buffer-list)))
                           (with-buffer id (lambda () (lsp-apply-text-edits! edits (lsp-get key 'encoding))))))))))))

;;; Servers: information and control

(define (lsp-server-lines)
  "A line for each running server, for :lsp-info.
   Each says its command, root, whether it is still starting, and what
   its positions count in."
  (map (lambda (key)
         (string-append (lsp-get key 'command) "  " (lsp-get key 'root)
                        (if (lsp-get key 'ready) "" "  (starting)")
                        "  positions: " (lsp-get key 'encoding)))
       (hash-keys->list *lsp-servers*)))

(define-ex! '("lsp-info")
  (lambda (ex)
    (let ([lines (lsp-server-lines)])
      (if (null? lines) (message "no language servers running") (show-popup! lines)))))

(define-ex! '("lsp-log")
  (lambda (ex)
    (if (null? *lsp-log*)
        (message "the language server log is empty")
        (show-popup! (apply append (map split-lines (reverse (take *lsp-log* (min 40 (length *lsp-log*))))))))))

(define (lsp-stop! key)
  "Asks the server to exit; it is killed if it hasn't after a second."
  (let ([job (lsp-get key 'job)])
    (lsp-request-now! key "shutdown" 'null
                      (lambda (result) (lsp-write! key (hash "jsonrpc" "2.0" "method" "exit"))))
    (run-after! 1000 (lambda () (when job (job-kill! job))))))

(define (buffers-of key)
  "The buffers that talk to server `key`."
  (filter (lambda (id) (with-buffer id (lambda () (equal? (buffer-local 'lsp-server) key)))) (buffer-list)))

(define-command! 'lsp-restart
  (lambda (count)
    "Restart the current buffer's language server (:lsp-restart).
     It starts again for every buffer that used it."
    (let ([key (buffer-local 'lsp-server)])
      (if (not key)
          (message "no language server for this buffer")
          (let ([ids (buffers-of key)])
            (when (lsp-state key) (lsp-stop! key))
            (set! *lsp-servers* (hash-remove *lsp-servers* key))
            (for-each (lambda (id)
                        (with-buffer id (lambda () (set-buffer-local! 'lsp-server #f) (lsp-attach!))))
                      ids)
            (message "restarted the language server"))))))

(define-ex! '("lsp-restart") (lambda (ex) (run-command 'lsp-restart)))
(define-ex! '("lsp-stop")
  (lambda (ex)
    (let ([key (lsp-key)])
      (if key (begin (lsp-stop! key) (message "stopping the language server")) (message "no language server for this buffer")))))

;;; Keys

(define-minor-mode! 'lsp-mode #f #f)
(define-mode-key! 'lsp-mode 'normal "K" 'lsp-hover)
(define-mode-key! 'lsp-mode 'normal "gd" 'lsp-definition)
(define-mode-key! 'lsp-mode 'normal "gr" 'lsp-references)

(define-leader-group! "c" "code")
(define-leader! "ca" 'lsp-code-action "code action")
(define-leader! "cr" 'lsp-rename "rename")
(define-leader! "cf" 'lsp-format "format buffer")
(define-leader! "cd" 'lsp-definition "go to definition")
(define-leader! "cD" 'lsp-references "references")
(define-leader! "ck" 'lsp-hover "hover")
(define-leader! "cx" 'list-diagnostics "diagnostics")
(define-leader! "cR" 'lsp-restart "restart server")

;;; Completion: the language server as a source for complete.scm's menu

(define (strip-snippet text)
  "Snippet `text` as plain text, without its tab stops.
   ${1:text} -> text, $1 ${1} $0 -> nothing, ${1|a,b|} -> a, \\$ -> $."
  (let loop ([cs (string->list text)] [out '()] [depth 0])
    (cond
      [(null? cs) (list->string (reverse out))]
      [(and (equal? (car cs) #\\) (pair? (cdr cs))) (loop (cddr cs) (cons (cadr cs) out) depth)]
      [(and (equal? (car cs) #\$) (pair? (cdr cs)) (char-digit? (cadr cs)))
       (loop (drop-while char-digit? (cdr cs)) out depth)]
      [(and (equal? (car cs) #\$) (pair? (cdr cs)) (equal? (cadr cs) #\{))
       (let* ([rest (drop-while char-digit? (cddr cs))])
         (cond [(and (pair? rest) (equal? (car rest) #\:)) (loop (cdr rest) out (+ depth 1))]
               [(and (pair? rest) (equal? (car rest) #\|))
                ;; A choice: keep the first option.
                (let* ([opts (cdr rest)]
                       [first-opt (take-while (lambda (c) (not (memv c (list #\, #\|)))) opts)]
                       [after (drop-while (lambda (c) (not (equal? c #\}))) opts)])
                  (loop (if (pair? after) (cdr after) after) (append (reverse first-opt) out) depth))]
               [else (loop (if (pair? rest) (cdr rest) rest) out depth)]))]
      [(and (equal? (car cs) #\}) (> depth 0)) (loop (cdr cs) out (- depth 1))]
      [else (loop (cdr cs) (cons (car cs) out) depth)])))


(define (lsp-item-text item)
  "What completion item `item` inserts: its edit's text, its insertText or
   its label (a snippet's body, for a snippet)."
  (let ([edit (jget item "textEdit")])
    (cond [edit (or (jget edit "newText") "")]
          [(jget item "insertText") => (lambda (t) t)]
          [else (or (jget item "label") "")])))

(define (lsp-snippet? item)
  "Whether completion item `item` inserts a snippet."
  (equal? (jget item "insertTextFormat") 2))

(define (completion-candidates result start encoding)
  "Menu candidates from completion reply `result`, in the server's order.
   `start` is where the typed word starts, for items without a textEdit;
   snippets are reduced to plain text. A reply Rust kept (see
   lsp-expect-completion!) is read there."
  (if (and (hash? result) (jget result "imp-completion"))
      (lsp-completion-candidates (jget result "imp-completion") start encoding)
      (completion-candidates-of result start encoding)))

(define (kept-item? item)
  "Whether `item` is a menu candidate's item from a reply Rust kept:
   (imp-completion handle index kind)."
  (and (pair? item) (equal? (car item) 'imp-completion)))

(define (full-completion-item item)
  "Completion item `item` whole: one from a reply Rust kept holds only
   its kind, and where to find the rest."
  (if (kept-item? item) (lsp-completion-item (cadr item) (caddr item)) item))

(define (completion-item-kind item)
  "The kind of completion item `item` (a CompletionItemKind number), or #f."
  (cond [(kept-item? item) (cadddr item)]
        [(hash? item) (jget item "kind")]
        [else #f]))

(define (completion-candidates-of result start encoding)
  "completion-candidates for a reply decoded in Scheme."
  (let* ([items (cond [(not result) '()] [(hash? result) (or (jget result "items") '())] [else result])]
         ;; The server's order (sortText), which matching keeps for ties.
         [sort-key (lambda (item) (or (jget item "sortText") (jget item "label") ""))]
         [items (sort items (lambda (a b) (string<? (sort-key a) (sort-key b))))])
    (map (lambda (item)
           (let* ([edit (jget item "textEdit")]
                  [edit-range (and edit (or (jget edit "range") (jget edit "insert")))]
                  [raw (lsp-item-text item)]
                  [text (if (lsp-snippet? item) (strip-snippet raw) raw)])
             (list (or (jget item "label") text)
                   (or (jget item "detail") "")
                   text
                   (if edit-range (lsp-offset (jget edit-range "start") encoding) start)
                   item)))
         items)))


(define (trigger-char? key c)
  "Whether `c` is one of server `key`'s completion trigger characters."
  (member (string c) (or (jget (lsp-get key 'capabilities) "completionProvider" "triggerCharacters") '())))


(define (lsp-completion-source manual? done)
  "The completion source for buffers with a language server: asks it
   (textDocument/completion) and answers with its items. Accepting one
   applies the server's extra edits (imports, say)."
  (let ([key (lsp-key)] [start (word-start-before (cursor))])
    (and key
         (let ([encoding (lsp-encoding)] [old (lsp-get key 'completion-request)])
           (lsp-sync!)
           ;; Only the newest request's reply is wanted: a server may send
           ;; megabytes for each.
           (when old
             (lsp-drop-completion! (lsp-stream key) old)
             (lsp-notify! key "$/cancelRequest" (hash "id" old)))
           (let ([id #f])
             (set! id (lsp-request! key "textDocument/completion"
                         (hash-insert (lsp-here) "context" (hash "triggerKind" 1))
                         (lambda (result)
                           (when (equal? (lsp-get key 'completion-request) id)
                             (lsp-put! key 'completion-request #f))
                           (done start (completion-candidates result start encoding)
                                 'incomplete (and (hash? result) (jget result "isIncomplete"))
                                 'fuzzy #t
                                 'on-accept (lambda (stub)
                                              (define item (full-completion-item stub))
                                              ;; The snippet went in as plain text: expand it.
                                              (when (and item (lsp-snippet? item))
                                                (let* ([raw (lsp-item-text item)] [plain (strip-snippet raw)])
                                                  (unless (equal? raw plain)
                                                    (snippet-insert! (- (cursor) (string-length plain)) (cursor) raw))))
                                              (let ([extra (and item (jget item "additionalTextEdits"))])
                                                (when (and extra (pair? extra))
                                                  (lsp-apply-text-edits! extra (lsp-get key 'encoding))))
                                              (lsp-changed!))))))
             (lsp-expect-completion! (lsp-stream key) id)
             (lsp-put! key 'completion-request id))
           #t))))

(define (lsp-auto-complete c)
  "Whether `c`, just typed, opens the menu by itself where a server is
   attached: after a word character or one of its trigger characters;
   'never with lsp-auto-complete off; #f without a server."
  (let ([key (lsp-key)])
    (cond [(not key) #f]
          [(not (option 'lsp-auto-complete)) 'never]
          [else (or (char-word? c) (and (trigger-char? key c) #t))])))

;; Ranked above the other sources; as you type, after a word character or
;; one of the server's trigger characters (lsp-auto-complete).
(define-completion-source! 'lsp lsp-completion-source
  'before 'scheme 'priority 100 'auto lsp-auto-complete)
