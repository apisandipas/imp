;;; fold.scm -- folds: ranges of lines that show as one line when closed.
;;;
;;; A fold is a pair of buffer marks, so it follows edits; a fold whose
;;; lines are all deleted goes away. Folds nest. Rust draws closed folds
;;; (set-closed-folds!); vim.scm has the keys (zf zo zc za zR zM zE zd) and
;;; makes j, k and linewise operators treat a closed fold as one line.
;;; Packages make folds too: Org folds headings with them.

(define *fold-next* 0)

(define (fold-entries)
  "The current buffer's folds, as (id closed?)."
  (or (buffer-local 'folds) '()))

(define (fold-mark id end?)
  "The name of fold `id`'s start mark, or its end mark when `end?`."
  (string-append "fold:" (number->string id) (if end? ":end" ":start")))

(define (fold-lines id)
  "(first last) of fold `id`, or #f once its lines are gone. The end mark
   sits at the start of the line after the fold."
  (let ([s (mark-get (fold-mark id #f))] [e (mark-get (fold-mark id #t))])
    (and s e (> e s) (list (offset->line s) (offset->line (- e 1))))))

(define (fold-forget! id)
  "Deletes fold `id`'s marks, leaving its entry in the buffer's list."
  (mark-delete! (fold-mark id #f))
  (mark-delete! (fold-mark id #t)))

(define (buffer-folds)
  "The current buffer's live folds, as (id first last closed?), dropping
   dead ones."
  (let loop ([entries (fold-entries)] [live '()] [kept '()] [dead? #f])
    (cond
      [(null? entries)
       (when dead? (set-buffer-local! 'folds (reverse kept)))
       (reverse live)]
      [(fold-lines (car (car entries)))
       => (lambda (lines)
            (loop (cdr entries) (cons (list (car (car entries)) (car lines) (cadr lines) (cadr (car entries))) live)
                  (cons (car entries) kept) dead?))]
      [else (fold-forget! (car (car entries))) (loop (cdr entries) live kept #t)])))

(define (fold-id f)
  "The id of fold `f`, an (id first last closed?) from buffer-folds."
  (car f))
(define (fold-first f)
  "The first line of fold `f`."
  (cadr f))
(define (fold-last f)
  "The last line of fold `f`."
  (caddr f))
(define (fold-closed? f)
  "Whether fold `f` is closed."
  (cadddr f))

(define (folds-changed!)
  "Tells the renderer which lines closed folds hide."
  (set-closed-folds! (map (lambda (f) (list (fold-first f) (fold-last f)))
                          (filter fold-closed? (buffer-folds))))
  (set-buffer-local! 'folds-version (buffer-version)))

(define (fold-create! first last closed?)
  "Makes a fold of lines first..last; returns its id."
  (set! *fold-next* (+ *fold-next* 1))
  (let ([id *fold-next*] [first (min first last)] [last (max first last)])
    (mark-set! (fold-mark id #f) (line-start first))
    (mark-set! (fold-mark id #t) (if (< last (last-line)) (line-start (+ last 1)) (buffer-length)))
    (set-buffer-local! 'folds (cons (list id closed?) (fold-entries)))
    (folds-changed!)
    id))

(define (fold-delete! id)
  "Removes fold `id` from the current buffer."
  (fold-forget! id)
  (set-buffer-local! 'folds (filter (lambda (e) (not (= (car e) id))) (fold-entries)))
  (folds-changed!))

(define (fold-set-closed! id closed?)
  "Closes fold `id`, or opens it when `closed?` is #f."
  (set-buffer-local! 'folds (map (lambda (e) (if (= (car e) id) (list id closed?) e)) (fold-entries)))
  (folds-changed!))

(define (folds-at line)
  "The current buffer's folds that hold `line`, outer and inner."
  (filter (lambda (f) (and (<= (fold-first f) line) (<= line (fold-last f)))) (buffer-folds)))

(define (fold-size f)
  "How many lines fold `f` spans, less one."
  (- (fold-last f) (fold-first f)))

(define (innermost-fold line ok?)
  "The innermost fold holding `line` that `ok?` accepts, or #f."
  (foldl (lambda (f best) (if (and (ok? f) (or (not best) (< (fold-size f) (fold-size best)))) f best))
         #f (folds-at line)))

(define (closed-fold-at line)
  "The outermost closed fold holding `line`: what the screen shows there."
  (if (null? (fold-entries))
      #f
      (foldl (lambda (f best) (if (and (fold-closed? f) (or (not best) (> (fold-size f) (fold-size best)))) f best))
             #f (folds-at line))))

;; The line `line` shows on, and the last line that shows there.
(define (shown-line line)
  "The line whose screen line `line` shows on: the start of the closed
   fold holding it, or `line` itself."
  (let ([f (closed-fold-at line)]) (if f (fold-first f) line)))
(define (shown-last line)
  "The last line shown on the same screen line as `line`: the end of
   the closed fold holding it, or `line` itself."
  (let ([f (closed-fold-at line)]) (if f (fold-last f) line)))

(define (fold-step line n)
  "The line `n` shown lines from `line` (negative goes up), stopping at the
   ends: what j and k count."
  (if (null? (fold-entries))
      (clamp (+ line n) 0 (last-line))
      (let loop ([line (shown-line line)] [n n])
        (cond [(= n 0) line]
              [(> n 0) (let ([next (+ (shown-last line) 1)])
                         (if (> next (last-line)) line (loop next (- n 1))))]
              [(= line 0) line]
              [else (loop (shown-line (- line 1)) (+ n 1))]))))

;; Set by the commands Vim's default 'foldopen' names (searches, marks, %,
;; undo): the folds where they land open.
(define *fold-open-wanted* #f)

(define (folds-after-command!)
  "Refreshes what the renderer hides when a command changed the text.
   Edits move fold marks, so closed folds may now cover other lines.
   After a command that 'foldopen' names, also opens the closed folds
   the cursor landed in."
  (unless (null? (fold-entries))
    (unless (equal? (buffer-local 'folds-version) (buffer-version))
      (folds-changed!))
    (when (and *fold-open-wanted* (closed-fold-at (current-line)))
      (for-each (lambda (f) (when (fold-closed? f) (fold-set-closed! (fold-id f) #f)))
                (folds-at (current-line)))))
  (set! *fold-open-wanted* #f))

(add-hook! 'post-command folds-after-command!)
(add-hook! 'buffer-enter (lambda () (unless (null? (fold-entries)) (folds-changed!))))
