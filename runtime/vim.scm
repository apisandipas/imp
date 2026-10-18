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
(define *cmdline* "")           ; text typed at the prompt
(define *cmdline-prompt* ":")
(define *cmdline-submit* #f)   ; (lambda (text) ...) on <ret>
(define *cmdline-change* #f)   ; (lambda (text) ...) after each edit
(define *cmdline-cancel* #f)   ; (lambda () ...) on <esc>
(define *cmdline-return* 'normal) ; the mode to go back to
(define *last-search* #f)      ; the last search pattern
(define *last-search-forward* #t)
(define *hlsearch* #f)         ; whether matches of *last-search* are shown
(define *last-substitute* #f)  ; (pattern replacement) for :s and &
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

;; WORD classes: anything that isn't white space is part of a WORD.
(define (big-class c)
  (cond [(not c) 0] [(char-whitespace? c) 0] [else 1]))

(define (class-at p) (char-class (buffer-char-at p)))

;; Word motions take the classifier, char-class for words (w b e ge) or
;; big-class for WORDs (W B E gE).
(define (next-word-start p classify)
  (let* ([len (buffer-length)]
         [cls-at (lambda (q) (classify (buffer-char-at q)))]
         [cls (cls-at p)]
         [after-word (let loop ([q p])
                       (if (and (< q len) (not (= cls 0)) (= (cls-at q) cls))
                           (loop (+ q 1))
                           q))])
    (let loop ([q after-word])
      (if (and (< q len) (= (cls-at q) 0))
          (loop (+ q 1))
          q))))

(define (prev-word-start p classify)
  (let* ([cls-at (lambda (q) (classify (buffer-char-at q)))]
         [q (let loop ([q (- p 1)])
              (if (and (> q 0) (= (cls-at q) 0)) (loop (- q 1)) q))]
         [cls (cls-at q)])
    (let loop ([q q])
      (if (and (> q 0) (= (cls-at (- q 1)) cls) (not (= cls 0)))
          (loop (- q 1))
          (max q 0)))))

(define (next-word-end p classify)
  (let* ([len (buffer-length)]
         [cls-at (lambda (q) (classify (buffer-char-at q)))]
         [q (let loop ([q (+ p 1)])
              (if (and (< q len) (= (cls-at q) 0)) (loop (+ q 1)) q))]
         [cls (cls-at q)])
    (let loop ([q q])
      (if (and (< (+ q 1) len) (= (cls-at (+ q 1)) cls) (not (= cls 0)))
          (loop (+ q 1))
          (min q (max 0 (- len 1)))))))

;; ge: back to the end of the previous word.
(define (prev-word-end p classify)
  (let* ([cls-at (lambda (q) (classify (buffer-char-at q)))]
         [cls (cls-at p)]
         [q (let loop ([q p])
              (if (and (> q 0) (not (= cls 0)) (= (cls-at q) cls)) (loop (- q 1)) q))])
    (let loop ([q q])
      (if (and (> q 0) (= (cls-at q) 0)) (loop (- q 1)) q))))

(define (word-motion step classify)
  (lambda (from n) (repeat-motion n (lambda (p) (step p classify)) from)))

(define (vertical from n)
  (line-col->offset (clamp (+ (offset->line from) n) 0 (last-line)) *goal-col*))

(define-motion! "h" 'exclusive
  (lambda (from n) (max (line-start (offset->line from)) (- from n))))
(define-motion! "l" 'exclusive
  (lambda (from n) (min (line-end (offset->line from)) (+ from n))))
(define-motion! "j" 'linewise (lambda (from n) (vertical from n)))
(define-motion! "k" 'linewise (lambda (from n) (vertical from (- n))))
(define-motion! "w" 'exclusive (word-motion next-word-start char-class))
(define-motion! "b" 'exclusive (word-motion prev-word-start char-class))
(define-motion! "e" 'inclusive (word-motion next-word-end char-class))
(define-motion! "ge" 'inclusive (word-motion prev-word-end char-class))
(define-motion! "W" 'exclusive (word-motion next-word-start big-class))
(define-motion! "B" 'exclusive (word-motion prev-word-start big-class))
(define-motion! "E" 'inclusive (word-motion next-word-end big-class))
(define-motion! "gE" 'inclusive (word-motion prev-word-end big-class))
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
(define-motion! "<home>" 'exclusive (motion-proc (hash-ref *motions* "0")))
(define-motion! "<end>" 'inclusive (motion-proc (hash-ref *motions* "$")))
;; No line wrapping yet, so display lines are buffer lines.
(define-motion! "gj" 'linewise (motion-proc (hash-ref *motions* "j")))
(define-motion! "gk" 'linewise (motion-proc (hash-ref *motions* "k")))

(define (line-motion offset)
  (lambda (from n)
    (line-first-nonblank (clamp (+ (offset->line from) (offset n)) 0 (last-line)))))

(define-motion! "+" 'linewise (line-motion (lambda (n) n)))
(define-motion! "<ret>" 'linewise (line-motion (lambda (n) n)))
(define-motion! "-" 'linewise (line-motion (lambda (n) (- n))))
(define-motion! "_" 'linewise (line-motion (lambda (n) (- n 1))))
(define-motion! "|" 'exclusive
  (lambda (from n) (line-col->offset (offset->line from) (- n 1))))

;; % jumps between matching brackets: the one under the cursor, or the next
;; one on the line. With a count, N% goes N percent of the way into the file.
(define *bracket-pairs* (list (list #\( #\)) (list #\[ #\]) (list #\{ #\})))

(define (bracket-match from)
  (let* ([hi (line-end (offset->line from))]
         [p (let loop ([p from])
              (cond [(>= p hi) #f]
                    [(memv (buffer-char-at p) (list #\( #\) #\[ #\] #\{ #\})) p]
                    [else (loop (+ p 1))]))])
    (and p
         (let* ([c (buffer-char-at p)]
                [pair (let loop ([ps *bracket-pairs*])
                        (if (memv c (car ps)) (car ps) (loop (cdr ps))))]
                [open (car pair)] [close (cadr pair)])
           (if (equal? c open)
               (find-close open close (+ p 1))
               (and (> p 0) (find-open open close (- p 1) 1)))))))

(define-motion! "%" 'inclusive
  (lambda (from n)
    (if *count-given*
        (line-first-nonblank (- (clamp (quotient (+ (* n (buffer-line-count)) 99) 100) 1 (+ (last-line) 1)) 1))
        (bracket-match from))))

;; { and }: back and forward to the next empty line.
(define (empty-line? line) (= (buffer-line-length line) 0))

(define (paragraph-forward from n)
  (let loop ([i 0] [line (offset->line from)])
    (if (= i n)
        (if (empty-line? line) (line-start line) (line-end line))
        (let* ([l (let skip ([l line]) (if (and (< l (last-line)) (empty-line? l)) (skip (+ l 1)) l))]
               [l (let skip ([l l]) (if (and (< l (last-line)) (not (empty-line? l))) (skip (+ l 1)) l))])
          (loop (+ i 1) l)))))

(define (paragraph-backward from n)
  (let loop ([i 0] [line (offset->line from)])
    (if (= i n)
        (line-start line)
        (let* ([l (let skip ([l line]) (if (and (> l 0) (empty-line? l)) (skip (- l 1)) l))]
               [l (let skip ([l l]) (if (and (> l 0) (not (empty-line? l))) (skip (- l 1)) l))])
          (loop (+ i 1) l)))))

(define-motion! "}" 'exclusive paragraph-forward)
(define-motion! "{" 'exclusive paragraph-backward)

;; H, M and L: lines of the window.
(define (window-bottom) (min (last-line) (+ (window-top) (window-height) -1)))

(define-motion! "H" 'linewise
  (lambda (from n) (line-first-nonblank (min (window-bottom) (+ (window-top) (- n 1))))))
(define-motion! "L" 'linewise
  (lambda (from n) (line-first-nonblank (max (window-top) (- (window-bottom) (- n 1))))))
(define-motion! "M" 'linewise
  (lambda (from n)
    (line-first-nonblank (+ (window-top) (quotient (- (window-bottom) (window-top)) 2)))))

;;; Motions that take a char: f F t T
;;;
;;; (define-char-motion! key type proc) makes `key` a prefix; `proc` is
;;; (lambda (from count char) target) and `fx` becomes a motion like any
;;; other, so it works with operators, visual mode and `.`.

(define *char-motions* (hash))
(define *last-char-search* #f) ; (key char) for ; and ,

(define (define-char-motion! key type proc)
  (set! *char-motions* (hash-insert *char-motions* key (list type proc))))

;; The char named by a key: "x" is x, "<tab>" a tab. Other named keys are
;; not chars.
(define (key-char key)
  (cond [(= (string-length key) 1) (string-ref key 0)]
        [(equal? key "<tab>") #\tab]
        [(equal? key "<space>") #\space]
        [else #f]))

;; The `n`th `ch` on the line, forward or backward. `till?` stops one short
;; of it; `skip-adjacent?` (for ; after t) doesn't count one right next to
;; the cursor, so repeating t moves on.
(define (char-search from n ch forward? till? skip-adjacent?)
  (let* ([line (offset->line from)] [lo (line-start line)] [hi (line-end line)]
         [step (if forward? 1 -1)])
    (let loop ([p (+ from (if (and till? skip-adjacent?) (* 2 step) step))] [k n])
      (cond [(or (< p lo) (>= p hi)) #f]
            [(equal? (buffer-char-at p) ch)
             (if (= k 1) (if till? (- p step) p) (loop (+ p step) (- k 1)))]
            [else (loop (+ p step) k)]))))

(define-char-motion! "f" 'inclusive (lambda (from n ch) (char-search from n ch #t #f #f)))
(define-char-motion! "F" 'exclusive (lambda (from n ch) (char-search from n ch #f #f #f)))
(define-char-motion! "t" 'inclusive (lambda (from n ch) (char-search from n ch #t #t #f)))
(define-char-motion! "T" 'exclusive (lambda (from n ch) (char-search from n ch #f #t #f)))

(define (reverse-char-key key)
  (cond [(equal? key "f") "F"] [(equal? key "F") "f"] [(equal? key "t") "T"] [else "t"]))

;; ; and , repeat the last f F t T, in the same or the other direction.
(define (repeat-char-motion reverse?)
  (and *last-char-search*
       (let* ([key (if reverse? (reverse-char-key (car *last-char-search*)) (car *last-char-search*))]
              [ch (cadr *last-char-search*)]
              [forward? (member key '("f" "t"))]
              [till? (member key '("t" "T"))])
         (list (car (hash-ref *char-motions* key))
               (lambda (from n) (char-search from n ch forward? till? #t))))))

;; The motion for `key`, as (type proc), or #f. Besides the motion table
;; this covers char motions (fx) and ; and ,.
(define (find-motion key)
  (cond
    [(hash-try-get *motions* key) => (lambda (m) m)]
    [(equal? key ";") (repeat-char-motion #f)]
    [(equal? key ",") (repeat-char-motion #t)]
    [(and (> (string-length key) 1) (hash-try-get *char-motions* (substring key 0 1)))
     => (lambda (m)
          (let ([ch (key-char (substring key 1 (string-length key)))]
                [prefix (substring key 0 1)])
            (and ch
                 (list (car m)
                       (lambda (from n)
                         (when (member prefix '("f" "F" "t" "T"))
                           (set! *last-char-search* (list prefix ch)))
                         ((cadr m) from n ch))))))]
    [else #f]))

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
       ;; Vim's rules for an exclusive motion that ends at the start of a
       ;; later line: it stops at the end of the line before instead, and
       ;; if it also began at or before the first non-blank it covers
       ;; whole lines. So d} deletes whole paragraphs.
       (let ([lo-line (offset->line lo)] [hi-line (offset->line hi)])
         (cond
           [(or (= hi-line lo-line) (not (= (offset->col hi) 0))) (list lo hi #f)]
           [(<= lo (line-first-nonblank lo-line)) (lines-range lo-line (- hi-line 1))]
           [else (list lo (line-end (- hi-line 1)) #f)]))])))

(define (run-operator! op-key motion-key count)
  (let* (;; Vim special case: `cw` on a word changes to its end, like `ce`,
         ;; leaving the space after it alone.
         [motion-key (cond
                       [(not (and (equal? op-key "c") (not (= (class-at (cursor)) 0)))) motion-key]
                       [(equal? motion-key "w") "e"]
                       [(equal? motion-key "W") "E"]
                       [else motion-key])]
         [m (find-motion motion-key)]
         [from (cursor)]
         [target ((motion-proc m) from count)])
    ;; A motion that finds nothing (f with no match) cancels the operator.
    (when target
      (let* ([target (if (member motion-key '("w" "W")) (word-operator-end from target) target)]
             [range (motion-range from target (motion-type m))])
        (undo-boundary!)
        ((hash-ref *operators* op-key) (car range) (cadr range) (caddr range))))))

;; Vim special case: with an operator, w stops at the end of the last word
;; it moved over rather than at the start of a word on a later line, so `dw`
;; on a line's last word keeps the line break.
(define (word-operator-end from target)
  (if (> (offset->line target) (offset->line from))
      (let ([end (let loop ([p target])
                   (if (and (> p from) (char-whitespace? (buffer-char-at (- p 1)))) (loop (- p 1)) p))])
        (if (< (offset->line end) (offset->line target)) end target))
      target))

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
  ;; The selection stays visible while a search prompt is open from it.
  (when (or (eq? *mode* 'visual) (and (eq? *mode* 'cmdline) *visual* (eq? *cmdline-return* 'visual)))
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

;;; Scrolling
;;;
;;; These move the window and keep the cursor inside it. They work in normal
;;; and visual mode.

(define (define-normal-and-visual! key proc)
  (define-key! 'normal key proc)
  (define-key! 'visual key proc))

(define (scroll-to! top)
  (set-window-top! (clamp top 0 (last-line))))

;; Moves the cursor onto `line`'s first non-blank, as Vim's 'startofline'.
(define (cursor-to-line! line)
  (set-cursor! (line-first-nonblank (clamp line 0 (last-line)))))

;; C-d and C-u: half a window, or `count` lines.
(define (half-page-scroll! sign)
  (lambda (count)
    (let ([n (if *count-given* count (max 1 (quotient (window-height) 2)))])
      (scroll-to! (+ (window-top) (* sign n)))
      (cursor-to-line! (+ (current-line) (* sign n))))))

;; C-f and C-b: a window less two lines, so some context stays on screen.
(define (page-scroll! sign)
  (lambda (count)
    (let ([n (* count (max 1 (- (window-height) 2)))])
      (scroll-to! (+ (window-top) (* sign n)))
      (cursor-to-line! (if (> sign 0) (window-top) (window-bottom))))))

;; C-e and C-y: the window moves a line; the cursor only if it must.
(define (line-scroll! sign)
  (lambda (count)
    (scroll-to! (+ (window-top) (* sign count)))
    (cond
      [(< (current-line) (window-top)) (cursor-to-line! (window-top))]
      [(> (current-line) (window-bottom)) (cursor-to-line! (window-bottom))]
      [else #t])))

(define-normal-and-visual! "C-d" (half-page-scroll! 1))
(define-normal-and-visual! "C-u" (half-page-scroll! -1))
(define-normal-and-visual! "C-f" (page-scroll! 1))
(define-normal-and-visual! "C-b" (page-scroll! -1))
(define-normal-and-visual! "<pagedown>" (page-scroll! 1))
(define-normal-and-visual! "<pageup>" (page-scroll! -1))
(define-normal-and-visual! "C-e" (line-scroll! 1))
(define-normal-and-visual! "C-y" (line-scroll! -1))

;; zt zz zb put the cursor line at the top, middle or bottom of the window;
;; z<ret> z. z- do the same and move to the first non-blank.
(define (cursor-line-at! where first-nonblank?)
  (lambda (count)
    (let* ([line (if *count-given* (clamp (- count 1) 0 (last-line)) (current-line))]
           [h (window-height)])
      (scroll-to! (cond [(eq? where 'top) line]
                        [(eq? where 'middle) (- line (quotient (- h 1) 2))]
                        [else (- line (- h 1))]))
      (if (or first-nonblank? *count-given*)
          (cursor-to-line! line)
          (set-cursor! (line-col->offset line *goal-col*))))))

(define-normal-and-visual! "zt" (cursor-line-at! 'top #f))
(define-normal-and-visual! "zz" (cursor-line-at! 'middle #f))
(define-normal-and-visual! "zb" (cursor-line-at! 'bottom #f))
(define-normal-and-visual! "z<ret>" (cursor-line-at! 'top #t))
(define-normal-and-visual! "z." (cursor-line-at! 'middle #t))
(define-normal-and-visual! "z-" (cursor-line-at! 'bottom #t))

;;; Normal mode dispatch

;; Normal-mode commands that take a char, such as r and m: `proc` is
;; (lambda (count char) ...).
(define *char-commands* (hash))

;; Keys that start a longer key: (define-prefix! "z") makes "zz", "zt" ...
;; reachable. Char motions and char commands are prefixes automatically.
(define *prefix-keys* (hash "g" #t "z" #t "Z" #t "[" #t "]" #t))

(define (define-prefix! key)
  (set! *prefix-keys* (hash-insert *prefix-keys* key #t)))

(define (prefix-key? key)
  (or (hash-contains? *prefix-keys* key)
      (hash-contains? *char-motions* key)
      (and (not *operator*) (hash-contains? *char-commands* key))))

(define (define-char-command! key proc)
  (set! *char-commands* (hash-insert *char-commands* key proc)))

(define (find-char-command key)
  (and (> (string-length key) 1)
       (let ([proc (hash-try-get *char-commands* (substring key 0 1))]
             [ch (key-char (substring key 1 (string-length key)))])
         (and proc ch (lambda (count) (proc count ch))))))

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

    ;; Search prompts. With an operator pending, the search is its motion.
    [(and (not *prefix*) (member key '("/" "?")))
     (let ([op *operator*]
           [count (* (count-value *operator-count*) (count-value *count*))])
       (reset-pending!)
       (start-search! (equal? key "/") op count))]

    ;; Prefix keys wait for the next key: `g`, `z`, char motions like `f`.
    [(and (not *prefix*) (prefix-key? key))
     (set! *prefix* key)]
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
              [(find-motion key)
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

         [(find-motion key)
          => (lambda (m)
               (let ([target ((motion-proc m) (cursor) count)])
                 (when target (set-cursor! target)))
               (set! *count* ""))]

         [(and (not (eq? *mode* 'visual)) (lookup-key 'normal key))
          ((lookup-key 'normal key) count)
          (set! *count* "")]

         [(and (not (eq? *mode* 'visual)) (find-char-command key))
          => (lambda (cmd) (cmd count) (set! *count* ""))]

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

;;; The command line
;;;
;;; One prompt serves `:`, `/` and `?`. Whoever opens it says what happens
;;; on each edit, on <ret> and on <esc>.

(define (open-cmdline! prompt initial on-submit on-change on-cancel)
  (set! *cmdline-return* (if (eq? *mode* 'visual) 'visual 'normal))
  (set! *cmdline-prompt* prompt)
  (set! *cmdline* initial)
  (set! *cmdline-submit* on-submit)
  (set! *cmdline-change* on-change)
  (set! *cmdline-cancel* on-cancel)
  (set-mode! 'cmdline)
  (show-cmdline!))

(define (show-cmdline!)
  (set-status! (string-append *cmdline-prompt* *cmdline*)))

(define (close-cmdline!)
  (set-mode! *cmdline-return*)
  (set-status! ""))

(define (cmdline-edit! text)
  (set! *cmdline* text)
  (show-cmdline!)
  (when *cmdline-change* (*cmdline-change* text)))

;; The text with its last word (and the white space after it) removed.
(define (drop-last-word text)
  (let* ([n (string-length text)]
         [p (let loop ([p n]) (if (and (> p 0) (char-whitespace? (string-ref text (- p 1)))) (loop (- p 1)) p))]
         [word? (and (> p 0) (char-word? (string-ref text (- p 1))))]
         [p (let loop ([p p])
              (if (and (> p 0)
                       (let ([c (string-ref text (- p 1))])
                         (and (not (char-whitespace? c)) (eq? (char-word? c) word?))))
                  (loop (- p 1))
                  p))])
    (substring text 0 p)))

(define (cmdline-key! key)
  (cond
    [(member key '("<esc>" "C-c"))
     (close-cmdline!)
     (when *cmdline-cancel* (*cmdline-cancel*))]
    [(equal? key "<ret>")
     (close-cmdline!)
     (*cmdline-submit* *cmdline*)
     (when (member *mode* '(normal visual)) (normal-clamp!))]
    [(equal? key "<bs>")
     (if (equal? *cmdline* "")
         (begin (close-cmdline!) (when *cmdline-cancel* (*cmdline-cancel*)))
         (cmdline-edit! (substring *cmdline* 0 (- (string-length *cmdline*) 1))))]
    [(equal? key "C-u") (cmdline-edit! "")]
    [(equal? key "C-w") (cmdline-edit! (drop-last-word *cmdline*))]
    [(= (string-length key) 1) (cmdline-edit! (string-append *cmdline* key))]
    [(equal? key "<tab>") (cmdline-edit! (string-append *cmdline* "\t"))]
    [else #t]))

;;; Search

;; Escapes the chars that are special in a Vim pattern.
(define (pattern-quote text)
  (list->string
   (let loop ([cs (string->list text)])
     (cond
       [(null? cs) '()]
       [(memv (car cs) (list #\\ #\/ #\. #\* #\$ #\^ #\~ #\[ #\]))
        (cons #\\ (cons (car cs) (loop (cdr cs))))]
       [else (cons (car cs) (loop (cdr cs)))]))))

(define (refresh-search-highlight!)
  (if (and *hlsearch* *last-search*)
      (highlight-pattern! "search" *last-search* "search")
      (highlight-clear! "search")))

;; Where the `count`th match of `pattern` from `from` is, or #f. Says on the
;; status line when the search wraps or fails.
(define (search-target pattern from forward? count)
  (let loop ([i 0] [p from] [wrapped #f])
    (if (= i count)
        (begin
          (when wrapped
            (set-status! (if forward?
                             "search hit BOTTOM, continuing at TOP"
                             "search hit TOP, continuing at BOTTOM")))
          p)
        (let ([r (search-next pattern p forward?)])
          (if r
              (loop (+ i 1) (car r) (or wrapped (= (cadr r) 1)))
              (begin (set-status! (string-append "Pattern not found: " pattern)) #f))))))

;; Searches for `pattern` and makes it the last search, so n, N and the
;; highlight follow it.
(define (search-motion! pattern forward? from count)
  (set! *last-search* pattern)
  (set! *last-search-forward* forward?)
  (set! *hlsearch* #t)
  (refresh-search-highlight!)
  (search-target pattern from forward? count))

(define (repeat-search from count reverse?)
  (cond
    [(not *last-search*) (set-status! "no previous regular expression") from]
    [else
     (set! *hlsearch* #t)
     (refresh-search-highlight!)
     (or (search-target *last-search* from (if reverse? (not *last-search-forward*) *last-search-forward*) count)
         from)]))

(define-motion! "n" 'exclusive (lambda (from n) (repeat-search from n #f)))
(define-motion! "N" 'exclusive (lambda (from n) (repeat-search from n #t)))

;; The word under or after the cursor on its line, as (start end), or #f.
(define (word-at from)
  (let* ([hi (line-end (offset->line from))]
         [p (let loop ([p from]) (if (and (< p hi) (blank-at? p)) (loop (+ p 1)) p))])
    (and (< p hi)
         (list (run-start p char-class (line-start (offset->line p)))
               (run-end p char-class hi)))))

;; * and #: search for the word under the cursor. Like Vim, they ignore case
;; even when smartcase would not.
(define (star-motion forward? whole?)
  (lambda (from n)
    (let ([w (word-at from)])
      (if (not w)
          (begin (set-status! "no string under cursor") from)
          (let* ([text (buffer-substring (car w) (cadr w))]
                 [word? (char-word? (string-ref text 0))]
                 [pattern (string-append
                           (if (and whole? word?) "\\<" "")
                           (pattern-quote text)
                           (if (and whole? word?) "\\>" "")
                           "\\c")])
            ;; Searching backward starts from the word's start, so the word
            ;; itself isn't the first match.
            (or (search-motion! pattern forward? (if forward? from (car w)) n) from))))))

(define-motion! "*" 'exclusive (star-motion #t #t))
(define-motion! "#" 'exclusive (star-motion #f #t))
(define-motion! "g*" 'exclusive (star-motion #t #f))
(define-motion! "g#" 'exclusive (star-motion #f #f))

;; Runs operator `op-key` over the text a motion of `type` covers.
(define (operate! op-key from target type)
  (let ([range (motion-range from target type)])
    (undo-boundary!)
    ((hash-ref *operators* op-key) (car range) (cadr range) (caddr range))))

;; / and ?: prompt for a pattern, moving to matches as it is typed. With an
;; operator pending, the search is the operator's (exclusive) motion.
(define (start-search! forward? op count)
  (let ([origin (cursor)] [prompt (if forward? "/" "?")])
    (open-cmdline!
     prompt ""
     (lambda (text)
       (set-cursor! origin)
       (let ([pattern (if (equal? text "") *last-search* text)])
         (cond
           [(not pattern) (set-status! "no previous regular expression")]
           [(pattern-error pattern) (set-status! (pattern-error pattern))]
           [else
            (let ([target (search-motion! pattern forward? origin count)])
              (cond
                [(not target) #t]
                [op
                 (operate! op origin target 'exclusive)
                 (when (changing-operator? op)
                   (record-change!
                    (lambda (n)
                      (let ([t (search-target pattern (cursor) forward? n)])
                        (when t (operate! op (cursor) t 'exclusive))))
                    count))]
                [else (set-cursor! target)]))])))
     ;; Incremental search: show where the pattern matches so far.
     (lambda (text)
       (set-cursor! origin)
       (if (or (equal? text "") (pattern-error text))
           (refresh-search-highlight!)
           (let ([r (search-next text origin forward?)])
             (highlight-pattern! "search" text "search")
             (when r (set-cursor! (car r))))))
     (lambda ()
       (set-cursor! origin)
       (refresh-search-highlight!)))))

;;; Ex commands
;;;
;;; A command line is [range] name[!] [args]. The range is resolved to line
;;; numbers before the command runs; commands read the parsed line with
;;; ex-range, ex-range-given?, ex-bang? and ex-args.

(define *ex-commands* (hash))

;; Defines an ex command under one name or a list of names (abbreviations
;; are spelled out, as in (define-ex! '("s" "substitute") ...)).
(define (define-ex! names proc)
  (for-each (lambda (name) (set! *ex-commands* (hash-insert *ex-commands* name proc)))
            (if (list? names) names (list names))))

(define (ex-range ex) (car ex))          ; (first-line last-line), 0-based
(define (ex-range-given? ex) (cadr ex))
(define (ex-bang? ex) (caddr ex))
(define (ex-args ex) (cadddr ex))

(define (char-at s i) (and (< i (string-length s)) (string-ref s i)))

(define (skip-spaces s i)
  (if (and (char-at s i) (char-whitespace? (char-at s i))) (skip-spaces s (+ i 1)) i))

(define (digits-end s i)
  (if (and (char-at s i) (char-numeric-ascii? (char-at s i))) (digits-end s (+ i 1)) i))

;; The '< and '> marks: the lines of the last visual selection.
(define (visual-mark-line which)
  (and *last-visual*
       (let ([a (cadr *last-visual*)] [b (caddr *last-visual*)])
         (offset->line (if (eq? which 'start) (min a b) (max a b))))))

;; Reads text up to an unescaped `delim`, from i. Returns (text . next-i),
;; next-i being just past the delimiter (or the end of the string).
(define (read-delimited s i delim)
  (let loop ([i i] [acc '()])
    (let ([c (char-at s i)])
      (cond
        [(not c) (cons (list->string (reverse acc)) i)]
        [(equal? c delim) (cons (list->string (reverse acc)) (+ i 1))]
        [(and (equal? c #\\) (equal? (char-at s (+ i 1)) delim))
         (loop (+ i 2) (cons delim acc))]
        [(equal? c #\\) (loop (+ i 2) (if (char-at s (+ i 1)) (cons (char-at s (+ i 1)) (cons c acc)) (cons c acc)))]
        [else (loop (+ i 1) (cons c acc))]))))

;; One address, as (line . next-i), line #f if there is none. Errors are
;; raised with (error ...) and shown by the caller.
(define (parse-address s i)
  (let* ([i (skip-spaces s i)]
         [c (char-at s i)]
         [base
          (cond
            [(equal? c #\.) (cons (current-line) (+ i 1))]
            [(equal? c #\$) (cons (last-line) (+ i 1))]
            [(and c (char-numeric-ascii? c))
             (let ([e (digits-end s i)])
               (cons (- (string->number (substring s i e)) 1) e))]
            [(equal? c #\')
             (let* ([m (char-at s (+ i 1))]
                    [line (cond [(equal? m #\<) (visual-mark-line 'start)]
                                [(equal? m #\>) (visual-mark-line 'end)]
                                [else (mark-line m)])])
               (if line (cons line (+ i 2)) (error "mark not set")))]
            [(memv c (list #\/ #\?))
             (let* ([r (read-delimited s (+ i 1) c)]
                    [pattern (if (equal? (car r) "") *last-search* (car r))]
                    [forward? (equal? c #\/)]
                    [from (if forward? (line-end (current-line)) (line-start (current-line)))])
               (when (or (not pattern) (pattern-error pattern)) (error "bad pattern"))
               (set! *last-search* pattern)
               (let ([hit (search-next pattern from forward?)])
                 (if hit (cons (offset->line (car hit)) (cdr r)) (error (string-append "Pattern not found: " pattern)))))]
            [else (cons #f i)])])
    ;; Offsets: +N, -N, or bare + and - meaning 1.
    (let loop ([line (car base)] [i (cdr base)])
      (let ([c (char-at s i)])
        (if (memv c (list #\+ #\-))
            (let* ([e (digits-end s (+ i 1))]
                   [n (if (= e (+ i 1)) 1 (string->number (substring s (+ i 1) e)))])
              (loop (+ (or line (current-line)) (if (equal? c #\+) n (- n))) e))
            (cons line i))))))

;; The range, as ((first last) given? . next-i).
(define (parse-range s i)
  (let ([i (skip-spaces s i)])
    (if (equal? (char-at s i) #\%)
        (list (list 0 (last-line)) #t (+ i 1))
        (let* ([a (parse-address s i)] [i (cdr a)])
          (if (memv (char-at s i) (list #\, #\;))
              (let* ([b (parse-address s (+ i 1))]
                     [first (or (car a) (current-line))]
                     [last (or (car b) (current-line))])
                (list (list (min first last) (max first last)) #t (cdr b)))
              (list (list (or (car a) (current-line)) (or (car a) (current-line)))
                    (if (car a) #t #f)
                    i))))))

(define (letter? c)
  (and c (let ([n (char->integer (char-downcase c))]) (and (>= n 97) (<= n 122)))))

;; Parses a command line into (name ex), ex being (range given? bang args).
(define (parse-ex line)
  (let* ([r (parse-range line 0)]
         [range (car r)]
         [i (skip-spaces line (caddr r))]
         [name-end (let loop ([j i]) (if (letter? (char-at line j)) (loop (+ j 1)) j))]
         ;; A command that isn't letters is one char: & < > ! =
         [name-end (if (and (= name-end i) (char-at line i)) (+ i 1) name-end)]
         [name (substring line i name-end)]
         [bang? (and (equal? (char-at line name-end) #\!) (not (equal? name "!")))]
         [args-start (skip-spaces line (if bang? (+ name-end 1) name-end))]
         [args (substring line args-start (string-length line))]
         [range (list (clamp (car range) 0 (last-line)) (clamp (cadr range) 0 (last-line)))])
    (list name (list range (cadr r) bang? args))))

(define (run-ex! line)
  (let ([parsed (with-handler (lambda (e) (error-message e)) (parse-ex line))])
    (if (string? parsed)
        (set-status! parsed)
        (let* ([name (car parsed)] [ex (cadr parsed)] [cmd (hash-try-get *ex-commands* name)])
          (cond
            [cmd (cmd ex)]
            ;; A range on its own goes to its last line.
            [(equal? name "")
             (when (ex-range-given? ex)
               (set-cursor! (line-first-nonblank (cadr (ex-range ex)))))]
            [else (set-status! (string-append "not an editor command: " line))])))))

;; The message of a caught error, without the space Steel puts in front.
(define (error-message e)
  (let* ([m (error-object-message e)] [m (if (string? m) m (to-string m))])
    (substring m (skip-spaces m 0) (string-length m))))

;; Marks other than '< and '> arrive with 1.9; until then they are unset.
(define (mark-line c) #f)

(define-key! 'normal ":"
  (lambda (count)
    (open-cmdline! ":" (if *count-given* (string-append ".,.+" (number->string (- count 1))) "")
                   run-ex! #f #f)))

(define-key! 'visual ":"
  (lambda (count)
    (leave-visual!)
    (open-cmdline! ":" "'<,'>" run-ex! #f #f)))

;;; The ex commands

(define (write-buffer! ex)
  (when (save!) (set-status! (string-append "wrote " (buffer-name)))))

(define-ex! '("w" "write") write-buffer!)
(define-ex! '("q" "quit")
  (lambda (ex)
    (if (and (buffer-modified?) (not (ex-bang? ex)))
        (set-status! "unsaved changes (add ! to override)")
        (quit!))))
(define-ex! "wq" (lambda (ex) (when (save!) (quit!))))
;; :x writes only if there is something to write.
(define-ex! '("x" "xit" "exit")
  (lambda (ex) (if (buffer-modified?) (when (save!) (quit!)) (quit!))))

(define-ex! '("noh" "nohlsearch")
  (lambda (ex) (set! *hlsearch* #f) (refresh-search-highlight!)))

;; :d and :y over lines, into the register like dd and yy.
(define (ex-lines-operator op-key)
  (lambda (ex)
    (let* ([range (ex-range ex)] [r (lines-range (car range) (cadr range))])
      (undo-boundary!)
      ((hash-ref *operators* op-key) (car r) (cadr r) #t))))

(define-ex! '("d" "de" "del" "delete") (ex-lines-operator "d"))
(define-ex! '("y" "ya" "yank") (lambda (ex) (let ([c (cursor)]) ((ex-lines-operator "y") ex) (set-cursor! c))))

;; :s/pattern/replacement/flags. Flags: g (every match on a line), i and I
;; (ignore or match case). An empty pattern is the last search; :s alone
;; repeats the last substitute.
(define (substitute-command ex)
  (let* ([args (ex-args ex)]
         [delim (char-at args 0)]
         [parts
          (cond
            [(not delim) (if *last-substitute* (append *last-substitute* (list "")) #f)]
            [(or (char-word? delim) (equal? delim #\\) (equal? delim #\")) #f]
            [else
             (let* ([p (read-delimited args 1 delim)]
                    [r (read-delimited args (cdr p) delim)])
               (list (car p) (car r) (substring args (cdr r) (string-length args))))])])
    (cond
      [(not parts) (set-status! (if delim "bad substitute" "no previous substitute"))]
      [else
       (let* ([pattern (if (equal? (car parts) "") *last-search* (car parts))]
              [flags (caddr parts)]
              [pattern (and pattern
                            (cond [(string-contains? flags "i") (string-append pattern "\\c")]
                                  [(string-contains? flags "I") (string-append pattern "\\C")]
                                  [else pattern]))])
         (cond
           [(not pattern) (set-status! "no previous regular expression")]
           [(pattern-error pattern) (set-status! (pattern-error pattern))]
           [else
            (set! *last-search* (if (equal? (car parts) "") *last-search* (car parts)))
            (set! *last-substitute* (list (car parts) (cadr parts)))
            (undo-boundary!)
            (let* ([range (ex-range ex)]
                   [r (substitute! pattern (cadr parts) (car range) (cadr range)
                                   (string-contains? flags "g"))])
              (if (= (car r) 0)
                  (set-status! (string-append "Pattern not found: " pattern))
                  (begin
                    (set-cursor! (line-first-nonblank (cadr r)))
                    (when (> (car r) 1)
                      (set-status! (string-append (number->string (car r)) " substitutions"))))))
            (when *hlsearch* (refresh-search-highlight!))]))])))

(define-ex! '("s" "su" "substitute") substitute-command)
;; & repeats the last substitute on the current line, without its flags.
(define-ex! "&" (lambda (ex) (substitute-command (list (ex-range ex) (ex-range-given? ex) #f ""))))
(define-key! 'normal "&"
  (lambda (count)
    (run-ex! "s")))

;; :eval EXPR runs Scheme in the editor and shows the result. This is the
;; quickest way to redefine something while imp is running.
(define-ex! '("eval" "ev")
  (lambda (ex)
    (let ([result (with-handler
                   (lambda (e) (string-append "error: " (error-message e)))
                   (to-string (eval (read (open-input-string (ex-args ex))))))])
      (set-status! result))))

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
