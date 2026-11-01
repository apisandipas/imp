;;; help.scm -- the editor describes itself.
;;;
;;; A function's documentation is its docstring, as in Emacs: a string as
;;; the first thing in its body, before the code.
;;;
;;;   (define (directory-of path)
;;;     "The directory part of PATH, without a trailing slash.
;;;      Continuation lines line up under the first; help strips that."
;;;     ...)
;;;
;;; A command's goes first in its lambda, (define-command! 'name (lambda
;;; (count) "Doc." ...)). The first line is a sentence of its own: M-x
;;; shows it beside the command. A string that is the whole body is the
;;; value, not documentation. Variables and options, which have no body,
;;; are documented by the comment block above them instead.
;;;
;;; The server keeps the source of every file it loaded (the runtime,
;;; init.scm, packages), so describe-function finds `(define (name` there
;;; and shows the docstring, the signature and where it is; describe-key
;;; works out what a key does and finds the form that bound it the same
;;; way; find-definition opens the source at that line.

;;; Finding definitions in the loaded sources

(define (source-lines name)
  "The lines of loaded source `name`, as a list of strings.
   '() for a source that isn't loaded."
  (split-lines (or (source-text name) "")))

(define (find-line lines match?)
  "The first line (counting from 0) in `lines` for which `match?` is true."
  (let loop ([ls lines] [i 0])
    (cond [(null? ls) #f]
          [(match? (car ls)) i]
          [else (loop (cdr ls) (+ i 1))])))

(define (find-in-sources match?)
  "Where `match?` first holds, as (source-name line), searching the most
   recently loaded source first so a redefinition in init.scm wins."
  (let loop ([names (reverse (source-names))])
    (if (null? names)
        #f
        (let ([line (find-line (source-lines (car names)) match?)])
          (if line (list (car names) line) (loop (cdr names)))))))

(define (defines-name? line name)
  "Does `line` define `name` with define, define-command!, define-syntax
   or one of the define-...-option! forms?"
  (equal? (defined-name line) name))

(define (find-definition-site name)
  "Where `name` (a string) is defined, as (source-name line), or #f.
   The most recently loaded source wins, so init.scm's redefinition
   is found before the runtime's."
  (find-in-sources (lambda (line) (defines-name? line name))))

(define (strip-comment line)
  "`line` without its leading semicolons and the space after them."
  (let loop ([i 0])
    (if (and (< i (string-length line)) (equal? (string-ref line i) #\;))
        (loop (+ i 1))
        (substring line (if (and (< i (string-length line)) (equal? (string-ref line i) #\space)) (+ i 1) i)
                   (string-length line)))))

;;; Reading docstrings out of the source

;; A reader over a vector of source lines: just enough Scheme to step
;; over forms and read a string literal. A position is (line . col); the
;; end of a line reads as #\newline, the end of the source as #f.

(define (source-char lines pos)
  "The character at `pos` in `lines`, a vector of strings.
   #\\newline at the end of a line, #f past the end of the source."
  (let ([i (car pos)] [j (cdr pos)])
    (cond [(>= i (vector-length lines)) #f]
          [(< j (string-length (vector-ref lines i))) (string-ref (vector-ref lines i) j)]
          [else #\newline])))

(define (source-next lines pos)
  "The position after `pos` in `lines`: the next column, or the start
   of the next line from the end of one."
  (if (< (cdr pos) (string-length (vector-ref lines (car pos))))
      (cons (car pos) (+ (cdr pos) 1))
      (cons (+ (car pos) 1) 0)))

(define (skip-blank lines pos)
  "The position of the first thing from `pos` that isn't whitespace
   or a ; comment."
  (let ([c (source-char lines pos)])
    (cond [(not c) pos]
          [(char-whitespace? c) (skip-blank lines (source-next lines pos))]
          [(equal? c #\;) (skip-blank lines (cons (+ (car pos) 1) 0))]
          [else pos])))

(define (source-delimiter? c)
  "Whether `c` ends a symbol: whitespace, a bracket, a quote, a ; or
   the end of the source (#f)."
  (or (not c) (char-whitespace? c) (memv c '(#\( #\) #\[ #\] #\" #\;))))

(define (read-string-literal lines pos)
  "The string literal at `pos` (on its opening quote), as (text . after)."
  (let loop ([pos (source-next lines pos)] [acc '()])
    (let ([c (source-char lines pos)])
      (cond
        [(not c) (cons (list->string (reverse acc)) pos)]
        [(equal? c #\") (cons (list->string (reverse acc)) (source-next lines pos))]
        [(equal? c #\\)
         (let* ([at (source-next lines pos)] [e (source-char lines at)])
           (loop (source-next lines at)
                 (cons (case e [(#\n) #\newline] [(#\t) #\tab] [else (or e #\\)]) acc)))]
        [else (loop (source-next lines pos) (cons c acc))]))))

(define (skip-form lines pos)
  "The position after the form at `pos`."
  (let ([c (source-char lines pos)])
    (cond
      [(not c) pos]
      [(equal? c #\") (cdr (read-string-literal lines pos))]
      [(memv c '(#\' #\` #\,)) (skip-form lines (source-next lines pos))]
      [(memv c '(#\( #\[))
       (let loop ([pos (skip-blank lines (source-next lines pos))])
         (let ([c (source-char lines pos)])
           (cond [(not c) pos]
                 [(memv c '(#\) #\])) (source-next lines pos)]
                 [else (loop (skip-blank lines (skip-form lines pos)))])))]
      [(and (equal? c #\#) (equal? (source-char lines (source-next lines pos)) #\\))
       ;; A character: #\( is one, so step over the char before the name.
       (let loop ([pos (source-next lines (source-next lines (source-next lines pos)))])
         (if (source-delimiter? (source-char lines pos)) pos (loop (source-next lines pos))))]
      [else
       (let loop ([pos pos])
         (if (source-delimiter? (source-char lines pos)) pos (loop (source-next lines pos))))])))

(define (token-at lines pos)
  "The symbol at `pos`, or \"\"."
  (let loop ([p pos] [acc '()])
    (let ([c (source-char lines p)])
      (if (source-delimiter? c) (list->string (reverse acc)) (loop (source-next lines p) (cons c acc))))))

(define (body-docstring lines pos)
  "The docstring at `pos`, the start of a body, or #f: a string literal
   with more of the body after it."
  (and (equal? (source-char lines pos) #\")
       (let ([read (read-string-literal lines pos)])
         (and (not (memv (source-char lines (skip-blank lines (cdr read))) '(#\) #\] #f)))
              (car read)))))

(define (lambda-docstring lines pos)
  "At `pos`, a (lambda ARGS ...) form: its docstring, or #f."
  (and (equal? (source-char lines pos) #\()
       (let ([at (skip-blank lines (source-next lines pos))])
         (and (equal? (token-at lines at) "lambda")
              (body-docstring lines (skip-blank lines (skip-form lines (skip-blank lines (skip-form lines at)))))))))

(define (definition-docstring lines n)
  "The docstring of the definition starting on line `n` of `lines` (a
   vector), or #f: (define (name ...) \"Doc\" ...), (define name (lambda ...
   \"Doc\" ...)) or (define-command! 'name (lambda (count) \"Doc\" ...))."
  (let* ([start (skip-blank lines (source-next lines (cons n 0)))]
         [head (skip-blank lines (skip-form lines start))]
         [after (skip-blank lines (skip-form lines head))])
    (if (and (equal? (token-at lines start) "define") (equal? (source-char lines head) #\())
        (body-docstring lines after)
        (lambda-docstring lines after))))

(define (docstring-lines text)
  "A docstring as lines: continuation lines lose the indentation they
   share, which lines them up under the first in the source."
  (let* ([lines (split-many text "\n")]
         [rest (cdr lines)]
         [indent (lambda (l) (let loop ([i 0]) (if (and (< i (string-length l)) (equal? (string-ref l i) #\space)) (loop (+ i 1)) i)))]
         [common (foldl (lambda (l m) (if (equal? (trim l) "") m (min m (indent l)))) 1000 rest)])
    (cons (car lines)
          (map (lambda (l) (if (< (string-length l) common) "" (substring l common (string-length l)))) rest))))

(define (definition-doc lines n)
  "The documentation of the definition on line `n`: its docstring, or the
   comment block above it; as lines, '() if there is none."
  (let ([doc (definition-docstring lines n)])
    (if doc
        (docstring-lines doc)
        (let loop ([i (- n 1)] [acc '()])
          (if (and (>= i 0) (starts-with? (vector-ref lines i) ";"))
              (loop (- i 1) (cons (strip-comment (vector-ref lines i)) acc))
              acc)))))

(define (site-description site)
  "Lines describing the definition at `site`: where it is, its first line
   and its documentation."
  (let* ([lines (list->vector (source-lines (car site)))] [n (cadr site)])
    (append (list (string-append "Defined in " (car site) ":" (number->string (+ n 1)))
                  ""
                  (string-append "  " (vector-ref lines n))
                  "")
            (let ([doc (definition-doc lines n)])
              (if (null? doc) (list "Not documented.") doc)))))

;;; One-line docs, shown beside commands in M-x (completion.scm)

;; Docs for commands defined without a line of their own, such as
;; emacs.scm's tables: name (a string) -> one line. These come before doc
;; comments.
(define *command-docs* (hash))

(define (document-command! name text)
  "Gives command `name` the one-line doc `text`, for M-x and help.
   For commands defined without a docstring of their own, such as
   those made in a loop from a table:

     (document-command! 'my-command \"Do the thing.\")"
  (set! *command-docs* (hash-insert *command-docs* (symbol->string name) text))
  void)

(define (command-doc name docs)
  "What command `name` (a string) does, in a line, or #f.
   A line from document-command! wins over one from `docs`, the
   table doc-lines returns. A command's own docstring comes before that
   of a function with the same name."
  (or (hash-try-get *command-docs* name)
      (hash-try-get docs (string-append "command " name))
      (hash-try-get docs name)))

(define *doc-lines* (hash))
(define *doc-lines-key* #f)  ; the sources (name . length) they were read from

(define (sources-key)
  "What the loaded sources are, to tell when one changes: their names and
   lengths."
  (list (source-names) (source-lengths)))

(define (doc-lines)
  "A hash of name -> the first line of its documentation, from every
   loaded source, later sources winning (as describe-function finds
   init.scm's redefinition first). Read again when a source changes."
  (let ([key (sources-key)])
    (unless (equal? key *doc-lines-key*)
      (set! *doc-lines* (foldl source-doc-lines (hash) (source-names)))
      (set! *doc-lines-key* key))
    *doc-lines*))

;; Built shortly after startup, when init.scm has loaded, rather than on
;; the first M-x.
(run-after! 1500 (lambda () (doc-lines)))

(define (source-doc-lines name table)
  "`table` with the first doc line of each definition in loaded source
   `name` added (read by source-doc-table, in Rust). Only documented
   definitions are added. Commands go in as \"command NAME\", apart from
   functions that share their name; a command defined as a named
   procedure gets that procedure's line."
  (let* ([read (source-doc-table name)]
         [table (let loop ([d (car read)] [t table])
                  (if (null? d) t (loop (cddr d) (hash-insert t (car d) (cadr d)))))])
    (let loop ([a (cadr read)] [t table])
      (if (null? a)
          t
          (loop (cddr a) (let ([doc (hash-try-get t (cadr a))]) (if doc (hash-insert t (car a) doc) t)))))))

;;; describe-function, describe-option, apropos
;;;
;;; The describe-function, describe-option, describe-command and
;;; find-definition commands pick a name with completion, so they are in
;;; completion.scm, which loads after this.

(define (describe-function name)
  "Shows in a popup where `name` (a string) is defined and its docs.
   A command with no source line, or a primitive from Steel or Rust,
   is said to be one; for anything else the status line says there
   is no definition."
  (let ([site (find-definition-site name)])
    (cond
      [site (show-popup! (cons (string-append name ":") (site-description site)))]
      [(command-proc (string->symbol name))
       (show-popup! (cons (string-append name " is a command, defined without a source line.")
                          (let ([doc (hash-try-get *command-docs* name)]) (if doc (list "" doc) '()))))]
      [(bound? (string->symbol name))
       (show-popup! (list (string-append name " is built into Steel or Rust; see crates/imp-server/src/api.rs.")))]
      [else (message (string-append "no definition of " name))])))

(define (describe-option name)
  "Shows in a popup the value of option `name` (a string) and its docs.
   `name` can be an alias; the docs are the comment above the
   option's define-option!."
  (let ([opt (option-name (string->symbol name))])
    (if (not opt)
        (message (string-append "unknown option: " name))
        (let ([site (find-definition-site (symbol->string opt))])
          (show-popup!
           (append (list (string-append (symbol->string opt) " = " (to-string (option opt))) "")
                   (if site (cddr (site-description site)) '())))))))

(define (apropos text)
  "The names defined in the loaded sources that contain `text`, sorted
   (defined-names-containing reads them, in Rust)."
  (defined-names-containing text))

(define (defined-name line)
  "The name a line defines, if it starts a definition."
  (let loop ([prefixes '("(define (" "(define-command! '" "(define-option! '" "(define-computed-option! '"
                         "(define-appearance-option! '" "(define-syntax " "(define ")])
    (cond
      [(null? prefixes) #f]
      [(starts-with? line (car prefixes))
       (let* ([start (string-length (car prefixes))]
              [end (let scan ([i start])
                     (if (and (< i (string-length line))
                              (not (memv (string-ref line i) (list #\space #\) #\())))
                         (scan (+ i 1))
                         i))])
         (and (> end start) (substring line start end)))]
      [else (loop (cdr prefixes))])))

;;; describe-key
;;;
;;; Reads keys until they make a complete command, then shows what it is
;;; and where it was bound.

(define *describing-keys* #f)  ; the keys read so far, or #f

(define (key-description keys)
  "What a key sequence runs in normal state in the current buffer, by the
   rule resolve-key follows, as (kind name site), or #f. Kinds: motion,
   motion taking a char, operator, command, command taking a char, and
   mode key for a mode's own procedure."
  (let* ([quoted (string-append "\"" keys "\"")]
         [binds? (lambda (forms)
                   (lambda (line)
                     (let loop ([fs forms])
                       (and (pair? fs)
                            (or (starts-with? line (string-append "(" (car fs) " " quoted))
                                (starts-with? line (string-append "(" (car fs) " 'normal " quoted))
                                (loop (cdr fs)))))))]
         [site-for (lambda (forms) (find-in-sources (binds? forms)))]
         [b (resolve-key 'normal keys)]
         [lead (lambda () (substring keys 0 1))])
    (case (and b (binding-record-kind b))
      [(motion)
       (if (and (> (string-length keys) 1) (hash-contains? *char-motions* (lead)))
           (list "motion taking a char" (lead) (site-for '("define-char-motion!")))
           (list "motion" keys (site-for '("define-motion!"))))]
      [(operator) (list "operator" keys (site-for '("define-operator!")))]
      [(char-command)
       (list "command taking a char" (lead) (site-for '("define-char-command!")))]
      [(mode-key normal-key)
       (let ([command (binding-record-command b)])
         (cond
           [command (list "command" command (find-definition-site command))]
           [(eq? (binding-record-kind b) 'mode-key)
            (list "mode key" (or (binding-record-label b) keys) #f)]
           [else
            (list "command" keys
                  (site-for '("define-key!" "insert-command!" "operator-command!" "paste-command!"
                              "define-normal-and-visual!")))]))]
      [else #f])))

(define (show-key-description! keys)
  "Shows in a popup what `keys` run in normal mode and where it was
   bound, or says in the status line that they're not bound."
  (let ([d (key-description keys)])
    (if (not d)
        (message (string-append keys " is not bound"))
        (show-popup!
         (cons (string-append keys " runs the " (car d) " " (cadr d))
               (if (caddr d)
                   (cdr (site-description (caddr d)))
                   (list "" "No source line found.")))))))

(define (describe-key-input! key)
  "Called with each key while describe-key is reading."
  (let ([keys (string-append *describing-keys* key)])
    (if (prefix-key-for-describe? keys)
        (set! *describing-keys* keys)
        (begin
          (set! *describing-keys* #f)
          (overlay-close! 'describe-key)
          (show-key-description! keys))))
  void)

(define (prefix-key-for-describe? keys)
  "Whether `keys` wait for another key in normal state in the current
   buffer, as resolve-key says."
  (let ([b (resolve-key 'normal keys)])
    (and b (eq? (binding-record-kind b) 'prefix))))

(define-command! 'describe-key
  (lambda (count)
    "Describe what the next keys do (Emacs's C-h k)."
    (set! *describing-keys* "")
    (overlay-open! 'describe-key '() 'keys (lambda (key) (describe-key-input! key) #t))
    (message "Describe key: ")))

(define-command! 'apropos
  (lambda (count)
    "List definitions whose name contains a string."
    (open-cmdline! "Apropos: " ""
                   (lambda (text)
                     (let ([hits (apropos text)])
                       (if (null? hits) (message "no matches") (show-popup! hits))))
                   #f #f)))

;;; Going to a definition

(define (find-definition name)
  "Opens the source of `name`'s definition at its line. Runtime files open
   from disk when IMP_RUNTIME is set; otherwise as a copy of the embedded
   text in a buffer of its own."
  (let ([site (find-definition-site name)])
    (if (not site)
        (message (string-append "no definition of " name))
        (let ([path (source-path (car site))])
          (record-jump!)
          (if path
              (open-file! path)
              (go-to-buffer! (source-copy-buffer (car site))))
          (set-cursor! (line-first-nonblank (min (cadr site) (last-line))))
          ;; Show the definition in the middle of the window, like zz.
          ((lookup-key 'normal "zz") 1)))))

;; The buffer holding a copy of embedded source `name`, made on first use.
(define *source-buffers* (hash))

(define (source-copy-buffer name)
  "The buffer holding a copy of embedded source `name`, made on first use.
   It is made again if it was closed."
  (let ([existing (hash-try-get *source-buffers* name)])
    (if (and existing (memv existing (buffer-list)))
        existing
        (let ([id (buffer-new! name)])
          (with-buffer id
            (lambda ()
              (buffer-insert! 0 (source-text name))
              (set-buffer-unmodified!)))
          (set! *source-buffers* (hash-insert *source-buffers* name id))
          id))))

(define (symbol-at-cursor)
  "The Scheme symbol under the cursor."
  (let ([r (form-at (cursor))])
    (and r (not (equal? (buffer-char-at (car r)) #\())
         (buffer-substring (car r) (cadr r)))))

(define-command! 'find-definition-at-point
  (lambda (count)
    "Go to the definition of the symbol under the cursor."
    (let ([name (symbol-at-cursor)])
      (if name (find-definition name) (message "no symbol at the cursor")))))

;; K: help for the Scheme symbol under the cursor. A language server's
;; hover takes over where one is attached (lsp.scm binds K in lsp-mode).
(define-key! 'normal "K"
  (lambda (count)
    (let ([name (and (equal? (buffer-language) "scheme") (symbol-at-cursor))])
      (cond [name (run-ex! (string-append "help " name))]
            [(equal? (buffer-language) "scheme") (message "no symbol at the cursor")]
            [else (message "K needs a language server for this file (see :help define-language-server!)")]))))

;;; Ex commands: :help and friends

(define-ex! '("h" "help")
  (lambda (ex)
    (let ([topic (ex-args ex)])
      (cond
        [(equal? topic "")
         (show-popup!
          (list "imp help. Everything here is Scheme you can read and redefine."
                ""
                "  :help NAME         a function, option or ex command"
                "  :describe-key      then press keys: what they run and where"
                "  :apropos TEXT      definitions whose name contains TEXT"
                "  :find-definition NAME   open the source of NAME"
                "  :eval EXPR         run Scheme now (define replaces live)"
                "  SPC h ...          the same from the leader menu"
                ""
                "Your config: ~/.config/imp/init.scm"))]
        [(option-name (string->symbol topic)) (describe-option topic)]
        [(and (hash-contains? *ex-commands* topic) (not (find-definition-site topic)))
         (let ([site (find-in-sources
                      (lambda (line)
                        (and (starts-with? line "(define-ex! ")
                             (string-contains? line (string-append "\"" topic "\"")))))])
           (if site
               (show-popup! (cons (string-append ":" topic) (site-description site)))
               (message (string-append "no help for :" topic))))]
        [else (describe-function topic)]))))

(define-ex-completion! '("h" "help")
  (lambda (typed)
    (let loop ([names (sort (filter (lambda (n) (starts-with? n typed))
                                    (append (map symbol->string (hash-keys->list *options*))
                                            (map symbol->string (command-names))
                                            (hash-keys->list *ex-commands*)))
                            string<?)])
      ;; Without repeats (a name can be a command and an ex command).
      (cond [(or (null? names) (null? (cdr names))) names]
            [(equal? (car names) (cadr names)) (loop (cdr names))]
            [else (cons (car names) (loop (cdr names)))]))))

