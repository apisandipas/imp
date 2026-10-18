;;; lsp.scm -- language servers: diagnostics, hover, definitions, rename,
;;; code actions, formatting and completion.
;;;
;;; A language server is a job (core.scm) with its stdin kept open. Rust
;;; only frames and decodes the messages (lsp-frame, lsp-take-message,
;;; json-encode); everything here is Scheme, so any of it can be redefined.
;;;
;;; Servers are configured per major mode:
;;;
;;;   (define-language-server! 'rust-mode "rust-analyzer" '("Cargo.toml" ".git") "rust")
;;;
;;; A buffer whose major mode has one, and whose file is somewhere, starts
;;; it (once per project root, found by walking up to one of the markers)
;;; if the program is installed and the `lsp` option is on. The buffer then
;;; gets lsp-mode: K hover, gd definition, gr references, SPC c r rename,
;;; SPC c a code actions, SPC c f format. ]d and [d move between
;;; diagnostics, :diagnostics lists them all. In insert mode C-x C-o (and
;;; completion as you type) asks the server; C-n and C-p complete words
;;; from the buffer when there is no server.

(define-option! 'lsp #t '())
(define-option! 'lsp-auto-complete #t '())
;; Milliseconds of quiet before changes are sent, and before completing.
(define-option! 'lsp-change-delay 200 '())
(define-option! 'lsp-complete-delay 150 '())

(define *language-servers* (hash))  ; major mode -> (command markers language-id)
(define *lsp-servers* (hash))       ; "command<tab>root" -> state (a hash, see lsp-start!)
(define *lsp-diagnostics* (hash))   ; uri -> list of diagnostics
(define *lsp-change-timers* (hash)) ; buffer id -> timer of the pending didChange
(define *lsp-log* '())              ; newest first: stderr and logMessage lines
(define *lsp-line-message* #f)      ; the diagnostic shown on the status line
(define *lsp-progress-message* #f)  ; the progress shown on the status line

(define (define-language-server! mode command markers language-id)
  (set! *language-servers* (hash-insert *language-servers* mode (list command markers language-id))))

(define-language-server! 'rust-mode "rust-analyzer" '("Cargo.toml" ".git") "rust")
(define-language-server! 'typescript-mode "typescript-language-server --stdio"
  '("tsconfig.json" "package.json" ".git") "typescript")
(define-language-server! 'javascript-mode "typescript-language-server --stdio"
  '("jsconfig.json" "package.json" ".git") "javascript")
(define-language-server! 'nix-mode "nil" '("flake.nix" ".git") "nix")
(define-language-server! 'markdown-mode "marksman server" '(".marksman.toml" ".git") "markdown")
(define-language-server! 'python-mode "pyright-langserver --stdio"
  '("pyproject.toml" "setup.py" "setup.cfg" ".git") "python")

;;; JSON helpers. Objects are hashes with string keys; null is 'null.

;; (jget obj "a" "b") is obj.a.b, or #f when any part is missing or null.
(define (jget obj . path)
  (let loop ([v obj] [path path])
    (cond [(null? path) (if (equal? v 'null) #f v)]
          [(hash? v) (loop (hash-try-get v (car path)) (cdr path))]
          [else #f])))

(define (lsp-log! text)
  (set! *lsp-log* (cons text (if (> (length *lsp-log*) 499) (take *lsp-log* 499) *lsp-log*))))

;;; Server state
;;;
;;; Fields: command, root, job, input (bytes not yet a whole message),
;;; next-id, pending (request id -> callback), ready (initialized),
;;; queue (messages held until then), capabilities, encoding ("utf-32" or
;;; "utf-16", what positions count).

(define (lsp-state key) (hash-try-get *lsp-servers* key))

(define (lsp-get key field)
  (let ([s (lsp-state key)]) (and s (hash-try-get s field))))

(define (lsp-put! key field value)
  (let ([s (lsp-state key)])
    (when s (set! *lsp-servers* (hash-insert *lsp-servers* key (hash-insert s field value))))))

(define (shell-quote text)
  (string-append "'" (apply string-append (map (lambda (c) (if (equal? c #\') "'\\''" (string c)))
                                               (string->list text)))
                 "'"))

;; The directory part of a path.
(define (lsp-dirname path)
  (let loop ([i (- (string-length path) 1)])
    (cond [(<= i 0) "/"]
          [(equal? (string-ref path i) #\/) (substring path 0 i)]
          [else (loop (- i 1))])))

;; The nearest directory above `file` holding one of `markers`, else the
;; file's own directory.
(define (lsp-root file markers)
  (let ([start (lsp-dirname file)])
    (let loop ([dir start])
      (cond [(ormap (lambda (m) (file-exists? (string-append dir "/" m))) markers) dir]
            [(equal? dir "/") start]
            [else (loop (lsp-dirname dir))]))))

(define (ormap pred lst) (and (pair? lst) (or (pred (car lst)) (ormap pred (cdr lst)))))

(define (lsp-start! key command root)
  (set! *lsp-servers*
        (hash-insert *lsp-servers* key
                     (hash 'command command 'root root 'input "" 'next-id 1 'pending (hash)
                           'ready #f 'queue '() 'capabilities (hash) 'encoding "utf-16")))
  (let ([job (start-job! (string-append "cd " (shell-quote root) " && exec " command) #f
                         (lambda (text stream) (lsp-output! key text stream))
                         (lambda (code) (lsp-exited! key code)))])
    (if job
        (begin (lsp-put! key 'job job) (lsp-initialize! key) #t)
        (begin (set! *lsp-servers* (hash-remove *lsp-servers* key)) #f))))

(define (lsp-initialize! key)
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
          (lsp-put! key 'queue '()))))))

(define (lsp-client-capabilities)
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
              "publishDiagnostics" (hash))
        "workspace" (hash "applyEdit" #t "workspaceEdit" (hash "documentChanges" #t)
                          "configuration" #t "workspaceFolders" #t)
        "window" (hash "workDoneProgress" #t)))

(define (lsp-exited! key code)
  (let ([command (lsp-get key 'command)])
    (set! *lsp-servers* (hash-remove *lsp-servers* key))
    (message (string-append "language server " (or command key) " exited (" (to-string code) ")"))))

;;; Sending

(define (lsp-write! key msg)
  (let ([job (lsp-get key 'job)])
    (when job (job-send! job (lsp-frame (json-encode msg))))))

;; Sends `msg`, or holds it until the server is initialized.
(define (lsp-send! key msg)
  (if (lsp-get key 'ready)
      (lsp-write! key msg)
      (lsp-put! key 'queue (append (or (lsp-get key 'queue) '()) (list msg)))))

(define (lsp-add-request! key on-result)
  (let ([id (lsp-get key 'next-id)])
    (lsp-put! key 'next-id (+ id 1))
    (lsp-put! key 'pending (hash-insert (lsp-get key 'pending) id on-result))
    id))

;; Asks the server; `on-result` gets the result (#f for null) on success.
(define (lsp-request! key method params on-result)
  (let ([id (lsp-add-request! key on-result)])
    (lsp-send! key (hash "jsonrpc" "2.0" "id" id "method" method "params" params))
    id))

(define (lsp-request-now! key method params on-result)
  (let ([id (lsp-add-request! key on-result)])
    (lsp-write! key (hash "jsonrpc" "2.0" "id" id "method" method "params" params))))

(define (lsp-notify! key method params)
  (lsp-send! key (hash "jsonrpc" "2.0" "method" method "params" params)))

;;; Receiving

(define (lsp-output! key text stream)
  (if (not (equal? stream "stdout"))
      (lsp-log! text)
      (begin
        (lsp-put! key 'input (string-append (or (lsp-get key 'input) "") text))
        (let loop ()
          (let* ([input (lsp-get key 'input)] [taken (and input (lsp-take-message input))])
            (when taken
              (lsp-put! key 'input (cadr taken))
              (when (car taken)
                (with-handler (lambda (e) (message (string-append "lsp: " (error-message e))))
                              (lsp-dispatch! key (car taken))))
              (loop)))))))

(define (lsp-dispatch! key msg)
  (let ([id (hash-try-get msg "id")] [method (hash-try-get msg "method")])
    (cond
      [(and method id) (lsp-reply! key id (lsp-server-request key method (jget msg "params")))]
      [method (lsp-notification! key method (jget msg "params"))]
      [id (lsp-response! key id msg)]
      [else #f])))

(define (lsp-response! key id msg)
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
  (lsp-write! key (if (and (pair? result) (eq? (car result) 'error))
                      (hash "jsonrpc" "2.0" "id" id "error" (hash "code" -32601 "message" (cadr result)))
                      (hash "jsonrpc" "2.0" "id" id "result" result))))

;; The answer to a request from the server.
(define (lsp-server-request key method params)
  (cond
    [(equal? method "workspace/configuration")
     (map (lambda (item) 'null) (or (jget params "items") '()))]
    [(member method '("client/registerCapability" "client/unregisterCapability"
                      "window/workDoneProgress/create"))
     'null]
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
  (cond
    [(equal? method "textDocument/publishDiagnostics")
     (lsp-set-diagnostics! (jget params "uri") (or (jget params "diagnostics") '()))]
    [(equal? method "window/showMessage")
     (lsp-log! (or (jget params "message") ""))
     (when (<= (or (jget params "type") 4) 2) (message (or (jget params "message") "")))]
    [(equal? method "window/logMessage") (lsp-log! (or (jget params "message") ""))]
    [(equal? method "$/progress") (lsp-progress! (jget params "value"))]
    [else #f]))

;; $/progress: shown on the status line unless something else is there.
(define (lsp-progress! value)
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

;; The server the current buffer talks to, if it is running.
(define (lsp-key)
  (let ([key (buffer-local 'lsp-server)]) (and key (lsp-state key) key)))

(define (lsp-uri) (buffer-local 'lsp-uri))

(define (lsp-language-id id path)
  (cond [(and (equal? id "typescript") (ends-with? path ".tsx")) "typescriptreact"]
        [(and (equal? id "javascript") (ends-with? path ".jsx")) "javascriptreact"]
        [else id]))

;; Starts (or joins) the server for the current buffer's major mode.
(define (lsp-attach!)
  (let ([spec (hash-try-get *language-servers* (major-mode))] [path (buffer-path)])
    (when (and spec path (option 'lsp) (not (lsp-key)))
      (let* ([command (car spec)] [words (split-whitespace command)])
        (when (and (pair? words) (find-executable (car words)))
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
                                       "version" 0 "text" (buffer-substring 0 (buffer-length))))))))))))

(define (lsp-text-document) (hash "uri" (lsp-uri)))

;; Sends the current buffer's text now, if it changed since last sent.
(define (lsp-sync!)
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
                           "contentChanges" (list (hash "text" (buffer-substring 0 (buffer-length))))))))))

;; Notes a change to the current buffer; it is sent after a pause.
(define (lsp-changed!)
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

;;; Positions
;;;
;;; imp's offsets count chars, which is LSP's "utf-32". Servers that only
;;; do UTF-16 count chars past U+FFFF twice.

(define (astral? c) (> (char->integer c) #xFFFF))

;; LSP's character for column `col` of `line` (the current buffer).
(define (lsp-character line col encoding)
  (if (equal? encoding "utf-32")
      col
      (let ([text (buffer-substring (line-start line) (+ (line-start line) col))])
        (+ col (length (filter astral? (string->list text)))))))

(define (lsp-position offset encoding)
  (let ([line (offset->line offset)])
    (hash "line" line "character" (lsp-character line (offset->col offset) encoding))))

;; The offset of an LSP position in the current buffer, clamped to it.
(define (lsp-offset pos encoding)
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
  (list (lsp-offset (jget r "start") encoding) (lsp-offset (jget r "end") encoding)))

(define (lsp-encoding) (or (lsp-get (lsp-key) 'encoding) "utf-16"))

;; textDocument and position at the cursor, the params most requests take.
(define (lsp-here)
  (hash "textDocument" (lsp-text-document) "position" (lsp-position (cursor) (lsp-encoding))))

;; Runs (proc key) with the current buffer's server, its text sent first.
(define (with-lsp proc)
  (let ([key (lsp-key)])
    (if (not key)
        (message "no language server for this buffer")
        (begin (lsp-sync!) (proc key)))))

;;; Diagnostics

(set-face! "diagnostic.error" "fg=#e06c75 underline")
(set-face! "diagnostic.warning" "fg=#e5c07b underline")
(set-face! "diagnostic.info" "underline")
(set-face! "diagnostic.hint" "underline")
(set-face! "sign.error" "fg=#e06c75 bold")
(set-face! "sign.warning" "fg=#e5c07b bold")
(set-face! "sign.info" "fg=#61afef")
(set-face! "sign.hint" "fg=#7f848e")

(define (severity d) (or (jget d "severity") 1))

(define (severity-name d)
  (let ([s (severity d)]) (cond [(= s 1) "error"] [(= s 2) "warning"] [(= s 3) "info"] [else "hint"])))

(define (severity-letter d)
  (let ([s (severity d)]) (cond [(= s 1) "E"] [(= s 2) "W"] [(= s 3) "I"] [else "H"])))

;; The buffer visiting `path`, or #f.
(define (buffer-for-path path)
  (let loop ([ids (buffer-list)])
    (cond [(null? ids) #f]
          [(let ([p (cadr (buffer-info (car ids)))]) (and p (equal? (absolute-path p) path))) (car ids)]
          [else (loop (cdr ids))])))

(define (lsp-set-diagnostics! uri diagnostics)
  (set! *lsp-diagnostics* (hash-insert *lsp-diagnostics* uri diagnostics))
  (let* ([path (uri->path uri)] [id (and path (buffer-for-path path))])
    (when id
      (with-buffer id lsp-show-signs!)
      (when (= id (current-buffer)) (lsp-show-diagnostics!)))))

;; The current buffer's diagnostics, sorted by where they start, each as
;; (start end diagnostic).
(define (buffer-diagnostics)
  (let ([uri (lsp-uri)] [encoding (lsp-encoding)])
    (if (not uri)
        '()
        (sort (map (lambda (d) (append (lsp-range-offsets (jget d "range") encoding) (list d)))
                   (or (hash-try-get *lsp-diagnostics* uri) '()))
              (lambda (a b) (< (car a) (car b)))))))

(define (lsp-show-signs!)
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
                     (hash-keys->list signs)))))

(define (lsp-show-diagnostics!)
  (highlight-clear! "diagnostics")
  (for-each (lambda (d)
              (let* ([s (car d)] [e (min (buffer-length) (max (cadr d) (+ s 1)))])
                (when (< s e)
                  (highlight-add! "diagnostics" s e (string-append "diagnostic." (severity-name (caddr d)))))))
            (buffer-diagnostics)))

(add-hook! 'buffer-enter lsp-show-diagnostics!)

(define (diagnostic-text d)
  (string-append (severity-letter d) ": " (or (jget d "message") "")
                 (let ([source (jget d "source")]) (if source (string-append " (" source ")") ""))))

;; The diagnostic to show for the cursor: one under it, else the most
;; severe on its line.
(define (diagnostic-at-cursor)
  (let* ([p (cursor)] [line (current-line)]
         [on-line (filter (lambda (d) (= (offset->line (car d)) line)) (buffer-diagnostics))]
         [under (filter (lambda (d) (and (<= (car d) p) (< p (max (cadr d) (+ (car d) 1))))) on-line)]
         [pick (if (pair? under) under on-line)])
    (and (pair? pick)
         (caddr (foldl (lambda (d best) (if (< (severity (caddr d)) (severity (caddr best))) d best))
                       (car pick) (cdr pick))))))

;; In normal mode the status line shows the diagnostic at the cursor, when
;; nothing else is there.
(add-hook! 'post-command
           (lambda ()
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
                       [else #f])))))

;; ]d and [d: the next or previous diagnostic, wrapping around.
(define (next-diagnostic! count forward?)
  (let* ([starts (map car (buffer-diagnostics))]
         [starts (if forward? starts (reverse starts))])
    (if (null? starts)
        (message "no diagnostics")
        (let loop ([p (cursor)] [n count])
          (if (= n 0)
              (set-cursor! p)
              (let ([next (filter (lambda (s) (if forward? (> s p) (< s p))) starts)])
                (loop (if (pair? next) (car next) (car starts)) (- n 1))))))))

(define-command! 'next-diagnostic (lambda (count) (next-diagnostic! count #t)))
(define-command! 'previous-diagnostic (lambda (count) (next-diagnostic! count #f)))
(define-key! 'normal "]d" 'next-diagnostic)
(define-key! 'normal "[d" 'previous-diagnostic)

(define (relative-path path)
  (let ([dir (string-append (current-dir) "/")])
    (if (starts-with? path dir) (substring path (string-length dir) (string-length path)) path)))

;; The text of line `line` of `path`, from its buffer if it is open.
(define (file-line path line)
  (let ([id (buffer-for-path path)])
    (if id
        (with-buffer id (lambda () (if (<= line (last-line)) (line-text line) "")))
        (let ([lines (if (file-exists? path) (split-lines (read-file path)) '())])
          (if (< line (length lines)) (list-ref lines line) "")))))

;; :diagnostics picks one from every file's to jump to.
(define-command! 'list-diagnostics
  (lambda (count)
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

;; Opens `uri` (if it isn't the current buffer) and puts the cursor at the
;; start of range `r`, as a jump. Positions count in `encoding`, or the
;; buffer's server's.
(define (lsp-jump! uri r encoding)
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

;; Locations from a definition or references reply, as (uri range).
(define (lsp-locations result)
  (let ([items (cond [(not result) '()] [(hash? result) (list result)] [else result])])
    (filter (lambda (l) (car l))
            (map (lambda (l)
                   (if (jget l "targetUri")
                       (list (jget l "targetUri") (or (jget l "targetSelectionRange") (jget l "targetRange")))
                       (list (jget l "uri") (jget l "range"))))
                 items))))

;; "file:line: text" for a location.
(define (location-label l)
  (let* ([path (or (uri->path (car l)) (car l))] [line (or (jget (cadr l) "start" "line") 0)])
    (string-append (relative-path path) ":" (number->string (+ line 1)) ": " (trim (file-line path line)))))

;; Goes to the only location, or lets you pick one.
(define (choose-location! locations what encoding)
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
    (with-lsp (lambda (key)
                (lsp-request! key "textDocument/definition" (lsp-here)
                              (lambda (result)
                                (choose-location! (lsp-locations result) "definition" (lsp-get key 'encoding))))))))

(define-command! 'lsp-references
  (lambda (count)
    (with-lsp (lambda (key)
                (lsp-request! key "textDocument/references"
                              (hash-insert (lsp-here) "context" (hash "includeDeclaration" #t))
                              (lambda (result)
                                (choose-location! (lsp-locations result) "reference" (lsp-get key 'encoding))))))))

;;; Hover

;; Markdown from a hover reply as lines, without code fences.
(define (hover-lines contents)
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
    (with-lsp (lambda (key)
                (lsp-request! key "textDocument/hover" (lsp-here)
                              (lambda (result)
                                (let ([lines (hover-lines (jget result "contents"))])
                                  (if (null? lines)
                                      (message "no information here")
                                      (show-popup! lines)))))))))

;;; Changing text from the server

;; Applies TextEdits to the current buffer as one undo step: last first,
;; so earlier positions stay valid; edits at the same place keep their
;; order.
(define (lsp-apply-text-edits! edits encoding)
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

;; Applies TextEdits to the file at `uri`, opening it if needed.
(define (lsp-edit-uri! uri edits encoding)
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

;; Applies a WorkspaceEdit; returns how many files it changed.
(define (lsp-apply-workspace-edit! edit encoding)
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

;; Runs a chosen code action: its edit, then its command; one with
;; neither is resolved first.
(define (run-code-action! key action)
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
  (lsp-request! key "workspace/executeCommand"
                (hash "command" (jget command "command") "arguments" (or (jget command "arguments") '()))
                (lambda (result) #f)))

(define-command! 'lsp-code-action
  (lambda (count)
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

;; Asks the server to exit; it is killed if it hasn't after a second.
(define (lsp-stop! key)
  (let ([job (lsp-get key 'job)])
    (lsp-request-now! key "shutdown" 'null
                      (lambda (result) (lsp-write! key (hash "jsonrpc" "2.0" "method" "exit"))))
    (run-after! 1000 (lambda () (when job (job-kill! job))))))

(define (buffers-of key)
  (filter (lambda (id) (with-buffer id (lambda () (equal? (buffer-local 'lsp-server) key)))) (buffer-list)))

;; :lsp-restart stops the current buffer's server and starts it again for
;; every buffer that used it.
(define-command! 'lsp-restart
  (lambda (count)
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

;;; Completion in insert mode
;;;
;;; A menu of candidates in the popup. It opens on C-x C-o (the server's
;;; completions), C-n or C-p (the server's, or words from the buffer
;;; without one), and by itself after typing part of a word when a server
;;; is attached (lsp-auto-complete). While it is open: C-n C-p <tab>
;;; <s-tab> <down> <up> move, C-y or <ret> accepts (<ret> only once
;;; something is selected in a menu that opened by itself), C-e closes it;
;;; other keys type as usual and narrow the menu.

;; Each candidate: (label detail text start item), `text` being what to
;; insert from offset `start` to the cursor.
(define *menu-candidates* '())
(define *menu-matches* '())
(define *menu-index* -1)
(define *menu-start* 0)       ; where the typed part of the word starts
(define *menu-open* #f)
(define *menu-key* #f)        ; the server the candidates came from
(define *menu-incomplete* #f) ; the server has more: ask again as you type
(define *complete-timer* #f)
(define *complete-request* 0) ; replies to older requests are dropped

(define (word-start-before p)
  (let ([lo (line-start (offset->line p))])
    (let loop ([q p]) (if (and (> q lo) (char-word? (buffer-char-at (- q 1)))) (loop (- q 1)) q))))

;; ${1:text} -> text, $1 ${1} $0 -> nothing, ${1|a,b|} -> a, \$ -> $.
(define (strip-snippet text)
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

(define (drop-while pred cs) (if (and (pair? cs) (pred (car cs))) (drop-while pred (cdr cs)) cs))
(define (take-while pred cs) (if (and (pair? cs) (pred (car cs))) (cons (car cs) (take-while pred (cdr cs))) '()))

;; Candidates from a completion reply.
(define (completion-candidates result start encoding)
  (let* ([items (cond [(not result) '()] [(hash? result) (or (jget result "items") '())] [else result])]
         ;; The server's order (sortText), which matching keeps for ties.
         [sort-key (lambda (item) (or (jget item "sortText") (jget item "label") ""))]
         [items (sort items (lambda (a b) (string<? (sort-key a) (sort-key b))))])
    (map (lambda (item)
           (let* ([edit (jget item "textEdit")]
                  [edit-range (and edit (or (jget edit "range") (jget edit "insert")))]
                  [raw (cond [edit (or (jget edit "newText") "")]
                             [(jget item "insertText") => (lambda (t) t)]
                             [else (or (jget item "label") "")])]
                  [text (if (equal? (jget item "insertTextFormat") 2) (strip-snippet raw) raw)])
             (list (or (jget item "label") text)
                   (or (jget item "detail") "")
                   text
                   (if edit-range (lsp-offset (jget edit-range "start") encoding) start)
                   item)))
         items)))

;; Words in the lines around the cursor that start with the word before
;; it, nearest first.
(define (buffer-word-candidates start)
  (let* ([prefix (buffer-substring start (cursor))]
         [line (current-line)]
         [lo (line-start (max 0 (- line 500)))]
         [hi (line-end (min (last-line) (+ line 500)))]
         [seen (hash prefix #t)])
    (let loop ([p lo] [words '()] [seen seen])
      (if (>= p hi)
          (map (lambda (w) (list w "" w start #f)) (reverse words))
          (if (char-word? (buffer-char-at p))
              (let* ([e (let run ([q p]) (if (and (< q hi) (char-word? (buffer-char-at q))) (run (+ q 1)) q))]
                     [w (buffer-substring p e)])
                (if (and (starts-with? w prefix) (not (hash-contains? seen w)) (not (= p start)))
                    (loop e (cons w words) (hash-insert seen w #t))
                    (loop e words seen)))
              (loop (+ p 1) words seen))))))

(define (menu-rows) (max 1 (min 10 (- (window-height) 2))))

(define (menu-line c)
  (let ([detail (cadr c)])
    (string-append " " (pad-right (car c) 24) (if (equal? detail "") "" (string-append " " detail)) " ")))

(define (draw-menu!)
  (let* ([n (length *menu-matches*)] [rows (menu-rows)]
         [i (max *menu-index* 0)]
         [top (max 0 (min (- i (- rows 1)) (- n rows)))]
         [top (max 0 (min top i))]
         [shown (take (list-tail *menu-matches* top) (min rows (- n top)))])
    (set-popup! (map menu-line shown))
    (set-popup-selected! (if (< *menu-index* 0) -1 (- *menu-index* top)))))

;; Narrows the menu to what has been typed since it opened; closes it
;; when nothing matches or the cursor left the word.
(define (refilter-menu!)
  (if (or (< (cursor) *menu-start*)
          (not (= (offset->line (cursor)) (offset->line *menu-start*)))
          (and (> (cursor) *menu-start*) (not (char-word? (buffer-char-at (- (cursor) 1))))))
      (close-menu!)
      (let* ([typed (buffer-substring *menu-start* (cursor))]
             [labels (map car *menu-candidates*)]
             [by-label (foldl (lambda (c h) (if (hash-contains? h (car c)) h (hash-insert h (car c) c)))
                              (hash) *menu-candidates*)]
             [hits (fuzzy-filter typed labels 200)])
        (set! *menu-matches* (map (lambda (l) (hash-ref by-label l)) hits))
        (cond [(null? *menu-matches*) (close-menu!)]
              ;; Only the word already typed: nothing left to offer.
              [(and (null? (cdr *menu-matches*)) (equal? (caddr (car *menu-matches*)) typed)
                    (= (cadddr (car *menu-matches*)) *menu-start*))
               (close-menu!)]
              [else
               (set! *menu-index* (if (< *menu-index* 0) -1 (min *menu-index* (- (length *menu-matches*) 1))))
               (draw-menu!)]))))

(define (open-menu! candidates start select?)
  (set! *menu-candidates* candidates)
  (set! *menu-start* start)
  (set! *menu-index* (if select? 0 -1))
  (set! *menu-open* #t)
  (set! *key-interceptor* menu-key!)
  (refilter-menu!)
  (when (and select? (not *menu-open*)) (message "no completions")))

(define (close-menu!)
  (when *menu-open*
    (set! *menu-open* #f)
    (set! *menu-matches* '())
    (set-popup! '())
    (set-popup-selected! -1)
    (when (eq? *key-interceptor* menu-key!) (set! *key-interceptor* #f))))

(define (move-menu! step)
  (let ([n (length *menu-matches*)])
    (when (> n 0)
      (set! *menu-index* (if (< *menu-index* 0)
                             (if (> step 0) 0 (- n 1))
                             (modulo (+ *menu-index* step) n)))
      (draw-menu!))))

;; Replaces the typed word with the candidate, as if typed (so . repeats
;; it), then applies the server's extra edits (imports).
(define (accept-candidate! c)
  (let* ([start (min (cadddr c) (cursor))] [old (buffer-substring start (cursor))] [text (caddr c)]
         [item (car (cddddr c))])
    (close-menu!)
    (buffer-delete! start (cursor))
    (set-cursor! start)
    (insert-text! text)
    (set! *insert-keys* (append (reverse (map string (string->list text)))
                                (map (lambda (ch) "<bs>") (string->list old))
                                *insert-keys*))
    (let ([extra (and item (jget item "additionalTextEdits"))] [key *menu-key*])
      (when (and extra (pair? extra) key)
        (lsp-apply-text-edits! extra (lsp-get key 'encoding))))
    (lsp-changed!)))

(define (menu-key! key)
  (cond
    [(not (memq *mode* '(insert replace))) (close-menu!) (handle-key! key)]
    [(member key '("C-n" "<down>" "<tab>")) (move-menu! 1)]
    [(member key '("C-p" "<up>" "<s-tab>")) (move-menu! -1)]
    [(equal? key "C-y") (accept-candidate! (list-ref *menu-matches* (max 0 *menu-index*)))]
    [(and (member key '("<ret>" "C-m")) (>= *menu-index* 0))
     (accept-candidate! (list-ref *menu-matches* *menu-index*))]
    [(equal? key "C-e") (close-menu!)]
    [(member key '("<esc>" "C-c" "<ret>" "C-m")) (close-menu!) (handle-key! key)]
    [else
     (handle-key! key)
     (when *menu-open* (refilter-menu!))
     (when (and *menu-open* *menu-incomplete*) (schedule-completion! #t))]))

;; Asks the server for completions at the cursor; `manual?` selects the
;; first one and says so when there are none.
(define (lsp-complete! manual?)
  (let ([key (lsp-key)] [start (word-start-before (cursor))] [id (current-buffer)])
    (when key
      (lsp-sync!)
      (set! *complete-request* (+ *complete-request* 1))
      (let ([request *complete-request*] [encoding (lsp-encoding)])
        (lsp-request! key "textDocument/completion"
                      (hash-insert (lsp-here) "context" (hash "triggerKind" 1))
                      (lambda (result)
                        (when (and (= request *complete-request*) (= id (current-buffer))
                                   (memq *mode* '(insert replace)) (>= (cursor) start))
                          (set! *menu-key* key)
                          (set! *menu-incomplete* (and (hash? result) (jget result "isIncomplete")))
                          (open-menu! (completion-candidates result start encoding) start
                                      (or manual? (and *menu-open* (>= *menu-index* 0)))))))))))

(define (complete-words! step)
  (let ([start (word-start-before (cursor))])
    (set! *menu-key* #f)
    (set! *menu-incomplete* #f)
    (open-menu! (buffer-word-candidates start) start #t)
    (when (and *menu-open* (< step 0)) (set! *menu-index* (- (length *menu-matches*) 1)) (draw-menu!))))

;; C-n and C-p: the server's completions, or words from the buffer.
(define (complete-command step)
  (lambda ()
    (if (lsp-key) (lsp-complete! #t) (complete-words! step))))

(define-key! 'insert "C-n" (complete-command 1))
(define-key! 'insert "C-p" (complete-command -1))

;; C-x starts Vim's completion keys: C-x C-o asks the server, C-x C-n
;; and C-x C-p complete words. The key after C-x isn't typed.
(define-key! 'insert "C-x"
  (lambda ()
    (set! *key-interceptor*
          (lambda (key)
            (set! *key-interceptor* #f)
            (cond [(equal? key "C-o") (if (lsp-key) (lsp-complete! #t) (message "no language server for this buffer"))]
                  [(equal? key "C-n") (complete-words! 1)]
                  [(equal? key "C-p") (complete-words! -1)]
                  [else (handle-key! key)])))))

;; Completing as you type: after a pause following a word character or
;; one of the server's trigger characters.
(define (trigger-char? key c)
  (member (string c) (or (jget (lsp-get key 'capabilities) "completionProvider" "triggerCharacters") '())))

;; `refresh?` asks again for an open menu whose list was incomplete.
(define (schedule-completion! refresh?)
  (when *complete-timer* (cancel-timer! *complete-timer*))
  (let ([id (current-buffer)] [at (cursor)])
    (set! *complete-timer*
          (run-after! (option 'lsp-complete-delay)
                      (lambda ()
                        (set! *complete-timer* #f)
                        (when (and (= id (current-buffer)) (= at (cursor)) (eq? *mode* 'insert)
                                   (if refresh? *menu-open* (not (or *menu-open* *key-interceptor*))))
                          (lsp-complete! #f)))))))

(add-hook! 'after-change
           (lambda ()
             (when (and (eq? *mode* 'insert) (option 'lsp-auto-complete) (not *menu-open*) (> (cursor) 0))
               (let ([key (lsp-key)] [c (buffer-char-at (- (cursor) 1))])
                 (when (and key (or (char-word? c) (trigger-char? key c)))
                   (schedule-completion! #f))))))

(add-hook! 'insert-leave (lambda () (close-menu!)))
