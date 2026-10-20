;;; org-babel.scm -- running the code in Org source blocks, after Org Babel.
;;;
;;;   (use-package! 'org-babel)
;;;
;;; In an Org buffer, C-c C-c in a source block runs it and puts what it
;;; printed under the block, replacing the results of the last run:
;;;
;;;   #+begin_src python
;;;   print(6 * 7)
;;;   #+end_src
;;;
;;;   #+RESULTS:
;;;   : 42
;;;
;;; Scheme (or steel) blocks run inside imp, like elisp blocks in Emacs,
;;; and their result is the value of the last form. Other languages run in
;;; the background through the interpreter org-babel-interpreters names
;;; for them, the code on its stdin; their result is what they print.
;;; Header arguments: `:dir DIR` runs the code there, `:results silent`
;;; shows the result on the message line instead of inserting it.
;;;
;;;   C-c C-c        run the block at the cursor
;;;   C-c C-v C-b    run every block in the buffer, top to bottom
;;;   C-c C-v k      remove the block's results
;;;
;;; org-babel-confirm (on by default, as in Org) asks before each run.

(define-option! 'org-babel-confirm #t '())
;; (language command): the shell command that runs code given on stdin.
(define-option! 'org-babel-interpreters
  '(("sh" "sh") ("shell" "sh") ("bash" "bash") ("zsh" "zsh") ("fish" "fish")
    ("python" "python3") ("python3" "python3") ("js" "node") ("javascript" "node")
    ("node" "node") ("ruby" "ruby") ("perl" "perl") ("lua" "lua") ("R" "Rscript -"))
  '())
;; Results longer than this many lines go in an example block.
(define-option! 'org-babel-example-lines 10 '())

(define *babel-runs* 0)  ; for naming the mark that follows a running block

(define (babel-line-start? line prefix)
  "Whether `line`, ignoring indentation and case, starts with `prefix`."
  (let ([t (string-downcase (trim line))])
    (starts-with? t prefix)))

(define (babel-indent line)
  "The whitespace `line` starts with."
  (let loop ([i 0])
    (if (and (< i (string-length line)) (char-whitespace? (string-ref line i)))
        (loop (+ i 1))
        (substring line 0 i))))

(define (babel-block-at line)
  "The source block around `line`, as (begin end), the lines of its
   #+begin_src and #+end_src; #f if `line` isn't in one."
  (let ([start (let up ([i line])
                 (cond [(< i 0) #f]
                       [(babel-line-start? (line-text i) "#+begin_src") i]
                       [(and (< i line) (babel-line-start? (line-text i) "#+end_src")) #f]
                       [else (up (- i 1))]))])
    (and start
         (let down ([i (+ start 1)])
           (cond [(> i (last-line)) #f]
                 [(babel-line-start? (line-text i) "#+end_src") (and (>= i line) (list start i))]
                 [(babel-line-start? (line-text i) "#+begin_src") #f]
                 [else (down (+ i 1))])))))

(define (babel-header begin)
  "The words after #+begin_src on line `begin`: the language, then the
   header arguments."
  (let ([words (filter (lambda (w) (not (equal? w ""))) (split-many (trim (line-text begin)) " "))])
    (if (null? words) '() (cdr words))))

(define (babel-arg header name)
  "The value of header argument `name` (like \":dir\") in `header`, or #f."
  (let loop ([h header])
    (cond [(or (null? h) (null? (cdr h))) #f]
          [(equal? (car h) name) (cadr h)]
          [else (loop (cdr h))])))

(define (babel-code begin end)
  "The code between lines `begin` and `end`, with a final line break,
   less the indentation of its #+begin_src line."
  (let ([indent (string-length (babel-indent (line-text begin)))])
    (apply string-append
           (map (lambda (i)
                  (let ([l (line-text i)])
                    (string-append (if (>= (string-length l) indent)
                                       (if (equal? (trim (substring l 0 indent)) "") (substring l indent (string-length l)) l)
                                       (trim l))
                                   "\n")))
                (range (+ begin 1) end)))))

(define (babel-results-end end)
  "The last line of the results of the block ending on line `end`, and the
   line they start on, as (first last); #f if it has none. Results are a
   #+RESULTS: line after at most one blank line, then lines starting with
   :, or an example block."
  (let* ([first (if (and (< (+ end 1) (buffer-line-count)) (equal? (trim (line-text (+ end 1))) ""))
                    (+ end 2) (+ end 1))])
    (and (<= first (last-line))
         (babel-line-start? (line-text first) "#+results")
         (let loop ([i (+ first 1)] [in-example? #f])
           (cond
             [(> i (last-line)) (list first (- i 1))]
             [in-example? (loop (+ i 1) (not (babel-line-start? (line-text i) "#+end_example")))]
             [(babel-line-start? (line-text i) "#+begin_example") (loop (+ i 1) #t)]
             [(babel-line-start? (line-text i) ":") (loop (+ i 1) #f)]
             [else (list first (- i 1))])))))

(define (babel-format output indent)
  "The text of a results block for `output`, each line starting with
   `indent`: `: ` lines, or an example block when it's long."
  (let* ([lines (text-lines output)]
         [body (if (> (length lines) (option 'org-babel-example-lines))
                   (append (list "#+begin_example") lines (list "#+end_example"))
                   (map (lambda (l) (if (equal? l "") ":" (string-append ": " l))) lines))])
    (apply string-append
           (map (lambda (l) (string-append indent l "\n"))
                (cons "#+RESULTS:" body)))))

(define (babel-insert-results! begin output)
  "Puts `output` as the results of the block starting on line `begin`,
   replacing the results it had."
  (let ([block (babel-block-at begin)])
    (when block
      (let* ([end (cadr block)]
             [old (babel-results-end end)]
             [text (babel-format output (babel-indent (line-text begin)))])
        (begin-change!)
        (if old
            (let ([from (line-start (car old))]
                  [to (if (< (cadr old) (last-line)) (line-start (+ (cadr old) 1)) (buffer-length))])
              (buffer-delete! from to)
              (buffer-insert! from (if (= to (buffer-length)) (without-final-newline text) text)))
            (let ([at (line-end end)])
              (buffer-insert! at (string-append "\n\n" (without-final-newline text)))))))))

(define (babel-show-or-insert! buf begin-mark header output)
  "Delivers the `output` of a run of the block marked `begin-mark` in
   buffer `buf`: on the message line with :results silent, else as its
   results."
  (if (equal? (babel-arg header ":results") "silent")
      (message (trim output))
      (when (memv buf (buffer-list))
        (with-buffer buf
          (lambda ()
            (let ([at (mark-get begin-mark)])
              (mark-delete! begin-mark)
              (when at (babel-insert-results! (offset->line at) output))))))))

(define (babel-scheme-value code)
  "Evaluates Scheme `code` inside imp: the last form's value as text (a
   string as it is), and #f after showing the error if there is one."
  (with-handler
   (lambda (e) (message (string-append "error: " (error-message e))) #f)
   (let ([v (imp-eval-string code)])
     (cond [(eq? v void) ""]
           [(string? v) v]
           [else (to-string v)]))))

(define (babel-run! begin end)
  "Runs the block from line `begin` to `end` and delivers its results."
  (let* ([header (babel-header begin)]
         [lang (if (null? header) "" (car header))]
         [code (babel-code begin end)]
         [buf (current-buffer)]
         [mark (begin (set! *babel-runs* (+ *babel-runs* 1))
                      (string-append "babel:" (number->string *babel-runs*)))]
         [dir (babel-arg header ":dir")]
         [interpreter (assoc lang (option 'org-babel-interpreters))])
    (mark-set! mark (line-start begin))
    (cond
      [(member lang '("scheme" "steel"))
       (let ([value (babel-scheme-value code)])
         (if value
             (babel-show-or-insert! buf mark header value)
             (mark-delete! mark)))]
      [(not interpreter)
       (mark-delete! mark)
       (message (string-append "no interpreter for " (if (equal? lang "") "a block with no language" lang)
                               "; add it to org-babel-interpreters"))]
      [else
       (let ([output '()])
         (message (string-append "running the " lang " block..."))
         (start-job! (string-append (if dir (string-append "cd " (shell-quote (expand-path dir)) " && ") "")
                                    (cadr interpreter) " 2>&1")
                     code
                     (lambda (text stream) (set! output (cons text output)))
                     (lambda (exit)
                       (message (string-append lang " block finished"
                                               (if (= exit 0) "" (string-append " with exit code " (number->string exit)))))
                       ;; After the message, so :results silent's output wins.
                       (babel-show-or-insert! buf mark header (apply string-append (reverse output))))))])))

(define (babel-execute-at! line)
  "Runs the source block around `line`, asking first with
   org-babel-confirm. Returns #f if `line` isn't in a block."
  (let ([block (babel-block-at line)])
    (and block
         (let* ([header (babel-header (car block))]
                [lang (if (null? header) "?" (car header))]
                [run (lambda () (babel-run! (car block) (cadr block)))])
           (if (option 'org-babel-confirm)
               (confirm! (string-append "Run this " lang " block?") run)
               (run))
           #t))))

(define (babel-blocks)
  "The source blocks in the buffer, as (begin end), top to bottom."
  (let loop ([i 0] [acc '()])
    (if (> i (last-line))
        (reverse acc)
        (let ([block (and (babel-line-start? (line-text i) "#+begin_src") (babel-block-at i))])
          (if block (loop (+ (cadr block) 1) (cons block acc)) (loop (+ i 1) acc))))))

(define-command! 'org-babel-execute
  (lambda (count)
    "Run the Org source block at the cursor and put its results under it."
    (unless (babel-execute-at! (current-line))
      (message "not in a source block"))))

(define-command! 'org-babel-execute-buffer
  (lambda (count)
    "Run every Org source block in the buffer, top to bottom."
    (let ([run (lambda ()
                 ;; Marks follow the blocks as results go in above them.
                 (let ([marks (map (lambda (b)
                                     (set! *babel-runs* (+ *babel-runs* 1))
                                     (let ([m (string-append "babel-all:" (number->string *babel-runs*))])
                                       (mark-set! m (line-start (car b)))
                                       m))
                                   (babel-blocks))])
                   (for-each (lambda (m)
                               (let ([block (babel-block-at (offset->line (mark-get m)))])
                                 (mark-delete! m)
                                 (when block (babel-run! (car block) (cadr block)))))
                             marks)))])
      (if (option 'org-babel-confirm)
          (confirm! (string-append "Run all " (number->string (length (babel-blocks))) " blocks?") run)
          (run)))))

(define-command! 'org-babel-remove-result
  (lambda (count)
    "Remove the results under the Org source block at the cursor."
    (let* ([block (babel-block-at (current-line))]
           [old (and block (babel-results-end (cadr block)))])
      (if (not old)
          (message "no results here")
          (let ([from (line-end (cadr block))] [to (line-end (cadr old))])
            (begin-change!)
            (buffer-delete! from to))))))

(for-each (lambda (state)
            (define-mode-key! 'org-mode state "C-cC-c" 'org-babel-execute)
            (define-mode-key! 'org-mode state "C-cC-vC-b" 'org-babel-execute-buffer)
            (define-mode-key! 'org-mode state "C-cC-vk" 'org-babel-remove-result))
          '(normal insert))
