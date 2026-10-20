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
;;; given) before loading. :packages lists them; :package-update NAME
;;; fetches and checks out its 'rev again (or pulls), then reloads it.

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
  "Clones package `name` into `dir` from its 'git URL, checking out its
   'rev if `options` give one. Returns #t, or #f after saying what failed."
  (let ([url (package-option options 'git)] [rev (package-option options 'rev)])
    (message (string-append "cloning " (symbol->string name) "..."))
    (and (run-or-report! (string-append "mkdir -p " (shell-quote (packages-dir))
                                        " && git clone --quiet " (shell-quote url) " " (shell-quote dir)))
         (or (not rev)
             (run-or-report! (string-append "git -C " (shell-quote dir) " checkout --quiet " (shell-quote rev)))))))

(define (set-package-status! name status)
  "Sets what :packages shows for package `name` to `status`."
  (set! *packages*
        (map (lambda (p) (if (eq? (car p) name) (list (car p) status (caddr p) (cadddr p)) p)) *packages*)))

(define (load-package! name)
  "Loads package `name`: its main file, then its 'config."
  (let* ([p (assq name *packages*)] [dir (caddr p)] [options (cadddr p)]
         [file (package-main-file dir (symbol->string name))])
    (if (not file)
        (set-package-status! name "no main file")
        (let ([result (with-handler (lambda (e) (error-message e))
                                    (begin (imp-load-file file)
                                           (let ([config (package-option options 'config)])
                                             (when config (config)))
                                           #t))])
          (set-package-status! name (if (eq? result #t) "loaded" (string-append "error: " result)))
          (unless (eq? result #t)
            (message (string-append "package " (symbol->string name) ": " result)))))))

(define (use-package! name . options)
  "Declares package `name` and loads it, cloning it first if needed.
   `options` are 'key value pairs: 'git (a URL to clone from), 'rev (a
   commit, tag or branch to pin), 'config (a thunk run after loading):

     (use-package! 'surround 'git \"https://github.com/someone/imp-surround\")

   Without 'git, the package must already be in packages-dir."
  (let ([dir (string-append (packages-dir) "/" (symbol->string name))])
    (set! *packages* (append (filter (lambda (p) (not (eq? (car p) name))) *packages*)
                             (list (list name "declared" dir options))))
    (cond
      [(file-exists? dir) (load-package! name)]
      [(package-option options 'git)
       (if (clone-package! name dir options)
           (load-package! name)
           (set-package-status! name "clone failed"))]
      [else (set-package-status! name "missing")
            (message (string-append "package " (symbol->string name) " is not in " (packages-dir)))])))

(define (package-revision dir)
  "The short commit hash checked out in `dir`, or \"-\" if it isn't a
   git checkout."
  (let ([r (run-shell (string-append "git -C " (shell-quote dir) " rev-parse --short HEAD") "")])
    (if (= (car r) 0) (trim-right (cadr r)) "-")))

(define-ex! '("packages")
  (lambda (ex)
    (show-popup!
     (if (null? *packages*)
         (list (string-append "No packages declared. Packages live in " (packages-dir)))
         (map (lambda (p)
                (string-append (pad-right (symbol->string (car p)) 20)
                               (pad-right (package-revision (caddr p)) 10)
                               (cadr p)))
              *packages*)))))

(define-ex! '("package-update")
  (lambda (ex)
    (let* ([name (string->symbol (ex-args ex))] [p (assq name *packages*)])
      (if (not p)
          (message (string-append "no package " (ex-args ex)))
          (let* ([dir (caddr p)] [rev (package-option (cadddr p) 'rev)]
                 [ok (if rev
                         (run-or-report! (string-append "git -C " (shell-quote dir) " fetch --quiet && git -C "
                                                        (shell-quote dir) " checkout --quiet " (shell-quote rev)))
                         (run-or-report! (string-append "git -C " (shell-quote dir) " pull --quiet")))])
            (when ok
              (load-package! name)
              (message (string-append "updated " (ex-args ex)))))))))
