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

(define *mode* 'normal)        ; normal | insert | replace | cmdline | visual, or a state added by another file
;; States other files add (emacs.scm): state -> (name cursor-shape key-handler).
(define *extra-states* (hash))
(define *visual* #f)           ; char | line | block while in visual mode
(define *block-eol* #f)        ; $ in block mode: every line to its end
(define *block-insert* #f)     ; (first last col) while typing I/A/c in a block
(define *visual-anchor* 0)     ; the end of the selection the cursor isn't on
(define *last-visual* #f)      ; (kind anchor cursor) for gv
(define *count* "")            ; digits typed so far
(define *operator* #f)         ; pending operator key, e.g. "d"
(define *operator-count* "")   ; count typed before the operator
(define *prefix* #f)           ; pending prefix key, e.g. "g"
(define *goal-col* 0)          ; column j/k try to keep
(define *registers* (hash))    ; register char -> (text linewise?)
(define *register-prefix* #f)  ; the register named with "x for this command
(define *register-just-set* #f)
(define *last-inserted* "")    ; the ". register
(define *last-ex* #f)          ; the ": register
(define *recording* #f)        ; the register q is recording into
(define *recorded-keys* '())   ; reversed
(define *last-macro* #f)       ; for @@
(define *command-failed* #f)
(define *u-line* #f)           ; the line U restores, and its old text
(define *u-text* "")
(define *jumps* '())           ; mark names of jump list entries, oldest first
(define *jump-index* 0)        ; where C-o and C-i are in *jumps*
(define *jump-counter* 0)      ; for naming jump marks
(define *popup-shown* #f)      ; a popup is up until the next key
(define *undo-group* #f)       ; while true, changes join one undo step
(define *alternate-buffer* #f) ; for C-^ and :e #   ; set when a key fails; stops a running macro
(define *insert-pending* #f)   ; C-r in insert mode waits for a register
(define *cmdline-pending* #f)  ; and on the command line
(define *last-change* #f)      ; (lambda (count) ...) repeated by `.`
(define *last-change-count* 1)
(define *insert-entry* #f)     ; how the current insert began, for `.`
(define *insert-keys* '())     ; keys typed during the current insert, reversed
(define *insert-count* 1)      ; 3ihi<esc> types hi three times
(define *insert-reentry* #f)   ; for 3o: how to start each repetition
(define *insert-start* 0)      ; where typing began, for C-u
(define *last-insert-pos* #f)  ; where insert mode was left, for gi
(define *autoindent-line* #f)  ; a line holding only indent we added
(define *replaced* '())        ; (offset . old-char) pairs, for <bs> in R
(define *insert-return* #f)    ; C-o: go back to insert after one command
(define *cmdline* "")           ; text typed at the prompt
(define *cmdline-prompt* ":")
(define *cmdline-submit* #f)   ; (lambda (text) ...) on <ret>
(define *cmdline-change* #f)   ; (lambda (text) ...) after each edit
(define *cmdline-cancel* #f)   ; (lambda () ...) on <esc>
(define *cmdline-return* 'normal) ; the mode to go back to
(define *cmdline-pos* 0)       ; cursor position in *cmdline*
(define *cmdline-key-handler* #f) ; sees keys first; #t from it means handled
(define *history* (hash))      ; prompt -> entries, newest first
(define *history-index* -1)    ; -1 while editing a fresh line
(define *history-prefix* "")   ; what <up> and <down> match against
(define *last-search* #f)      ; the last search pattern
(define *last-search-forward* #t)
(define *hlsearch* #f)         ; whether matches of *last-search* are shown
(define *last-substitute* #f)  ; (pattern replacement) for :s and &
;; True while running a command whose count the user typed, so G and gg can
;; tell "5G" from "G".
(define *count-given* #f)

;; Adds an editor state beside Vim's: keys in it go to `handler`.
(define (define-state! state name cursor-shape handler)
  (set! *extra-states* (hash-insert *extra-states* state (list name cursor-shape handler))))

(define (set-mode! mode)
  (let ([old *mode*])
    (set! *mode* mode)
    (unless (eq? old mode)
      (let ([typing? (lambda (m) (memq m '(insert replace)))])
        (cond [(and (typing? mode) (not (typing? old))) (run-hooks 'insert-enter)]
              [(and (typing? old) (not (typing? mode))) (run-hooks 'insert-leave)]
              [else #t]))
      (run-hooks 'mode-change old mode)))
  (set-cursor-shape! (cond [(eq? mode 'insert) "bar"]
                           [(eq? mode 'replace) "underline"]
                           [(hash-try-get *extra-states* mode) => cadr]
                           [else "block"]))
  (show-mode!))

(define (show-mode!)
  ;; %#mode# in the status line: status.mode.normal, .insert, .visual...
  (set-mode-face! (string-append "status.mode."
                                 (cond [(eq? *mode* 'cmdline) "command"]
                                       [else (symbol->string *mode*)])))
  (set-mode-name!
   (string-append
    (cond
      [(eq? *mode* 'insert) "INSERT"]
      [(eq? *mode* 'replace) "REPLACE"]
      [(eq? *mode* 'cmdline) "COMMAND"]
      [(eq? *mode* 'visual)
       (cond [(eq? *visual* 'line) "VISUAL LINE"] [(eq? *visual* 'block) "VISUAL BLOCK"] [else "VISUAL"])]
      [(hash-try-get *extra-states* *mode*) => car]
      [else "NORMAL"])
    (if *recording* (string-append " recording @" (string *recording*)) ""))))

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

;; The classifiers motions and text objects are built with. They call
;; char-class and big-class by name each time, so redefining those (to make
;; - a word char in Lisp, say) changes w, e, iw and the rest at once.
(define (word-class c) (char-class c))
(define (WORD-class c) (big-class c))

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

;; j and k go as far as they can, but fail (#f) if they can't move at all,
;; as Vim's do: that stops a macro at the end of the file.
(define (vertical from n)
  (let ([line (clamp (+ (offset->line from) n) 0 (last-line))])
    (and (not (= line (offset->line from)))
         (line-col->offset line *goal-col*))))

(define-motion! "h" 'exclusive
  (lambda (from n)
    (let ([lo (line-start (offset->line from))]) (and (> from lo) (max lo (- from n))))))
(define-motion! "l" 'exclusive
  (lambda (from n)
    (let ([hi (line-end (offset->line from))]) (and (< from hi) (min hi (+ from n))))))
(define-motion! "j" 'linewise (lambda (from n) (vertical from n)))
(define-motion! "k" 'linewise (lambda (from n) (vertical from (- n))))
(define-motion! "w" 'exclusive (word-motion next-word-start word-class))
(define-motion! "b" 'exclusive (word-motion prev-word-start word-class))
(define-motion! "e" 'inclusive (word-motion next-word-end word-class))
(define-motion! "ge" 'inclusive (word-motion prev-word-end word-class))
(define-motion! "W" 'exclusive (word-motion next-word-start WORD-class))
(define-motion! "B" 'exclusive (word-motion prev-word-start WORD-class))
(define-motion! "E" 'inclusive (word-motion next-word-end WORD-class))
(define-motion! "gE" 'inclusive (word-motion prev-word-end WORD-class))
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
;; gj and gk move by screen rows when lines wrap: within a long line, then
;; on to the next line, keeping the wanted column (the goal column, which
;; they leave alone as j and k do). Without wrap they are j and k. Like
;; Vim's, they are exclusive.
(define (screen-row-motion dir)
  (lambda (from n)
    (if (not (option 'wrap))
        ((motion-proc (hash-ref *motions* (if (> dir 0) "j" "k"))) from n)
        (let* ([w (window-text-width)] [column (modulo *goal-col* w)])
          (let loop ([p from] [i 0])
            (if (= i n)
                p
                (let* ([line (offset->line p)]
                       [x (line-display-col line (offset->col p))]
                       [row-start (- x (modulo x w))]
                       [end-x (line-display-col line (buffer-line-length line))]
                       [at (lambda (l x) (line-col->offset l (line-col-at-display l x)))])
                  (cond
                    [(and (> dir 0) (< (+ row-start w) end-x)) (loop (at line (+ row-start w column)) (+ i 1))]
                    [(and (< dir 0) (> row-start 0)) (loop (at line (+ (- row-start w) column)) (+ i 1))]
                    [(and (> dir 0) (< line (last-line))) (loop (at (+ line 1) column) (+ i 1))]
                    [(and (< dir 0) (> line 0))
                     (let* ([prev (- line 1)]
                            [prev-end (line-display-col prev (buffer-line-length prev))])
                       (loop (at prev (+ (* w (quotient (max 0 (- prev-end 1)) w)) column)) (+ i 1)))]
                    [else (and (> i 0) p)]))))))))

(define-motion! "gj" 'exclusive (screen-row-motion 1))
(define-motion! "gk" 'exclusive (screen-row-motion -1))

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

;; Normal-mode commands that take a char, such as r and m: `proc` is
;; (lambda (count char) ...).
(define *char-commands* (hash))

(define (find-char-command key)
  (and (> (string-length key) 1)
       (let ([proc (hash-try-get *char-commands* (substring key 0 1))]
             [ch (key-char (substring key 1 (string-length key)))])
         (and proc ch (lambda (count) (proc count ch))))))

(define (define-char-command! key proc)
  (set! *char-commands* (hash-insert *char-commands* key proc)))

;; The char named by a key: "x" is x, "<tab>" a tab. Other named keys are
;; not chars.
(define (key-char key)
  (cond [(= (string-length key) 1) (string-ref key 0)]
        [(equal? key "<tab>") #\tab]
        [(equal? key "<space>") #\space]
        [(equal? key "<ret>") #\newline]
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
(define (vertical-motion? key) (member key '("j" "k" "<down>" "<up>" "gj" "gk")))

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

;;; Registers
;;;
;;; As in Vim: yanks go to "0, deletes of a line or more shift through "1-"9
;;; and smaller ones go to "-; "a-"z are yours ("A-"Z append), "_ discards,
;;; "+ and "* are the system clipboard and selection, and ". ": "/ "% are
;;; the last insert, command line, search and file name. The unnamed
;;; register "" is whichever was written last. A register is (text
;;; linewise?); linewise text is whole lines, each ending in a line break.

(define (upper-letter? c) (let ([n (char->integer c)]) (and (>= n 65) (<= n 90))))

(define (valid-register? c)
  (or (letter? c) (char-numeric-ascii? c) (memv c (string->list "\"-_+*.:/%"))))

(define (current-register) (or *register-prefix* #\"))

(define (clipboard-register c) (memv c (list #\+ #\*)))

(define (register-get c)
  (let ([c (char-downcase c)])
    (cond
      [(clipboard-register c)
       (let ([text (clipboard-get (equal? c #\*))])
         (if text
             (list text (ends-with? text "\n"))
             (hash-try-get *registers* c)))]
      [(and (equal? c #\") (equal? (option 'clipboard) "unnamedplus")) (register-get #\+)]
      [(equal? c #\.) (list *last-inserted* #f)]
      [(equal? c #\:) (and *last-ex* (list *last-ex* #f))]
      [(equal? c #\/) (and *last-search* (list *last-search* #f))]
      [(equal? c #\%) (list (buffer-name) #f)]
      [else (hash-try-get *registers* c)])))

(define (store! c value)
  (set! *registers* (hash-insert *registers* c value)))

;; Puts `text` in register `c`. `kind` is 'yank or 'delete, which decides
;; where an unnamed write also goes.
(define (register-set! c text linewise? kind)
  (let* ([text (if (and (eq? linewise? #t) (not (ends-with? text "\n"))) (string-append text "\n") text)]
         [value (list text linewise?)])
    (cond
      [(equal? c #\_) #t]
      [(upper-letter? c)
       ;; Appending: if either side is lines, the result is lines.
       (let* ([lower (char-downcase c)]
              [old (hash-try-get *registers* lower)]
              [value (cond
                       [(not old) value]
                       [(or linewise? (cadr old))
                        (list (string-append (car old) (if (ends-with? (car old) "\n") "" "\n") text) #t)]
                       [else (list (string-append (car old) text) #f)])])
         (store! lower value)
         (store! #\" value))]
      [(clipboard-register c)
       (clipboard-set! text (equal? c #\*))
       (store! c value)
       (store! #\" value)]
      [(equal? c #\")
       (store! #\" value)
       (when (equal? (option 'clipboard) "unnamedplus") (clipboard-set! text #f))
       (cond
         [(eq? kind 'yank) (store! #\0 value)]
         [(or linewise? (string-contains? text "\n"))
          ;; Shift "1-"8 down to "2-"9.
          (let loop ([i 8])
            (when (>= i 1)
              (let ([v (hash-try-get *registers* (integer->char (+ 48 i)))])
                (when v (store! (integer->char (+ 49 i)) v)))
              (loop (- i 1))))
          (store! #\1 value)]
         [else (store! #\- value)])]
      [else (store! c value) (store! #\" value)])))

(define (store-range! start end linewise? kind)
  (mark-set! "[" start)
  (mark-set! "]" (max start (- end 1)))
  (register-set! (current-register) (buffer-substring start end) linewise? kind))

(define (yank-range! start end linewise?) (store-range! start end linewise? 'delete))

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
    (store-range! start end linewise? 'yank)
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
        (begin-change!)
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
    (begin-change!)
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

(define-text-object! "iw" (inner-word word-class))
(define-text-object! "aw" (a-word word-class))
(define-text-object! "iW" (inner-word WORD-class))
(define-text-object! "aW" (a-word WORD-class))

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
;; cursor belongs to the pair it opens or closes. find-open and find-close
;; are Rust primitives: scanning a large file a char at a time from Scheme
;; took most of a second.
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

;; Tags: <name ...> ... </name>. tag-pairs-around (Rust, for speed on big
;; files) lists the pairs around the cursor, innermost first, as
;; (open-start open-end close-start close-end); the count picks one.
(define (tag-object around?)
  (lambda (from n)
    (let ([pairs (tag-pairs-around from)])
      (if (< (length pairs) n)
          #f
          (let ([t (list-ref pairs (- n 1))])
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
      (begin-change!)
      ((hash-ref *operators* op-key) (car range) (cadr range) (caddr range)))))

;;; Changes and dot-repeat

(define (changing-operator? key) (not (equal? key "y")))

;; Runs `thunk` with all its changes in one undo step.
(define (with-undo-group thunk)
  (if *undo-group*
      (thunk)
      (begin
        (undo-boundary!)
        (set! *undo-group* #t)
        (let ([result (with-handler (lambda (e) (set! *undo-group* #f) (raise-error e)) (thunk))])
          (set! *undo-group* #f)
          result))))

;; Every change starts here: it makes an undo point, and remembers the
;; line's text for U when the change is on a new line.
(define (begin-change!)
  (unless *undo-group* (undo-boundary!))
  (mark-set! "." (cursor))
  (unless (equal? *u-line* (current-line))
    (set! *u-line* (current-line))
    (set! *u-text* (buffer-substring (line-start (current-line)) (line-end (current-line))))))

;; Records `change` as the thing `.` repeats. If it ends in insert mode, the
;; record is completed when insert mode exits, with the text that was typed.
(define (record-change! change count)
  (set! *last-change-count* count)
  (let ([change (with-register change (next-register *register-prefix*))])
  (if (typing-mode?)
      (begin (set! *insert-entry* change) (set! *insert-keys* '()))
      (set! *last-change* change))))

;; A change that runs with register `reg` named, as when it was made. "1p
;; repeated with . pastes "2, then "3 and so on, as in Vim.
(define (with-register change reg)
  (if (not reg)
      change
      (lambda (n)
        (set! *register-prefix* reg)
        (change n)
        (set! *register-prefix* #f)
        (unless (equal? reg (next-register reg))
          (set! *last-change* (with-register change (next-register reg)))))))

;; The register . uses after one: "1 to "8 step to the next, others stay.
(define (next-register reg)
  (if (and reg (char-numeric-ascii? reg) (not (memv reg (list #\0 #\9))))
      (integer->char (+ 1 (char->integer reg)))
      reg))

(define (typing-mode?) (member *mode* '(insert replace)))

;; Types `keys` again `n` more times, as for 3ihi<esc> or 3ofoo<esc>.
(define (repeat-insert! keys n reentry)
  (let loop ([i 0])
    (when (< i n)
      (when reentry (reentry))
      (replay-insert-keys! keys)
      (loop (+ i 1)))))

;; Types keys recorded in insert mode again, including C-r {register}.
(define (replay-insert-keys! keys)
  (let loop ([ks keys])
    (cond
      [(null? ks) #t]
      [(and (equal? (car ks) "C-r") (pair? (cdr ks)))
       (let* ([c (key-char (cadr ks))] [reg (and c (valid-register? c) (register-get c))])
         (when reg (insert-text! (car reg))))
       (loop (cddr ks))]
      [else (insert-key! (car ks)) (loop (cdr ks))])))

(define (finish-insert-record! keys)
  (let ([entry *insert-entry*] [counted? (> *insert-count* 0)] [reentry *insert-reentry*])
    (when entry
      (set! *last-change*
            (lambda (count)
              (entry count)
              (replay-insert-keys! keys)
              ;; The count repeats the text only for insert commands; for
              ;; 3cw it was the operator's.
              (when counted? (repeat-insert! keys (- count 1) reentry))
              (leave-insert!))))
    (set! *insert-entry* #f)))

;;; Normal mode commands
;;;
;;; Commands in the normal keymap take the count (1 if none was typed).

;; The white space at the start of `line`.
(define (line-indent line)
  (buffer-substring (line-start line) (line-first-nonblank line)))

(define (enter-insert! where)
  (lambda (count)
    (begin-change!)
    (let ([line (current-line)])
      (cond
        [(eq? where 'after) (set-cursor! (min (+ (cursor) 1) (line-end line)))]
        [(eq? where 'line-end) (set-cursor! (line-end line))]
        [(eq? where 'line-start) (set-cursor! (line-first-nonblank line))]
        [(eq? where 'column-0) (set-cursor! (line-start line))]
        [(eq? where 'last-insert)
         (when *last-insert-pos* (set-cursor! (min *last-insert-pos* (buffer-length))))]
        [(eq? where 'below) (open-line! line #t)]
        [(eq? where 'above) (open-line! line #f)]
        [else #t]))
    (set-mode! (if (eq? where 'replace) 'replace 'insert))
    (set! *insert-start* (cursor))
    (set! *replaced* '())))

;; o and O: a new line below or above `line`, indented like it when
;; autoindent is on.
(define (open-line! line below?)
  (let ([indent (if (option 'autoindent) (line-indent line) "")])
    (if below?
        (begin
          (set-cursor! (line-end line))
          (buffer-insert! (cursor) (string-append "\n" indent))
          (set-cursor! (+ (cursor) 1 (string-length indent))))
        (begin
          (set-cursor! (line-start line))
          (buffer-insert! (cursor) (string-append indent "\n"))
          (set-cursor! (+ (cursor) (string-length indent)))))
    (set! *autoindent-line* (and (> (string-length indent) 0) (current-line)))))

(define (insert-command! key where)
  (define-key! 'normal key
    (let ([enter (enter-insert! where)])
      (lambda (count)
        (enter count)
        (record-change! enter count)
        (set! *insert-count* count)
        ;; 3o opens three lines; 3i just types the text three times.
        (set! *insert-reentry*
              (cond [(eq? where 'below) (lambda () (open-line! (current-line) #t))]
                    [(eq? where 'above) (lambda () (open-line! (current-line) #t))]
                    [else #f]))))))

(insert-command! "i" 'here)
(insert-command! "a" 'after)
(insert-command! "A" 'line-end)
(insert-command! "I" 'line-start)
(insert-command! "gI" 'column-0)
(insert-command! "gi" 'last-insert)
(insert-command! "o" 'below)
(insert-command! "O" 'above)
(insert-command! "R" 'replace)
(insert-command! "<insert>" 'here)

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
(operator-command! "<del>" "d" "l")

;; S and Y are cc and yy.
(define-key! 'normal "S"
  (lambda (count)
    (let ([change (lambda (n) (run-linewise-operator! "c" n))])
      (change count)
      (record-change! change count))))
(define-key! 'normal "Y" (lambda (count) (run-linewise-operator! "y" count)))

(define (string-repeat text n)
  (let loop ([i 0] [acc '()])
    (if (< i n) (loop (+ i 1) (cons text acc)) (apply string-append acc))))

(define (paste! after? cursor-after?)
  (lambda (count)
    (let ([reg (register-get (current-register))])
      (if reg
          (begin (begin-change!) (put-text! (string-repeat (car reg) count) (cadr reg) after? cursor-after?) #t)
          (begin
            (set-status! (string-append "nothing in register " (string (current-register))))
            #f)))))

;; Puts text after or before the cursor (whole lines go below or above its
;; line). The cursor ends on the last char put, or with gp just after it.
(define (put-text! text linewise? after? cursor-after?)
  (if (eq? linewise? 'block)
      (put-block! text after?)
      (put-text-at! text linewise? after? cursor-after?))
  (mark-set! "]" (max 0 (- (cursor) (if cursor-after? 1 0)))))

(define (put-text-at! text linewise? after? cursor-after?)
  (if linewise?
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
        (mark-set! "[" at)
        (set-cursor! (if cursor-after?
                         (min (+ at (string-length text)) (buffer-length))
                         (line-first-nonblank (if after? (+ line 1) line)))))
      (let ([at (if after? (min (+ (cursor) 1) (line-end (current-line))) (cursor))])
        (buffer-insert! at text)
        (mark-set! "[" at)
        (set-cursor! (+ at (string-length text) (if cursor-after? 0 -1))))))

(define (paste-command! key after? cursor-after?)
  (define-key! 'normal key
    (lambda (count)
      (let ([paste (paste! after? cursor-after?)])
        (when (paste count) (record-change! paste count))))))

(paste-command! "p" #t #f)
(paste-command! "P" #f #f)
(paste-command! "gp" #t #t)
(paste-command! "gP" #f #t)

;; u and C-r put the cursor where the text changed, like Vim.
(define (undo-command step! message)
  (lambda (count)
    (let loop ([i 0] [at #f])
      (let ([r (and (< i count) (step!))])
        (cond
          [r (loop (+ i 1) r)]
          [at (set-cursor! (min at (buffer-length))) (normal-clamp!)]
          [else (set-status! message)])))))

(define-key! 'normal "u" (undo-command undo! "already at oldest change"))
(define-key! 'normal "C-r" (undo-command redo! "already at newest change"))

;; U undoes the latest changes on the last changed line, as one new change
;; (so U again redoes them).
(define-key! 'normal "U"
  (lambda (count)
    (when (and *u-line* (<= *u-line* (last-line)))
      (let ([line *u-line*] [old *u-text*] [now (buffer-substring (line-start *u-line*) (line-end *u-line*))])
        (undo-boundary!)
        (replace-range! (line-start line) (line-end line) old)
        (set! *u-text* now)
        (set-cursor! (line-start line))))))

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
  (set! *block-eol* #f)
  (set! *visual* kind)
  (set! *visual-anchor* anchor)
  (set-mode! 'visual))

(define (leave-visual!)
  (set! *last-visual* (list *visual* *visual-anchor* (cursor)))
  (mark-set! "visual-anchor" *visual-anchor*)
  (mark-set! "visual-cursor" (cursor))
  (mark-set! "<" (min *visual-anchor* (cursor)))
  (mark-set! ">" (max *visual-anchor* (cursor)))
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
    (if (eq? *visual* 'block)
        (for-each (lambda (seg) (highlight-add! "visual" (car seg) (max (cadr seg) (+ (car seg) 1)) "visual"))
                  (block-segments))
        (let ([r (visual-range)])
          (highlight-add! "visual" (car r) (cadr r) "visual")))))

;;; Block selections
;;;
;;; A block is the columns between the anchor's and the cursor's, on every
;;; line between them (to each line's end after $). Columns are chars; a
;;; tab inside a block counts as one column for now.

;; (first-line last-line left-col right-col), right inclusive.
(define (block-bounds)
  (let ([a *visual-anchor*] [c (cursor)])
    (list (min (offset->line a) (offset->line c))
          (max (offset->line a) (offset->line c))
          (min (offset->col a) (offset->col c))
          (max (offset->col a) (offset->col c)))))

;; The selected part of each line, as (start end) offsets, top to bottom.
(define (block-segments)
  (let* ([b (block-bounds)] [left (caddr b)] [right (cadddr b)])
    (map (lambda (l)
           (list (line-col->offset l left)
                 (if *block-eol* (line-end l) (line-col->offset l (+ right 1)))))
         (range (car b) (+ (cadr b) 1)))))

(define (block-text segments)
  (string-join (map (lambda (seg) (buffer-substring (car seg) (cadr seg))) segments) "\n"))

;; Deletes the segments, bottom first so offsets above stay right.
(define (delete-segments! segments)
  (for-each (lambda (seg) (buffer-delete! (car seg) (cadr seg))) (reverse segments)))

;; Puts a block's lines at the cursor column (after it with p), one per
;; line downward, adding lines and padding short ones as needed.
(define (put-block! text after?)
  (let* ([lines (split-lines text)]
         [first (current-line)]
         [col (if (and after? (> (buffer-line-length first) 0)) (+ (current-col) 1) (current-col))])
    (let loop ([ls lines] [l first])
      (unless (null? ls)
        (when (> l (last-line))
          (buffer-insert! (buffer-length) (if (ends-with? (buffer-substring 0 (buffer-length)) "\n") "\n" "\n\n")))
        (let ([len (buffer-line-length l)])
          (when (< len col) (buffer-insert! (line-end l) (make-string (- col len) #\space)))
          (buffer-insert! (line-col->offset l col) (car ls)))
        (loop (cdr ls) (+ l 1))))
    (mark-set! "[" (line-col->offset first col))
    (set-cursor! (line-col->offset first col))))

;; d y c and the rest on a block. d and y keep the text as a block register.
(define (block-operator! op-key to-eol?)
  (when to-eol? (set! *block-eol* #t))
  (let* ([segments (block-segments)] [b (block-bounds)]
         [top-left (line-col->offset (car b) (caddr b))])
    (leave-visual!)
    (begin-change!)
    (cond
      [(equal? op-key "y")
       (register-set! (current-register) (block-text segments) 'block 'yank)
       (set-cursor! top-left)]
      [(equal? op-key "d")
       (register-set! (current-register) (block-text segments) 'block 'delete)
       (delete-segments! segments)
       (set-cursor! top-left)]
      [(equal? op-key "c")
       (register-set! (current-register) (block-text segments) 'block 'delete)
       (delete-segments! segments)
       (start-block-insert! (car b) (cadr b) (caddr b) top-left)]
      [else
       (for-each (lambda (seg) ((hash-ref *operators* op-key) (car seg) (cadr seg) #f))
                 (reverse segments))
       (set-cursor! top-left)])
    (set! *block-eol* #f)))

;; I, A and c on a block: type on the first line; on <esc> the same text
;; goes into every other line of the block.
(define (start-block-insert! first last col at)
  (set! *block-insert* (list first last col))
  (set-cursor! at)
  (set-mode! 'insert)
  (set! *insert-start* at))

(define (finish-block-insert!)
  (let* ([b *block-insert*] [first (car b)] [last (cadr b)] [col (caddr b)])
    (set! *block-insert* #f)
    (when (and (= (current-line) first) (>= (current-col) (if (eq? col 'eol) 0 col)))
      (let* ([start (if (eq? col 'eol) *insert-start* (line-col->offset first col))]
             [text (buffer-substring start (cursor))])
        (unless (or (equal? text "") (string-contains? text "\n"))
          (let loop ([l (+ first 1)])
            (when (<= l last)
              (let ([len (buffer-line-length l)])
                (cond
                  [(eq? col 'eol) (buffer-insert! (line-end l) text)]
                  [(>= len col) (buffer-insert! (line-col->offset l col) text)]
                  ;; A short line gets text only when appending (A pads).
                  [(caddr (cdr b))
                   (buffer-insert! (line-end l) (string-append (make-string (- col len) #\space) text))]
                  [else #t]))
              (loop (+ l 1)))))))))

(define (block-insert-command append?)
  (lambda (count)
    (if (not (eq? *visual* 'block))
        ;; In other visual modes I and A insert at the selection's ends.
        (let ([r (visual-range)])
          (leave-visual!)
          (begin-change!)
          (set-cursor! (if append? (cadr r) (car r)))
          (set-mode! 'insert)
          (set! *insert-start* (cursor)))
        (let* ([b (block-bounds)] [first (car b)] [last (cadr b)]
               [col (cond [(not append?) (caddr b)] [*block-eol* 'eol] [else (+ (cadddr b) 1)])])
          (leave-visual!)
          (begin-change!)
          (set! *block-eol* #f)
          (start-block-insert! first last col
                               (if (eq? col 'eol) (line-end first) (min (line-col->offset first col) (line-end first))))
          (set! *block-insert* (list first last col append?))
          ;; Appending past a short first line pads it, as Vim does.
          (when (and (not (eq? col 'eol)) (< (buffer-line-length first) col))
            (buffer-insert! (line-end first) (make-string (- col (buffer-line-length first)) #\space))
            (set-cursor! (line-col->offset first col)))))))

(define-key! 'visual "I" (block-insert-command #f))
(define-key! 'visual "A" (block-insert-command #t))

;; O in a block goes to the other corner on the same line.
(define-key! 'visual "O"
  (lambda (count)
    (if (eq? *visual* 'block)
        (let ([a *visual-anchor*] [c (cursor)])
          (set! *visual-anchor* (line-col->offset (offset->line a) (offset->col c)))
          (set-cursor! (line-col->offset (offset->line c) (offset->col a))))
        ((lookup-key 'visual "o") count))))

;; v, V: start a selection, or switch kind, or leave if already that kind.
(define (visual-command! kind)
  (lambda (count)
    (cond
      [(not (eq? *mode* 'visual)) (enter-visual! kind (cursor))]
      [(eq? *visual* kind) (leave-visual!)]
      [else (set! *visual* kind) (set-mode! 'visual)])))

(define-key! 'normal "v" (visual-command! 'char))
(define-key! 'normal "V" (visual-command! 'line))
(define-key! 'normal "C-v" (visual-command! 'block))
(define-key! 'normal "C-q" (visual-command! 'block))
(define-key! 'visual "C-v" (visual-command! 'block))
(define-key! 'visual "C-q" (visual-command! 'block))
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
      (enter-visual! (car *last-visual*) (mark-get "visual-anchor"))
      (set-cursor! (mark-get "visual-cursor")))))

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
      (begin-change!)
      (let ([r (if linewise?
                   (lines-range (current-line) (min (last-line) (+ (current-line) lines)))
                   (list (cursor) (min (buffer-length) (+ (cursor) chars)) #f))])
        ((hash-ref *operators* op-key) (car r) (cadr r) (caddr r))))))

(define (visual-operator! op-key linewise?)
  (if (eq? *visual* 'block)
      (block-operator! op-key linewise?)
      (char-or-line-operator! op-key linewise?)))

(define (char-or-line-operator! op-key linewise?)
  (let ([range (if linewise?
                   (let ([r (visual-range)])
                     (lines-range (offset->line (car r)) (offset->line (max (car r) (- (cadr r) 1)))))
                   (visual-range))])
    (leave-visual!)
    (begin-change!)
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
    (let* ([reg (or (register-get (current-register)) (list "" #f))]
           [text (string-repeat (car reg) count)] [text-linewise? (cadr reg)]
           [range (visual-range)] [start (car range)] [linewise? (caddr range)])
      (leave-visual!)
      ;; The replaced text goes to the unnamed register, not the one pasted.
      (set! *register-prefix* #f)
      (begin-change!)
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

;;; More operators and commands

;; Case operators: gu gU g~ g?, and ~ on chars.
(define (map-string f text) (list->string (map f (string->list text))))

(define (toggle-case c) (if (equal? (char-upcase c) c) (char-downcase c) (char-upcase c)))

(define (rot13 c)
  (let ([n (char->integer c)])
    (cond [(and (>= n 97) (<= n 122)) (integer->char (+ 97 (modulo (+ (- n 97) 13) 26)))]
          [(and (>= n 65) (<= n 90)) (integer->char (+ 65 (modulo (+ (- n 65) 13) 26)))]
          [else c])))

(define (replace-range! start end text)
  (buffer-delete! start end)
  (buffer-insert! start text))

(define (case-operator f)
  (lambda (start end linewise?)
    (replace-range! start end (map-string f (buffer-substring start end)))
    (set-cursor! (if linewise? (line-first-nonblank (offset->line start)) start))))

(define-operator! "gu" (case-operator char-downcase))
(define-operator! "gU" (case-operator char-upcase))
(define-operator! "g~" (case-operator toggle-case))
(define-operator! "g?" (case-operator rot13))

(define (tilde! count)
  (let* ([p (cursor)] [end (min (+ p count) (line-end (current-line)))])
    (begin-change!)
    (replace-range! p end (map-string toggle-case (buffer-substring p end)))
    (set-cursor! end)))

(define-key! 'normal "~"
  (lambda (count) (tilde! count) (record-change! tilde! count)))

(define-key! 'visual "u" (lambda (count) (visual-operator! "gu" #f)))
(define-key! 'visual "U" (lambda (count) (visual-operator! "gU" #f)))
(define-key! 'visual "~" (lambda (count) (visual-operator! "g~" #f)))

;; Shifting: > and < move lines by shiftwidth, with spaces or tabs as
;; expandtab says. Empty lines are left alone, as in Vim.
(define (indent-string cols)
  (if (option 'expandtab)
      (make-string cols #\space)
      (let ([ts (option 'tabstop)])
        (string-append (make-string (quotient cols ts) #\tab) (make-string (modulo cols ts) #\space)))))

(define (shift-line! line dir)
  (let* ([start (line-start line)] [indent-end (line-first-nonblank line)]
         [cols (display-col indent-end)]
         [sw (option 'shiftwidth)]
         [new (max 0 (if (> dir 0) (+ cols (* sw dir)) (+ cols (* sw dir))))])
    (unless (= (buffer-line-length line) 0)
      (replace-range! start indent-end (indent-string new)))))

(define (shift-operator dir)
  (lambda (start end linewise?)
    (let ([first (offset->line start)] [last (offset->line (max start (- end 1)))])
      (let loop ([l first]) (when (<= l last) (shift-line! l dir) (loop (+ l 1))))
      (set-cursor! (line-first-nonblank first)))))

(define-operator! ">" (shift-operator 1))
(define-operator! "<" (shift-operator -1))

;; In visual mode a count shifts that many times: 3> is three shiftwidths.
(define (visual-shift! dir)
  (lambda (count)
    (let* ([r (visual-range)] [first (offset->line (car r))]
           [last (offset->line (max (car r) (- (cadr r) 1)))]
           [lines (- last first)])
      (leave-visual!)
      (let ([change (lambda (n)
                      (begin-change!)
                      (let ([first (current-line)])
                        (let loop ([l first])
                          (when (<= l (min (last-line) (+ first lines)))
                            (shift-line! l (* dir n))
                            (loop (+ l 1))))
                        (set-cursor! (line-first-nonblank first))))])
        (set-cursor! (line-start first))
        (change count)
        (record-change! change count)))))

(define-key! 'visual ">" (visual-shift! 1))
(define-key! 'visual "<" (visual-shift! -1))

;; r{char}: replace `count` chars. r<ret> replaces them with a line break.
(define (replace-chars! count ch)
  (let* ([p (cursor)] [end (+ p count)])
    (when (<= end (line-end (current-line)))
      (begin-change!)
      (if (equal? ch #\newline)
          (begin (replace-range! p end "\n") (set-cursor! (+ p 1)))
          (begin (replace-range! p end (make-string count ch)) (set-cursor! (- end 1))))
      #t)))

(define-char-command! "r"
  (lambda (count ch)
    (if (eq? *mode* 'visual)
        ;; Visual r replaces every selected char but line breaks.
        (let ([ranges (if (eq? *visual* 'block)
                          (block-segments)
                          (let ([r (visual-range)]) (list (list (car r) (cadr r)))))])
          (leave-visual!)
          (begin-change!)
          (for-each (lambda (r)
                      (replace-range! (car r) (cadr r)
                                      (map-string (lambda (c) (if (equal? c #\newline) c ch))
                                                  (buffer-substring (car r) (cadr r)))))
                    ranges)
          (set-cursor! (car (car ranges))))
        (when (replace-chars! count ch)
          (record-change! (lambda (n) (replace-chars! n ch)) count)))))

;; J joins lines with one space between them (none before a closing paren,
;; or if the line already ends in white space); gJ joins them as they are.
(define (join-lines! line count spaces?)
  (let loop ([i 1])
    (when (and (< i (max 2 count)) (< line (last-line)))
      (let* ([e (line-end line)]
             [next-start (+ e 1)]
             [cut-end (if spaces? (line-first-nonblank (+ line 1)) next-start)])
        (buffer-delete! e cut-end)
        (set-cursor! e)
        (when (and spaces?
                   (> e (line-start line))
                   (not (blank-at? (- e 1)))
                   (< e (line-end line))
                   (not (equal? (buffer-char-at e) #\))))
          (buffer-insert! e " "))
        (loop (+ i 1))))))

(define (join-command spaces?)
  (lambda (count)
    (let ([change (lambda (n) (begin-change!) (join-lines! (current-line) n spaces?))])
      (change count)
      (record-change! change count))))

(define-key! 'normal "J" (join-command #t))
(define-key! 'normal "gJ" (join-command #f))

(define (visual-join spaces?)
  (lambda (count)
    (let* ([r (visual-range)] [first (offset->line (car r))]
           [last (offset->line (max (car r) (- (cadr r) 1)))])
      (leave-visual!)
      (begin-change!)
      (join-lines! first (max 2 (+ 1 (- last first))) spaces?))))

(define-key! 'visual "J" (visual-join #t))
(define-key! 'visual "gJ" (visual-join #f))

;; C-a and C-x: add to the number under or after the cursor. Decimal
;; (with a minus sign) and 0x hex, as with Vim's default nrformats.
(define (hex-digit? c)
  (and c (or (char-numeric-ascii? c) (memv (char-downcase c) (string->list "abcdef")))))

;; The number at or after p on its line, as (start end value hex?), start
;; including any sign or 0x.
(define (number-at p)
  (let* ([line (offset->line p)] [lo (line-start line)] [hi (line-end line)]
         [digit? (lambda (q) (and (< q hi) (char-numeric-ascii? (buffer-char-at q))))]
         ;; Back up to the start of a number the cursor is inside.
         [p (let loop ([q p]) (if (and (> q lo) (hex-digit? (buffer-char-at q)) (hex-digit? (buffer-char-at (- q 1)))) (loop (- q 1)) q))]
         ;; Inside a hex number, back up over its 0x too.
         [p (cond
              [(and (>= (- p 2) lo) (memv (buffer-char-at (- p 1)) (list #\x #\X))
                    (equal? (buffer-char-at (- p 2)) #\0))
               (- p 2)]
              [(and (> p lo) (memv (buffer-char-at p) (list #\x #\X))
                    (equal? (buffer-char-at (- p 1)) #\0))
               (- p 1)]
              [else p])]
         [start (let loop ([q p]) (cond [(>= q hi) #f] [(digit? q) q] [else (loop (+ q 1))]))])
    (and start
         (if (and (equal? (buffer-char-at start) #\0)
                  (memv (buffer-char-at (+ start 1)) (list #\x #\X))
                  (hex-digit? (buffer-char-at (+ start 2))))
             (let ([end (let loop ([q (+ start 2)]) (if (and (< q hi) (hex-digit? (buffer-char-at q))) (loop (+ q 1)) q))])
               (list start end (string->number (buffer-substring (+ start 2) end) 16) #t))
             (let* ([end (let loop ([q start]) (if (digit? q) (loop (+ q 1)) q))]
                    [neg? (and (> start lo) (equal? (buffer-char-at (- start 1)) #\-))]
                    [n (string->number (buffer-substring start end))])
               (list (if neg? (- start 1) start) end (if neg? (- n) n) #f))))))

(define (pad-left text width)
  (if (< (string-length text) width)
      (string-append (make-string (- width (string-length text)) #\0) text)
      text))

(define (increment! delta)
  (let ([num (number-at (cursor))])
    (when num
      (let* ([start (car num)] [end (cadr num)] [value (+ (caddr num) delta)]
             [old (buffer-substring start end)]
             [text (if (cadddr num)
                       (let* ([digits (number->string (modulo value 18446744073709551616) 16)]
                              [upper? (let loop ([cs (string->list old)])
                                        (cond [(null? cs) #f]
                                              [(memv (car cs) (string->list "ABCDEF")) #t]
                                              [else (loop (cdr cs))]))])
                         (string-append (substring old 0 2)
                                        (pad-left (if upper? (string-upcase digits) digits)
                                                  (- (string-length old) 2))))
                       (number->string value))])
        (begin-change!)
        (replace-range! start end text)
        (set-cursor! (+ start (string-length text) -1))
        #t))))

(define (increment-command sign)
  (lambda (count)
    (let ([change (lambda (n) (increment! (* sign n)))])
      (when (change count) (record-change! change count)))))

(define-key! 'normal "C-a" (increment-command 1))
(define-key! 'normal "C-x" (increment-command -1))

(define-key! 'normal "ZZ" (lambda (count) (run-ex! "x")))
(define-key! 'normal "ZQ" (lambda (count) (run-ex! "q!")))

(define-key! 'normal "C-g"
  (lambda (count)
    (let ([lines (buffer-line-count)])
      (set-status! (string-append "\"" (buffer-name) "\""
                                  (if (buffer-modified?) " [Modified]" "")
                                  " " (number->string lines) (if (= lines 1) " line" " lines")
                                  " --" (number->string (quotient (* 100 (+ (current-line) 1)) lines)) "%--")))))

;;; Marks and the jump list
;;;
;;; Marks are kept by the buffer (mark-set!, mark-get), so they move with
;;; the text. m{a-zA-Z} sets one; '{mark} goes to its line and `{mark} to
;;; its exact place, as motions that work with operators. Special marks:
;;; ' (before the latest jump), . (last change), ^ (last insert), [ and ]
;;; (last changed or yanked text), < and > (last visual selection).

(define (mark-char? c)
  (or (letter? c) (memv c (string->list "'`[]<>.^\""))))

(define (mark-pos c)
  (let ([m (mark-get (if (equal? c #\`) "'" (string c)))])
    (or m (begin (set-status! (string-append "mark not set: " (string c))) #f))))

(define-char-command! "m"
  (lambda (count c)
    (if (or (letter? c) (memv c (string->list "'`[]<>")))
        (mark-set! (if (equal? c #\`) "'" (string c)) (cursor))
        (set-status! (string-append "invalid mark " (string c))))))

(define-char-motion! "'" 'linewise
  (lambda (from n c) (let ([m (mark-pos c)]) (and m (line-first-nonblank (offset->line m))))))
(define-char-motion! "`" 'exclusive (lambda (from n c) (mark-pos c)))

;; Motions that count as jumps: they set the ' mark and go in the jump list.
(define (jump-motion? key)
  (or (member key '("G" "gg" "%" "{" "}" "n" "N" "*" "#" "g*" "g#" "H" "M" "L"))
      (and (= (string-length key) 2) (member (substring key 0 1) '("'" "`")))))

(define (jump-mark-line name) (offset->line (or (mark-get name) 0)))

;; Runs `thunk` with buffer `id` current, then switches back.
(define (with-buffer id thunk)
  (let ([here (current-buffer)])
    (if (= id here)
        (thunk)
        (begin
          (switch-to-buffer! id)
          (let ([result (thunk)])
            (switch-to-buffer! here)
            result)))))

;; Jump list entries are (buffer-id . mark-name), so jumps cross buffers.
(define (jump-buffer j) (car j))
(define (jump-mark j) (cdr j))

;; Records the cursor as a jump. Like Vim, an older entry on the same line
;; is dropped, and the list keeps the last 100.
(define (record-jump!)
  (mark-set! "'" (cursor))
  (let* ([line (current-line)] [buf (current-buffer)]
         [keep (filter (lambda (j)
                         (if (and (= (jump-buffer j) buf) (= (jump-mark-line (jump-mark j)) line))
                             (begin (mark-delete! (jump-mark j)) #f)
                             (memv (jump-buffer j) (buffer-list))))
                       *jumps*)]
         [name (string-append "jump" (number->string *jump-counter*))])
    (set! *jump-counter* (+ *jump-counter* 1))
    (mark-set! name (cursor))
    (set! *jumps* (append keep (list (cons buf name))))
    (when (> (length *jumps*) 100)
      (let ([old (car *jumps*)])
        (when (memv (jump-buffer old) (buffer-list))
          (with-buffer (jump-buffer old) (lambda () (mark-delete! (jump-mark old))))))
      (set! *jumps* (cdr *jumps*)))
    (set! *jump-index* (length *jumps*))))

;; C-o and C-i (<tab> in a terminal) move back and forth in the list.
(define (jump-older! count)
  (when (= *jump-index* (length *jumps*))
    ;; Leaving the newest position: remember it so C-i can come back.
    (record-jump!)
    (set! *jump-index* (- (length *jumps*) 1)))
  (jump-to-index! (- *jump-index* count)))

(define (jump-to-index! i)
  (if (or (< i 0) (>= i (length *jumps*)))
      (set! *command-failed* #t)
      (let ([j (list-ref *jumps* i)])
        (set! *jump-index* i)
        (when (and (not (= (jump-buffer j) (current-buffer))) (memv (jump-buffer j) (buffer-list)))
          (go-to-buffer! (jump-buffer j)))
        (set-cursor! (or (mark-get (jump-mark j)) (cursor))))))

(define-key! 'normal "C-o" (lambda (count) (jump-older! count)))
(define-key! 'normal "C-i" (lambda (count) (jump-to-index! (+ *jump-index* count))))
(define-key! 'normal "<tab>" (lambda (count) (jump-to-index! (+ *jump-index* count))))

;;; Popups: output longer than the status line

(define (show-popup! lines)
  (set-popup! lines)
  (set! *popup-shown* #t))

(define (close-popup!)
  (set-popup! '())
  (set! *popup-shown* #f))

;; Shows a char as it would be typed: line breaks as ^J, tabs as ^I.
(define (printable text)
  (apply string-append
         (map (lambda (c) (cond [(equal? c #\newline) "^J"] [(equal? c #\tab) "^I"] [else (string c)]))
              (string->list text))))

(define (pad-right text width)
  (if (< (string-length text) width) (string-append text (make-string (- width (string-length text)) #\space)) text))

(define (clip text width)
  (if (> (string-length text) width) (substring text 0 width) text))

;;; Macros
;;;
;;; q{reg} records keys into a register as text, in Vim's key notation
;;; ("<esc>", "<C-r>", "<lt>" for <), so a macro can be pasted, edited and
;;; yanked back. @{reg} plays it; @@ plays the last one again and @: repeats
;;; the last command line. A key that fails stops the macro, as in Vim.

(define (key->notation key)
  (cond [(equal? key "<") "<lt>"]
        [(= (string-length key) 1) key]
        [(starts-with? key "<") key]
        [else (string-append "<" key ">")]))

(define (keys->string keys) (apply string-append (map key->notation keys)))

;; The inverse: splits text back into keys.
(define (string->keys text)
  (let ([n (string-length text)])
    (let loop ([i 0] [acc '()])
      (if (>= i n)
          (reverse acc)
          (let* ([close (and (equal? (string-ref text i) #\<)
                             (let find ([j (+ i 1)])
                               (cond [(>= j n) #f]
                                     [(equal? (string-ref text j) #\>) j]
                                     [(char-whitespace? (string-ref text j)) #f]
                                     [else (find (+ j 1))])))]
                 [name (and close (> close (+ i 1)) (substring text (+ i 1) close))])
            (cond
              [(not name)
               (let ([c (string-ref text i)])
                 (loop (+ i 1) (cons (if (equal? c #\newline) "<ret>" (string c)) acc)))]
              [(equal? name "lt") (loop (+ close 1) (cons "<" acc))]
              [(or (starts-with? name "C-") (starts-with? name "M-")) (loop (+ close 1) (cons name acc))]
              [else (loop (+ close 1) (cons (string-append "<" name ">") acc))]))))))

(define (start-recording! c)
  (set! *recording* c)
  (set! *recorded-keys* '())
  (show-mode!))

(define (stop-recording!)
  (let ([c *recording*])
    (set! *recording* #f)
    (register-set! c (keys->string (reverse *recorded-keys*)) #f 'macro)
    (show-mode!)))

(define-char-command! "q"
  (lambda (count c)
    (if (or (letter? c) (char-numeric-ascii? c) (equal? c #\"))
        (start-recording! c)
        (set-status! (string-append "invalid register " (string c))))))

;; Feeds `keys` to the editor, stopping early if one fails.
(define (play-keys! keys)
  (set! *command-failed* #f)
  (let loop ([ks keys])
    (unless (or (null? ks) *command-failed*)
      (process-key! (car ks))
      (loop (cdr ks)))))

(define-char-command! "@"
  (lambda (count c)
    (let ([c (if (equal? c #\@) *last-macro* c)])
      (cond
        [(not c) (set-status! "no previous macro")]
        [(equal? c #\:)
         (if *last-ex* (let loop ([i 0]) (when (< i count) (run-ex! *last-ex*) (loop (+ i 1))))
             (set-status! "no previous command line"))]
        [else
         (let ([reg (register-get c)])
           (set! *last-macro* c)
           (if reg
               (let ([keys (string->keys (car reg))])
                 (let loop ([i 0])
                   (when (and (< i count) (not *command-failed*))
                     (play-keys! keys)
                     (loop (+ i 1))))
                 (set! *command-failed* #f))
               (set-status! (string-append "nothing in register " (string c)))))]))))

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

;; Keys that start a longer key: (define-prefix! "z") makes "zz", "zt" ...
;; reachable. Char motions and char commands are prefixes automatically.
(define *prefix-keys* (hash "g" #t "z" #t "Z" #t "[" #t "]" #t "\"" #t))

(define (define-prefix! key)
  (set! *prefix-keys* (hash-insert *prefix-keys* key #t)))

(define (prefix-key? key)
  (or (hash-contains? *prefix-keys* key)
      (hash-contains? *char-motions* key)
      (and (not *operator*) (hash-contains? *char-commands* key))))

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
    [(and (digit? key) (not *prefix*) (not (and (equal? key "0") (equal? *count* ""))))
     (set! *count* (string-append *count* key))]

    ;; Search prompts. With an operator pending, the search is its motion.
    [(and (not *prefix*) (member key '("/" "?"))
          (not (and (equal? *operator* "g?") (equal? key "?")))) ; g??
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
       (set! *register-just-set* #f)
       (cond
         ;; "x names the register for the command that follows.
         [(and (= (string-length key) 2) (starts-with? key "\""))
          (let ([c (string-ref key 1)])
            (if (valid-register? c)
                (begin (set! *register-prefix* c) (set! *register-just-set* #t))
                (set-status! (string-append "invalid register " (string c)))))]

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
              ;; dd, and for two-key operators both gugu and guu.
              [(or (equal? key op)
                   (and (= (string-length op) 2) (equal? key (substring op 1 2))))
               (let ([change (lambda (n) (run-linewise-operator! op n))])
                 (set! *operator* #f)
                 (change count)
                 (when (changing-operator? op) (record-change! change count)))]
              [else (set-status! (string-append "no motion " key))]))
          (set! *count* "")
          (set! *operator-count* "")]

         [(and (eq? *mode* 'visual) (lookup-key 'visual key))
          (set! *count* "")
          ((lookup-key 'visual key) count)]

         [(and (eq? *mode* 'visual) (hash-contains? *operators* key))
          (visual-operator! key #f)
          (set! *count* "")]

         [(and (eq? *mode* 'visual) (hash-contains? *text-objects* key))
          (visual-text-object! key count)
          (set! *count* "")]

         [(and (eq? *mode* 'visual) (find-char-command key))
          => (lambda (cmd) (set! *count* "") (cmd count))]

         [(hash-contains? *operators* key)
          (set! *operator* key)
          (set! *operator-count* *count*)
          (set! *count* "")]

         [(find-motion key)
          => (lambda (m)
               (let ([target ((motion-proc m) (cursor) count)])
                 (cond
                   [(not target) (set! *command-failed* #t)]
                   [else
                    (when (jump-motion? key) (record-jump!))
                    (when (eq? *visual* 'block)
                      (cond [(equal? key "$") (set! *block-eol* #t)]
                            [(vertical-motion? key) #t]
                            [else (set! *block-eol* #f)]))
                    (set-cursor! target)]))
               (set! *count* ""))]

         ;; The count is cleared before a command runs, so keys it feeds itself
         ;; (a macro) start fresh.
         [(and (not (eq? *mode* 'visual)) (lookup-key 'normal key))
          (set! *count* "")
          ((lookup-key 'normal key) count)]

         [(and (not (eq? *mode* 'visual)) (find-char-command key))
          => (lambda (cmd) (set! *count* "") (cmd count))]

         [else
          (set! *count* "")
          (set! *command-failed* #t)
          (set-status! (string-append "no binding for " key))])
       (set! *count-given* #f))])

  ;; The register named with "x lasts for one command.
  (unless (or *operator* *prefix* *register-just-set* (not (equal? *count* "")))
    (set! *register-prefix* #f))

  (when (member *mode* '(normal visual))
    (normal-clamp!)
    (unless (or *operator* *prefix* (vertical-motion? key))
      (set! *goal-col* (current-col)))))

;;; Insert and replace mode

;; The text that typing `keys` inserts, near enough for the ". register.
(define (keys->text keys)
  (apply string-append
         (map (lambda (k)
                (cond [(= (string-length k) 1) k]
                      [(equal? k "<ret>") "\n"]
                      [(equal? k "<tab>") "\t"]
                      [else ""]))
              keys)))

;; The display column of offset `p`, counting tabs to the next tab stop.
(define (display-col p)
  (let ([ts (option 'tabstop)])
    (let loop ([q (line-start (offset->line p))] [col 0])
      (if (>= q p)
          col
          (loop (+ q 1) (if (equal? (buffer-char-at q) #\tab) (+ col (- ts (modulo col ts))) (+ col 1)))))))

(define (insert-tab!)
  (if (option 'expandtab)
      (let ([ts (option 'tabstop)])
        (insert-text! (make-string (- ts (modulo (display-col (cursor)) ts)) #\space)))
      (insert-text! "\t")))

;; If the cursor's line holds only indent that autoindent added, remove it:
;; leaving the line or insert mode doesn't keep stray white space.
(define (drop-unused-autoindent!)
  (when (and *autoindent-line* (= *autoindent-line* (current-line)) (blank-line? (current-line)))
    (let ([start (line-start (current-line))])
      (buffer-delete! start (line-end (current-line)))
      (set-cursor! start)))
  (set! *autoindent-line* #f))

;; smartindent: after a line ending in an opening bracket the new line is
;; indented one shiftwidth more, and <ret> between a pair of brackets puts
;; the closing one on its own line. Modes set which brackets count.
(define-option! 'smartindent #f '(si))
(define-option! 'indent-open "{[(" '())
(define-option! 'indent-close "}])" '())

(define (char-before-cursor-on-line)
  (let ([lo (line-start (current-line))])
    (let loop ([p (cursor)])
      (cond [(<= p lo) #f]
            [(char-whitespace? (buffer-char-at (- p 1))) (loop (- p 1))]
            [else (buffer-char-at (- p 1))]))))

(define (char-after-cursor-on-line)
  (let ([hi (line-end (current-line))])
    (let loop ([p (cursor)])
      (cond [(>= p hi) #f]
            [(char-whitespace? (buffer-char-at p)) (loop (+ p 1))]
            [else (buffer-char-at p)]))))

(define (opens-indent? c) (and c (memv c (string->list (option 'indent-open)))))
(define (closes-indent? c) (and c (memv c (string->list (option 'indent-close)))))

(define (insert-newline!)
  (let* ([indent (if (option 'autoindent)
                     (buffer-substring (line-start (current-line))
                                       (min (cursor) (line-first-nonblank (current-line))))
                     "")]
         [smart? (and (option 'smartindent) (opens-indent? (char-before-cursor-on-line)))]
         [deeper (if smart? (string-append indent (indent-string (option 'shiftwidth))) indent)])
    (drop-unused-autoindent!)
    (if (and smart? (closes-indent? (char-after-cursor-on-line)))
        ;; Between brackets: open a line for the inside, and put the
        ;; closing bracket on the line after it.
        (let ([p (cursor)])
          (insert-text! (string-append "\n" deeper))
          (let ([inside (cursor)])
            (buffer-insert! inside (string-append "\n" indent))
            (set-cursor! inside)))
        (insert-text! (string-append "\n" deeper)))
    (set! *autoindent-line* (and (> (string-length deeper) 0) (current-line)))))

;; Typing a closing bracket first on a line takes one shiftwidth off it.
(define (maybe-dedent-for! ch)
  (when (and (option 'smartindent) (closes-indent? ch)
             (= (cursor) (line-first-nonblank (current-line)))
             (> (cursor) (line-start (current-line))))
    (let* ([line (current-line)] [from-end (- (line-end line) (cursor))])
      (shift-line! line -1)
      (set-cursor! (- (line-end line) from-end)))))

;; C-w: the word (or white space run, or line break) before the cursor.
(define (delete-word-before!)
  (let* ([p (cursor)] [lo (line-start (current-line))])
    (if (= p lo)
        (when (> p 0) (buffer-delete! (- p 1) p) (set-cursor! (- p 1)))
        (let* ([q (let loop ([q p]) (if (and (> q lo) (blank-at? (- q 1))) (loop (- q 1)) q))]
               [q (if (> q lo) (run-start (- q 1) char-class lo) q)])
          (buffer-delete! q p)
          (set-cursor! q)))))

;; C-u: what was typed on this line, or if nothing was, the line before the
;; cursor down to its indent.
(define (delete-line-before!)
  (let* ([p (cursor)] [line (current-line)]
         [q (cond [(and (< *insert-start* p) (= (offset->line *insert-start*) line)) *insert-start*]
                  [(> p (line-first-nonblank line)) (line-first-nonblank line)]
                  [else (line-start line)])])
    (buffer-delete! q p)
    (set-cursor! q)))

;; C-t and C-d: shift the line by shiftwidth, keeping the cursor on its text.
(define (shift-current-line! dir)
  (let* ([line (current-line)] [from-end (- (line-end line) (cursor))])
    (shift-line! line dir)
    (set-cursor! (max (line-first-nonblank line) (- (line-end line) from-end)))))

(define (replace-char! ch)
  (let ([p (cursor)])
    (if (< p (line-end (current-line)))
        (begin
          (set! *replaced* (cons (cons p (buffer-char-at p)) *replaced*))
          (buffer-delete! p (+ p 1)))
        (set! *replaced* (cons (cons p #f) *replaced*)))
    (insert-text! ch)))

;; <bs> in replace mode puts back what was overwritten.
(define (replace-backspace!)
  (when (> (cursor) 0)
    (let ([p (- (cursor) 1)])
      (if (and (pair? *replaced*) (= (car (car *replaced*)) p))
          (let ([old (cdr (car *replaced*))])
            (set! *replaced* (cdr *replaced*))
            (buffer-delete! p (+ p 1))
            (when old (buffer-insert! p (string old)))
            (set-cursor! p))
          (set-cursor! (max (line-start (current-line)) p))))))

(define (insert-key! key)
  (unless (member key '("<ret>" "C-j" "C-m")) (set! *autoindent-line* #f))
  (cond
    ;; A mode's own insert keys come first (the REPL's <ret>).
    [(local-key-proc 'insert key) => (lambda (proc) (proc))]
    [(member key '("<ret>" "C-j" "C-m")) (insert-newline!)]
    [(equal? key "<tab>") (insert-tab!)]
    [(and (member key '("<bs>" "C-h")) (eq? *mode* 'replace)) (replace-backspace!)]
    [(member key '("<bs>" "C-h"))
     (when (> (cursor) 0)
       (buffer-delete! (- (cursor) 1) (cursor))
       (set-cursor! (- (cursor) 1)))]
    [(equal? key "<del>") (buffer-delete! (cursor) (+ (cursor) 1))]
    [(equal? key "C-w") (delete-word-before!)]
    [(equal? key "C-u") (delete-line-before!)]
    [(equal? key "C-t") (shift-current-line! 1)]
    [(equal? key "C-d") (shift-current-line! -1)]
    [(equal? key "<left>") (set-cursor! (max (line-start (current-line)) (- (cursor) 1)))]
    [(equal? key "<right>") (set-cursor! (min (line-end (current-line)) (+ (cursor) 1)))]
    [(equal? key "<home>") (set-cursor! (line-start (current-line)))]
    [(equal? key "<end>") (set-cursor! (line-end (current-line)))]
    [(member key '("<up>" "<down>"))
     (let ([line (clamp (+ (current-line) (if (equal? key "<up>") -1 1)) 0 (last-line))])
       (set-cursor! (line-col->offset line (current-col))))]
    [(and (= (string-length key) 1) (eq? *mode* 'replace)) (replace-char! key)]
    [(and (= (string-length key) 1) (closes-indent? (string-ref key 0)))
     (maybe-dedent-for! (string-ref key 0))
     (insert-text! key)]
    [(= (string-length key) 1) (insert-text! key)]
    [(lookup-key 'insert key) ((lookup-key 'insert key))]
    [else #t]))

(define (insert-text! text)
  (buffer-insert! (cursor) text)
  (set-cursor! (+ (cursor) (string-length text))))

(define (leave-insert!)
  (drop-unused-autoindent!)
  (mark-set! "^" (cursor))
  (set! *last-insert-pos* (cursor))
  (set-mode! 'normal)
  ;; Leaving insert mode steps back onto the last inserted char.
  (when (> (current-col) 0)
    (set-cursor! (- (cursor) 1)))
  (normal-clamp!)
  (set! *goal-col* (current-col)))

(define (insert-mode-key! key)
  (cond
    ;; C-r {register} inserts the register's text.
    [*insert-pending*
     (set! *insert-pending* #f)
     (set! *insert-keys* (cons key *insert-keys*))
     (let* ([c (key-char key)] [reg (and c (valid-register? c) (register-get c))])
       (when reg (insert-text! (car reg))))]
    [(equal? key "C-r")
     (set! *insert-keys* (cons key *insert-keys*))
     (set! *insert-pending* #t)]
    [(member key '("<esc>" "C-c" "C-["))
     (let ([keys (reverse *insert-keys*)])
       (set! *last-inserted* (keys->text keys))
       (repeat-insert! keys (- *insert-count* 1) *insert-reentry*)
       (when *block-insert* (finish-block-insert!))
       (leave-insert!)
       (finish-insert-record! keys)
       (set! *insert-count* 1)
       (set! *insert-reentry* #f))]
    ;; C-o runs one normal-mode command, then comes back.
    [(equal? key "C-o")
     (set! *insert-return* *mode*)
     (set-mode! 'normal)]
    [else
     (set! *insert-keys* (cons key *insert-keys*))
     (insert-key! key)]))

;;; The command line
;;;
;;; One prompt serves `:`, `/` and `?`. Whoever opens it says what happens
;;; on each edit, on <ret> and on <esc>.

(define (open-cmdline! prompt initial on-submit on-change on-cancel)
  ;; Back to whatever state opened it (normal, visual, emacs...).
  (set! *cmdline-return* (if (eq? *mode* 'cmdline) *cmdline-return* *mode*))
  (set! *cmdline-prompt* prompt)
  (set! *cmdline* initial)
  (set! *cmdline-pos* (string-length initial))
  (set! *cmdline-submit* on-submit)
  (set! *cmdline-change* on-change)
  (set! *cmdline-cancel* on-cancel)
  (set! *history-index* -1)
  (set-mode! 'cmdline)
  (show-cmdline!))

(define (show-cmdline!)
  (set-cmdline! (string-append *cmdline-prompt* *cmdline*)
                (+ (string-length *cmdline-prompt*) *cmdline-pos*)))

(define (close-cmdline!)
  (set! *cmdline-key-handler* #f)
  (clear-cmdline!)
  (set-mode! *cmdline-return*)
  (set-status! ""))

;; Replaces the text, putting the cursor at `pos`.
(define (cmdline-edit! text pos)
  (set! *cmdline* text)
  (set! *cmdline-pos* (clamp pos 0 (string-length text)))
  (show-cmdline!)
  (when *cmdline-change* (*cmdline-change* text)))

(define (cmdline-before) (substring *cmdline* 0 *cmdline-pos*))
(define (cmdline-after) (substring *cmdline* *cmdline-pos* (string-length *cmdline*)))

;; Inserts text at the cursor.
(define (cmdline-insert! text)
  (cmdline-edit! (string-append (cmdline-before) text (cmdline-after))
                 (+ *cmdline-pos* (string-length text))))

;; Deletes from `from` to the cursor.
(define (cmdline-delete-back! from)
  (cmdline-edit! (string-append (substring *cmdline* 0 from) (cmdline-after)) from))

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

;;; Command-line history: one list per prompt, newest first. <up> and
;;; <down> go through the entries that start with what was typed.

(define (history prompt) (or (hash-try-get *history* prompt) '()))

(define (add-history! prompt text)
  (unless (equal? text "")
    (let* ([old (filter (lambda (h) (not (equal? h text))) (history prompt))]
           [new (cons text old)])
      (set! *history* (hash-insert *history* prompt
                                   (if (> (length new) 200) (take new 200) new))))))


(define (history-step! dir)
  (when (= *history-index* -1) (set! *history-prefix* *cmdline*))
  (let* ([entries (history *cmdline-prompt*)]
         [n (length entries)])
    (let loop ([i (+ *history-index* dir)])
      (cond
        [(< i 0)
         (set! *history-index* -1)
         (cmdline-edit! *history-prefix* (string-length *history-prefix*))]
        [(>= i n) #f]
        [(starts-with? (list-ref entries i) *history-prefix*)
         (set! *history-index* i)
         (cmdline-edit! (list-ref entries i) (string-length (list-ref entries i)))]
        [else (loop (+ i dir))]))))

(define (cmdline-key! key)
  (cond
    ;; Completion menus and the like take the keys they want first.
    [(and *cmdline-key-handler* (*cmdline-key-handler* key)) #t]
    ;; C-r {register} inserts a register; C-r C-w the word under the cursor.
    [*cmdline-pending*
     (set! *cmdline-pending* #f)
     (cmdline-insert!
      (cond
        [(equal? key "C-w")
         (let ([w (word-at (cursor))]) (if w (buffer-substring (car w) (cadr w)) ""))]
        [(and (key-char key) (valid-register? (key-char key)))
         (let ([reg (register-get (key-char key))])
           (if reg (without-final-newline (car reg)) ""))]
        [else ""]))]
    [(equal? key "C-r") (set! *cmdline-pending* #t)]
    [(member key '("<esc>" "C-c"))
     (add-history! *cmdline-prompt* *cmdline*)
     (close-cmdline!)
     (when *cmdline-cancel* (*cmdline-cancel*))]
    [(member key '("<ret>" "C-m" "C-j"))
     (add-history! *cmdline-prompt* *cmdline*)
     (close-cmdline!)
     (*cmdline-submit* *cmdline*)
     (when (member *mode* '(normal visual)) (normal-clamp!))]
    [(member key '("<bs>" "C-h"))
     (cond
       [(equal? *cmdline* "")
        (close-cmdline!)
        (when *cmdline-cancel* (*cmdline-cancel*))]
       [(> *cmdline-pos* 0) (cmdline-delete-back! (- *cmdline-pos* 1))]
       [else #t])]
    [(equal? key "<del>")
     (when (< *cmdline-pos* (string-length *cmdline*))
       (cmdline-edit! (string-append (cmdline-before)
                                     (substring *cmdline* (+ *cmdline-pos* 1) (string-length *cmdline*)))
                      *cmdline-pos*))]
    [(equal? key "C-u") (cmdline-delete-back! 0)]
    [(equal? key "C-w") (cmdline-delete-back! (string-length (drop-last-word (cmdline-before))))]
    [(equal? key "<left>") (cmdline-edit! *cmdline* (- *cmdline-pos* 1))]
    [(equal? key "<right>") (cmdline-edit! *cmdline* (+ *cmdline-pos* 1))]
    [(member key '("<home>" "C-b")) (cmdline-edit! *cmdline* 0)]
    [(member key '("<end>" "C-e")) (cmdline-edit! *cmdline* (string-length *cmdline*))]
    [(member key '("<up>" "C-p")) (history-step! 1)]
    [(member key '("<down>" "C-n")) (history-step! -1)]
    [(equal? key "<tab>") (cmdline-complete!)]
    [(= (string-length key) 1) (cmdline-insert! key)]
    [else #t]))

;; <tab> on the command line: completion arrives with the completion
;; framework (2.8). Until then it completes ex command names.
(define (cmdline-complete!)
  (when (equal? *cmdline-prompt* ":")
    (let* ([text (cmdline-before)]
           [names (filter (lambda (n) (and (starts-with? n text) (> (string-length n) (string-length text))))
                          (hash-keys->list *ex-commands*))]
           [names (sort names (lambda (a b) (< (string-length a) (string-length b))))])
      (if (null? names)
          (set-status! "no completions")
          (cmdline-insert! (substring (car names) (string-length text) (string-length (car names))))))))

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
  (if (and *hlsearch* *last-search* (option 'hlsearch))
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
          (cond
            [(not r)
             (set-status! (string-append "Pattern not found: " pattern))
             (set! *command-failed* #t)
             #f]
            [(and (= (cadr r) 1) (not (option 'wrapscan)))
             (set-status! (string-append "search hit " (if forward? "BOTTOM" "TOP")
                                         " without match for: " pattern))
             #f]
            [else (loop (+ i 1) (car r) (or wrapped (= (cadr r) 1)))])))))

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
    (begin-change!)
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
                [else (record-jump!) (set-cursor! target)]))])))
     ;; Incremental search: show where the pattern matches so far.
     (lambda (text)
       (set-cursor! origin)
       (if (or (not (option 'incsearch)) (equal? text "") (pattern-error text))
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
  (let ([m (mark-get (if (eq? which 'start) "<" ">"))])
    (and m (offset->line m))))

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
         ;; Names are letters, with dashes inside longer ones
         ;; (:describe-key).
         [name-end (let loop ([j i])
                     (if (or (letter? (char-at line j))
                             (and (> j i) (equal? (char-at line j) #\-) (letter? (char-at line (+ j 1)))))
                         (loop (+ j 1))
                         j))]
         ;; A command that isn't letters is one char: & < > ! =
         [name-end (if (and (= name-end i) (char-at line i)) (+ i 1) name-end)]
         [name (substring line i name-end)]
         [bang? (and (equal? (char-at line name-end) #\!) (not (equal? name "!")))]
         [args-start (skip-spaces line (if bang? (+ name-end 1) name-end))]
         [args (substring line args-start (string-length line))]
         [range (list (clamp (car range) 0 (last-line)) (clamp (cadr range) 0 (last-line)))])
    (list name (list range (cadr r) bang? args))))

(define (run-ex! line)
  (unless (equal? line "") (set! *last-ex* line))
  (let ([parsed (with-handler (lambda (e) (error-message e)) (parse-ex line))])
    (if (string? parsed)
        (set-status! parsed)
        (let* ([name (car parsed)] [ex (cadr parsed)] [cmd (hash-try-get *ex-commands* name)])
          (cond
            [cmd (with-handler (lambda (e) (set-status! (error-message e))) (cmd ex))]
            ;; A range on its own goes to its last line.
            [(equal? name "")
             (when (ex-range-given? ex)
               (record-jump!)
               (set-cursor! (line-first-nonblank (cadr (ex-range ex)))))]
            [else (set-status! (string-append "not an editor command: " line))])))))

;; The message of a caught error, without the space Steel puts in front.
(define (error-message e)
  (let* ([m (error-object-message e)] [m (if (string? m) m (to-string m))])
    (substring m (skip-spaces m 0) (string-length m))))

;; The line of mark `c`, for ex addresses like 'a.
(define (mark-line c)
  (let ([m (mark-get (if (equal? c #\`) "'" (string c)))]) (and m (offset->line m))))

(define-key! 'normal ":"
  (lambda (count)
    (open-cmdline! ":" (if *count-given* (string-append ".,.+" (number->string (- count 1))) "")
                   run-ex! #f #f)))

(define-key! 'visual ":"
  (lambda (count)
    (leave-visual!)
    (open-cmdline! ":" "'<,'>" run-ex! #f #f)))

;;; The ex commands

(define-ex! '("marks")
  (lambda (ex)
    (let ([names (filter (lambda (n) (= (string-length n) 1)) (mark-names))])
      (show-popup!
       (cons "mark line  col text"
             (map (lambda (n)
                    (let* ([p (mark-get n)] [line (offset->line p)])
                      (string-append " " (pad-right n 4) (pad-right (number->string (+ line 1)) 6)
                                     (pad-right (number->string (offset->col p)) 5)
                                     (clip (printable (buffer-substring (line-start line) (line-end line))) 60))))
                  names))))))

(define-ex! '("delm" "delmarks")
  (lambda (ex)
    (if (ex-bang? ex)
        (for-each (lambda (n) (when (letter? (string-ref n 0)) (when (= (string-length n) 1) (mark-delete! n))))
                  (mark-names))
        (for-each (lambda (c) (unless (char-whitespace? c) (mark-delete! (string c))))
                  (string->list (ex-args ex))))))

(define-ex! '("reg" "registers" "di" "display")
  (lambda (ex)
    (let ([names (string->list "\"0123456789abcdefghijklmnopqrstuvwxyz-.:/%")])
      (show-popup!
       (cons "reg  type text"
             (filter (lambda (x) x)
                     (map (lambda (c)
                            (let ([r (if (memv c (string->list ".:/%")) (register-get c) (hash-try-get *registers* c))])
                              (and r (not (equal? (car r) ""))
                                   (string-append " \"" (string c) "  " (if (cadr r) "l    " "c    ")
                                                  (clip (printable (car r)) 70)))))
                          names)))))))

(define-ex! '("ju" "jumps")
  (lambda (ex)
    (show-popup!
     (cons " jump line  col text"
           (let loop ([js *jumps*] [i 0] [acc '()])
             (if (null? js)
                 (reverse (cons ">" acc))
                 (let* ([j (car js)]
                        [p (if (= (jump-buffer j) (current-buffer)) (or (mark-get (jump-mark j)) 0) 0)]
                        [line (offset->line p)])
                   (loop (cdr js) (+ i 1)
                         (cons (string-append (if (= i *jump-index*) ">" " ")
                                              (pad-right (number->string (abs (- *jump-index* i))) 5)
                                              (pad-right (number->string (+ line 1)) 6)
                                              (pad-right (number->string (offset->col p)) 5)
                                              (clip (printable (buffer-substring (line-start line) (line-end line))) 60))
                               acc)))))))))

;; Saves the current buffer, running the save hooks. Returns #t if saved.
;; A file changed on disk since it was read isn't overwritten unless
;; `force?` (as :w! does).
(define (save-buffer! . force)
  (cond
    [(and (buffer-changed-on-disk?) (file-exists? (or (buffer-path) "")) (or (null? force) (not (car force))))
     (message (string-append (buffer-name) " changed on disk since it was read (:w! to overwrite, :e! to reload)"))
     #f]
    [else
     (run-hooks 'before-save)
     (set-backup! (option 'backup))
     (and (save!)
          (begin (run-hooks 'after-save) #t))]))

;; :w writes the buffer; :w FILE writes a copy (or names the buffer, if it
;; had no file).
(define (write-buffer! ex)
  (let ([file (ex-args ex)])
    (cond
      [(equal? file "")
       (if (buffer-path)
           (when (save-buffer! (ex-bang? ex)) (set-status! (string-append "wrote " (buffer-name))))
           (set-status! "no file name (use :w FILE)"))]
      [(and (file-exists? (expand-path file)) (not (ex-bang? ex)) (not (equal? (expand-path file) (buffer-path))))
       (set-status! (string-append file " exists (add ! to override)"))]
      [(not (buffer-path)) (set-buffer-path! (expand-path file)) (write-buffer! (list (ex-range ex) #f #f ""))]
      [else
       (let ([r (with-handler (lambda (e) (error-message e)) (write-file! (expand-path file)))])
         (set-status! (if (string? r) r (string-append "wrote " file))))])))

(define-ex! '("w" "write") write-buffer!)
(define-ex! '("wa" "wall")
  (lambda (ex) (when (write-all!) (set-status! "wrote all buffers"))))
(define-ex! '("sav" "saveas")
  (lambda (ex)
    (if (equal? (ex-args ex) "")
        (set-status! "saveas needs a file name")
        (begin (set-buffer-path! (expand-path (ex-args ex))) (write-buffer! (list (ex-range ex) #f #f ""))))))

;; Quits unless some buffer has unsaved changes (or ! was given).
(define (quit-if-saved! ex)
  (let ([dirty (modified-buffers)])
    (if (and (pair? dirty) (not (ex-bang? ex)))
        (begin
          (set-status! (string-append "unsaved changes in " (car (buffer-info (car dirty)))
                                      " (add ! to override)"))
          (unless (= (car dirty) (current-buffer)) (go-to-buffer! (car dirty))))
        (quit!))))

;; :q closes the window when there are several, as in Vim; :qa quits.
(define-ex! '("q" "quit")
  (lambda (ex)
    (if (> (length (window-list)) 1)
        (close-current-window!)
        (quit-if-saved! ex))))
(define-ex! '("qa" "qall" "quita" "quitall") quit-if-saved!)
;; :wq and :x close the window too when there are several.
(define (quit-window-or-editor! ex)
  (if (> (length (window-list)) 1)
      (close-current-window!)
      (quit-if-saved! ex)))

(define-ex! "wq"
  (lambda (ex) (when (save-buffer!) (quit-window-or-editor! ex))))
;; :x writes only if there is something to write.
(define-ex! '("x" "xit" "exit")
  (lambda (ex)
    (when (or (not (buffer-modified?)) (save-buffer!)) (quit-window-or-editor! ex))))
;; In a daemon, stops it for every client (:q only detaches one).
(define-ex! '("kill-server") (lambda (ex) (kill-server!)))

(define-ex! '("wqa" "wqall" "xa" "xall")
  (lambda (ex) (when (write-all!) (quit-if-saved! ex))))

(define-ex! '("noh" "nohlsearch")
  (lambda (ex) (set! *hlsearch* #f) (refresh-search-highlight!)))

;; :d and :y over lines, into the register like dd and yy.
(define (ex-lines-operator op-key)
  (lambda (ex)
    (let* ([range (ex-range ex)] [r (lines-range (car range) (cadr range))])
      (begin-change!)
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
            (begin-change!)
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

;; :set opt, :set noopt, :set opt=value, :set opt? and :set opt! (toggle).
(define (set-one-option! arg) (set-one-option-with! set-option! arg))

;; The same, setting with `setter` (set-option! or set-local-option!).
(define (set-one-option-with! setter arg)
  (let* ([eq (let loop ([i 0]) (cond [(>= i (string-length arg)) #f] [(equal? (string-ref arg i) #\=) i] [else (loop (+ i 1))]))]
         [query? (ends-with? arg "?")]
         [toggle? (ends-with? arg "!")]
         [word (cond [eq (substring arg 0 eq)]
                     [(or query? toggle?) (substring arg 0 (- (string-length arg) 1))]
                     [else arg])]
         [no? (and (not eq) (starts-with? word "no") (not (option-name (string->symbol word))))]
         [name (option-name (string->symbol (if no? (substring word 2 (string-length word)) word)))])
    (cond
      [(not name) (set-status! (string-append "unknown option: " word))]
      [query? (set-status! (string-append (symbol->string name) "=" (to-string (option name))))]
      [eq (let* ([text (substring arg (+ eq 1) (string-length arg))]
                 [n (string->number text)])
            (setter name (if n n text)))]
      [toggle? (setter name (not (option name)))]
      [(boolean? (option name)) (setter name (not no?))]
      [else (set-status! (string-append (symbol->string name) "=" (to-string (option name))))])))

(define-ex! '("se" "set")
  (lambda (ex) (for-each set-one-option! (split-whitespace (ex-args ex)))))

;;; Buffers
;;;
;;; Every buffer stays open until :bd; switching keeps each one's cursor.
;;; As with Vim's 'hidden', a modified buffer can be left without saving;
;;; :q and :qa refuse while any buffer has unsaved changes.

;; Makes buffer `id` current, remembering the one left for C-^.
(define (go-to-buffer! id)
  (unless (= id (current-buffer))
    (when (eq? *mode* 'visual) (leave-visual!))
    (set! *alternate-buffer* (current-buffer))
    (switch-to-buffer! id)
    (normal-clamp!)
    (set! *goal-col* (current-col))
    (run-hooks 'buffer-enter)))

;; Opens `path` (or switches to the buffer that has it) and returns the id,
;; or #f after saying why on the status line.
(define (open-file! path)
  (let ([r (buffer-open! (expand-path path))])
    (if (string? r)
        (begin (set-status! r) #f)
        (begin
          (record-jump!)
          (let ([new? (not (buffer-seen? r))])
            (go-to-buffer! r)
            (when new? (mark-buffer-seen! r) (run-hooks 'buffer-open)))
          r))))

;; Called when a daemon client asks for files (imp --connect FILE...).
(define (imp-open-files paths) (for-each open-file! paths))

(define *seen-buffers* (hash))
(define (buffer-seen? id) (hash-contains? *seen-buffers* id))
(define (mark-buffer-seen! id) (set! *seen-buffers* (hash-insert *seen-buffers* id #t)))

;; ~ and $HOME at the start of a path.
(define (expand-path path)
  (cond
    [(equal? path "~") (home-dir)]
    [(starts-with? path "~/") (string-append (home-dir) (substring path 1 (string-length path)))]
    [else path]))

(define (buffer-modified-by-id? id)
  (let ([info (buffer-info id)]) (and info (caddr info))))

(define (modified-buffers)
  (filter buffer-modified-by-id? (buffer-list)))

;; :e FILE opens it; :e alone re-reads the current file if unchanged, and
;; :e! re-reads it discarding changes; :e # is the alternate buffer.
(define-ex! '("e" "edit")
  (lambda (ex)
    (let ([arg (ex-args ex)])
      (cond
        [(equal? arg "#")
         (if (and *alternate-buffer* (memv *alternate-buffer* (buffer-list)))
             (go-to-buffer! *alternate-buffer*)
             (set-status! "no alternate file"))]
        [(not (equal? arg "")) (open-file! arg)]
        [(not (buffer-path)) (set-status! "no file name")]
        [(and (buffer-modified?) (not (ex-bang? ex)))
         (set-status! "unsaved changes (add ! to discard them)")]
        [else
         (let ([r (with-handler (lambda (e) (error-message e)) (buffer-reload!))])
           (if (string? r)
               (set-status! r)
               (begin (normal-clamp!) (set-status! (string-append "reloaded " (buffer-name))))))]))))

(define-ex! '("ene" "enew")
  (lambda (ex) (go-to-buffer! (buffer-new! ""))))

(define (buffer-line id)
  (let ([info (buffer-info id)])
    (string-append (pad-right (number->string id) 4)
                   (cond [(= id (current-buffer)) "%a "]
                         [(equal? id *alternate-buffer*) "#  "]
                         [else "   "])
                   (if (caddr info) "+ " "  ")
                   "\"" (car info) "\"")))

(define-ex! '("ls" "buffers" "files")
  (lambda (ex) (show-popup! (map buffer-line (buffer-list)))))

;; :b N or :b NAME (any unique part of a name).
(define (find-buffer arg)
  (let ([n (string->number arg)])
    (if n
        (and (memv n (buffer-list)) n)
        (let ([hits (filter (lambda (id) (string-contains? (car (buffer-info id)) arg)) (buffer-list))])
          (cond [(null? hits) (set-status! (string-append "no matching buffer for " arg)) #f]
                [(null? (cdr hits)) (car hits)]
                [else (set-status! (string-append "more than one match for " arg)) #f])))))

(define-ex! '("b" "bu" "buf" "buffer")
  (lambda (ex)
    (let ([id (if (equal? (ex-args ex) "")
                  (and (ex-range-given? ex) (+ 1 (cadr (ex-range ex))))
                  (find-buffer (ex-args ex)))])
      (when id
        (if (memv id (buffer-list)) (go-to-buffer! id) (set-status! "no such buffer"))))))

;; The buffer `step` places after (or before) the current one, wrapping.
(define (buffer-step step)
  (let* ([ids (buffer-list)] [n (length ids)]
         [i (let loop ([l ids] [i 0]) (if (= (car l) (current-buffer)) i (loop (cdr l) (+ i 1))))])
    (list-ref ids (modulo (+ i step) n))))

(define-ex! '("bn" "bnext") (lambda (ex) (go-to-buffer! (buffer-step 1))))
(define-ex! '("bp" "bprevious" "bN" "bNext") (lambda (ex) (go-to-buffer! (buffer-step -1))))

(define-ex! '("bd" "bdelete" "bw" "bwipeout")
  (lambda (ex)
    (let ([id (if (equal? (ex-args ex) "") (current-buffer) (find-buffer (ex-args ex)))])
      (cond
        [(not id) #f]
        [(and (buffer-modified-by-id? id) (not (ex-bang? ex)))
         (set-status! "unsaved changes (add ! to discard them)")]
        [else
         (let ([alt *alternate-buffer*])
           ;; Prefer going back to the alternate buffer, as Vim does.
           (when (and (= id (current-buffer)) alt (not (= alt id)) (memv alt (buffer-list)))
             (go-to-buffer! alt))
           (run-hooks 'buffer-kill id)
           (buffer-kill! id)
           (kill-buffer-locals! id)
           (when (equal? *alternate-buffer* id) (set! *alternate-buffer* #f))
           (set! *jumps* (filter (lambda (j) (not (= (jump-buffer j) id))) *jumps*))
           (set! *jump-index* (length *jumps*))
           (normal-clamp!))]))))

(define-key! 'normal "C-^"
  (lambda (count)
    (if (and *alternate-buffer* (memv *alternate-buffer* (buffer-list)))
        (go-to-buffer! *alternate-buffer*)
        (set-status! "no alternate file"))))
(define-key! 'normal "C-6" (lookup-key 'normal "C-^"))

;; Writes every modified buffer that has a file. Returns #t if all went.
(define (write-all!)
  (let ([ok #t])
    (for-each (lambda (id)
                (with-buffer id
                  (lambda ()
                    (when (and (buffer-modified?) (buffer-path))
                      (unless (save-buffer!) (set! ok #f))))))
              (buffer-list))
    ok))

;;; Windows
;;;
;;; Rust owns the layout (split-window!, close-window!, focus-window!...);
;;; these are Vim's commands for it. A new split shows the same buffer and
;;; is focused; it goes above or to the left unless splitbelow/splitright.

(define-option! 'splitbelow #f '(sb))
(define-option! 'splitright #f '(spr))

(define (leave-pending-states!)
  (when (eq? *mode* 'visual) (leave-visual!)))

(define (split! vertical?)
  (leave-pending-states!)
  (split-window! (if vertical?
                     (if (option 'splitright) "right" "left")
                     (if (option 'splitbelow) "below" "above")))
  (after-window-change!))

;; After focus moves to another window: its buffer may differ, so the
;; buffer's options and mode line come back, as on switching buffers.
(define (after-window-change!)
  (normal-clamp!)
  (set! *goal-col* (current-col))
  (run-hooks 'buffer-enter))

(define (go-to-window! id)
  (when id
    (leave-pending-states!)
    (unless (= id (current-window))
      (focus-window! id)
      (after-window-change!))))

(define (window-step step)
  (let* ([ws (window-list)] [n (length ws)]
         [i (let loop ([l ws] [i 0]) (if (= (car l) (current-window)) i (loop (cdr l) (+ i 1))))])
    (list-ref ws (modulo (+ i step) n))))

(define (close-current-window!)
  (if (close-window! (current-window))
      (after-window-change!)
      (message "can't close the last window")))

;; :sp FILE and :vs FILE split and open FILE in the new window.
(define (split-ex vertical?)
  (lambda (ex)
    (split! vertical?)
    (unless (equal? (ex-args ex) "") (open-file! (ex-args ex)))))

(define-ex! '("sp" "split") (split-ex #f))
(define-ex! '("vs" "vsplit") (split-ex #t))
(define-ex! '("new") (lambda (ex) (split! #f) (go-to-buffer! (buffer-new! ""))))
(define-ex! '("vne" "vnew") (lambda (ex) (split! #t) (go-to-buffer! (buffer-new! ""))))
(define-ex! '("clo" "close") (lambda (ex) (close-current-window!)))
(define-ex! '("on" "only") (lambda (ex) (only-window!)))

(define (window-command! keys proc)
  (for-each (lambda (k) (define-key! 'normal (string-append "C-w" k) proc)
                        (define-key! 'visual (string-append "C-w" k) proc))
            keys))

(define-prefix! "C-w")
(window-command! '("s" "S" "C-s") (lambda (n) (split! #f)))
(window-command! '("v" "C-v") (lambda (n) (split! #t)))
(window-command! '("n" "C-n") (lambda (n) (split! #f) (go-to-buffer! (buffer-new! ""))))
(window-command! '("w" "C-w") (lambda (n) (go-to-window! (window-step n))))
(window-command! '("W") (lambda (n) (go-to-window! (window-step (- n)))))
(window-command! '("h" "C-h" "<left>") (lambda (n) (go-to-window! (window-in-direction "left"))))
(window-command! '("l" "C-l" "<right>") (lambda (n) (go-to-window! (window-in-direction "right"))))
(window-command! '("k" "C-k" "<up>") (lambda (n) (go-to-window! (window-in-direction "up"))))
(window-command! '("j" "C-j" "<down>") (lambda (n) (go-to-window! (window-in-direction "down"))))
(window-command! '("c" "C-c" "q" "C-q") (lambda (n) (close-current-window!)))
(window-command! '("o" "C-o") (lambda (n) (only-window!)))
(window-command! '("=") (lambda (n) (equalize-windows!)))
(window-command! '("+") (lambda (n) (resize-window! "height" n)))
(window-command! '("-") (lambda (n) (resize-window! "height" (- n))))
(window-command! '(">") (lambda (n) (resize-window! "width" n)))
(window-command! '("<") (lambda (n) (resize-window! "width" (- n))))

;;; Line commands: :m :t :> :< :j :pu :k :p :sort :normal :g

;; Text of lines first..last, each with its line break.
(define (lines-text first last)
  (let ([r (lines-range first last)])
    (let ([text (buffer-substring (car r) (cadr r))])
      (if (ends-with? text "\n") text (string-append text "\n")))))

;; Deletes lines first..last, keeping the file's final newline.
(define (delete-lines! first last)
  (let ([r (lines-range first last)])
    (if (and (= (cadr r) (buffer-length)) (> (car r) 0))
        (buffer-delete! (- (car r) 1) (without-final-break (car r) (cadr r)))
        (buffer-delete! (car r) (cadr r)))))

;; Inserts whole lines (text ending in a line break) after line `line`, or
;; before the first line if `line` is -1.
(define (insert-lines-after! line text)
  (cond
    [(< line 0) (buffer-insert! 0 text)]
    [(< line (last-line)) (buffer-insert! (line-start (+ line 1)) text)]
    [(and (> (buffer-length) 0) (not (equal? (buffer-substring (- (buffer-length) 1) (buffer-length)) "\n")))
     (buffer-insert! (buffer-length) (string-append "\n" (without-final-newline text)))]
    [else (buffer-insert! (buffer-length) text)]))

;; The line an address argument names (as for :m and :t), 0 meaning
;; "before the first line" and so -1 here.
(define (address-arg text)
  (if (equal? (substring text (skip-spaces text 0) (string-length text)) "0")
      -1
      (let ([a (parse-address text 0)])
        (or (car a) (error "missing address")))))

(define-ex! '("m" "mo" "move")
  (lambda (ex)
    (let* ([first (car (ex-range ex))] [last (cadr (ex-range ex))]
           [to (address-arg (ex-args ex))])
      (if (and (>= to first) (< to last))
          (set-status! "cannot move a range into itself")
          (let ([text (lines-text first last)] [n (+ 1 (- last first))])
            (begin-change!)
            (delete-lines! first last)
            ;; Lines above the target moved up if the range was above it.
            (let ([to (if (> to last) (- to n) to)])
              (insert-lines-after! to text)
              (set-cursor! (line-first-nonblank (+ to n)))))))))

(define-ex! '("t" "co" "copy")
  (lambda (ex)
    (let* ([first (car (ex-range ex))] [last (cadr (ex-range ex))]
           [to (address-arg (ex-args ex))]
           [text (lines-text first last)])
      (begin-change!)
      (insert-lines-after! to text)
      (set-cursor! (line-first-nonblank (+ to 1 (- last first)))))))

;; :> and :< shift once per > or < (:>> twice).
(define (ex-shift dir)
  (lambda (ex)
    (let ([times (+ 1 (string-length (ex-args ex)))])
      (begin-change!)
      (let loop ([l (car (ex-range ex))])
        (when (<= l (cadr (ex-range ex)))
          (shift-line! l (* dir times))
          (loop (+ l 1))))
      (set-cursor! (line-first-nonblank (cadr (ex-range ex)))))))

(define-ex! ">" (ex-shift 1))
(define-ex! "<" (ex-shift -1))

(define-ex! '("j" "join")
  (lambda (ex)
    (let ([first (car (ex-range ex))] [last (cadr (ex-range ex))])
      (begin-change!)
      (join-lines! first (if (ex-range-given? ex) (+ 1 (- last first)) 2) (not (ex-bang? ex))))))

(define-ex! '("u" "undo") (lambda (ex) ((lookup-key 'normal "u") 1)))
(define-ex! '("red" "redo") (lambda (ex) ((lookup-key 'normal "C-r") 1)))

;; :pu [x] puts a register's text as lines below the line (:pu! above).
(define-ex! '("pu" "put")
  (lambda (ex)
    (let* ([arg (ex-args ex)]
           [c (if (equal? arg "") #\" (string-ref arg 0))]
           [reg (register-get c)])
      (if (not reg)
          (set-status! (string-append "nothing in register " (string c)))
          (let* ([text (car reg)]
                 [text (if (ends-with? text "\n") text (string-append text "\n"))]
                 [line (cadr (ex-range ex))]
                 [after (if (ex-bang? ex) (- line 1) line)])
            (begin-change!)
            (insert-lines-after! after text)
            (set-cursor! (line-first-nonblank (+ after (length (split-lines text))))))))))

(define (split-lines text)
  (let loop ([cs (string->list text)] [cur '()] [acc '()])
    (cond
      [(null? cs) (reverse (if (null? cur) acc (cons (list->string (reverse cur)) acc)))]
      [(equal? (car cs) #\newline) (loop (cdr cs) '() (cons (list->string (reverse cur)) acc))]
      [else (loop (cdr cs) (cons (car cs) cur) acc)])))

(define-ex! '("k" "ma" "mark")
  (lambda (ex)
    (let ([arg (ex-args ex)])
      (if (equal? arg "")
          (set-status! "mark needs a name")
          (mark-set! (string (string-ref arg 0)) (line-start (cadr (ex-range ex))))))))

;; :p and :nu show lines in a popup; :g with no command collects them.
(define *print-lines* #f)

(define (print-lines! ex numbered?)
  (let loop ([l (car (ex-range ex))] [acc '()])
    (if (> l (cadr (ex-range ex)))
        (let ([lines (reverse acc)])
          (if *print-lines*
              (set! *print-lines* (append *print-lines* lines))
              (show-popup! lines))
          (set-cursor! (line-first-nonblank (cadr (ex-range ex)))))
        (loop (+ l 1)
              (cons (string-append (if numbered? (pad-right (number->string (+ l 1)) 4) "")
                                   (printable (buffer-substring (line-start l) (line-end l))))
                    acc)))))

(define-ex! '("p" "print") (lambda (ex) (print-lines! ex #f)))
(define-ex! '("nu" "number" "#") (lambda (ex) (print-lines! ex #t)))

;; :sort [!] [i] [n] [u] sorts lines: reversed, ignoring case, by the first
;; number on the line, dropping duplicates. Without a range, the whole file.
(define (first-number text)
  (let loop ([cs (string->list text)] [digits '()])
    (cond
      [(and (null? cs) (null? digits)) #f]
      [(and (pair? cs) (char-numeric-ascii? (car cs))) (loop (cdr cs) (cons (car cs) digits))]
      [(null? digits) (loop (cdr cs) '())]
      [else (string->number (list->string (reverse digits)))])))

(define (dedupe lines same?)
  (cond [(null? lines) '()]
        [(and (pair? (cdr lines)) (same? (car lines) (cadr lines))) (dedupe (cdr lines) same?)]
        [else (cons (car lines) (dedupe (cdr lines) same?))]))

(define-ex! '("sor" "sort")
  (lambda (ex)
    (let* ([flags (ex-args ex)]
           [range (if (ex-range-given? ex) (ex-range ex) (list 0 (last-line)))]
           [first (car range)] [last (cadr range)]
           [lines (split-lines (lines-text first last))]
           [ci? (string-contains? flags "i")]
           [less (cond
                   [(string-contains? flags "n")
                    (lambda (a b) (let ([x (first-number a)] [y (first-number b)])
                                    (cond [(not x) (and y #t)] [(not y) #f] [else (< x y)])))]
                   [ci? string-ci<?]
                   [else string<?])]
           [sorted (sort lines less)]
           [sorted (if (string-contains? flags "u")
                       (dedupe sorted (if ci? (lambda (a b) (equal? (string-downcase a) (string-downcase b))) equal?))
                       sorted)]
           [sorted (if (ex-bang? ex) (reverse sorted) sorted)])
      (begin-change!)
      (let ([r (lines-range first last)])
        (replace-range! (car r) (without-final-break (car r) (cadr r))
                        (string-join sorted "\n")))
      (set-cursor! (line-start first)))))

;; :normal {keys} runs keys as if typed in normal mode, on each line of
;; the range (from its start) if one is given. :normal! would skip
;; mappings; there are no mappings yet, so it is the same.
(define-ex! '("norm" "normal")
  (lambda (ex)
    (let ([keys (string->keys (ex-args ex))])
      (with-undo-group
       (lambda ()
         (if (ex-range-given? ex)
             (for-each-line-mark (car (ex-range ex)) (cadr (ex-range ex))
                                 (lambda () (run-normal-keys! keys)))
             (run-normal-keys! keys)))))))

(define (run-normal-keys! keys)
  (play-keys! keys)
  ;; Finish whatever the keys left half done, as Vim does.
  (when (typing-mode?) (process-key! "<esc>"))
  (when (eq? *mode* 'cmdline) (process-key! "<esc>"))
  (when (eq? *mode* 'visual) (leave-visual!))
  (reset-pending!)
  (set! *command-failed* #f))

;; Runs `thunk` with the cursor at the start of each line first..last.
;; Lines are marked first, so the thunk may add or delete lines.
(define (for-each-line-mark first last thunk)
  (for-each-marked-line (range first (+ last 1)) thunk))

(define (for-each-marked-line lines thunk)
  (let ([names (map (lambda (l)
                      (let ([name (string-append "line" (number->string l))])
                        (mark-set! name (line-start l))
                        name))
                    lines)])
    (for-each (lambda (name)
                (let ([p (mark-get name)])
                  (mark-delete! name)
                  ;; A line that was deleted leaves its mark on the next
                  ;; line's start; Vim skips deleted lines too.
                  (when p
                    (set-cursor! p)
                    (thunk))))
              names)))

;; :g/pattern/command runs command on every line matching pattern (:g! and
;; :v on the others). The default command is :p. Without a range, the
;; whole file.
(define (global-command invert?)
  (lambda (ex)
    (let* ([args (ex-args ex)]
           [delim (char-at args 0)])
      (if (or (not delim) (char-word? delim) (char-whitespace? delim))
          (set-status! "global needs /pattern/")
          (let* ([p (read-delimited args 1 delim)]
                 [pattern (if (equal? (car p) "") *last-search* (car p))]
                 [command (substring args (cdr p) (string-length args))]
                 [command (if (equal? command "") "p" command)]
                 [span (if (ex-range-given? ex) (ex-range ex) (list 0 (last-line)))])
            (cond
              [(not pattern) (set-status! "no previous regular expression")]
              [(pattern-error pattern) (set-status! (pattern-error pattern))]
              [else
               (set! *last-search* pattern)
               (let ([lines (filter (lambda (l)
                                      (let ([hit (line-matches? pattern l)])
                                        (if invert? (not hit) hit)))
                                    (range (car span) (+ (cadr span) 1)))])
                 (set! *print-lines* '())
                 (with-undo-group
                  (lambda ()
                    (for-each-marked-line lines (lambda () (run-ex! command)))))
                 (let ([printed *print-lines*])
                   (set! *print-lines* #f)
                   (unless (null? printed) (show-popup! printed)))
                 (when (null? lines)
                   (set-status! (string-append "Pattern not found: " pattern))))]))))))

(define (line-matches? pattern line)
  (let ([hit (search-next pattern (max 0 (- (line-start line) 1)) #t)])
    (and hit
         (let ([at (car hit)])
           ;; A match at the very start of the buffer is found by wrapping.
           (or (= (offset->line at) line)
               (and (= line 0) (= at 0)))))))

(define-ex! '("g" "global") (lambda (ex) ((global-command (ex-bang? ex)) ex)))
(define-ex! '("v" "vglobal") (global-command #t))

;;; Shell commands
;;;   :!cmd           run it and show the output
;;;   :{range}!cmd    filter the lines through it
;;;   :r !cmd         insert its output below the line
;;;   :r FILE         insert a file below the line

(define-ex! "!"
  (lambda (ex)
    (let ([command (ex-args ex)])
      (if (ex-range-given? ex)
          (let* ([first (car (ex-range ex))] [last (cadr (ex-range ex))]
                 [result (run-shell command (lines-text first last))])
            (begin-change!)
            (let ([r (lines-range first last)])
              (replace-range! (car r) (without-final-break (car r) (cadr r))
                              (without-final-newline (cadr result))))
            (set-cursor! (line-first-nonblank first))
            (unless (= (car result) 0)
              (set-status! (string-append "shell returned " (number->string (car result))))))
          (let ([result (run-shell command "")])
            (show-popup! (append (split-lines (cadr result))
                                 (list (string-append "shell returned " (number->string (car result)))))))))))

(define-ex! '("r" "read")
  (lambda (ex)
    (let* ([arg (ex-args ex)]
           [text (if (starts-with? arg "!")
                     (cadr (run-shell (substring arg 1 (string-length arg)) ""))
                     (read-file arg))]
           [text (if (or (equal? text "") (ends-with? text "\n")) text (string-append text "\n"))]
           [line (cadr (ex-range ex))])
      (unless (equal? text "")
        (begin-change!)
        (insert-lines-after! line text)
        (set-cursor! (line-first-nonblank (+ line 1)))))))

;;; Evaluating Scheme in the editor
;;;
;;; :eval EXPR, :source FILE, and commands that evaluate the form at the
;;; cursor, the top-level form around it, the selection or the buffer. All
;;; go through imp-eval-string (core.scm), so a define of an existing
;;; function replaces it for the whole editor right away.

;; Shows a result: on the status line, or in a popup if it is long.
(define (show-result! value)
  (let ([text (if (string? value) value (to-string value))])
    (if (or (string-contains? text "\n") (> (string-length text) 100))
        (show-popup! (split-lines text))
        (message text))))

;; Evaluates `text`, showing the value or the error.
(define (eval-and-show! text)
  (show-result!
   (with-handler (lambda (e) (string-append "error: " (error-message e)))
                 (let ([v (imp-eval-string text)]) (if (eq? v void) "#<void>" v)))))

(define-ex! '("eval" "ev") (lambda (ex) (eval-and-show! (ex-args ex))))

(define-ex! '("so" "source")
  (lambda (ex)
    (let ([path (expand-path (if (equal? (ex-args ex) "") (or (buffer-path) "") (ex-args ex)))])
      (show-result!
       (with-handler (lambda (e) (string-append "error: " (error-message e)))
                     (begin (imp-load-file path) (string-append "sourced " path)))))))

(define-ex! '("mes" "messages")
  (lambda (ex) (show-popup! (if (null? *messages*) (list "no messages") (reverse *messages*)))))

;; Chars that end a symbol.
(define (delimiter? c)
  (or (not c) (char-whitespace? c) (memv c (string->list "()[]\"';`,"))))

;; The form at the cursor, as (start end): the list whose ( or ) the cursor
;; is on, the symbol or number under it, or else the innermost list around
;; it.
(define (form-at p)
  (let ([c (buffer-char-at p)])
    (cond
      [(memv c (list #\) #\]))
       (let ([o (find-open (if (equal? c #\)) #\( #\[) c p 1)]) (and o (list o (+ p 1))))]
      [(memv c (list #\( #\[))
       (let ([e (find-close c (if (equal? c #\() #\) #\]) (+ p 1))]) (and e (list p (+ e 1))))]
      [(not (delimiter? c))
       (let ([lo (let loop ([q p]) (if (and (> q 0) (not (delimiter? (buffer-char-at (- q 1))))) (loop (- q 1)) q))]
             [hi (let loop ([q p]) (if (not (delimiter? (buffer-char-at q))) (loop (+ q 1)) q))])
         (list lo hi))]
      [else (let ([o (find-open #\( #\) p 1)]) (and o (form-at o)))])))

;; The top-level form around the cursor: the outermost list containing it.
(define (top-level-form-at p)
  (let loop ([o (if (equal? (buffer-char-at p) #\() p (find-open #\( #\) p 1))])
    (and o
         (let ([outer (and (> o 0) (find-open #\( #\) (- o 1) 1))])
           (if outer (loop outer) (form-at o))))))

(define (eval-range-command range-of)
  (lambda (count)
    (let ([r (range-of (cursor))])
      (if r
          (eval-and-show! (buffer-substring (car r) (cadr r)))
          (message "no form at the cursor")))))

;; Evaluate the form at the cursor (Emacs's C-x C-e).
(define-command! 'eval-last-sexp (eval-range-command form-at))
;; Evaluate the top-level form around the cursor (C-M-x).
(define-command! 'eval-defun (eval-range-command top-level-form-at))
;; Evaluate the whole buffer.
(define-command! 'eval-buffer
  (lambda (count) (eval-and-show! (buffer-substring 0 (buffer-length)))))
;; Evaluate the visual selection.
(define-command! 'eval-region
  (lambda (count)
    (if (eq? *mode* 'visual)
        (let ([r (visual-range)])
          (leave-visual!)
          (eval-and-show! (buffer-substring (car r) (cadr r))))
        (run-command 'eval-last-sexp))))
;; Prompt for an expression and evaluate it (M-:).
(define-command! 'eval-expression
  (lambda (count) (open-cmdline! "Eval: " "" eval-and-show! #f #f)))

;;; Entry points

(define (imp-init)
  (set-mode! 'normal)
  (normal-clamp!)
  (run-hooks 'startup))

(define *last-version* #f)  ; buffer and version after the last key

(define (imp-handle-key key)
  (when (and *recording* (not (stops-recording? key)))
    (set! *recorded-keys* (cons key *recorded-keys*)))
  (handle-top-level-key! key)
  ;; after-change runs once per key that changed the current buffer;
  ;; post-command after every key.
  (let ([now (cons (current-buffer) (buffer-version))])
    (when (and *last-version* (= (car now) (car *last-version*)) (not (= (cdr now) (cdr *last-version*))))
      (run-hooks 'after-change))
    (set! *last-version* now))
  (run-hooks 'post-command))

(define (handle-top-level-key! key)
  (if *popup-shown*
      ;; Any key closes a popup; <ret>, <esc> and space only do that, other
      ;; keys also run, as at Vim's "Press ENTER" prompt.
      (begin
        (close-popup!)
        (unless (member key '("<ret>" "<esc>" " " "C-c")) (process-key! key)))
      (process-key! key)))

;; q stops recording, when it isn't part of a longer command.
(define (stops-recording? key)
  (and *recording* (equal? key "q") (member *mode* '(normal visual))
       (not *operator*) (not *prefix*) (equal? *count* "")))

;; Handles one key without recording it; macros play keys through here.
(define (process-key! key)
  (define typing? (typing-mode?))
  (cond
    [(stops-recording? key) (stop-recording!)]
    ;; Something (describe-key) wants the next keys instead.
    [*key-interceptor* (*key-interceptor* key)]
    [else (handle-key! key)])
  ;; After C-o's one command (once nothing is pending), back to insert.
  (when (and *insert-return* (not typing?) (eq? *mode* 'normal)
             (not *operator*) (not *prefix*) (equal? *count* ""))
    (set-mode! *insert-return*)
    (set! *insert-return* #f))
  (update-visual-highlight!))

(define (handle-key! key)
  (cond
    [(hash-try-get *extra-states* *mode*) => (lambda (s) ((caddr s) key))]
    [(typing-mode?) (insert-mode-key! key)]
    [(eq? *mode* 'cmdline) (cmdline-key! key)]
    [else
     ;; A fresh command clears the last message.
     (when (and (not *operator*) (not *prefix*) (equal? *count* ""))
       (set-status! ""))
     (normal-key! key)]))
