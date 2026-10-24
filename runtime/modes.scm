;;; modes.scm -- major and minor modes.
;;;
;;; Every buffer has one major mode, picked from its file name when it
;;; opens, and any number of minor modes. A mode can have keymaps per
;;; state ('normal, 'visual, 'insert), set options just for its buffers,
;;; and bind keys under SPC m (the local leader). Key lookup goes: the
;;; buffer's minor modes, newest first; its major mode, then that mode's
;;; parents; the global keymap.
;;;
;;;   (define-major-mode! 'lua-mode 'prog-mode '("lua")
;;;     (lambda () (set-local-option! 'shiftwidth 2)
;;;                (set-local-option! 'commentstring "-- %s")))
;;;   (define-mode-key! 'lua-mode 'normal "K" 'describe-function)

(define *major-modes* (hash))  ; name -> (parent extensions setup)
(define *minor-modes* (hash))  ; name -> (setup teardown)
(define *file-names* (hash))   ; exact file names ("Makefile") -> mode

(define (define-major-mode! name parent extensions setup)
  "Defines major mode `name`, for files ending in one of `extensions`.
   `parent` is the mode it builds on, or #f: the parent's keys apply
   in its buffers and the parent's `setup` runs before its own.
   `setup`, a procedure of no arguments or #f, runs in each buffer
   that takes the mode, to set local options:

     (define-major-mode! 'lua-mode 'prog-mode '(\"lua\")
       (lambda () (set-local-option! 'shiftwidth 2)))"
  (set! *major-modes* (hash-insert *major-modes* name (list parent extensions setup)))
  void)

(define (define-minor-mode! name setup teardown)
  "Defines minor mode `name`, which a buffer can turn on and off.
   `setup` runs when it turns on in a buffer and `teardown` when it
   turns off; each is a procedure of no arguments, or #f."
  (set! *minor-modes* (hash-insert *minor-modes* name (list setup teardown)))
  void)

;; Files with no extension, or one that misleads, by their whole name.
(define (define-file-name-mode! file-name mode)
  "Makes files named exactly `file-name` open in major mode `mode`.
   This wins over the extension:

     (define-file-name-mode! \"Justfile\" 'makefile-mode)"
  (set! *file-names* (hash-insert *file-names* file-name mode))
  void)

(define (mode-keymap mode state)
  "The keymap name for `mode` in `state`, e.g. scheme-mode:normal."
  (string->symbol (string-append (symbol->string mode) ":" (symbol->string state))))

(define (define-mode-key! mode state key command . label)
  "Binds `key` to `command` in `state` for buffers in `mode`.
   `state` is 'normal, 'visual or 'insert; the binding wins over the
   global one there. `mode` can be a major or a minor mode. An optional
   last argument is the label which-key shows:

     (define-mode-key! 'lua-mode 'normal \"K\" 'describe-function \"describe\")"
  (apply define-key! (append (list (mode-keymap mode state) key command) label)))

(define (major-mode)
  "The current buffer's major mode, fundamental-mode if it has none."
  (or (buffer-local 'major-mode) 'fundamental-mode))
(define (minor-modes)
  "The minor modes on in the current buffer, newest first."
  (or (buffer-local 'minor-modes) '()))

(define (mode-lineage mode)
  "`mode` and its parents, nearest first."
  (let ([spec (hash-try-get *major-modes* mode)])
    (if (and spec (car spec)) (cons mode (mode-lineage (car spec))) (list mode))))

(set! *local-keymaps*
      (lambda (state)
        (map (lambda (m) (mode-keymap m state))
             (append (minor-modes) (mode-lineage (major-mode))))))

;;; Choosing and switching major modes

(define (file-name-of path)
  "The last part of `path`, after its final slash."
  (let loop ([i (- (string-length path) 1)])
    (cond [(< i 0) path]
          [(equal? (string-ref path i) #\/) (substring path (+ i 1) (string-length path))]
          [else (loop (- i 1))])))

(define (extension-of name)
  "The extension of file name `name`, without the dot, or #f.
   A leading dot doesn't start one: .bashrc has no extension."
  (let loop ([i (- (string-length name) 1)])
    (cond [(<= i 0) #f]
          [(equal? (string-ref name i) #\.) (substring name (+ i 1) (string-length name))]
          [else (loop (- i 1))])))

(define (mode-for-path path)
  "The major mode for a file path."
  (let* ([name (file-name-of path)] [ext (extension-of name)])
    (or (hash-try-get *file-names* name)
        (and ext
             (let loop ([modes (hash-keys->list *major-modes*)])
               (cond [(null? modes) #f]
                     [(member ext (cadr (hash-ref *major-modes* (car modes)))) (car modes)]
                     [else (loop (cdr modes))])))
        'fundamental-mode)))

(define (set-major-mode! mode)
  "Makes `mode` the current buffer's major mode: its parents' setups run
   first, then its own, so a mode can adjust what its parent set."
  (set-buffer-local! 'major-mode mode)
  (for-each (lambda (m)
              (let ([spec (hash-try-get *major-modes* m)])
                (when (and spec (caddr spec)) ((caddr spec)))))
            (reverse (mode-lineage mode)))
  (show-major-mode!)
  (run-hooks 'major-mode mode))

(define (show-major-mode!)
  "Shows the major mode's name, without -mode, in the status line.
   The buffer's mode-line-label shows instead when it has one (org
   capture's keys)."
  (let* ([name (symbol->string (major-mode))]
         [short (or (buffer-local 'mode-line-label)
                    (if (ends-with? name "-mode") (substring name 0 (- (string-length name) 5)) name))])
    (set-mode-line-extra! short)
    ;; %{major} in the status line, per buffer.
    (set-status-value! "major" short #f)))

;; Turns minor mode `name` on or off in the current buffer.
(define (minor-mode-on! name)
  "Turns minor mode `name` on in the current buffer, if it's off.
   Runs its setup."
  (unless (memq name (minor-modes))
    (set-buffer-local! 'minor-modes (cons name (minor-modes)))
    (let ([spec (hash-try-get *minor-modes* name)])
      (when (and spec (car spec)) ((car spec))))))

(define (minor-mode-off! name)
  "Turns minor mode `name` off in the current buffer, if it's on.
   Runs its teardown."
  (when (memq name (minor-modes))
    (set-buffer-local! 'minor-modes (filter (lambda (m) (not (eq? m name))) (minor-modes)))
    (let ([spec (hash-try-get *minor-modes* name)])
      (when (and spec (cadr spec)) ((cadr spec))))))

(define (toggle-minor-mode! name)
  "Turns minor mode `name` on in the current buffer, or off if it's on."
  (if (memq name (minor-modes)) (minor-mode-off! name) (minor-mode-on! name)))

;; A buffer gets its major mode when it opens; switching buffers brings
;; back its options and mode line.
(define (pick-major-mode!)
  "Sets the current buffer's major mode from its file name."
  (set-major-mode! (mode-for-path (or (buffer-path) ""))))

(add-hook! 'buffer-open pick-major-mode!)
(add-hook! 'buffer-enter
           (lambda ()
             (unless (buffer-local 'major-mode) (pick-major-mode!))
             (refresh-option-watchers!)
             (show-major-mode!)))

;; Buffers that exist at startup (files on the command line) get theirs
;; once the user's init.scm has defined any extra modes.
(add-hook! 'startup
           (lambda ()
             (for-each (lambda (id) (with-buffer id pick-major-mode!)) (buffer-list))
             (refresh-option-watchers!)
             (show-major-mode!)))

(define-ex! '("setl" "setlocal")
  (lambda (ex)
    (for-each (lambda (arg) (set-one-option-with! set-local-option! arg))
              (split-whitespace (ex-args ex)))))

;; :mode NAME switches major mode (without -mode is fine: :mode rust).
(define-ex! '("mode")
  (lambda (ex)
    (let* ([arg (ex-args ex)]
           [name (string->symbol (if (ends-with? arg "-mode") arg (string-append arg "-mode")))])
      (cond [(equal? arg "") (message (symbol->string (major-mode)))]
            [(or (hash-contains? *major-modes* name) (eq? name 'fundamental-mode)) (set-major-mode! name)]
            [else (message (string-append "no major mode " arg))]))))

;;; Commenting: gc{motion}, gcc, visual gc
;;;
;;; commentstring is "<before>%s<after>", e.g. ";; %s" or "/* %s */". gc
;;; comments every line in the range at their smallest indent, or, if they
;;; are all commented already, uncomments them.

(define-option! 'commentstring "# %s" '(cms))

(define (comment-parts)
  "(before after) from commentstring, without padding spaces."
  (let* ([cs (option 'commentstring)]
         [at (let loop ([i 0]) (cond [(>= (+ i 1) (string-length cs)) #f]
                                     [(and (equal? (string-ref cs i) #\%) (equal? (string-ref cs (+ i 1)) #\s)) i]
                                     [else (loop (+ i 1))]))])
    (if at
        (list (trim-right (substring cs 0 at)) (trim-left (substring cs (+ at 2) (string-length cs))))
        (list (trim-right cs) ""))))

(define (trim-left s)
  "`s` without the whitespace at its start."
  (let loop ([i 0]) (if (and (< i (string-length s)) (char-whitespace? (string-ref s i))) (loop (+ i 1)) (substring s i (string-length s)))))
(define (trim-right s)
  "`s` without the whitespace at its end."
  (let loop ([i (string-length s)]) (if (and (> i 0) (char-whitespace? (string-ref s (- i 1)))) (loop (- i 1)) (substring s 0 i))))

(define (line-text line)
  "The text of `line`, without its newline."
  (buffer-substring (line-start line) (line-end line)))

(define (commented? line before after)
  "Whether `line` is commented with `before` and `after`.
   Leading whitespace is ignored; an empty `after` matches any end."
  (let ([text (trim-left (line-text line))])
    (and (starts-with? text before)
         (or (equal? after "") (ends-with? (trim-right text) after)))))

(define (comment-lines! first last)
  "Comments lines `first` to `last`, or uncomments them if they all are.
   Uses the commentstring option. Blank lines are left alone; the
   others are commented at the smallest indent among them."
  (let* ([parts (comment-parts)] [before (car parts)] [after (cadr parts)]
         [lines (filter (lambda (l) (not (blank-line? l))) (range first (+ last 1)))])
    (unless (null? lines)
      (if (andmap (lambda (l) (commented? l before after)) lines)
          (for-each (lambda (l) (uncomment-line! l before after)) lines)
          (let ([indent (apply min (map (lambda (l) (- (line-first-nonblank l) (line-start l))) lines))])
            (for-each (lambda (l) (comment-line! l indent before after)) lines))))))

(define (andmap pred lst)
  "Whether `pred` holds for every element of `lst` (#t for none)."
  (or (null? lst) (and (pred (car lst)) (andmap pred (cdr lst)))))

(define (comment-line! line indent before after)
  "Comments `line` with `before` at column `indent`, and `after`
   (if not empty) at its end."
  (unless (equal? after "")
    (buffer-insert! (line-end line) (string-append " " after)))
  (buffer-insert! (+ (line-start line) indent) (string-append before " ")))

(define (uncomment-line! line before after)
  "Removes `before` from the start of `line` and `after` from its end,
   with the space beside each."
  (let* ([start (line-first-nonblank line)]
         [n (string-length before)]
         ;; Take the space after the marker too, if there is one.
         [n (if (equal? (buffer-char-at (+ start n)) #\space) (+ n 1) n)])
    (buffer-delete! start (+ start n))
    (unless (equal? after "")
      (let* ([text (line-text line)] [end (+ (line-start line) (string-length (trim-right text)))]
             [m (string-length after)]
             [m (if (equal? (buffer-char-at (- end m 1)) #\space) (+ m 1) m)])
        (buffer-delete! (- end m) end)))))

(define-operator! "gc"
  (lambda (start end linewise?)
    (let ([first (offset->line start)] [last (offset->line (max start (- end 1)))])
      (comment-lines! first last)
      (set-cursor! (line-first-nonblank first)))))

(define-key! 'visual "gc" (lambda (count) (visual-operator! "gc" #t)))

;;; The modes that come with imp

(define-major-mode! 'fundamental-mode #f '() #f)
(define-major-mode! 'text-mode #f '("txt" "text")
  (lambda () (set-local-option! 'commentstring "# %s")))
(define-major-mode! 'prog-mode #f '() #f)

(define (indent-with spaces? width)
  "Sets the current buffer to indent by `width`, with spaces if
   `spaces?`, else with tabs shown `width` wide (Vim's ts=sw), so a
   level is one tab."
  (set-local-option! 'expandtab spaces?)
  (set-local-option! 'shiftwidth width)
  (set-local-option! 'tabstop width))

;; (name extensions comment indent-spaces? indent-width)
(for-each
 (lambda (spec)
   (let ([comment (caddr spec)] [spaces? (cadddr spec)] [width (car (cddddr spec))])
     (define-major-mode! (car spec) 'prog-mode (cadr spec)
       (lambda ()
         (set-local-option! 'commentstring comment)
         (indent-with spaces? width)))))
 (list (list 'scheme-mode '("scm" "ss" "sld" "rkt") ";; %s" #t 2)
       (list 'lisp-mode '("lisp" "cl" "el" "clj" "cljs" "fnl") ";; %s" #t 2)
       (list 'rust-mode '("rs") "// %s" #t 4)
       (list 'typescript-mode '("ts" "tsx" "mts" "cts") "// %s" #t 2)
       (list 'javascript-mode '("js" "jsx" "mjs" "cjs") "// %s" #t 2)
       (list 'json-mode '("json") "// %s" #t 2)
       (list 'nix-mode '("nix") "# %s" #t 2)
       (list 'python-mode '("py" "pyi") "# %s" #t 4)
       (list 'go-mode '("go") "// %s" #f 4)
       (list 'c-mode '("c" "h") "/* %s */" #t 4)
       (list 'cpp-mode '("cc" "cpp" "cxx" "hpp" "hh") "// %s" #t 4)
       (list 'shell-mode '("sh" "bash" "zsh" "fish") "# %s" #t 2)
       (list 'lua-mode '("lua") "-- %s" #t 2)
       (list 'toml-mode '("toml") "# %s" #t 2)
       (list 'yaml-mode '("yml" "yaml") "# %s" #t 2)
       (list 'html-mode '("html" "htm" "xml" "svg") "<!-- %s -->" #t 2)
       (list 'css-mode '("css" "scss") "/* %s */" #t 2)
       (list 'sql-mode '("sql") "-- %s" #t 2)
       (list 'makefile-mode '("mk" "make") "# %s" #f 8)))

(define-major-mode! 'markdown-mode 'text-mode '("md" "markdown")
  (lambda () (set-local-option! 'commentstring "<!-- %s -->")))

(define-file-name-mode! "Makefile" 'makefile-mode)
(define-file-name-mode! "makefile" 'makefile-mode)
(define-file-name-mode! "init.scm" 'scheme-mode)
(define-file-name-mode! "flake.lock" 'json-mode)
(define-file-name-mode! "Cargo.lock" 'toml-mode)

;;; Scheme mode: the editor's own language

;; K describes the symbol under the cursor, gd goes to its definition.
(define-command! 'describe-symbol-at-point
  (lambda (count)
    "Describe the Scheme function or variable under the cursor."
    (let ([name (symbol-at-cursor)])
      (if name (describe-function name) (message "no symbol at the cursor")))))

(define-mode-key! 'scheme-mode 'normal "K" 'describe-symbol-at-point)
(define-mode-key! 'scheme-mode 'normal "gd" 'find-definition-at-point)

;;; The local leader: SPC m runs the major mode's own bindings.

(define *mode-leaders* (hash))  ; mode -> hash of keys -> (command description)

(define (define-mode-leader! mode keys command description)
  "Binds `keys` under SPC m for buffers in major mode `mode`.
   `command` and `description` are as for define-leader!. A mode's
   buffers also get the SPC m bindings of its parents:

     (define-mode-leader! 'lua-mode \"r\" 'lua-run \"run file\")"
  (let ([table (or (hash-try-get *mode-leaders* mode) (hash))])
    (set! *mode-leaders* (hash-insert *mode-leaders* mode (hash-insert table keys (list command description)))))
  void)

(define-command! 'local-leader
  (lambda (count)
    "Show the SPC m bindings of the buffer's major mode and its parents."
    (let ([bindings (filter (lambda (x) x)
                            (map (lambda (m) (hash-try-get *mode-leaders* m)) (mode-lineage (major-mode))))])
      (if (null? bindings)
          (message (string-append "no SPC m bindings for " (symbol->string (major-mode))))
          (begin
            ;; Install them under "m" for this sequence, then continue it.
            (for-each (lambda (keys) (when (starts-with? keys "m") (undefine-leader! keys)))
                      (hash-keys->list *leader-bindings*))
            (for-each (lambda (table)
                        (for-each (lambda (keys)
                                    (let ([b (hash-ref table keys)])
                                      (unless (hash-contains? *leader-bindings* (string-append "m" keys))
                                        (define-leader! (string-append "m" keys) (car b) (cadr b)))))
                                  (hash-keys->list table)))
                      bindings)
            (set! *leader-keys* "m")
            (set! *key-interceptor* leader-input!)
            (show-which-key!))))))

(define-mode-leader! 'scheme-mode "e" 'eval-defun "eval top-level form")
(define-mode-leader! 'scheme-mode "b" 'eval-buffer "eval buffer")
(define-mode-leader! 'scheme-mode "s" 'eval-last-sexp "eval form at cursor")
(define-mode-leader! 'scheme-mode "d" 'find-definition-at-point "go to definition")
(define-mode-leader! 'scheme-mode "k" 'describe-symbol-at-point "describe symbol")

;;; The Scheme REPL: a buffer where <ret> evaluates what you typed.
;;;
;;; :repl (or SPC e i) opens *scheme*. Type after the "imp> " prompt and
;;; press <ret> at the end of the buffer: the input is evaluated in the
;;; running editor, like :eval, and the result is printed with a new
;;; prompt. Anywhere else <ret> just breaks the line.

(define *repl-prompt* "imp> ")

(define-major-mode! 'repl-mode 'scheme-mode '() #f)

(define (repl-input-start)
  "Where the input after the last prompt starts."
  (let loop ([line (last-line)])
    (cond [(< line 0) 0]
          [(starts-with? (buffer-substring (line-start line) (line-end line)) *repl-prompt*)
           (+ (line-start line) (string-length *repl-prompt*))]
          [else (loop (- line 1))])))

(define (repl-print! text)
  "Adds `text` at the end of the REPL buffer and moves the cursor there."
  (buffer-insert! (buffer-length) text)
  (set-cursor! (buffer-length)))

(define (repl-send!)
  "Evaluates the REPL input after the last prompt and prints the result.
   With the cursor before the input, or no input, it only breaks the
   line. Prints errors too, then a new prompt."
  (let* ([start (repl-input-start)]
         [input (buffer-substring start (buffer-length))])
    (if (or (< (cursor) start) (equal? (trim-left input) ""))
        (insert-newline!)
        (let ([result (with-handler (lambda (e) (string-append "error: " (error-message e)))
                                    (let ([v (imp-eval-string input)])
                                      (if (eq? v void) "" (to-string v))))])
          (repl-print! (string-append "\n" (if (equal? result "") "" (string-append result "\n")) *repl-prompt*))))))

(define-mode-key! 'repl-mode 'insert "<ret>" repl-send!)
(define-mode-key! 'repl-mode 'normal "<ret>"
  (lambda (count)
    (set-cursor! (buffer-length))
    (set-mode! 'insert)
    (repl-send!)))

(define-command! 'repl
  (lambda (count)
    "Open the Scheme REPL, *scheme*, ready to type at its prompt."
    (let ([existing (filter (lambda (id) (equal? (car (buffer-info id)) "*scheme*")) (buffer-list))])
      (if (pair? existing)
          (go-to-buffer! (car existing))
          (let ([id (buffer-new! "*scheme*")])
            (go-to-buffer! id)
            (set-major-mode! 'repl-mode)
            (buffer-insert! 0 (string-append ";; imp's Scheme. Definitions replace the editor's own, live.\n"
                                             *repl-prompt*))
            (set-buffer-unmodified!)))
      (set-cursor! (buffer-length))
      (set-mode! 'insert))))

(define-ex! '("repl") (lambda (ex) (run-command 'repl)))
(define-leader! "ei" 'repl "REPL")
