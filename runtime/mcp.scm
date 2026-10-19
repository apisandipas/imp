;;; mcp.scm -- the Model Context Protocol: AI agents use the editor.
;;;
;;; Off until (mcp-enable!) in init.scm (or M-x mcp-enable). The editor
;;; then listens on a Unix socket only you can reach
;;; ($XDG_RUNTIME_DIR/imp/mcp.sock), speaking MCP's JSON-RPC, one message a
;;; line. An agent runs `imp --mcp` as a stdio MCP server; it relays to the
;;; socket. For example, for Claude Code:
;;;
;;;   claude mcp add imp -- imp --mcp
;;;
;;; An agent gets the access you have: it can read and edit buffers, open
;;; and save files, move the cursor, search, run commands and ex commands,
;;; read diagnostics and evaluate Scheme. Each change it makes is noted on
;;; the status line and in :mcp-log. Add tools with define-mcp-tool!.

(define *mcp-listener* #f)
(define *mcp-tools* '())         ; (name description schema handler), in order
(define *mcp-log* '())           ; newest first
(define *mcp-versions* '("2025-06-18" "2025-03-26" "2024-11-05"))

;; A tool: `schema` is the JSON Schema of its arguments (a hash), and
;; `handler` gets the arguments (a hash) and returns text, or (error text).
(define (define-mcp-tool! name description schema handler)
  (set! *mcp-tools*
        (append (filter (lambda (t) (not (equal? (car t) name))) *mcp-tools*)
                (list (list name description schema handler)))))

(define (mcp-log! text)
  (set! *mcp-log* (cons text (if (> (length *mcp-log*) 199) (take *mcp-log* 199) *mcp-log*))))

;; Tells the user what an agent did.
(define (mcp-note! text)
  (mcp-log! text)
  (message (string-append "agent: " text)))

;;; The connection

(define (mcp-enable! . path)
  (if *mcp-listener*
      (message "MCP is already on")
      (let ([path (if (pair? path) (car path) (socket-path "mcp"))])
        (set! *mcp-listener*
              (listen-socket! path
                              (lambda (conn) (mcp-note! "connected"))
                              mcp-line!
                              (lambda (conn) (mcp-log! "disconnected"))))
        (when *mcp-listener* (mcp-log! (string-append "listening on " path))))))

(define (mcp-disable!)
  (when *mcp-listener*
    (socket-stop! *mcp-listener*)
    (set! *mcp-listener* #f)
    (message "MCP is off")))

;; Let AI agents use the editor over the Model Context Protocol.
(define-command! 'mcp-enable (lambda (count) (mcp-enable!) (when *mcp-listener* (message "MCP is on"))))
;; Stop listening for MCP agents.
(define-command! 'mcp-disable (lambda (count) (mcp-disable!)))
(define-ex! '("mcp-log")
  (lambda (ex) (show-popup! (if (null? *mcp-log*) (list "nothing yet") (reverse *mcp-log*)))))

(define (mcp-send! conn msg)
  (socket-send! conn (string-append (json-encode msg) "\n")))

(define (mcp-line! conn line)
  (unless (equal? (trim line) "")
    (let ([msg (with-handler (lambda (e) #f) (json-decode line))])
      (cond
        [(not msg)
         (mcp-send! conn (hash "jsonrpc" "2.0" "id" 'null
                               "error" (hash "code" -32700 "message" "parse error")))]
        ;; A batch.
        [(list? msg)
         (let ([replies (filter (lambda (r) r) (map mcp-handle msg))])
           (unless (null? replies) (mcp-send! conn replies)))]
        [else
         (let ([reply (mcp-handle msg)])
           (when reply (mcp-send! conn reply)))]))))

;; The reply to one message, or #f for a notification.
(define (mcp-handle msg)
  (let ([id (and (hash? msg) (hash-try-get msg "id"))] [method (jget msg "method")] [params (or (jget msg "params") (hash))])
    (if (not id)
        #f
        (let ([outcome (with-handler (lambda (e) (list 'failed (error-message e)))
                                     (list 'ok (mcp-method method params)))])
          (cond
            [(eq? (car outcome) 'failed)
             (hash "jsonrpc" "2.0" "id" id "error" (hash "code" -32603 "message" (cadr outcome)))]
            [(and (pair? (cadr outcome)) (eq? (car (cadr outcome)) 'rpc-error))
             (hash "jsonrpc" "2.0" "id" id
                   "error" (hash "code" (cadr (cadr outcome)) "message" (caddr (cadr outcome))))]
            [else (hash "jsonrpc" "2.0" "id" id "result" (cadr outcome))])))))

(define (mcp-method method params)
  (cond
    [(equal? method "initialize")
     (let ([asked (jget params "protocolVersion")])
       (hash "protocolVersion" (if (member asked *mcp-versions*) asked (car *mcp-versions*))
             "capabilities" (hash "tools" (hash "listChanged" #f))
             "serverInfo" (hash "name" "imp" "version" "0.1.0")
             "instructions" (string-append
                             "This is imp, a Vim-like editor the user is working in. Buffers are open files; "
                             "lines and columns in these tools count from 1. Edits you make are visible to "
                             "the user at once and can be undone with u.")))]
    [(equal? method "ping") (hash)]
    [(equal? method "tools/list")
     (hash "tools" (map (lambda (t) (hash "name" (car t) "description" (cadr t) "inputSchema" (caddr t)))
                        *mcp-tools*))]
    [(equal? method "tools/call") (mcp-call-tool (jget params "name") (or (jget params "arguments") (hash)))]
    [else (list 'rpc-error -32601 (string-append "unknown method " (or method "")))]))

(define (mcp-call-tool name args)
  (let ([tool (assoc name *mcp-tools*)])
    (if (not tool)
        (list 'rpc-error -32602 (string-append "unknown tool " (or name "")))
        (let ([result (with-handler (lambda (e) (list 'error (error-message e))) ((cadddr tool) args))])
          (if (and (pair? result) (eq? (car result) 'error))
              (hash "content" (list (hash "type" "text" "text" (cadr result))) "isError" #t)
              (hash "content" (list (hash "type" "text" "text" (if (string? result) result (to-string result))))
                    "isError" #f))))))

;;; Helpers for tools

;; A JSON Schema object with `props`: (name type description) lists;
;; `required` names those that must be given.
(define (schema props required)
  (hash "type" "object"
        "properties" (foldl (lambda (p h) (hash-insert h (car p) (hash "type" (cadr p) "description" (caddr p))))
                            (hash) props)
        "required" required))

(define buffer-prop '("buffer" "string" "Buffer id, name or file path; the current buffer if omitted"))

;; The buffer an argument names: an id, a name, or a path; else the
;; current one.
(define (mcp-buffer args)
  (let ([b (jget args "buffer")])
    (cond
      [(or (not b) (equal? b "")) (current-buffer)]
      [(and (number? b) (memv b (buffer-list))) b]
      [(and (string? b) (string->number b) (memv (string->number b) (buffer-list))) (string->number b)]
      [(string? b)
       (or (buffer-for-path (absolute-path (expand-path b)))
           (let ([hits (filter (lambda (id) (equal? (car (buffer-info id)) b)) (buffer-list))])
             (and (pair? hits) (car hits)))
           (error (string-append "no buffer " b " (open_file opens one)")))]
      [else (error "buffer must be an id, name or path")])))

(define (arg-int args name default)
  (let ([v (jget args name)])
    (cond [(number? v) v]
          [(and (string? v) (string->number v)) (string->number v)]
          [else default])))

(define (number-pad n width)
  (let ([s (number->string n)])
    (if (< (string-length s) width) (string-append (make-string (- width (string-length s)) #\space) s) s)))

(define (buffer-label id)
  (let ([info (buffer-info id)])
    (or (cadr info) (car info))))

;; Lines `first`..`last` (0-based) numbered from 1, as cat -n does.
(define (numbered-lines first last)
  (string-join (map (lambda (l) (string-append (number-pad (+ l 1) 6) "\t" (line-text l))) (range first (+ last 1)))
               "\n"))

;; Changes text in buffer `id` as one undo step, telling the language
;; server.
(define (mcp-replace! id start end text)
  (with-buffer id
    (lambda ()
      (begin-change!)
      (with-undo-group (lambda () (replace-range! start end text)))
      (when (eq? *mode* 'normal) (normal-clamp!))
      (lsp-changed!))))

;;; The tools

(define-mcp-tool! "list_buffers"
  "List the open buffers: id, name, file path, whether modified, and which is current."
  (schema '() '())
  (lambda (args)
    (string-join
     (map (lambda (id)
            (let ([info (buffer-info id)])
              (string-append (number->string id) "\t" (car info) "\t" (or (cadr info) "(no file)")
                             (if (caddr info) "\tmodified" "")
                             (if (= id (current-buffer)) "\tcurrent" ""))))
          (buffer-list))
     "\n")))

(define-mcp-tool! "read_buffer"
  "Read a buffer's text with line numbers (from 1), as it is in the editor, including unsaved changes. At most 2000 lines at a time; use start_line and end_line for more."
  (schema (list buffer-prop
                '("start_line" "integer" "First line to read (default 1)")
                '("end_line" "integer" "Last line to read (default start_line + 1999)"))
          '())
  (lambda (args)
    (let ([id (mcp-buffer args)])
      (with-buffer id
        (lambda ()
          (let* ([count (buffer-line-count)]
                 [first (clamp (- (arg-int args "start_line" 1) 1) 0 (max 0 (- count 1)))]
                 [last (clamp (- (arg-int args "end_line" (+ first 2000)) 1) first (- count 1))]
                 [last (min last (+ first 1999))])
            (string-append (buffer-label id) " (" (number->string count) " lines"
                           (if (buffer-modified?) ", modified" "") ")\n"
                           (numbered-lines first last))))))))

(define-mcp-tool! "edit_buffer"
  "Change a buffer's text (not saved until save_buffer). Either give old_text (which must occur exactly once, or set all) and new_text, or give start_line and end_line (from 1, inclusive) and text to replace those whole lines with; end_line = start_line - 1 inserts before start_line. One edit is one undo step for the user."
  (schema (list buffer-prop
                '("old_text" "string" "Exact text to replace")
                '("new_text" "string" "What replaces old_text")
                '("all" "boolean" "Replace every occurrence of old_text")
                '("start_line" "integer" "First line to replace")
                '("end_line" "integer" "Last line to replace")
                '("text" "string" "The new lines"))
          '())
  (lambda (args)
    (let ([id (mcp-buffer args)] [old (jget args "old_text")])
      (cond
        [(string? old)
         (let* ([new (or (jget args "new_text") "")]
                [hits (with-buffer id (lambda () (buffer-find-all old 10001)))])
           (cond
             [(null? hits) (list 'error "old_text not found")]
             [(and (pair? (cdr hits)) (not (jget args "all")))
              (list 'error (string-append "old_text occurs " (number->string (length hits))
                                          " times; give more context or set all"))]
             [else
              (with-buffer id
                (lambda ()
                  (begin-change!)
                  (with-undo-group
                   (lambda () (for-each (lambda (p) (replace-range! p (+ p (string-length old)) new)) (reverse hits))))
                  (when (eq? *mode* 'normal) (normal-clamp!))
                  (lsp-changed!)))
              (mcp-note! (string-append "edited " (buffer-label id)))
              (string-append "replaced " (number->string (length hits)) " occurrence"
                             (if (= (length hits) 1) "" "s") " in " (buffer-label id))]))]
        [(jget args "start_line")
         (with-buffer id
           (lambda ()
             (let* ([count (buffer-line-count)]
                    [first (- (arg-int args "start_line" 1) 1)]
                    [last (- (arg-int args "end_line" (+ first 1)) 1)]
                    [text (or (jget args "text") "")])
               (cond
                 [(or (< first 0) (> first count)) (list 'error "start_line is outside the buffer")]
                 [else
                  (let* ([start (if (< first count) (line-start first) (buffer-length))]
                         [end (cond [(< last first) start]
                                    [(>= last (- count 1)) (buffer-length)]
                                    [else (line-start (+ last 1))])]
                         ;; Whole lines: keep the break before the next.
                         ;; Adding lines after a last line with no line break.
                         [text (if (and (= start (buffer-length)) (> start 0) (not (equal? text ""))
                                        (not (equal? (buffer-char-at (- start 1)) #\newline)))
                                   (string-append "\n" text)
                                   text)]
                         [text (if (and (not (equal? text "")) (not (ends-with? text "\n"))
                                        (or (< end (buffer-length)) (and (> (buffer-length) 0) (equal? (buffer-char-at (- (buffer-length) 1)) #\newline))))
                                   (string-append text "\n")
                                   text)])
                    (mcp-replace! id start end text)
                    (mcp-note! (string-append "edited " (buffer-label id)))
                    (string-append "replaced lines " (number->string (+ first 1)) "-" (number->string (+ (max last (- first 1)) 1))
                                   " of " (buffer-label id)))]))))]
        [else (list 'error "give old_text and new_text, or start_line, end_line and text")]))))

(define-mcp-tool! "open_file"
  "Open a file in the editor (it becomes the current buffer) and return its buffer id. The file need not exist yet."
  (schema (list '("path" "string" "The file's path")) '("path"))
  (lambda (args)
    (let ([id (open-file! (expand-path (or (jget args "path") "")))])
      (if id
          (begin (mcp-note! (string-append "opened " (buffer-label id)))
                 (string-append "buffer " (number->string id) ": " (buffer-label id)))
          (list 'error (status-text))))))

(define-mcp-tool! "save_buffer"
  "Save a buffer to its file."
  (schema (list buffer-prop) '())
  (lambda (args)
    (let ([id (mcp-buffer args)])
      (with-buffer id (lambda () (run-ex! "w")))
      (if (buffer-modified-by-id? id)
          (list 'error (status-text))
          (begin (mcp-note! (string-append "saved " (buffer-label id))) (status-text))))))

(define-mcp-tool! "get_cursor"
  "Where the user is: the current buffer, the cursor's line and column (from 1), the editor's mode, and the selected text in visual mode."
  (schema '() '())
  (lambda (args)
    (string-append "buffer " (number->string (current-buffer)) ": " (buffer-label (current-buffer))
                   "\nline " (number->string (+ 1 (current-line))) ", column " (number->string (+ 1 (current-col)))
                   "\nmode " (symbol->string *mode*)
                   (if (eq? *mode* 'visual)
                       (let ([r (visual-range)]) (string-append "\nselection:\n" (buffer-substring (car r) (cadr r))))
                       ""))))

(define-mcp-tool! "set_cursor"
  "Move the cursor to a line and column (from 1), switching to the buffer first if one is given."
  (schema (list buffer-prop '("line" "integer" "Line") '("column" "integer" "Column (default 1)")) '("line"))
  (lambda (args)
    (let ([id (mcp-buffer args)])
      (unless (= id (current-buffer)) (go-to-buffer! id))
      (let* ([line (clamp (- (arg-int args "line" 1) 1) 0 (last-line))]
             [col (max 0 (- (arg-int args "column" 1) 1))])
        (record-jump!)
        (set-cursor! (min (+ (line-start line) col) (line-end line)))
        (when (eq? *mode* 'normal) (normal-clamp!))
        (string-append "cursor at line " (number->string (+ line 1)) ", column " (number->string (+ 1 (current-col))))))))

(define-mcp-tool! "search"
  "Find lines matching a pattern in a buffer (Vim regex syntax, as with /). Returns up to 200 matching lines with their numbers."
  (schema (list buffer-prop '("pattern" "string" "What to search for")) '("pattern"))
  (lambda (args)
    (let ([id (mcp-buffer args)] [pattern (or (jget args "pattern") "")])
      (with-buffer id
        (lambda ()
          (let ([problem (pattern-error pattern)])
            (if problem
                (list 'error problem)
                (let* ([lines (let loop ([ps (search-all pattern 2000)] [seen '()])
                                (cond [(null? ps) (reverse seen)]
                                      [(and (pair? seen) (= (car seen) (offset->line (car ps)))) (loop (cdr ps) seen)]
                                      [else (loop (cdr ps) (cons (offset->line (car ps)) seen))]))]
                       [lines (take lines (min 200 (length lines)))])
                  (if (null? lines)
                      "no matches"
                      (string-join (map (lambda (l) (string-append (number->string (+ l 1)) ": " (line-text l))) lines)
                                   "\n"))))))))))

;; What a command left for the user to see.
(define (command-output)
  (let ([popup (popup-lines)] [status (status-text)])
    (cond [(pair? popup) (string-join popup "\n")]
          [(equal? status "") "done"]
          [else status])))

(define-mcp-tool! "run_command"
  "Run one of the editor's named commands (what M-x runs), e.g. save-buffer, lsp-format, toggle-breakpoint. Without a name, lists them."
  (schema (list '("name" "string" "The command") '("count" "integer" "Its count (default 1)")) '())
  (lambda (args)
    (let ([name (jget args "name")])
      (cond
        [(or (not name) (equal? name ""))
         (string-join (sort (map symbol->string (command-names)) string<?) "\n")]
        [(not (command-proc (string->symbol name))) (list 'error (string-append "no command " name))]
        [else
         (set-status! "")
         (run-command (string->symbol name) (arg-int args "count" 1))
         (mcp-note! (string-append "ran " name))
         (command-output)]))))

(define-mcp-tool! "ex_command"
  "Run an ex command, as typed after : in Vim, e.g. \"%s/foo/bar/g\", \"w\", \"ls\". Returns what it showed."
  (schema (list '("command" "string" "The command, with or without the leading :")) '("command"))
  (lambda (args)
    (let* ([text (or (jget args "command") "")]
           [text (if (starts-with? text ":") (substring text 1 (string-length text)) text)])
      (set-status! "")
      (close-popup!)
      (run-ex! text)
      (mcp-note! (string-append ":" text))
      (command-output))))

(define-mcp-tool! "diagnostics"
  "The language servers' errors and warnings, for one buffer or (without buffer) every file."
  (schema (list buffer-prop) '())
  (lambda (args)
    (let* ([uris (if (jget args "buffer")
                     (let ([id (mcp-buffer args)]) (with-buffer id (lambda () (if (lsp-uri) (list (lsp-uri)) '()))))
                     (hash-keys->list *lsp-diagnostics*))]
           [lines (apply append
                         (map (lambda (uri)
                                (map (lambda (d)
                                       (string-append (or (uri->path uri) uri) ":"
                                                      (number->string (+ 1 (or (jget d "range" "start" "line") 0))) ":"
                                                      (number->string (+ 1 (or (jget d "range" "start" "character") 0))) ": "
                                                      (severity-name d) ": " (or (jget d "message") "")))
                                     (or (hash-try-get *lsp-diagnostics* uri) '())))
                              uris))])
      (if (null? lines) "no diagnostics" (string-join lines "\n")))))

(define-mcp-tool! "eval_scheme"
  "Evaluate Steel Scheme in the running editor, the language the editor is written in, and return the result. Definitions replace the editor's own, live; describe-function and apropos document what exists."
  (schema (list '("code" "string" "Scheme code")) '("code"))
  (lambda (args)
    (let ([v (imp-eval-string (or (jget args "code") ""))])
      (mcp-log! "evaluated Scheme")
      (if (eq? v void) "" (to-string v)))))
