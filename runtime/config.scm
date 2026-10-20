;;; config.scm -- ~/.config/imp/config.kdl, settings as data.
;;;
;;; Built with the `kdl` feature. config.kdl sits beside init.scm and loads
;;; before it, so Scheme can still change anything it sets. Each node is
;;; one setting:
;;;
;;;   theme "gruvbox-dark"
;;;   option "number" #true
;;;   options { tabstop 4; relativenumber #true }
;;;   key "normal" "C-s" "save-buffer"
;;;   keys "insert" { "C-s" "save-buffer" }
;;;   leader "gs" "save-buffer" "save"
;;;   language-server "python-mode" "pylsp" markers=".git pyproject.toml" language="python"
;;;
;;; A node that isn't understood, or a bad value, is reported with its
;;; line, and the rest still loads. (load-kdl-config! PATH) loads a file
;;; by hand.

(define (kdl-name n) (car n))
(define (kdl-args n) (cadr n))
(define (kdl-props n) (caddr n))
(define (kdl-children n) (cadddr n))
(define (kdl-line n) (list-ref n 4))

(define (kdl-prop n key default)
  (let ([p (assoc key (kdl-props n))]) (if p (cadr p) default)))

(define (kdl-expect n what ok?)
  "Checks that node `n` has arguments that `ok?` accepts; returns them."
  (let ([args (kdl-args n)])
    (if (ok? args) args (error (string-append (kdl-name n) " takes " what)))))

(define (all-strings? args) (or (null? args) (and (string? (car args)) (all-strings? (cdr args)))))

(define (config-option! name value)
  (set-option! (string->symbol name) value))

(define (config-node! n)
  (let ([name (kdl-name n)])
    (cond
      [(equal? name "theme")
       (load-theme! (string->symbol (car (kdl-expect n "a theme name" (lambda (a) (and (= (length a) 1) (string? (car a))))))))]
      [(equal? name "option")
       (let ([a (kdl-expect n "a name and a value" (lambda (a) (and (= (length a) 2) (string? (car a)))))])
         (config-option! (car a) (cadr a)))]
      [(equal? name "options")
       (for-each (lambda (c)
                   (config-guard c (lambda ()
                                     (let ([a (kdl-expect c "one value" (lambda (a) (= (length a) 1)))])
                                       (config-option! (kdl-name c) (car a))))))
                 (kdl-children n))]
      [(equal? name "key")
       (let ([a (kdl-expect n "a state, keys and a command" (lambda (a) (and (= (length a) 3) (all-strings? a))))])
         (define-key! (string->symbol (car a)) (cadr a) (string->symbol (caddr a))))]
      [(equal? name "keys")
       (let ([state (string->symbol (car (kdl-expect n "a state" (lambda (a) (and (= (length a) 1) (string? (car a)))))))])
         (for-each (lambda (c)
                     (config-guard c (lambda ()
                                       (let ([a (kdl-expect c "a command" (lambda (a) (and (= (length a) 1) (string? (car a)))))])
                                         (define-key! state (kdl-name c) (string->symbol (car a)))))))
                   (kdl-children n)))]
      [(equal? name "leader")
       (let ([a (kdl-expect n "keys, a command and maybe a description"
                            (lambda (a) (and (>= (length a) 2) (<= (length a) 3) (all-strings? a))))])
         (define-leader! (car a) (string->symbol (cadr a)) (if (= (length a) 3) (caddr a) (cadr a))))]
      [(equal? name "language-server")
       (let ([a (kdl-expect n "a major mode and a command" (lambda (a) (and (= (length a) 2) (all-strings? a))))])
         (define-language-server! (string->symbol (car a)) (cadr a)
                                  (split-whitespace (kdl-prop n "markers" ".git"))
                                  (kdl-prop n "language" (car a))))]
      [else (error (string-append "unknown setting " name))])))

(define (config-guard n thunk)
  "Runs `thunk` for node `n`, turning an error into a problem with its line."
  (with-handler
   (lambda (e)
     (set! *config-problems*
           (cons (string-append "line " (number->string (kdl-line n)) ": " (trim (to-string (error-object-message e))))
                 *config-problems*)))
   (thunk)))

(define *config-problems* '())

(define (apply-kdl-config! text)
  "Loads a KDL config; returns its problems, each \"line N: what\"."
  (set! *config-problems* '())
  (with-handler
   (lambda (e) (set! *config-problems* (list (trim (to-string (error-object-message e))))))
   (for-each (lambda (n) (config-guard n (lambda () (config-node! n)))) (kdl-parse text)))
  (reverse *config-problems*))

(define (load-kdl-config! path)
  "Loads PATH, showing what went wrong on the message line."
  (let ([problems (apply-kdl-config! (read-file path))])
    (unless (null? problems)
      (message (string-append (file-name-of path) ": " (string-join problems "; "))))
    problems))
