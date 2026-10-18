;;; vim.scm -- Vim editing, imp's default.
;;;
;;; Vim's grammar is [count] operator [count] motion. Motions and operators
;;; are registered in tables, so anything defined later -- in init.scm or a
;;; package -- composes with everything else: a new motion works with d, c, y
;;; and `.` without further code.
;;;
;;; Dot-repeat stores the last change as a closure, not as keystrokes, so it
;;; repeats the command itself at the new cursor position.

;;; State

(define *mode* 'normal)        ; normal | insert | cmdline | visual
(define *visual* #f)           ; char | line while in visual mode
(define *visual-anchor* 0)     ; the end of the selection the cursor isn't on
(define *last-visual* #f)      ; (kind anchor cursor) for gv
(define *count* "")            ; digits typed so far
(define *operator* #f)         ; pending operator key, e.g. "d"
(define *operator-count* "")   ; count typed before the operator
(define *prefix* #f)           ; pending prefix key, e.g. "g"
(define *goal-col* 0)          ; column j/k try to keep
(define *register* "")         ; last yanked or deleted text
(define *register-linewise* #f)
(define *last-change* #f)      ; (lambda (count) ...) repeated by `.`
(define *last-change-count* 1)
(define *insert-entry* #f)     ; how the current insert began, for `.`
(define *insert-keys* '())     ; keys typed during the current insert, reversed
(define *cmdline* "")
;; True while running a command whose count the user typed, so G and gg can
;; tell "5G" from "G".
(define *count-given* #f)

(define (set-mode! mode)
  (set! *mode* mode)
  (cond
    [(eq? mode 'insert) (set-mode-name! "INSERT") (set-cursor-shape! "bar")]
    [(eq? mode 'cmdline) (set-mode-name! "COMMAND") (set-cursor-shape! "block")]
    [(eq? mode 'visual)
     (set-mode-name! (if (eq? *visual* 'line) "VISUAL LINE" "VISUAL"))
     (set-cursor-shape! "block")]
    [else (set-mode-name! "NORMAL") (set-cursor-shape! "block")]))

(define (reset-pending!)
  (set! *count* "")
  (set! *operator* #f)
  (set! *operator-count* "")
  (set! *prefix* #f))

;; In normal mode the cursor sits on a char, never on a line's end, unless the
;; line is empty.
(define (normal-clamp!)
  (let* ([line (current-line)]
         [len (buffer-line-length line)])
    (set-cursor! (line-col->offset line (clamp (current-col) 0 (max 0 (- len 1)))))))

;;; Motions
;;;
;;; A motion maps (from count) to a target offset and has a type that decides
;;; which chars an operator covers:
;;;   exclusive -- from..target, not including target
;;;   inclusive -- from..target, including target
;;;   linewise  -- every line from from's line to target's line

(define *motions* (hash))

(define (define-motion! key type proc)
  (set! *motions* (hash-insert *motions* key (list type proc))))

(define (motion-type m) (car m))
(define (motion-proc m) (cadr m))

(define (repeat-motion n step from)
  (let loop ([i 0] [p from])
    (if (< i n) (loop (+ i 1) (step p)) p)))

;; Char classes for word motions: 0 whitespace, 1 word, 2 punctuation.
(define (char-class c)
  (cond [(not c) 0]
        [(char-whitespace? c) 0]
        [(char-word? c) 1]
        [else 2]))

(define (class-at p) (char-class (buffer-char-at p)))

(define (next-word-start p)
  (let* ([len (buffer-length)]
         [cls (class-at p)]
         [after-word (let loop ([q p])
                       (if (and (< q len) (not (= cls 0)) (= (class-at q) cls))
                           (loop (+ q 1))
                           q))])
    (let loop ([q after-word])
      (if (and (< q len) (= (class-at q) 0))
          (loop (+ q 1))
          q))))

(define (prev-word-start p)
  (let* ([q (let loop ([q (- p 1)])
              (if (and (> q 0) (= (class-at q) 0)) (loop (- q 1)) q))]
         [cls (class-at q)])
    (let loop ([q q])
      (if (and (> q 0) (= (class-at (- q 1)) cls) (not (= cls 0)))
          (loop (- q 1))
          (max q 0)))))

(define (next-word-end p)
  (let* ([len (buffer-length)]
         [q (let loop ([q (+ p 1)])
              (if (and (< q len) (= (class-at q) 0)) (loop (+ q 1)) q))]
         [cls (class-at q)])
    (let loop ([q q])
      (if (and (< (+ q 1) len) (= (class-at (+ q 1)) cls) (not (= cls 0)))
          (loop (+ q 1))
          (min q (max 0 (- len 1)))))))

(define (vertical from n)
  (line-col->offset (clamp (+ (offset->line from) n) 0 (last-line)) *goal-col*))

(define-motion! "h" 'exclusive
  (lambda (from n) (max (line-start (offset->line from)) (- from n))))
(define-motion! "l" 'exclusive
  (lambda (from n) (min (line-end (offset->line from)) (+ from n))))
(define-motion! "j" 'linewise (lambda (from n) (vertical from n)))
(define-motion! "k" 'linewise (lambda (from n) (vertical from (- n))))
(define-motion! "w" 'exclusive (lambda (from n) (repeat-motion n next-word-start from)))
(define-motion! "b" 'exclusive (lambda (from n) (repeat-motion n prev-word-start from)))
(define-motion! "e" 'inclusive (lambda (from n) (repeat-motion n next-word-end from)))
(define-motion! "0" 'exclusive (lambda (from n) (line-start (offset->line from))))
(define-motion! "^" 'exclusive (lambda (from n) (line-first-nonblank (offset->line from))))
(define-motion! "$" 'inclusive
  (lambda (from n)
    (let ([line (clamp (+ (offset->line from) (- n 1)) 0 (last-line))])
      (max (line-start line) (- (line-end line) 1)))))
(define-motion! "G" 'linewise
  (lambda (from n) (line-first-nonblank (if *count-given* (- n 1) (last-line)))))
(define-motion! "gg" 'linewise
  (lambda (from n) (line-first-nonblank (if *count-given* (- n 1) 0))))
(define-motion! "<left>" 'exclusive (motion-proc (hash-ref *motions* "h")))
(define-motion! "<right>" 'exclusive (motion-proc (hash-ref *motions* "l")))
(define-motion! "<down>" 'linewise (motion-proc (hash-ref *motions* "j")))
(define-motion! "<up>" 'linewise (motion-proc (hash-ref *motions* "k")))

;; Vertical motions keep the goal column; everything else resets it.
(define (vertical-motion? key) (member key '("j" "k" "<down>" "<up>")))

;;; Operators
;;;
;;; An operator receives (start end linewise?) for the chars to act on.

(define *operators* (hash))

(define (define-operator! key proc)
  (set! *operators* (hash-insert *operators* key proc)))

;; Whole lines `first` through `last`, as (start end #t). The range always
;; starts at the beginning of `first`, so every linewise operator sees the
;; same shape; only `d` has to care about the file's final newline.
(define (lines-range first last)
  (list (line-start first)
        (if (< last (last-line)) (line-start (+ last 1)) (buffer-length))
        #t))

;; Linewise text is stored as whole lines, each ending in a line break.
(define (yank-range! start end linewise?)
  (let ([text (buffer-substring start end)])
    (set! *register*
          (if (and linewise? (not (ends-with? text "\n")))
              (string-append text "\n")
              text))
    (set! *register-linewise* linewise?)))

;; End of a linewise range without its final line break, if it has one.
(define (without-final-break start end)
  (if (and (> end start) (equal? (buffer-substring (- end 1) end) "\n"))
      (- end 1)
      end))

(define-operator! "d"
  (lambda (start end linewise?)
    (yank-range! start end linewise?)
    (if (and linewise? (= end (buffer-length)) (> start 0))
        ;; Deleting through the last line takes the line break before it
        ;; instead, so the file keeps its final newline.
        (buffer-delete! (- start 1) (without-final-break start end))
        (buffer-delete! start end))
    (set-cursor! (if linewise?
                     (line-first-nonblank (min (offset->line start) (last-line)))
                     start))))

(define-operator! "y"
  (lambda (start end linewise?)
    (yank-range! start end linewise?)
    (set-cursor! start)))

(define-operator! "c"
  (lambda (start end linewise?)
    (yank-range! start end linewise?)
    ;; A linewise change keeps the line itself: its text goes, its line
    ;; break stays.
    (buffer-delete! start (if linewise? (without-final-break start end) end))
    (set-cursor! start)
    (set-mode! 'insert)))

;; The range a motion covers from `from`, as (start end linewise?).
(define (motion-range from target type)
  (let ([lo (min from target)] [hi (max from target)])
    (cond
      [(eq? type 'linewise) (lines-range (offset->line lo) (offset->line hi))]
      [(eq? type 'inclusive) (list lo (min (+ hi 1) (buffer-length)) #f)]
      [else
       ;; An exclusive motion that crosses into a later line stops at the end
       ;; of the first one, so `dw` on a line's last word keeps the newline.
       (if (> (offset->line hi) (offset->line lo))
           (list lo (max lo (min hi (line-end (offset->line lo)))) #f)
           (list lo hi #f))])))

(define (run-operator! op-key motion-key count)
  (let* (;; Vim special case: `cw` on a word changes to its end, like `ce`,
         ;; leaving the space after it alone.
         [motion-key (if (and (equal? op-key "c") (equal? motion-key "w")
                              (not (= (class-at (cursor)) 0)))
                         "e"
                         motion-key)]
         [m (hash-ref *motions* motion-key)]
         [from (cursor)]
         [target ((motion-proc m) from count)]
         [range (motion-range from target (motion-type m))])
    (undo-boundary!)
    ((hash-ref *operators* op-key) (car range) (cadr range) (caddr range))))

;; `dd`, `cc`, `yy`: the operator over `count` whole lines.
(define (run-linewise-operator! op-key count)
  (let* ([from (cursor)]
         [target (line-start (clamp (+ (current-line) (- count 1)) 0 (last-line)))]
         [range (motion-range from target 'linewise)])
    (undo-boundary!)
    ((hash-ref *operators* op-key) (car range) (cadr range) (caddr range))))

;;; Text objects
;;;
;;; A text object maps (from count) straight to the range it selects, as
;;; (start end linewise?), or #f when there is nothing there. In
;;; operator-pending and visual mode, `i` and `a` are prefixes, so `diw`
;;; looks up "iw" here.

(define *text-objects* (hash))

(define (define-text-object! key proc)
  (set! *text-objects* (hash-insert *text-objects* key proc)))

;; WORD classes: anything that isn't white space is part of a WORD.
(define (big-class c)
  (cond [(not c) 0] [(char-whitespace? c) 0] [else 1]))

;; The run of chars sharing p's class, as far as `hi` (exclusive).
(define (run-end p classify hi)
  (let ([cls (classify (buffer-char-at p))])
    (let loop ([q p])
      (if (and (< q hi) (= (classify (buffer-char-at q)) cls)) (loop (+ q 1)) q))))

(define (run-start p classify lo)
  (let ([cls (classify (buffer-char-at p))])
    (let loop ([q p])
      (if (and (> q lo) (= (classify (buffer-char-at (- q 1))) cls)) (loop (- q 1)) q))))

(define (blank-at? p) (= (char-class (buffer-char-at p)) 0))

;; iw: `count` runs of word, punctuation or white space, on the cursor's line.
(define (inner-word classify)
  (lambda (from n)
    (let* ([line (offset->line from)] [lo (line-start line)] [hi (line-end line)])
      (if (= lo hi)
          #f
          (let loop ([i 1] [end (run-end from classify hi)])
            (if (and (< i n) (< end hi))
                (loop (+ i 1) (run-end end classify hi))
                (list (run-start from classify lo) end #f)))))))

;; aw: words with the white space after them; if a word has none after it,
;; the white space before it instead. From white space, the white space and
;; the word after it.
(define (a-word classify)
  (lambda (from n)
    (let* ([line (offset->line from)] [lo (line-start line)] [hi (line-end line)]
           [skip-word (lambda (p) (if (and (< p hi) (not (blank-at? p))) (run-end p classify hi) p))]
           [skip-blank (lambda (p) (if (and (< p hi) (blank-at? p)) (run-end p classify hi) p))])
      (cond
        [(= lo hi) #f]
        [(blank-at? from)
         (let loop ([i 0] [end (run-start from classify lo)])
           (if (< i n)
               (loop (+ i 1) (skip-word (skip-blank end)))
               (list (run-start from classify lo) end #f)))]
        [else
         (let* ([start (run-start from classify lo)]
                [word-end (run-end from classify hi)]
                [end (let loop ([i 1] [end (skip-blank word-end)])
                       (if (< i n) (loop (+ i 1) (skip-blank (skip-word end))) end))])
           (if (and (= end word-end) (> start lo) (blank-at? (- start 1)))
               (list (run-start (- start 1) classify lo) end #f)
               (list start end #f)))]))))

(define-text-object! "iw" (inner-word char-class))
(define-text-object! "aw" (a-word char-class))
(define-text-object! "iW" (inner-word big-class))
(define-text-object! "aW" (a-word big-class))

;; Quotes, on the cursor's line only, as in Vim. A quote preceded by a
;; backslash doesn't count.
(define (quote-positions q lo hi)
  (let loop ([p lo] [acc '()])
    (cond
      [(>= p hi) (reverse acc)]
      [(and (equal? (buffer-char-at p) q)
            (not (and (> p lo) (equal? (buffer-char-at (- p 1)) #\\))))
       (loop (+ p 1) (cons p acc))]
      [else (loop (+ p 1) acc)])))

;; The (open close) pair of quotes around `from`. Quotes pair up from the
;; start of the line; if the cursor isn't inside a pair, the next pair after
;; it on the line is used.
(define (quote-pair q from)
  (let* ([line (offset->line from)]
         [qs (quote-positions q (line-start line) (line-end line))])
    (let loop ([qs qs])
      (cond
        [(or (null? qs) (null? (cdr qs))) #f]
        [(<= from (cadr qs)) (list (car qs) (cadr qs))]
        [else (loop (cddr qs))]))))

(define (quote-object q around?)
  (lambda (from n)
    (let ([pair (quote-pair q from)])
      (cond
        [(not pair) #f]
        [(not around?) (list (+ (car pair) 1) (cadr pair) #f)]
        [else
         (let* ([open (car pair)] [close (+ (cadr pair) 1)]
                [hi (line-end (offset->line open))] [lo (line-start (offset->line open))]
                [after (let loop ([p close]) (if (and (< p hi) (blank-at? p)) (loop (+ p 1)) p))])
           (if (> after close)
               (list open after #f)
               (list (let loop ([p open]) (if (and (> p lo) (blank-at? (- p 1))) (loop (- p 1)) p))
                     close #f)))]))))

(for-each
 (lambda (q)
   (define-text-object! (string-append "i" (string q)) (quote-object q #f))
   (define-text-object! (string-append "a" (string q)) (quote-object q #t)))
 (list #\" #\' #\`))

;; Brackets. The count picks the nth enclosing pair. A bracket under the
;; cursor belongs to the pair it opens or closes.
(define (find-open open close from n)
  (let loop ([q from] [depth 0] [n n])
    (if (< q 0)
        #f
        (let ([c (buffer-char-at q)])
          (cond
            [(and (equal? c close) (not (= q from))) (loop (- q 1) (+ depth 1) n)]
            [(equal? c open)
             (cond [(> depth 0) (loop (- q 1) (- depth 1) n)]
                   [(= n 1) q]
                   [else (loop (- q 1) 0 (- n 1))])]
            [else (loop (- q 1) depth n)])))))

(define (find-close open close from)
  (let ([len (buffer-length)])
    (let loop ([q from] [depth 0])
      (if (>= q len)
          #f
          (let ([c (buffer-char-at q)])
            (cond
              [(equal? c open) (loop (+ q 1) (+ depth 1))]
              [(equal? c close) (if (= depth 0) q (loop (+ q 1) (- depth 1)))]
              [else (loop (+ q 1) depth)]))))))

(define (only-blanks-before? p)
  (let ([lo (line-start (offset->line p))])
    (let loop ([q lo]) (cond [(= q p) #t] [(blank-at? q) (loop (+ q 1))] [else #f]))))

(define (bracket-object open close around?)
  (lambda (from n)
    (let* ([o (find-open open close from n)]
           [c (and o (find-close open close (+ o 1)))])
      (cond
        [(not c) #f]
        [around? (list o (+ c 1) #f)]
        ;; A block whose brackets end and begin lines, as in
        ;;   if x {
        ;;       body
        ;;   }
        ;; selects the lines between them.
        [(and (equal? (buffer-char-at (+ o 1)) #\newline)
              (only-blanks-before? c)
              (> (offset->line c) (+ (offset->line o) 1)))
         (lines-range (+ (offset->line o) 1) (- (offset->line c) 1))]
        [else (list (+ o 1) c #f)]))))

(for-each
 (lambda (spec)
   (let ([open (car spec)] [close (cadr spec)])
     (for-each
      (lambda (name)
        (define-text-object! (string-append "i" name) (bracket-object open close #f))
        (define-text-object! (string-append "a" name) (bracket-object open close #t)))
      (cddr spec))))
 (list (list #\( #\) "(" ")" "b")
       (list #\[ #\] "[" "]")
       (list #\{ #\} "{" "}" "B")
       (list #\< #\> "<" ">")))

;; Tags: <name ...> ... </name>. Every tag in the buffer is paired with a
;; stack, then the count picks the nth innermost pair around the cursor.
(define (tag-name-end p)
  (let ([len (buffer-length)])
    (let loop ([q p])
      (let ([c (buffer-char-at q)])
        (if (and (< q len) c (not (char-whitespace? c)) (not (memv c (list #\> #\/))))
            (loop (+ q 1))
            q)))))

(define (char-after-tag p)
  (let ([len (buffer-length)])
    (let loop ([q p]) (cond [(>= q len) #f] [(equal? (buffer-char-at q) #\>) (+ q 1)] [else (loop (+ q 1))]))))

;; List of (open-start open-end close-start close-end) for every tag pair.
(define (tag-pairs)
  (let ([len (buffer-length)])
    (let loop ([p 0] [stack '()] [pairs '()])
      (cond
        [(>= p len) pairs]
        [(not (equal? (buffer-char-at p) #\<)) (loop (+ p 1) stack pairs)]
        [else
         (let* ([closing? (equal? (buffer-char-at (+ p 1)) #\/)]
                [name-start (if closing? (+ p 2) (+ p 1))]
                [name-end (tag-name-end name-start)]
                [name (buffer-substring name-start name-end)]
                [end (char-after-tag name-end)])
           (cond
             [(or (not end) (equal? name "")) (loop (+ p 1) stack pairs)]
             [closing?
              ;; Pop to the matching open tag, dropping unclosed ones (<br>).
              (let pop ([s stack])
                (cond
                  [(null? s) (loop end stack pairs)]
                  [(equal? (car (car s)) name)
                   (loop end (cdr s)
                         (cons (list (cadr (car s)) (caddr (car s)) p end) pairs))]
                  [else (pop (cdr s))]))]
             [(equal? (buffer-char-at (- end 2)) #\/) (loop end stack pairs)]
             [else (loop end (cons (list name p end) stack) pairs)]))]))))

(define (tag-object around?)
  (lambda (from n)
    (let* ([around (filter (lambda (t) (and (<= (car t) from) (< from (cadddr t)))) (tag-pairs))]
           ;; Innermost first: the latest-opening pair is the innermost.
           [sorted (sort around (lambda (a b) (> (car a) (car b))))])
      (if (< (length sorted) n)
          #f
          (let ([t (list-ref sorted (- n 1))])
            (if around?
                (list (car t) (cadddr t) #f)
                (list (cadr t) (caddr t) #f)))))))

(define-text-object! "it" (tag-object #f))
(define-text-object! "at" (tag-object #t))

;; Paragraphs: runs of non-blank lines, separated by runs of blank lines
;; (lines that are empty or only white space). Each run counts once.
(define (blank-line? line)
  (let ([end (line-end line)])
    (let loop ([p (line-start line)])
      (cond [(= p end) #t] [(blank-at? p) (loop (+ p 1))] [else #f]))))

(define (run-last-line line)
  (let ([blank (blank-line? line)])
    (let loop ([l line])
      (if (and (< l (last-line)) (eq? (blank-line? (+ l 1)) blank)) (loop (+ l 1)) l))))

(define (run-first-line line)
  (let ([blank (blank-line? line)])
    (let loop ([l line])
      (if (and (> l 0) (eq? (blank-line? (- l 1)) blank)) (loop (- l 1)) l))))

;; The last line after `n` runs starting at `line`.
(define (runs-forward line n)
  (let loop ([i 1] [last (run-last-line line)])
    (if (and (< i n) (< last (last-line)))
        (loop (+ i 1) (run-last-line (+ last 1)))
        last)))

(define-text-object! "ip"
  (lambda (from n)
    (let ([line (offset->line from)])
      (lines-range (run-first-line line) (runs-forward line n)))))

;; ap: a paragraph and the blank lines after it, or before it if there are
;; none after. From blank lines, the blanks and the paragraph after them.
(define-text-object! "ap"
  (lambda (from n)
    (let* ([line (offset->line from)]
           [first (run-first-line line)]
           [last (runs-forward line (* 2 n))])
      (if (or (blank-line? line) (blank-line? last) (= first 0))
          (lines-range first last)
          (let ([before (- first 1)])
            (lines-range (if (blank-line? before) (run-first-line before) first) last))))))

(define (run-text-object! op-key object-key count)
  (let ([range ((hash-ref *text-objects* object-key) (cursor) count)])
    (when range
      (undo-boundary!)
      ((hash-ref *operators* op-key) (car range) (cadr range) (caddr range)))))

;;; Changes and dot-repeat

(define (changing-operator? key) (not (equal? key "y")))

;; Records `change` as the thing `.` repeats. If it ends in insert mode, the
;; record is completed when insert mode exits, with the text that was typed.
(define (record-change! change count)
  (set! *last-change-count* count)
  (if (eq? *mode* 'insert)
      (begin (set! *insert-entry* change) (set! *insert-keys* '()))
      (set! *last-change* change)))

(define (finish-insert-record!)
  (let ([entry *insert-entry*] [keys (reverse *insert-keys*)])
    (when entry
      (set! *last-change*
            (lambda (count)
              (entry count)
              (for-each insert-key! keys)
              (leave-insert!))))
    (set! *insert-entry* #f)))

;;; Normal mode commands
;;;
;;; Commands in the normal keymap take the count (1 if none was typed).

(define (enter-insert! where)
  (lambda (count)
    (undo-boundary!)
    (let ([line (current-line)])
      (cond
        [(eq? where 'after) (set-cursor! (min (+ (cursor) 1) (line-end line)))]
        [(eq? where 'line-end) (set-cursor! (line-end line))]
        [(eq? where 'line-start) (set-cursor! (line-first-nonblank line))]
        [(eq? where 'below)
         (set-cursor! (line-end line))
         (buffer-insert! (cursor) "\n")
         (set-cursor! (+ (cursor) 1))]
        [(eq? where 'above)
         (set-cursor! (line-start line))
         (buffer-insert! (cursor) "\n")]
        [else #t]))
    (set-mode! 'insert)))

(define (insert-command! key where)
  (define-key! 'normal key
    (let ([enter (enter-insert! where)])
      (lambda (count)
        (enter count)
        (record-change! enter count)))))

(insert-command! "i" 'here)
(insert-command! "a" 'after)
(insert-command! "A" 'line-end)
(insert-command! "I" 'line-start)
(insert-command! "o" 'below)
(insert-command! "O" 'above)

;; A command made of an operator and a motion, like x = dl.
(define (operator-command! key op-key motion-key)
  (define-key! 'normal key
    (lambda (count)
      (let ([change (lambda (n) (run-operator! op-key motion-key n))])
        (change count)
        (record-change! change count)))))

(operator-command! "x" "d" "l")
(operator-command! "X" "d" "h")
(operator-command! "D" "d" "$")
(operator-command! "C" "c" "$")
(operator-command! "s" "c" "l")

(define (paste! after?)
  (lambda (count)
    (undo-boundary!)
    (let ([text *register*])
      (if *register-linewise*
          (let* ([line (current-line)]
                 [at (if after?
                         (if (< line (last-line)) (line-start (+ line 1)) (buffer-length))
                         (line-start line))]
                 ;; At the end of a file with no final newline, the break goes
                 ;; before the pasted lines instead of after them.
                 [no-break? (and (= at (buffer-length)) (> at 0)
                                 (not (equal? (buffer-substring (- at 1) at) "\n")))]
                 [text (if no-break?
                           (string-append "\n" (substring text 0 (- (string-length text) 1)))
                           text)])
            (buffer-insert! at text)
            (set-cursor! (line-first-nonblank (if after? (+ line 1) line))))
          (let ([at (if after? (min (+ (cursor) 1) (line-end (current-line))) (cursor))])
            (buffer-insert! at text)
            (set-cursor! (+ at (- (string-length text) 1))))))))

(define-key! 'normal "p"
  (lambda (count) ((paste! #t) count) (record-change! (paste! #t) count)))
(define-key! 'normal "P"
  (lambda (count) ((paste! #f) count) (record-change! (paste! #f) count)))

(define-key! 'normal "u"
  (lambda (count)
    (unless (undo!) (set-status! "already at oldest change"))
    (set-cursor! (cursor))))
(define-key! 'normal "C-r"
  (lambda (count)
    (unless (redo!) (set-status! "already at newest change"))))

(define-key! 'normal "."
  (lambda (count)
    (when *last-change*
      (*last-change* (if *count-given* count *last-change-count*)))))

(define-key! 'normal ":"
  (lambda (count)
    (set! *cmdline* "")
    (set-mode! 'cmdline)
    (set-status! ":")))

;;; Visual mode
;;;
;;; The selection runs from *visual-anchor* to the cursor, both included.
;;; Motions move the cursor, text objects grow the selection, and operators
;;; act on it and return to normal mode.

(define (enter-visual! kind anchor)
  (set! *visual* kind)
  (set! *visual-anchor* anchor)
  (set-mode! 'visual))

(define (leave-visual!)
  (set! *last-visual* (list *visual* *visual-anchor* (cursor)))
  (set! *visual* #f)
  (set-mode! 'normal))

;; The selection as (start end linewise?).
(define (visual-range)
  (let ([lo (min *visual-anchor* (cursor))] [hi (max *visual-anchor* (cursor))])
    (if (eq? *visual* 'line)
        (lines-range (offset->line lo) (offset->line hi))
        (list lo (min (+ hi 1) (buffer-length)) #f))))

(define (update-visual-highlight!)
  (highlight-clear! "visual")
  (when (eq? *mode* 'visual)
    (let ([r (visual-range)])
      (highlight-add! "visual" (car r) (cadr r) "visual"))))

;; v, V: start a selection, or switch kind, or leave if already that kind.
(define (visual-command! kind)
  (lambda (count)
    (cond
      [(not (eq? *mode* 'visual)) (enter-visual! kind (cursor))]
      [(eq? *visual* kind) (leave-visual!)]
      [else (set! *visual* kind) (set-mode! 'visual)])))

(define-key! 'normal "v" (visual-command! 'char))
(define-key! 'normal "V" (visual-command! 'line))
(define-key! 'visual "v" (visual-command! 'char))
(define-key! 'visual "V" (visual-command! 'line))
(define-key! 'visual "<esc>" (lambda (count) (leave-visual!)))
(define-key! 'visual "C-c" (lambda (count) (leave-visual!)))

(define-key! 'visual "o"
  (lambda (count)
    (let ([anchor *visual-anchor*])
      (set! *visual-anchor* (cursor))
      (set-cursor! anchor))))

(define-key! 'normal "gv"
  (lambda (count)
    (when *last-visual*
      (enter-visual! (car *last-visual*) (cadr *last-visual*))
      (set-cursor! (caddr *last-visual*)))))

;; A text object in visual mode selects the object, taking in the current
;; selection if it is larger than one char.
(define (visual-text-object! key count)
  (let ([range ((hash-ref *text-objects* key) (cursor) count)])
    (when range
      (let* ([start (car range)] [end (max (car range) (- (cadr range) 1))])
        (if (= *visual-anchor* (cursor))
            (set! *visual-anchor* start)
            (set! *visual-anchor* (min *visual-anchor* start)))
        (set-cursor! (max (cursor) end))
        (when (and (caddr range) (eq? *visual* 'char))
          (set! *visual* 'line)
          (set-mode! 'visual))))))

;; How to repeat a visual operator with `.`: the same number of lines, or of
;; chars, from wherever the cursor is then.
(define (visual-repeat op-key range)
  (let* ([start (car range)] [end (cadr range)] [linewise? (caddr range)]
         [lines (- (offset->line (max start (- end 1))) (offset->line start))]
         [chars (- end start)])
    (lambda (n)
      (undo-boundary!)
      (let ([r (if linewise?
                   (lines-range (current-line) (min (last-line) (+ (current-line) lines)))
                   (list (cursor) (min (buffer-length) (+ (cursor) chars)) #f))])
        ((hash-ref *operators* op-key) (car r) (cadr r) (caddr r))))))

(define (visual-operator! op-key linewise?)
  (let ([range (if linewise?
                   (let ([r (visual-range)])
                     (lines-range (offset->line (car r)) (offset->line (max (car r) (- (cadr r) 1)))))
                   (visual-range))])
    (leave-visual!)
    (undo-boundary!)
    ((hash-ref *operators* op-key) (car range) (cadr range) (caddr range))
    (when (changing-operator? op-key)
      (record-change! (visual-repeat op-key range) 1))))

;; Visual shorthands: x is d, s is c; the capitals act on whole lines.
(for-each
 (lambda (spec)
   (define-key! 'visual (car spec)
     (lambda (count) (visual-operator! (cadr spec) (caddr spec)))))
 (list (list "x" "d" #f) (list "s" "c" #f)
       (list "X" "d" #t) (list "D" "d" #t) (list "Y" "y" #t)
       (list "C" "c" #t) (list "S" "c" #t) (list "R" "c" #t)))

;; p in visual replaces the selection with the register, and the replaced
;; text becomes the register, so pasting again swaps back.
(define-key! 'visual "p"
  (lambda (count)
    (let* ([text *register*] [text-linewise? *register-linewise*]
           [range (visual-range)] [start (car range)] [linewise? (caddr range)])
      (leave-visual!)
      (undo-boundary!)
      (yank-range! start (cadr range) linewise?)
      (buffer-delete! start (if linewise? (without-final-break start (cadr range)) (cadr range)))
      (let ([text (cond
                    [(and text-linewise? linewise?) (without-final-newline text)]
                    [text-linewise? (string-append "\n" text)]
                    [else text])])
        (buffer-insert! start text)
        (set-cursor! (if text-linewise?
                         (line-first-nonblank (offset->line (if linewise? start (+ start 1))))
                         (max start (- (+ start (string-length text)) 1))))))))

(define (without-final-newline text)
  (if (ends-with? text "\n") (substring text 0 (- (string-length text) 1)) text))

;;; Normal mode dispatch

(define (digit? key)
  (and (= (string-length key) 1)
       (char-numeric-ascii? (string-ref key 0))))

(define (char-numeric-ascii? c)
  (let ([n (char->integer c)]) (and (>= n 48) (<= n 57))))

(define (count-value s) (if (equal? s "") 1 (string->number s)))

(define (normal-key! key)
  (cond
    [(and (member key '("<esc>" "C-c")) (or *operator* *prefix* (not (equal? *count* ""))))
     (reset-pending!)]
    [(and (member key '("<esc>" "C-c")) (not (eq? *mode* 'visual)))
     (reset-pending!)]

    ;; Counts. A leading 0 is the motion, not a count.
    [(and (digit? key) (not (and (equal? key "0") (equal? *count* ""))))
     (set! *count* (string-append *count* key))]

    ;; Prefix keys: `g` waits for the next key.
    [(and (not *prefix*) (equal? key "g"))
     (set! *prefix* "g")]
    [(and (or *operator* (eq? *mode* 'visual)) (not *prefix*) (member key '("i" "a")))
     (set! *prefix* key)]

    [else
     (let* ([key (if *prefix* (string-append *prefix* key) key)]
            [given (or (not (equal? *count* "")) (not (equal? *operator-count* "")))]
            ;; 2d3w deletes six words: the two counts multiply.
            [count (* (count-value *operator-count*) (count-value *count*))])
       (set! *prefix* #f)
       (set! *count-given* given)
       (cond
         ;; An operator is pending: this key is its motion, or the operator
         ;; again for the linewise form (dd).
         [*operator*
          (let ([op *operator*])
            (cond
              [(hash-contains? *motions* key)
               (let ([change (lambda (n) (run-operator! op key n))])
                 (set! *operator* #f)
                 (change count)
                 (when (changing-operator? op) (record-change! change count)))]
              [(hash-contains? *text-objects* key)
               (let ([change (lambda (n) (run-text-object! op key n))])
                 (set! *operator* #f)
                 (change count)
                 (when (changing-operator? op) (record-change! change count)))]
              [(equal? key op)
               (let ([change (lambda (n) (run-linewise-operator! op n))])
                 (set! *operator* #f)
                 (change count)
                 (when (changing-operator? op) (record-change! change count)))]
              [else (set-status! (string-append "no motion " key))]))
          (set! *count* "")
          (set! *operator-count* "")]

         [(and (eq? *mode* 'visual) (hash-contains? *operators* key))
          (visual-operator! key #f)
          (set! *count* "")]

         [(and (eq? *mode* 'visual) (hash-contains? *text-objects* key))
          (visual-text-object! key count)
          (set! *count* "")]

         [(and (eq? *mode* 'visual) (lookup-key 'visual key))
          ((lookup-key 'visual key) count)
          (set! *count* "")]

         [(hash-contains? *operators* key)
          (set! *operator* key)
          (set! *operator-count* *count*)
          (set! *count* "")]

         [(hash-contains? *motions* key)
          (set-cursor! ((motion-proc (hash-ref *motions* key)) (cursor) count))
          (set! *count* "")]

         [(and (not (eq? *mode* 'visual)) (lookup-key 'normal key))
          ((lookup-key 'normal key) count)
          (set! *count* "")]

         [else
          (set! *count* "")
          (set-status! (string-append "no binding for " key))])
       (set! *count-given* #f))])

  (when (member *mode* '(normal visual))
    (normal-clamp!)
    (unless (or *operator* (vertical-motion? key))
      (set! *goal-col* (current-col)))))

;;; Insert mode

(define (insert-key! key)
  (cond
    [(equal? key "<ret>") (insert-text! "\n")]
    [(equal? key "<tab>") (insert-text! "\t")]
    [(equal? key "<bs>")
     (when (> (cursor) 0)
       (buffer-delete! (- (cursor) 1) (cursor))
       (set-cursor! (- (cursor) 1)))]
    [(equal? key "<left>") (set-cursor! (max (line-start (current-line)) (- (cursor) 1)))]
    [(equal? key "<right>") (set-cursor! (min (line-end (current-line)) (+ (cursor) 1)))]
    [(= (string-length key) 1) (insert-text! key)]
    [(lookup-key 'insert key) ((lookup-key 'insert key))]
    [else #t]))

(define (insert-text! text)
  (buffer-insert! (cursor) text)
  (set-cursor! (+ (cursor) (string-length text))))

(define (leave-insert!)
  (set-mode! 'normal)
  ;; Leaving insert mode steps back onto the last inserted char.
  (when (> (current-col) 0)
    (set-cursor! (- (cursor) 1)))
  (normal-clamp!)
  (set! *goal-col* (current-col)))

(define (insert-mode-key! key)
  (if (member key '("<esc>" "C-c"))
      (begin (leave-insert!) (finish-insert-record!))
      (begin
        (set! *insert-keys* (cons key *insert-keys*))
        (insert-key! key))))

;;; Command line (:w, :q, ...)

(define *ex-commands* (hash))

(define (define-ex! name proc)
  (set! *ex-commands* (hash-insert *ex-commands* name proc)))

(define-ex! "w" (lambda () (when (save!) (set-status! (string-append "wrote " (buffer-name))))))
(define-ex! "q"
  (lambda ()
    (if (buffer-modified?)
        (set-status! "unsaved changes (add ! to override)")
        (quit!))))
(define-ex! "q!" (lambda () (quit!)))
(define-ex! "wq" (lambda () (when (save!) (quit!))))
(define-ex! "x" (lambda () (if (buffer-modified?) (when (save!) (quit!)) (quit!))))

(define (run-ex! line)
  (let ([cmd (hash-try-get *ex-commands* line)])
    (cond
      [cmd (set-status! "") (cmd)]
      [(string->number line)
       (set-cursor! (line-first-nonblank (clamp (- (string->number line) 1) 0 (last-line))))
       (set-status! "")]
      [(equal? line "") (set-status! "")]
      [else (set-status! (string-append "not an editor command: " line))])))

(define (cmdline-key! key)
  (cond
    [(member key '("<esc>" "C-c"))
     (set-mode! 'normal)
     (set-status! "")]
    [(equal? key "<ret>")
     (set-mode! 'normal)
     (run-ex! *cmdline*)
     (when (eq? *mode* 'normal) (normal-clamp!))]
    [(equal? key "<bs>")
     (if (equal? *cmdline* "")
         (begin (set-mode! 'normal) (set-status! ""))
         (begin
           (set! *cmdline* (substring *cmdline* 0 (- (string-length *cmdline*) 1)))
           (set-status! (string-append ":" *cmdline*))))]
    [(= (string-length key) 1)
     (set! *cmdline* (string-append *cmdline* key))
     (set-status! (string-append ":" *cmdline*))]
    [else #t]))

;;; Entry points

(define (imp-init)
  (set-mode! 'normal)
  (normal-clamp!))

(define (imp-handle-key key)
  (cond
    [(eq? *mode* 'insert) (insert-mode-key! key)]
    [(eq? *mode* 'cmdline) (cmdline-key! key)]
    [else
     ;; A fresh command clears the last message.
     (when (and (not *operator*) (not *prefix*) (equal? *count* ""))
       (set-status! ""))
     (normal-key! key)])
  (update-visual-highlight!))
