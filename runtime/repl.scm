;;; repl.scm -- the Scheme REPL, *scheme*.
;;;
;;; A buffer where <ret> evaluates what you typed.
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
