;;; repl.scm -- the Scheme REPL, *scheme*.
;;;
;;; A buffer where <ret> evaluates what you typed.
;;;
;;; :repl (or SPC e i) opens *scheme*. Type after the "imp> " prompt and
;;; press <ret> at the end of the buffer: the input is evaluated in the
;;; running editor, like :eval, and the result is printed with a new
;;; prompt. Anywhere else <ret> just breaks the line.

(define *repl-prompt* "imp> ")

;; Inputs sent, newest first, as the command line's history in vim.scm.
(define *repl-history* '())
(define *repl-history-index* -1)   ; -1 while editing a fresh input
(define *repl-history-prefix* "")  ; what M-p and M-n match against

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
          (repl-add-history! (trim-right-newlines input))
          (repl-print! (string-append "\n" (if (equal? result "") "" (string-append result "\n")) *repl-prompt*))))))

(define (trim-right-newlines text)
  "`text` without the line breaks at its end."
  (let loop ([end (string-length text)])
    (if (and (> end 0) (equal? (string-ref text (- end 1)) #\newline))
        (loop (- end 1))
        (substring text 0 end))))

;;; History: M-p and M-n, and <up> and <down> on the prompt's line, as on
;;; the command line.

(define (repl-add-history! input)
  "Adds `input` to the REPL history as the newest entry, dropping an
   earlier copy and keeping 200, and starts the next input fresh."
  (set! *repl-history-index* -1)
  (let ([new (cons input (filter (lambda (h) (not (equal? h input))) *repl-history*))])
    (set! *repl-history* (if (> (length new) 200) (take new 200) new)))
  void)

(define (repl-set-input! text)
  "Replaces the input after the last prompt with `text`, cursor at its end."
  (buffer-delete! (repl-input-start) (buffer-length))
  (repl-print! text))

(define (repl-history-step! dir)
  "Steps `dir` entries through the REPL history (1 is older), visiting
   only entries that start with what was typed before the first step.
   Stepping past the newest brings that text back."
  (when (= *repl-history-index* -1)
    (set! *repl-history-prefix* (buffer-substring (repl-input-start) (buffer-length))))
  (let ([n (length *repl-history*)])
    (let loop ([i (+ *repl-history-index* dir)])
      (cond
        [(< i 0)
         (set! *repl-history-index* -1)
         (repl-set-input! *repl-history-prefix*)]
        [(>= i n) (message "no more REPL history")]
        [(starts-with? (list-ref *repl-history* i) *repl-history-prefix*)
         (set! *repl-history-index* i)
         (repl-set-input! (list-ref *repl-history* i))]
        [else (loop (+ i dir))])))
  void)

(define (repl-arrow! dir)
  "<up> or <down> in insert state: history on the last prompt's line,
   otherwise a line up or down as insert state does."
  (if (= (current-line) (offset->line (repl-input-start)))
      (repl-history-step! dir)
      (let ([line (clamp (+ (current-line) (- dir)) 0 (last-line))])
        (set-cursor! (line-col->offset line (current-col))))))

(define-mode-key! 'repl-mode 'insert "M-p" (lambda () (repl-history-step! 1)))
(define-mode-key! 'repl-mode 'insert "M-n" (lambda () (repl-history-step! -1)))
(define-mode-key! 'repl-mode 'normal "M-p" (lambda (count) (repl-history-step! count)))
(define-mode-key! 'repl-mode 'normal "M-n" (lambda (count) (repl-history-step! (- count))))
(define-mode-key! 'repl-mode 'insert "<up>" (lambda () (repl-arrow! 1)))
(define-mode-key! 'repl-mode 'insert "<down>" (lambda () (repl-arrow! -1)))

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
