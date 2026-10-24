;;; foldmethod.scm -- folds worked out from the text: Vim's 'foldmethod'.
;;;
;;; With foldmethod indent, syntax or expr, a buffer's folds are worked
;;; out from its text and kept in step with it. They are ordinary folds
;;; (fold.scm), so drawing, j and k and the z keys treat them as any
;;; other. Loaded after syntax.scm, for the node kinds the text objects
;;; know, and after vim.scm, for its keys.

(define-option! 'foldmethod "manual" '(fdm))
(define-option! 'foldlevel 0 '(fdl))
;; A procedure (lambda (line) level) for foldmethod expr, or #f.
(define-option! 'foldexpr #f '(fde))

;; language -> node kinds that fold, from define-syntax-folds!.
(define *syntax-folds* (hash))

(define (define-syntax-folds! language kinds)
  "Sets the tree-sitter node kinds that make folds for `language` with
   foldmethod syntax, in place of its functions and classes:

     (define-syntax-folds! \"rust\" '(\"function_item\" \"impl_item\" \"block\"))"
  (set! *syntax-folds* (hash-insert *syntax-folds* language kinds))
  void)

(define (automatic-folds?)
  "Whether the current buffer's folds come from its text."
  (member (option 'foldmethod) '("indent" "syntax" "expr")))

;;; Levels: indent and expr give each line a fold level.

(define (indent-width line)
  "How many columns the indent of `line` takes, tabs to tabstop."
  (let ([ts (max 1 (option 'tabstop))])
    (let loop ([cs (string->list (line-indent line))] [w 0])
      (cond [(null? cs) w]
            [(equal? (car cs) #\tab) (loop (cdr cs) (* (+ (quotient w ts) 1) ts))]
            [else (loop (cdr cs) (+ w 1))]))))

(define (indent-levels)
  "Each line's fold level by indent: indent over shiftwidth, a blank
   line taking the lower level of the lines around it."
  (let* ([sw (let ([sw (option 'shiftwidth)]) (if (> sw 0) sw (max 1 (option 'tabstop))))]
         [raw (map (lambda (l) (if (blank-line? l) #f (quotient (indent-width l) sw)))
                   (range 0 (+ (last-line) 1)))])
    (fill-blank-levels raw)))

(define (fill-blank-levels levels)
  "`levels` with each #f (a blank line) replaced by the lower of the
   nearest levels above and below it, or the one there is, or 0."
  (let* ([below (let loop ([ls (reverse levels)] [next #f] [acc '()])
                  (if (null? ls) acc
                      (let ([n (or (car ls) next)]) (loop (cdr ls) n (cons n acc)))))])
    (let loop ([ls levels] [bs below] [prev #f] [acc '()])
      (if (null? ls)
          (reverse acc)
          (let ([l (or (car ls)
                       (cond [(and prev (car bs)) (min prev (car bs))]
                             [else (or prev (car bs) 0)]))])
            (loop (cdr ls) (cdr bs) (or (car ls) prev) (cons l acc)))))))

(define (expr-levels)
  "Each line's fold level from foldexpr; 0 where it fails or is unset."
  (let ([expr (option 'foldexpr)])
    (map (lambda (l)
           (if (procedure? expr)
               (with-handler (lambda (e) 0) (let ([v (expr l)]) (if (integer? v) (max 0 v) 0)))
               0))
         (range 0 (+ (last-line) 1)))))

(define (level-ranges levels)
  "The folds `levels` make, as (first last): each run of lines at level n
   or deeper, for every n, so they nest. One-line folds are left out, as
   Vim shows them open anyway."
  (let loop ([ls levels] [line 0] [open '()] [acc '()])
    ;; `open` holds the first line of each open fold, deepest first.
    (let* ([level (if (null? ls) 0 (car ls))]
           [depth (length open)])
      (cond
        [(< level depth)
         (let ([closed (list (car open) (- line 1))])
           (loop ls line (cdr open) (if (> (cadr closed) (car closed)) (cons closed acc) acc)))]
        [(null? ls) (reverse acc)]
        [(> level depth) (loop ls line (cons line open) acc)]
        [else (loop (cdr ls) (+ line 1) open acc)]))))

(define (syntax-ranges)
  "The folds tree-sitter nodes make: those of the language's fold kinds
   (define-syntax-folds!), or else its functions and classes."
  (let* ([lang (buffer-language)]
         [kinds (and lang (or (hash-try-get *syntax-folds* lang)
                              (let ([objects (hash-try-get *syntax-objects* lang)])
                                (and objects (append (car objects) (cadr objects))))))])
    (if (pair? kinds)
        (filter (lambda (r) (> (cadr r) (car r))) (syntax-fold-lines kinds))
        '())))

(define (wanted-folds)
  "The folds the current buffer's foldmethod wants, as (first last)."
  (let ([method (option 'foldmethod)])
    (cond [(equal? method "indent") (level-ranges (indent-levels))]
          [(equal? method "expr") (level-ranges (expr-levels))]
          [(equal? method "syntax") (syntax-ranges)]
          [else '()])))

(define (fold-depth range ranges)
  "How many of `ranges` hold `range`, itself included: its fold level."
  (length (filter (lambda (r) (and (<= (car r) (car range)) (>= (cadr r) (cadr range)))) ranges)))

(define (sync-folds! fresh?)
  "Makes the current buffer's folds the ones its foldmethod wants. A fold
   still wanted keeps its state; new ones start open, or when `fresh?`
   (foldmethod was just set) closed if deeper than foldlevel."
  (let* ([wanted (wanted-folds)]
         [have (buffer-folds)]
         [key (lambda (first last) (string-append (number->string first) ":" (number->string last)))]
         [wanted-keys (foldl (lambda (r h) (hash-insert h (key (car r) (cadr r)) #t)) (hash) wanted)]
         [kept (foldl (lambda (f h)
                        (let ([k (key (fold-first f) (fold-last f))])
                          (if (and (hash-contains? wanted-keys k) (not (hash-contains? h k)))
                              (hash-insert h k #t)
                              (begin (fold-remove! (fold-id f)) h))))
                      (hash) have)])
    (for-each (lambda (r)
                (unless (hash-contains? kept (key (car r) (cadr r)))
                  (fold-add! (car r) (cadr r)
                             (and fresh? (> (fold-depth r wanted) (option 'foldlevel))))))
              wanted)
    (when fresh? (apply-foldlevel!))
    (folds-changed!)
    (set-buffer-local! 'folds-synced (buffer-version)))
  void)

(define (apply-foldlevel!)
  "Closes the folds deeper than foldlevel and opens the rest, as setting
   foldlevel does in Vim."
  (let ([ranges (map (lambda (f) (list (fold-first f) (fold-last f))) (buffer-folds))]
        [level (option 'foldlevel)])
    (for-each (lambda (f)
                (let ([closed? (> (fold-depth (list (fold-first f) (fold-last f)) ranges) level)])
                  (unless (eq? closed? (fold-closed? f))
                    (set-buffer-local! 'folds (map (lambda (e) (if (= (car e) (fold-id f)) (list (car e) closed?) e))
                                                   (fold-entries))))))
              (buffer-folds))
    (folds-changed!)))

;; Setting foldmethod (or foldexpr) works the folds out afresh; foldlevel
;; opens and closes them.
(add-hook! 'option-change
  (lambda (name value)
    (cond [(and (memq name '(foldmethod foldexpr)) (automatic-folds?)) (sync-folds! #t)]
          [(and (eq? name 'foldlevel) (pair? (fold-entries))) (apply-foldlevel!)])))

;; After a change outside insert state, and when insert ends.
(define (refresh-automatic-folds!)
  "Syncs the current buffer's folds to its text if it changed since."
  (when (and (automatic-folds?) (not (equal? (buffer-local 'folds-synced) (buffer-version))))
    (sync-folds! #f)))
(add-hook! 'post-command (lambda () (unless (typing-mode?) (refresh-automatic-folds!))))
(add-hook! 'insert-leave refresh-automatic-folds!)
;; A file opened with foldmethod set (in init.scm) starts with its folds.
(add-hook! 'buffer-open (lambda () (when (automatic-folds?) (sync-folds! #t))))
