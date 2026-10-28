;;; grammars.scm -- tree-sitter grammars installed at runtime.
;;;
;;;   (define-grammar! "ruby" "https://github.com/tree-sitter/tree-sitter-ruby" "v0.23.1")
;;;
;;; declares one, and :TSInstallGrammar clones and builds each declared
;;; grammar that isn't built at its revision, in the background. A build
;;; is grammars/NAME@REV.so under $XDG_DATA_HOME/imp, one file for each
;;; revision: dlopen hands back the library it already has for a path it
;;; has seen, and overwriting a loaded library can crash imp. Rust loads a
;;; registered grammar the first time its language is used (syntax.rs).

(define *grammars* (hash))  ; name -> (url rev subdir-or-#f)
(define *grammars-dir* #f)  ; where they go, when not the default (tests)

(define (grammars-dir)
  "Where grammars are cloned and built: imp/grammars in $XDG_DATA_HOME,
   or ~/.local/share."
  (or *grammars-dir*
      (let ([data (getenv "XDG_DATA_HOME")])
        (string-append (if (and data (not (equal? data "")))
                           data
                           (string-append (or (getenv "HOME") ".") "/.local/share"))
                       "/imp/grammars"))))

(define (grammar-library name rev)
  "The library grammar `name` is built into at revision `rev`."
  (string-append (grammars-dir) "/" name "@"
                 (list->string (map (lambda (c) (if (equal? c #\/) #\_ c)) (string->list rev)))
                 ".so"))

(define (grammar-clone name)
  "The directory grammar `name` is cloned into."
  (string-append (grammars-dir) "/" name))

(define (grammar-source name)
  "The directory with grammar `name`'s src/ and queries/: its clone, or
   the subdirectory of it the grammar was declared with."
  (let ([subdir (caddr (hash-try-get *grammars* name))])
    (string-append (grammar-clone name) (if subdir (string-append "/" subdir) ""))))

(define (grammar-built? name)
  "Whether declared grammar `name` is built at its declared revision."
  (let ([g (hash-try-get *grammars* name)])
    (and g (file-exists? (grammar-library name (cadr g))))))

(define (register-built-grammar! name)
  "Tells Rust where grammar `name`'s library and queries are."
  (register-grammar! name (grammar-library name (cadr (hash-try-get *grammars* name)))
                     (string-append (grammar-source name) "/queries")))

(define (define-grammar! name url rev . subdir)
  "Declares tree-sitter grammar `name`, from the git repository at `url`
   at revision `rev` (a tag, branch or commit), and in its subdirectory
   `subdir` when the repository has several grammars. :TSInstallGrammar
   builds it; once built it's used like a bundled grammar, in place of a
   bundled one of the same name.

     (define-grammar! \"ruby\" \"https://github.com/tree-sitter/tree-sitter-ruby\" \"v0.23.1\")
     (define-grammar! \"php\" \"https://github.com/tree-sitter/tree-sitter-php\" \"v0.23.11\" \"php\")"
  (set! *grammars* (hash-insert *grammars* name (list url rev (if (null? subdir) #f (car subdir)))))
  (when (grammar-built? name) (register-built-grammar! name))
  void)

(define (grammar-fetch-command name url rev)
  "A shell command that fetches revision `rev` (a tag, branch or commit)
   of grammar `name` from `url` into its clone and checks it out. Only
   that revision, with no history: grammar repositories commit every
   generated parser, so a full clone of one can be hundreds of megabytes."
  (let ([dir (shell-quote (grammar-clone name))])
    (string-append
     "{ command -v git >/dev/null || { echo \"git isn't installed\"; exit 1; }; "
     "mkdir -p " (shell-quote (grammars-dir)) " && "
     "{ [ -d " dir "/.git ] || { git init --quiet " dir " && git -C " dir " remote add origin " (shell-quote url) "; }; } && "
     "git -C " dir " remote set-url origin " (shell-quote url) " && "
     "GIT_TERMINAL_PROMPT=0 git -C " dir " fetch --quiet --depth 1 origin " (shell-quote rev) " && "
     "git -C " dir " checkout --quiet --detach FETCH_HEAD; } 2>&1")))

(define (grammar-build-command name rev)
  "A shell command that compiles grammar `name`'s src/parser.c, and its
   src/scanner.c or src/scanner.cc, into its library for `rev`, written to
   a temporary file and renamed, then removes its other revisions'."
  (let* ([lib (shell-quote (grammar-library name rev))]
         [tmp (shell-quote (string-append (grammars-dir) "/.build-" name))]
         [others (string-append (shell-quote (string-append (grammars-dir) "/" name "@")) "*.so")])
    (string-append
     "{ cd " (shell-quote (grammar-source name)) " && "
     "[ -f src/parser.c ] || { echo \"no src/parser.c: generating one needs the tree-sitter CLI\"; exit 1; }; "
     "CC=${CC:-cc}; command -v \"$CC\" >/dev/null || { echo \"no C compiler: $CC isn't installed\"; exit 1; }; "
     "rm -rf " tmp " && mkdir -p " tmp " && "
     "\"$CC\" -c -fPIC -O2 -I src src/parser.c -o " tmp "/parser.o && objects=" tmp "/parser.o && link=$CC && "
     "if [ -f src/scanner.cc ]; then CXX=${CXX:-c++}; "
     "command -v \"$CXX\" >/dev/null || { echo \"no C++ compiler: $CXX isn't installed\"; exit 1; }; "
     "\"$CXX\" -c -fPIC -O2 -I src src/scanner.cc -o " tmp "/scanner.o && objects=\"$objects \"" tmp "/scanner.o && link=$CXX; "
     "elif [ -f src/scanner.c ]; then "
     "\"$CC\" -c -fPIC -O2 -I src src/scanner.c -o " tmp "/scanner.o && objects=\"$objects \"" tmp "/scanner.o; fi && "
     "\"$link\" -shared $objects -o " tmp "/grammar.so && mv " tmp "/grammar.so " lib " && "
     "for f in " others "; do [ \"$f\" = " lib " ] || rm -f \"$f\"; done; rm -rf " tmp "; } 2>&1")))

(define (run-grammar-step! name command done failed)
  "Runs `command` for grammar `name` in the background, then calls `done`,
   or says why it failed and calls `failed`."
  (let ([output ""])
    (unless (start-job! command ""
                        (lambda (text stream) (set! output (string-append output text)))
                        (lambda (code)
                          (if (= code 0)
                              (done)
                              (let ([lines (split-lines (trim-right output))])
                                (message (string-append "grammar " name ": failed: "
                                                        (if (null? lines) "" (last lines))))
                                (failed)))))
      (failed))
    void))

(define (install-grammar! name then)
  "Clones or fetches grammar `name`, builds it and registers it, in the
   background, saying in the message line how it's going; then `then`."
  (let* ([g (hash-try-get *grammars* name)] [rev (cadr g)])
    (message (string-append "grammar " name ": fetching " rev "..."))
    (run-grammar-step!
     name (grammar-fetch-command name (car g) rev)
     (lambda ()
       (message (string-append "grammar " name ": building..."))
       (run-grammar-step!
        name (grammar-build-command name rev)
        (lambda ()
          (register-built-grammar! name)
          (attach-grammar! name)
          (message (string-append "grammar " name ": installed"))
          (then))
        then))
     then)))

(define (attach-grammar! name)
  "Parses the open buffers whose language is `name` with its grammar as
   it is now, so a grammar just installed highlights them in place."
  (for-each (lambda (id)
              (with-buffer id (lambda ()
                                (when (equal? (language-for-buffer) name)
                                  (set-buffer-language! name)))))
            (buffer-list))
  void)

(define (install-grammars! names)
  "Installs grammars `names`, one after another."
  (unless (null? names)
    (install-grammar! (car names) (lambda () (install-grammars! (cdr names)))))
  void)

;; :TSInstallGrammar installs every declared grammar not built at its
;; revision; :TSInstallGrammar NAME installs or rebuilds that one.
(define-ex! '("TSInstallGrammar")
  (lambda (ex)
    (let ([name (ex-args ex)])
      (cond
        [(not (equal? name ""))
         (if (hash-try-get *grammars* name)
             (install-grammars! (list name))
             (message (string-append "no grammar " name " is declared (see define-grammar!)")))]
        [else
         (let ([todo (filter (lambda (n) (not (grammar-built? n)))
                             (sort (hash-keys->list *grammars*) string<?))])
           (if (null? todo)
               (message "every declared grammar is built")
               (install-grammars! todo)))]))))

;; A buffer whose language is declared but not built says how to build
;; it; nothing is cloned or built unasked. (Here, not in syntax.scm's
;; hook, which runs first: that file can't see this one's definitions.)
(add-hook! 'major-mode
           (lambda (mode)
             (let ([language (language-for-buffer)])
               (when (and language (hash-try-get *grammars* language) (not (grammar-built? language)))
                 (message (string-append "grammar " language " isn't built: run :TSInstallGrammar"))))))
