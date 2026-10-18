;;; help.scm -- the editor describes itself.
;;;
;;; Documentation is the comment block above a definition, which is how the
;;; runtime is written anyway. The server keeps the source of every file it
;;; loaded (the runtime, init.scm, packages), so describe-function finds
;;; `(define (name` there and shows the comment, the signature and where it
;;; is; describe-key works out what a key does and finds the form that
;;; bound it the same way; find-definition opens the source at that line.

;;; Finding definitions in the loaded sources

;; Every loaded source as (name . lines), lines as a list of strings.
(define (source-lines name) (split-lines (or (source-text name) "")))

;; The first line (counting from 0) in `lines` for which `match?` is true.
(define (find-line lines match?)
  (let loop ([ls lines] [i 0])
    (cond [(null? ls) #f]
          [(match? (car ls)) i]
          [else (loop (cdr ls) (+ i 1))])))

;; Where `match?` first holds, as (source-name line), searching the most
;; recently loaded source first so a redefinition in init.scm wins.
(define (find-in-sources match?)
  (let loop ([names (reverse (source-names))])
    (if (null? names)
        #f
        (let ([line (find-line (source-lines (car names)) match?)])
          (if line (list (car names) line) (loop (cdr names)))))))

;; Does `line` define `name` with define, define-command!, define-option!
;; or define-syntax?
(define (defines-name? line name)
  (equal? (defined-name line) name))

(define (find-definition-site name)
  (find-in-sources (lambda (line) (defines-name? line name))))

;; The comment block right above line `n`, without the semicolons.
(define (doc-comment lines n)
  (let loop ([i (- n 1)] [acc '()])
    (if (< i 0)
        acc
        (let ([line (list-ref lines i)])
          (if (starts-with? line ";")
              (loop (- i 1) (cons (strip-comment line) acc))
              acc)))))

(define (strip-comment line)
  (let loop ([i 0])
    (if (and (< i (string-length line)) (equal? (string-ref line i) #\;))
        (loop (+ i 1))
        (substring line (if (and (< i (string-length line)) (equal? (string-ref line i) #\space)) (+ i 1) i)
                   (string-length line)))))

;; Lines describing the definition at `site`: where it is, its first line
;; and its comment.
(define (site-description site)
  (let* ([lines (source-lines (car site))] [n (cadr site)])
    (append (list (string-append "Defined in " (car site) ":" (number->string (+ n 1)))
                  ""
                  (string-append "  " (list-ref lines n))
                  "")
            (let ([doc (doc-comment lines n)])
              (if (null? doc) (list "Not documented.") doc)))))

;;; describe-function, describe-option, apropos

(define (describe-function name)
  (let ([site (find-definition-site name)])
    (cond
      [site (show-popup! (cons (string-append name ":") (site-description site)))]
      [(command-proc (string->symbol name))
       (show-popup! (list (string-append name " is a command, defined without a source line.")))]
      [(bound? (string->symbol name))
       (show-popup! (list (string-append name " is built into Steel or Rust; see crates/imp-server/src/api.rs.")))]
      [else (message (string-append "no definition of " name))])))

(define (describe-option name)
  (let ([opt (option-name (string->symbol name))])
    (if (not opt)
        (message (string-append "unknown option: " name))
        (let ([site (find-definition-site (symbol->string opt))])
          (show-popup!
           (append (list (string-append (symbol->string opt) " = " (to-string (option opt))) "")
                   (if site (cddr (site-description site)) '())))))))

;; Names defined in the loaded sources that contain `text`.
(define (apropos text)
  (let ([hits '()])
    (for-each
     (lambda (src)
       (for-each
        (lambda (line)
          (let ([name (defined-name line)])
            (when (and name (string-contains? name text) (not (member name hits)))
              (set! hits (cons name hits)))))
        (source-lines src)))
     (source-names))
    (sort hits string<?)))

;; The name a line defines, if it starts a definition.
(define (defined-name line)
  (let loop ([prefixes '("(define (" "(define-command! '" "(define-option! '" "(define-syntax " "(define ")])
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

;; What a key sequence is bound to in normal mode, as (kind name site), or
;; #f. Kinds: motion, operator, text-object, command.
(define (key-description keys)
  (let* ([quoted (string-append "\"" keys "\"")]
         [binds? (lambda (forms)
                   (lambda (line)
                     (let loop ([fs forms])
                       (and (pair? fs)
                            (or (starts-with? line (string-append "(" (car fs) " " quoted))
                                (starts-with? line (string-append "(" (car fs) " 'normal " quoted))
                                (loop (cdr fs)))))))]
         [site-for (lambda (forms) (find-in-sources (binds? forms)))])
    (cond
      [(hash-contains? *motions* keys)
       (list "motion" keys (site-for '("define-motion!")))]
      [(and (> (string-length keys) 1) (hash-contains? *char-motions* (substring keys 0 1)))
       (list "motion taking a char" (substring keys 0 1)
             (find-in-sources (binds? '("define-char-motion!")) ))]
      [(hash-contains? *operators* keys) (list "operator" keys (site-for '("define-operator!")))]
      [(hash-contains? *text-objects* keys) (list "text object" keys (site-for '("define-text-object!")))]
      [(key-binding 'normal keys)
       => (lambda (b)
            (if (symbol? b)
                (list "command" (symbol->string b) (find-definition-site (symbol->string b)))
                (list "command" keys
                      (site-for '("define-key!" "insert-command!" "operator-command!" "paste-command!"
                                  "define-normal-and-visual!")))))]
      [(and (> (string-length keys) 1) (hash-contains? *char-commands* (substring keys 0 1)))
       (list "command taking a char" (substring keys 0 1)
             (find-in-sources (binds? '("define-char-command!"))))]
      [else #f])))

(define (show-key-description! keys)
  (let ([d (key-description keys)])
    (if (not d)
        (message (string-append keys " is not bound"))
        (show-popup!
         (cons (string-append keys " runs the " (car d) " " (cadr d))
               (if (caddr d)
                   (cdr (site-description (caddr d)))
                   (list "" "No source line found.")))))))

;; Called with each key while describe-key is reading.
(define (describe-key-input! key)
  (let ([keys (string-append *describing-keys* key)])
    (if (and (prefix-key-for-describe? keys) (not (key-description keys)))
        (set! *describing-keys* keys)
        (begin
          (set! *describing-keys* #f)
          (set! *key-interceptor* #f)
          (show-key-description! keys)))))

;; Whether `keys` could be the start of a longer key.
(define (prefix-key-for-describe? keys)
  (and (= (string-length keys) 1)
       (or (hash-contains? *prefix-keys* keys)
           (hash-contains? *char-motions* keys)
           (hash-contains? *char-commands* keys))))

;; Describe what the next keys do (Emacs's C-h k).
(define-command! 'describe-key
  (lambda (count)
    (set! *describing-keys* "")
    (set! *key-interceptor* describe-key-input!)
    (message "Describe key: ")))

;; Describe a function: where it is defined and its documentation (C-h f).
(define-command! 'describe-function
  (lambda (count) (open-cmdline! "Describe function: " "" describe-function #f #f)))

(define-command! 'describe-option
  (lambda (count) (open-cmdline! "Describe option: " "" describe-option #f #f)))

;; List definitions whose name contains a string.
(define-command! 'apropos
  (lambda (count)
    (open-cmdline! "Apropos: " ""
                   (lambda (text)
                     (let ([hits (apropos text)])
                       (if (null? hits) (message "no matches") (show-popup! hits))))
                   #f #f)))

;;; Going to a definition

;; Opens the source of `name`'s definition at its line. Runtime files open
;; from disk when IMP_RUNTIME is set; otherwise as a copy of the embedded
;; text in a buffer of its own.
(define (find-definition name)
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

;; The Scheme symbol under the cursor.
(define (symbol-at-cursor)
  (let ([r (form-at (cursor))])
    (and r (not (equal? (buffer-char-at (car r)) #\())
         (buffer-substring (car r) (cadr r)))))

;; Go to the definition of the symbol under the cursor.
(define-command! 'find-definition-at-point
  (lambda (count)
    (let ([name (symbol-at-cursor)])
      (if name (find-definition name) (message "no symbol at the cursor")))))

(define-command! 'find-definition
  (lambda (count) (open-cmdline! "Find definition: " "" find-definition #f #f)))

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

(define-ex! '("describe-key") (lambda (ex) (run-command 'describe-key)))
(define-ex! '("describe-function") (lambda (ex) (describe-function (ex-args ex))))
(define-ex! '("apropos") (lambda (ex) (let ([hits (apropos (ex-args ex))]) (show-popup! (if (null? hits) (list "no matches") hits)))))
(define-ex! '("find-definition" "fd") (lambda (ex) (find-definition (ex-args ex))))
