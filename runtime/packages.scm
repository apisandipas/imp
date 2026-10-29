;;; packages.scm -- loading other people's Scheme.
;;;
;;; A package is a directory in ~/.config/imp/packages (packages-dir) whose
;;; main file is NAME.scm, init.scm or package.scm. init.scm declares the
;;; packages it wants, and imp loads them through the same evaluator as
;;; init.scm, so a package can redefine anything:
;;;
;;;   (use-package! 'surround)                     ; already in packages/
;;;   (use-package! 'surround
;;;     'git "https://github.com/someone/imp-surround"
;;;     'rev "4f1c2e9"                             ; a commit, tag or branch
;;;     'config (lambda () (set-option! 'surround-pairs "()[]{}")))
;;;
;;; A package with 'git that isn't there yet is cloned (pinned to 'rev if
;;; given) in the background, and loaded when the clone finishes. M-x list-packages lists them; package-update
;;; fetches and checks out its 'rev again (or pulls), then reloads it.
;;;
;;; Some packages come with imp (packages/ in its source): what isn't
;;; essential to editing, like olivetti. They're built in but opt-in,
;;; loaded only when declared: (use-package! 'olivetti). A directory of
;;; the same name in packages-dir, or a 'git, takes their place.

(define *packages* '())  ; (name status dir options), in declaration order

(define (packages-dir)
  "The directory packages live in: the packages-dir option, or
   packages/ in the config directory when it is empty."
  (or (option-or-false 'packages-dir) (string-append (config-dir) "/packages")))

(define (option-or-false name)
  "The value of string option `name` if it is set and not \"\", else #f."
  (and (option-name name) (let ([v (option name)]) (and (string? v) (not (equal? v "")) v))))

(define-option! 'packages-dir "" '())

(define (package-option options key)
  "The value of `key` in `options`, a (key value ...) list, or #f."
  (let loop ([o options])
    (cond [(or (null? o) (null? (cdr o))) #f]
          [(eq? (car o) key) (cadr o)]
          [else (loop (cddr o))])))

(define (package-main-file dir name)
  "The path of the main file of the package in `dir`: NAME.scm,
   init.scm or package.scm, the first that exists. #f if none does."
  (let loop ([candidates (list (string-append name ".scm") "init.scm" "package.scm")])
    (cond [(null? candidates) #f]
          [(file-exists? (string-append dir "/" (car candidates))) (string-append dir "/" (car candidates))]
          [else (loop (cdr candidates))])))

(define (shell-quote text)
  "`text` quoted for the shell, in single quotes."
  (string-append "'" (list->string (apply append (map (lambda (c) (if (equal? c #\') (string->list "'\\''") (list c)))
                                                      (string->list text))))
                 "'"))

(define (run-or-report! command)
  "Runs a shell command, returning #t or saying what went wrong."
  (let ([r (run-shell command "")])
    (or (= (car r) 0)
        (begin (message (string-append "failed: " command ": " (cadr r))) #f))))

(define (clone-package! name dir options)
  "Clones package `name` into `dir` from its 'git URL in the background,
   checking out its 'rev if `options` give one, and loads it when that
   finishes. A failed checkout removes the clone, so the next start tries
   again rather than loading the wrong revision."
  (let* ([url (package-option options 'git)] [rev (package-option options 'rev)]
         [label (symbol->string name)]
         [output ""]
         [command (string-append
                   "mkdir -p " (shell-quote (packages-dir))
                   " && GIT_TERMINAL_PROMPT=0 git clone --quiet " (shell-quote url) " " (shell-quote dir)
                   (if rev
                       (string-append " && { git -C " (shell-quote dir) " checkout --quiet " (shell-quote rev)
                                      " || { rm -rf " (shell-quote dir) "; false; }; }")
                       "")
                   " 2>&1")])
    (set-package-status! name "cloning")
    (message (string-append "cloning " label "..."))
    (unless (start-job! command ""
                        (lambda (text stream) (set! output (string-append output text)))
                        (lambda (code)
                          (if (= code 0)
                              (begin
                                (load-package! name)
                                (when (equal? (package-status name) "loaded")
                                  (message (string-append "installed " label))))
                              (begin
                                (set-package-status! name "clone failed")
                                (message (string-append "package " label ": clone failed: " (trim-right output)))))))
      (set-package-status! name "clone failed"))
    void))

(define (package-status name)
  "What list-packages shows for package `name`, or #f if it isn't declared."
  (let ([p (assq name *packages*)]) (and p (cadr p))))

(define (set-package-status! name status)
  "Sets what list-packages shows for package `name` to `status`."
  (set! *packages*
        (map (lambda (p) (if (eq? (car p) name) (list (car p) status (caddr p) (cadddr p)) p)) *packages*))
  void)

(define (load-package! name)
  "Loads package `name`: its main file (or the built-in copy, for one
   that comes with imp), then its 'config."
  (let* ([p (assq name *packages*)] [dir (caddr p)] [options (cadddr p)]
         [builtin (and (not (file-exists? dir)) (builtin-package (symbol->string name)))]
         [file (and (not builtin) (package-main-file dir (symbol->string name)))])
    (if (not (or builtin file))
        (set-package-status! name "no main file")
        (let ([result (with-handler (lambda (e) (error-message e))
                                    (begin (if builtin
                                               (begin (record-source! (car builtin) (cadr builtin) (caddr builtin))
                                                      (imp-eval-string (caddr builtin)))
                                               (imp-load-file file))
                                           (let ([config (package-option options 'config)])
                                             (when config (config)))
                                           #t))])
          (set-package-status! name (if (eq? result #t) "loaded" (string-append "error: " result)))
          (unless (eq? result #t)
            (message (string-append "package " (symbol->string name) ": " result)))))))

(define (use-package! name . options)
  "Declares package `name` and loads it, cloning it in the background
   first if needed (its 'config runs once it has loaded).
   `options` are 'key value pairs: 'git (a URL to clone from), 'rev (a
   commit, tag or branch to pin), 'config (a thunk run after loading):

     (use-package! 'surround 'git \"https://github.com/someone/imp-surround\")

   Without 'git, the package must be in packages-dir or come with imp
   (builtin-package-names lists those)."
  (let ([dir (string-append (packages-dir) "/" (symbol->string name))])
    (set! *packages* (append (filter (lambda (p) (not (eq? (car p) name))) *packages*)
                             (list (list name "declared" dir options))))
    (cond
      [(file-exists? dir) (load-package! name)]
      [(package-option options 'git) (clone-package! name dir options)]
      [(builtin-package (symbol->string name)) (load-package! name)]
      [else (set-package-status! name "missing")
            (message (string-append "package " (symbol->string name) " is not in " (packages-dir)))])))

(define (package-revision dir)
  "The short commit hash checked out in `dir`, \"built-in\" for a package
   that comes with imp, or \"-\" if it isn't a git checkout."
  (if (not (file-exists? dir))
      "built-in"
      (package-revision-of dir)))

(define (package-revision-of dir)
  "The short commit hash checked out in git checkout `dir`, or \"-\"."
  (let ([r (run-shell (string-append "git -C " (shell-quote dir) " rev-parse --short HEAD") "")])
    (if (= (car r) 0) (trim-right (cadr r)) "-")))

(define-command! 'list-packages
  (lambda (count)
    "List the packages declared, with their revisions, and those that come
     with imp but are off."
    (show-popup!
     (append
      (if (null? *packages*)
          (list (string-append "No packages declared. Packages live in " (packages-dir)))
          (map (lambda (p)
                 (string-append (pad-right (symbol->string (car p)) 20)
                                (pad-right (package-revision (caddr p)) 10)
                                (cadr p)))
               *packages*))
      (let ([unused (filter (lambda (n) (not (assq (string->symbol n) *packages*))) (builtin-package-names))])
        (if (null? unused)
            '()
            (list "" (string-append "Built in, off until (use-package! 'NAME): " (string-join unused " ")))))))))

(define (package-update! text)
  "Updates package `text` (its name, a string) from git and loads it again:
   to its declared revision if it has one, else the latest."
  (let* ([name (string->symbol text)] [p (assq name *packages*)])
      (cond
        [(not p) (message (string-append "no package " text))]
        [(not (file-exists? (caddr p))) (message (string-append text " comes with imp, and updates with it"))]
        [else
         (let* ([dir (caddr p)] [rev (package-option (cadddr p) 'rev)]
                 [ok (if rev
                         (run-or-report! (string-append "git -C " (shell-quote dir) " fetch --quiet && git -C "
                                                        (shell-quote dir) " checkout --quiet " (shell-quote rev)))
                         (run-or-report! (string-append "git -C " (shell-quote dir) " pull --quiet")))])
            (when ok
              (load-package! name)
              (message (string-append "updated " text))))])))

(define-command! 'package-update
  (lambda (count)
    "Update a package loaded from git, chosen by name, and load it again."
    (let ([names (map (lambda (p) (symbol->string (car p)))
                      (filter (lambda (p) (file-exists? (caddr p))) *packages*))])
      (if (null? names)
          (message "no packages are loaded from git")
          (completing-read "Update package: " (sort names string<?) package-update!)))))
