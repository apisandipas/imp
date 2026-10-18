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

(define *mode* 'normal)        ; normal | insert | cmdline
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

;; Linewise text is stored as whole lines, each ending in a line break,
;; whichever side of the range the break came from.
(define (yank-range! start end linewise?)
  (let ([text (buffer-substring start end)])
    (set! *register*
          (if linewise?
              (let* ([text (if (starts-with? text "\n") (substring text 1 (string-length text)) text)])
                (if (ends-with? text "\n") text (string-append text "\n")))
              text))
    (set! *register-linewise* linewise?)))

(define-operator! "d"
  (lambda (start end linewise?)
    (yank-range! start end linewise?)
    (buffer-delete! start end)
    (set-cursor! (if linewise? (line-first-nonblank (offset->line start)) start))))

(define-operator! "y"
  (lambda (start end linewise?)
    (yank-range! start end linewise?)
    (set-cursor! start)))

(define-operator! "c"
  (lambda (start end linewise?)
    (yank-range! start end linewise?)
    (if linewise?
        ;; Keep the line itself: change its text, not its line break.
        (let ([end (if (> end start) (- end 1) end)])
          (buffer-delete! start end))
        (buffer-delete! start end))
    (set-cursor! start)
    (set-mode! 'insert)))

;; The range a motion covers from `from`, as (start end linewise?).
(define (motion-range from target type)
  (let ([lo (min from target)] [hi (max from target)])
    (cond
      [(eq? type 'linewise)
       (let* ([first (offset->line lo)]
              [last (offset->line hi)]
              [start (line-start first)]
              [end (if (< last (last-line)) (line-start (+ last 1)) (buffer-length))])
;; Deleting through the last line takes the line break before it
         ;; instead, so the file keeps its final newline.
         (if (and (= last (last-line)) (> first 0))
             (list (- start 1) (line-end last) #t)
             (list start end #t)))]
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

;;; Normal mode dispatch

(define (digit? key)
  (and (= (string-length key) 1)
       (char-numeric-ascii? (string-ref key 0))))

(define (char-numeric-ascii? c)
  (let ([n (char->integer c)]) (and (>= n 48) (<= n 57))))

(define (count-value s) (if (equal? s "") 1 (string->number s)))

(define (normal-key! key)
  (cond
    [(member key '("<esc>" "C-c")) (reset-pending!)]

    ;; Counts. A leading 0 is the motion, not a count.
    [(and (digit? key) (not (and (equal? key "0") (equal? *count* ""))))
     (set! *count* (string-append *count* key))]

    ;; Prefix keys: `g` waits for the next key.
    [(and (not *prefix*) (equal? key "g"))
     (set! *prefix* "g")]

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
              [(equal? key op)
               (let ([change (lambda (n) (run-linewise-operator! op n))])
                 (set! *operator* #f)
                 (change count)
                 (when (changing-operator? op) (record-change! change count)))]
              [else (set-status! (string-append "no motion " key))]))
          (set! *count* "")
          (set! *operator-count* "")]

         [(hash-contains? *operators* key)
          (set! *operator* key)
          (set! *operator-count* *count*)
          (set! *count* "")]

         [(hash-contains? *motions* key)
          (set-cursor! ((motion-proc (hash-ref *motions* key)) (cursor) count))
          (set! *count* "")]

         [(lookup-key 'normal key)
          ((lookup-key 'normal key) count)
          (set! *count* "")]

         [else
          (set! *count* "")
          (set-status! (string-append "no binding for " key))])
       (set! *count-given* #f))])

  (when (eq? *mode* 'normal)
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
     (normal-key! key)]))
