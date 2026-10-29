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
(define *block-insert* #f)     ; (first last col append?) while typing I/A/c in a block
(define *visual-anchor* 0)     ; the end of the selection the cursor isn't on
(define *last-visual* #f)      ; (kind anchor cursor) for gv
(define *count* "")            ; digits typed so far
(define *operator* #f)         ; pending operator key, e.g. "d"
(define *operator-count* "")   ; count typed before the operator
(define *prefix* #f)           ; pending prefix key, e.g. "g"
;; Called with (state title prefix) when a prefix starts waiting, and with
;; (#f #f #f) when it stops; leader.scm sets it to show which-key.
(define *prefix-which-key* (lambda (state title prefix) void))
(define *goal-col* 0)          ; column j/k try to keep
(define *registers* (hash))    ; register char -> (text linewise?)
(define *register-prefix* #f)  ; the register named with "x for this command
(define *register-just-set* #f)
(define *last-inserted* "")    ; the ". register
(define *last-ex* #f)          ; the ": register
(define *recording* #f)        ; the register q is recording into
(define *recorded-keys* '())   ; reversed
(define *last-macro* #f)       ; for @@
(define *command-failed* #f)   ; set when a key fails; stops a running macro
(define *u-line* #f)           ; the line U restores, and its old text
(define *u-text* "")
(define *jumps* '())           ; mark names of jump list entries, oldest first
(define *jump-index* 0)        ; where C-o and C-i are in *jumps*
(define *jump-counter* 0)      ; for naming jump marks
(define *popup-shown* #f)      ; a popup is up until the next key
(define *undo-group* #f)       ; while true, changes join one undo step
(define *alternate-buffer* #f) ; for C-^ and :e #
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
(define *pasting* #f)          ; replaying a paste for `.`: its brackets don't pair
(define *pairs* '())           ; pairs auto-pairs added in this insert, innermost first
(define *pair-added* #f)       ; the pair the key being handled added
(define *typed-char-handler* #f) ; called with each plain char typed (end tags, syntax.scm)
(define *cmdline* "")           ; text typed at the prompt
(define *cmdline-prompt* ":")
(define *cmdline-submit* #f)   ; (lambda (text) ...) on <ret>
(define *cmdline-change* #f)   ; (lambda (text) ...) after each edit
(define *cmdline-cancel* #f)   ; (lambda () ...) on <esc>
(define *cmdline-return* 'normal) ; the mode to go back to
(define *cmdline-pos* 0)       ; cursor position in *cmdline*
(define *cmdline-key-handler* #f) ; sees keys first; #t from it means handled
(define *insert-key-handler* #f)  ; sees typed insert keys first (map.scm); #t means handled
;; Completion on the command line, if set (complete.scm's menu):
;; (lambda (event arg)) told 'edit after each edit, 'close, and 'key with
;; each key before the line sees it, returning #t for a key it took.
(define *cmdline-completer* #f)
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

(define (define-state! state name cursor-shape handler)
  "Adds an editor state beside Vim's: keys in it go to `handler`."
  (set! *extra-states* (hash-insert *extra-states* state (list name cursor-shape handler)))
  void)

(define (set-mode! mode)
  "Switches to `mode`, running the mode hooks and setting the cursor.
   Entering or leaving insert/replace runs insert-enter or insert-leave;
   any change of mode runs mode-change. The cursor shape and the mode
   name in the status line follow the new mode."
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
  "Updates the status line's mode name and face for the current mode.
   The name gets \" recording @x\" while a macro is being recorded."
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
  "Forgets a half-typed command: its count, operator and prefix key."
  (set! *count* "")
  (set! *operator* #f)
  (set! *operator-count* "")
  (when *prefix* (*prefix-which-key* #f #f #f))
  (set! *prefix* #f)
  void)

(define (normal-clamp!)
  "Moves the cursor back onto the line's last char if it is past it.
   In normal mode the cursor sits on a char, never on a line's end,
   unless the line is empty."
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

(define (define-motion! key type proc . label)
  "Makes `key` a motion of `type` (exclusive, inclusive or linewise).
   `proc` is (lambda (from count) target-offset), returning #f when the
   motion can't move. It then works with every operator and visual mode.
   An optional last argument is the label which-key shows."
  (set! *motions* (hash-insert *motions* key (list type proc)))
  (set-binding-label! 'motion key (and (pair? label) (car label)))
  void)

(define (motion-type m)
  "The type of motion `m`: exclusive, inclusive or linewise."
  (car m))
(define (motion-proc m)
  "The procedure of motion `m`, (lambda (from count) target)."
  (cadr m))

(define (repeat-motion n step from)
  "The position after applying `step` `n` times, starting at `from`."
  (let loop ([i 0] [p from])
    (if (< i n) (loop (+ i 1) (step p)) p)))

(define (char-class c)
  "The class of char `c` for word motions: 0 white space, 1 word, 2 other.
   Punctuation is class 2; #f (past the buffer's end) counts as white
   space."
  (cond [(not c) 0]
        [(char-whitespace? c) 0]
        [(char-word? c) 1]
        [else 2]))

;; The classifiers motions and text objects are built with. They call
;; char-class and big-class by name each time, so redefining those (to make
;; - a word char in Lisp, say) changes w, e, iw and the rest at once.
(define (word-class c)
  "The class of `c` for word motions and objects (w b e iw aw)."
  (char-class c))
(define (WORD-class c)
  "The class of `c` for WORD motions and objects (W B E iW aW)."
  (big-class c))

(define (big-class c)
  "The class of `c` for WORD motions: 0 for white space, else 1.
   Anything that isn't white space is part of a WORD."
  (cond [(not c) 0] [(char-whitespace? c) 0] [else 1]))

(define (class-at p)
  "The word class (char-class) of the char at offset `p`."
  (char-class (buffer-char-at p)))

;; Word motions take the classifier, char-class for words (w b e ge) or
;; big-class for WORDs (W B E gE).
(define (next-word-start p classify)
  "The start of the next word after `p` (w, W), past any white space."
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
  "The start of the word before `p`, or of the one `p` is inside (b, B)."
  (let* ([cls-at (lambda (q) (classify (buffer-char-at q)))]
         [q (let loop ([q (- p 1)])
              (if (and (> q 0) (= (cls-at q) 0)) (loop (- q 1)) q))]
         [cls (cls-at q)])
    (let loop ([q q])
      (if (and (> q 0) (= (cls-at (- q 1)) cls) (not (= cls 0)))
          (loop (- q 1))
          (max q 0)))))

(define (next-word-end p classify)
  "The end of the word after `p`, or of the one `p` is inside (e, E).
   Never goes past the buffer's last char."
  (let* ([len (buffer-length)]
         [cls-at (lambda (q) (classify (buffer-char-at q)))]
         [q (let loop ([q (+ p 1)])
              (if (and (< q len) (= (cls-at q) 0)) (loop (+ q 1)) q))]
         [cls (cls-at q)])
    (let loop ([q q])
      (if (and (< (+ q 1) len) (= (cls-at (+ q 1)) cls) (not (= cls 0)))
          (loop (+ q 1))
          (min q (max 0 (- len 1)))))))

(define (prev-word-end p classify)
  "ge: back to the end of the previous word."
  (let* ([cls-at (lambda (q) (classify (buffer-char-at q)))]
         [cls (cls-at p)]
         [q (let loop ([q p])
              (if (and (> q 0) (not (= cls 0)) (= (cls-at q) cls)) (loop (- q 1)) q))])
    (let loop ([q q])
      (if (and (> q 0) (= (cls-at q) 0)) (loop (- q 1)) q))))

(define (word-motion step classify)
  "A motion proc that takes `step` count times with classifier `classify`."
  (lambda (from n) (repeat-motion n (lambda (p) (step p classify)) from)))

(define (vertical from n)
  "j and k go as far as they can, but fail (#f) if they can't move at all,
   as Vim's do: that stops a macro at the end of the file. A closed fold
   counts as one line."
  (let ([line (fold-step (offset->line from) n)])
    (and (not (= line (shown-line (offset->line from))))
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
(define (screen-row-motion dir)
  "gj and gk move by screen rows when lines wrap: within a long line, then
   on to the next line, keeping the wanted column (the goal column, which
   they leave alone as j and k do). Without wrap they are j and k. Like
   Vim's, they are exclusive."
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
  "A motion to the first non-blank of a line `offset` lines away.
   `offset` maps the count to a line delta, so + is n lines down and _
   is n - 1. The target is clamped to the buffer."
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
  "The bracket matching the one at or after `from` on its line, or #f.
   Used by %: from an opening bracket it finds the close, and back from a
   closing one. #f when the line has no bracket after `from` or the
   match is missing."
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
(define (empty-line? line)
  "Whether `line` has no chars at all."
  (= (buffer-line-length line) 0))

(define (paragraph-forward from n)
  "The end of the `n`th paragraph from `from`, for }.
   Lands on the next empty line, or the end of the last line when there
   is none."
  (let loop ([i 0] [line (offset->line from)])
    (if (= i n)
        (if (empty-line? line) (line-start line) (line-end line))
        (let* ([l (let skip ([l line]) (if (and (< l (last-line)) (empty-line? l)) (skip (+ l 1)) l))]
               [l (let skip ([l l]) (if (and (< l (last-line)) (not (empty-line? l))) (skip (+ l 1)) l))])
          (loop (+ i 1) l)))))

(define (paragraph-backward from n)
  "The start of the `n`th paragraph back from `from`, for {.
   Lands on the previous empty line, or the start of the first line."
  (let loop ([i 0] [line (offset->line from)])
    (if (= i n)
        (line-start line)
        (let* ([l (let skip ([l line]) (if (and (> l 0) (empty-line? l)) (skip (- l 1)) l))]
               [l (let skip ([l l]) (if (and (> l 0) (not (empty-line? l))) (skip (- l 1)) l))])
          (loop (+ i 1) l)))))

(define-motion! "}" 'exclusive paragraph-forward)
(define-motion! "{" 'exclusive paragraph-backward)

;; H, M and L: lines of the window.
(define (window-bottom)
  "The last buffer line shown in the window."
  (min (last-line) (+ (window-top) (window-height) -1)))

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
  "Makes `key` a motion that takes a char, as f and t do.
   `proc` is (lambda (from count char) target); `key` becomes a prefix
   and `key` plus a char works like any other motion."
  (set! *char-motions* (hash-insert *char-motions* key (list type proc)))
  void)

;; Normal-mode commands that take a char, such as r and m: `proc` is
;; (lambda (count char) ...).
(define *char-commands* (hash))

(define (find-char-command key)
  "The command for `key` if it is a char command and its char, or #f.
   Returns (lambda (count) ...) that calls the command with the char, so
   \"rx\" gives r's proc applied to x."
  (and (> (string-length key) 1)
       (let ([proc (hash-try-get *char-commands* (substring key 0 1))]
             [ch (key-char (substring key 1 (string-length key)))])
         (and proc ch (lambda (count) (proc count ch))))))

(define (define-char-command! key proc)
  "Makes `key` a normal-mode command that takes the next char, as r does.
   `proc` is (lambda (count char) ...)."
  (set! *char-commands* (hash-insert *char-commands* key proc))
  void)

(define (key-char key)
  "The char named by a key: \"x\" is x, \"<tab>\" a tab. Other named keys are
   not chars."
  (cond [(= (string-length key) 1) (string-ref key 0)]
        [(equal? key "<tab>") #\tab]
        [(equal? key "<space>") #\space]
        [(equal? key "<ret>") #\newline]
        [else #f]))

(define (char-search from n ch forward? till? skip-adjacent?)
  "The `n`th `ch` on the line, forward or backward. `till?` stops one short
   of it; `skip-adjacent?` (for ; after t) doesn't count one right next to
   the cursor, so repeating t moves on."
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
  "The char motion going the other way from `key`: f and F, t and T swap."
  (cond [(equal? key "f") "F"] [(equal? key "F") "f"] [(equal? key "t") "T"] [else "t"]))

(define (repeat-char-motion reverse?)
  "; and , repeat the last f F t T, in the same or the other direction."
  (and *last-char-search*
       (let* ([key (if reverse? (reverse-char-key (car *last-char-search*)) (car *last-char-search*))]
              [ch (cadr *last-char-search*)]
              [forward? (member key '("f" "t"))]
              [till? (member key '("t" "T"))])
         (list (car (hash-ref *char-motions* key))
               (lambda (from n) (char-search from n ch forward? till? #t))))))

(define (find-motion key)
  "The motion for `key`, as (type proc), or #f. Besides the motion table
   this covers char motions (fx) and ; and ,."
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

(define (vertical-motion? key)
  "Vertical motions keep the goal column; everything else resets it."
  (member key '("j" "k" "<down>" "<up>" "gj" "gk")))

;;; Operators
;;;
;;; An operator receives (start end linewise?) for the chars to act on.

(define *operators* (hash))

(define (define-operator! key proc . label)
  "Makes `key` an operator. `proc` is (lambda (start end linewise?) ...).
   It then works with every motion, text object, visual mode and `.`.
   An optional last argument is the label which-key shows."
  (set! *operators* (hash-insert *operators* key proc))
  (set-binding-label! 'operator key (and (pair? label) (car label)))
  void)

(define (lines-range first last)
  "Whole lines `first` through `last`, as (start end #t). The range always
   starts at the beginning of `first`, so every linewise operator sees the
   same shape; only `d` has to care about the file's final newline."
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

(define (upper-letter? c)
  "Whether `c` is an ASCII capital letter (A-Z)."
  (let ([n (char->integer c)]) (and (>= n 65) (<= n 90))))

(define (valid-register? c)
  "Whether `c` names a register: a letter, a digit, or one of \"-_+*.:/%."
  (or (letter? c) (char-numeric-ascii? c) (memv c (string->list "\"-_+*.:/%"))))

(define (current-register)
  "The register this command uses: the one named with \"x, else \"."
  (or *register-prefix* #\"))

(define (clipboard-register c)
  "Whether `c` is a system clipboard register, \"+ or \"*."
  (memv c (list #\+ #\*)))

(define (register-get c)
  "The contents of register `c`, as (text linewise?), or #f if empty.
   Capitals read their letter; \"+ and \"* read the system clipboard (the
   last copy kept here if it can't be read); \". \": \"/ and \"% come from
   the editor's state. With clipboard=unnamedplus, \"\" reads \"+."
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
  "Sets register `c` to `value`, (text linewise?), and nothing else."
  (set! *registers* (hash-insert *registers* c value))
  void)

(define (register-set! c text linewise? kind)
  "Puts `text` in register `c`. `kind` is 'yank or 'delete, which decides
   where an unnamed write also goes."
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
  "Puts the text from `start` to `end` in the current register.
   Also sets the [ and ] marks to it. `kind` is 'yank or 'delete, as for
   register-set!."
  (mark-set! "[" start)
  (mark-set! "]" (max start (- end 1)))
  (register-set! (current-register) (buffer-substring start end) linewise? kind))

(define (yank-range! start end linewise?)
  "Saves the text from `start` to `end` in the registers as a delete.
   Operators that remove text call it first, so \"1-\"9 and \"- fill as
   in Vim."
  (store-range! start end linewise? 'delete))

(define (without-final-break start end)
  "End of a linewise range without its final line break, if it has one."
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

(define (motion-range from target type)
  "The range a motion covers from `from`, as (start end linewise?)."
  (let ([lo (min from target)] [hi (max from target)])
    (cond
      ;; Linewise, a closed fold is taken whole.
      [(eq? type 'linewise) (lines-range (shown-line (offset->line lo)) (shown-last (offset->line hi)))]
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
  "Runs operator `op-key` over the text motion `motion-key` covers.
   `count` goes to the motion. Does nothing if the motion fails (f with
   no match). Handles Vim's special cases: cw acts like ce, and w with an
   operator stops at the end of the line."
  (let* (;; Vim special case: `cw` on a word changes to its end, like `ce`,
         ;; leaving the space after it alone. On a word's last char it
         ;; changes just that char, where `ce` would go on to the next word.
         [cw? (and (equal? op-key "c") (not (= (class-at (cursor)) 0)) (member motion-key '("w" "W")))]
         [classify (if (equal? motion-key "W") big-class char-class)]
         [motion-key (cond [(not cw?) motion-key] [(equal? motion-key "w") "e"] [else "E"])]
         [m (find-motion motion-key)]
         [from (cursor)]
         [at-word-end? (and cw?
                            (let ([next (+ from 1)])
                              (or (>= next (line-end (offset->line from)))
                                  (not (= (classify (buffer-char-at next)) (classify (buffer-char-at from)))))))]
         [target (cond [(not at-word-end?) ((motion-proc m) from count)]
                       [(= count 1) from]
                       [else ((motion-proc m) from (- count 1))])])
    ;; A motion that finds nothing (f with no match) cancels the operator.
    (when target
      (let* ([target (if (member motion-key '("w" "W")) (word-operator-end from target) target)]
             [range (motion-range from target (motion-type m))])
        (begin-change!)
        ((hash-ref *operators* op-key) (car range) (cadr range) (caddr range))))))

(define (word-operator-end from target)
  "Vim special case: with an operator, w stops at the end of the last word
   it moved over rather than at the start of a word on a later line, so `dw`
   on a line's last word keeps the line break."
  (if (> (offset->line target) (offset->line from))
      (let ([end (let loop ([p target])
                   (if (and (> p from) (char-whitespace? (buffer-char-at (- p 1)))) (loop (- p 1)) p))])
        (if (< (offset->line end) (offset->line target)) end target))
      target))

(define (run-linewise-operator! op-key count)
  "`dd`, `cc`, `yy`: the operator over `count` whole lines."
  (let* ([from (cursor)]
         [target (line-start (fold-step (current-line) (- count 1)))]
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
  "Makes `key` (such as \"iw\") a text object.
   `proc` is (lambda (from count) (start end linewise?)), or #f when there
   is nothing to select. It then works after any operator and in visual
   mode."
  (set! *text-objects* (hash-insert *text-objects* key proc))
  void)

(define (run-end p classify hi)
  "The end of the run of chars sharing `p`'s class, as far as `hi`.
   The end is exclusive: the first offset past the run."
  (let ([cls (classify (buffer-char-at p))])
    (let loop ([q p])
      (if (and (< q hi) (= (classify (buffer-char-at q)) cls)) (loop (+ q 1)) q))))

(define (run-start p classify lo)
  "The start of the run of chars sharing `p`'s class, back as far as `lo`."
  (let ([cls (classify (buffer-char-at p))])
    (let loop ([q p])
      (if (and (> q lo) (= (classify (buffer-char-at (- q 1))) cls)) (loop (- q 1)) q))))

(define (blank-at? p)
  "Whether the char at offset `p` is white space (or past the end)."
  (= (char-class (buffer-char-at p)) 0))

(define (inner-word classify)
  "iw: `count` runs of word, punctuation or white space, on the cursor's line."
  (lambda (from n)
    (let* ([line (offset->line from)] [lo (line-start line)] [hi (line-end line)])
      (if (= lo hi)
          #f
          (let loop ([i 1] [end (run-end from classify hi)])
            (if (and (< i n) (< end hi))
                (loop (+ i 1) (run-end end classify hi))
                (list (run-start from classify lo) end #f)))))))

(define (a-word classify)
  "aw: words with the white space after them; if a word has none after it,
   the white space before it instead. From white space, the white space and
   the word after it."
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

(define (quote-positions q lo hi)
  "The offsets of quote char `q` from `lo` to `hi`, in order.
   Quotes count on the cursor's line only, as in Vim. A quote preceded
   by a backslash doesn't count."
  (let loop ([p lo] [acc '()])
    (cond
      [(>= p hi) (reverse acc)]
      [(and (equal? (buffer-char-at p) q)
            (not (and (> p lo) (equal? (buffer-char-at (- p 1)) #\\))))
       (loop (+ p 1) (cons p acc))]
      [else (loop (+ p 1) acc)])))

(define (quote-pair q from)
  "The (open close) pair of quotes around `from`. Quotes pair up from the
   start of the line; if the cursor isn't inside a pair, the next pair after
   it on the line is used."
  (let* ([line (offset->line from)]
         [qs (quote-positions q (line-start line) (line-end line))])
    (let loop ([qs qs])
      (cond
        [(or (null? qs) (null? (cdr qs))) #f]
        [(<= from (cadr qs)) (list (car qs) (cadr qs))]
        [else (loop (cddr qs))]))))

(define (quote-object q around?)
  "The text object for quote char `q`: i\" without the quotes, a\" with.
   The a form also takes the white space after the closing quote, or
   before the opening one if there is none after."
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
  "Whether only white space comes before offset `p` on its line."
  (let ([lo (line-start (offset->line p))])
    (let loop ([q lo]) (cond [(= q p) #t] [(blank-at? q) (loop (+ q 1))] [else #f]))))

(define (bracket-object open close around?)
  "The text object for brackets `open` and `close` (ib, aB and the like).
   The count picks the nth enclosing pair; `around?` includes the
   brackets. The inner object of a block whose brackets end and start
   lines selects just the lines between them. #f when there is no pair."
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
  "The it text object, or at with `around?`: the `n`th tag pair out.
   it is the text between the tags, at includes them. #f when there are
   fewer than `n` pairs around the cursor."
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
  "Whether `line` is empty or holds only white space."
  (let ([end (line-end line)])
    (let loop ([p (line-start line)])
      (cond [(= p end) #t] [(blank-at? p) (loop (+ p 1))] [else #f]))))

(define (run-last-line line)
  "The last line of the run of blank or non-blank lines holding `line`."
  (let ([blank (blank-line? line)])
    (let loop ([l line])
      (if (and (< l (last-line)) (eq? (blank-line? (+ l 1)) blank)) (loop (+ l 1)) l))))

(define (run-first-line line)
  "The first line of the run of blank or non-blank lines holding `line`."
  (let ([blank (blank-line? line)])
    (let loop ([l line])
      (if (and (> l 0) (eq? (blank-line? (- l 1)) blank)) (loop (- l 1)) l))))

(define (runs-forward line n)
  "The last line after `n` runs starting at `line`."
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
  "Runs operator `op-key` over text object `object-key` at the cursor.
   Does nothing if the object finds nothing there."
  (let ([range ((hash-ref *text-objects* object-key) (cursor) count)])
    (when range
      (begin-change!)
      ((hash-ref *operators* op-key) (car range) (cadr range) (caddr range)))))

;;; Changes and dot-repeat

(define (changing-operator? key)
  "Whether operator `key` changes text, so `.` should repeat it.
   Every operator but y and zf does."
  (not (member key '("y" "zf"))))

(define (with-undo-group thunk)
  "Runs `thunk` with all its changes in one undo step."
  (if *undo-group*
      (thunk)
      (begin
        (undo-boundary!)
        (set! *undo-group* #t)
        (let ([result (with-handler (lambda (e) (set! *undo-group* #f) (raise-error e)) (thunk))])
          (set! *undo-group* #f)
          result))))

(define (begin-change!)
  "Every change starts here: it makes an undo point, and remembers the
   line's text for U when the change is on a new line."
  (unless *undo-group* (undo-boundary!))
  (mark-set! "." (cursor))
  (unless (equal? *u-line* (current-line))
    (set! *u-line* (current-line))
    (set! *u-text* (buffer-substring (line-start (current-line)) (line-end (current-line)))))
  void)

(define (record-change! change count)
  "Records `change` as the thing `.` repeats. If it ends in insert mode, the
   record is completed when insert mode exits, with the text that was typed."
  (set! *last-change-count* count)
  (let ([change (with-register change (next-register *register-prefix*))])
  (if (typing-mode?)
      (begin (set! *insert-entry* change) (set! *insert-keys* '()) (set! *pairs* '()))
      (set! *last-change* change)))
  void)

(define (with-register change reg)
  "A change that runs with register `reg` named, as when it was made. \"1p
   repeated with . pastes \"2, then \"3 and so on, as in Vim."
  (if (not reg)
      change
      (lambda (n)
        (set! *register-prefix* reg)
        (change n)
        (set! *register-prefix* #f)
        (unless (equal? reg (next-register reg))
          (set! *last-change* (with-register change (next-register reg)))))))

(define (next-register reg)
  "The register . uses after one: \"1 to \"8 step to the next, others stay."
  (if (and reg (char-numeric-ascii? reg) (not (memv reg (list #\0 #\9))))
      (integer->char (+ 1 (char->integer reg)))
      reg))

(define (typing-mode?)
  "Whether the editor is in insert or replace mode."
  (member *mode* '(insert replace)))

(define (repeat-insert! keys n reentry)
  "Types `keys` again `n` more times, as for 3ihi<esc> or 3ofoo<esc>."
  (let loop ([i 0])
    (when (< i n)
      (when reentry (reentry))
      (replay-insert-keys! keys)
      (loop (+ i 1)))))

(define (replay-insert-keys! keys)
  "Types keys recorded in insert mode again, including C-r {register}."
  (let loop ([ks keys])
    (cond
      [(null? ks) #t]
      [(and (equal? (car ks) "C-r") (pair? (cdr ks)))
       (let* ([c (key-char (cadr ks))] [reg (and c (valid-register? c) (register-get c))])
         (when reg (insert-text! (car reg))))
       (loop (cddr ks))]
      [(member (car ks) '("<paste-start>" "<paste-end>"))
       (set! *pasting* (equal? (car ks) "<paste-start>"))
       (loop (cdr ks))]
      [else (insert-key! (car ks)) (loop (cdr ks))]))
  (set! *pasting* #f)
  void)

(define (finish-insert-record! keys)
  "Completes the `.` record for an insert that just ended.
   `keys` are the keys typed. The change replays how the insert began,
   then the keys, and for insert commands repeats them for the count."
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
    (set! *insert-entry* #f))
  void)

;;; Normal mode commands
;;;
;;; Commands in the normal keymap take the count (1 if none was typed).

(define (line-indent line)
  "The white space at the start of `line`."
  (buffer-substring (line-start line) (line-first-nonblank line)))

(define (enter-insert! where)
  "A command that enters insert mode at `where`.
   `where` is 'here, 'after, 'line-end, 'line-start, 'column-0,
   'last-insert (gi), 'below or 'above (opening a line), or 'replace for
   replace mode."
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

(define (open-line! line below?)
  "o and O: a new line below or above `line`, indented like it when
   autoindent is on."
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
    (set! *autoindent-line* (and (> (string-length indent) 0) (current-line))))
  void)

(define (insert-command! key where)
  "Binds `key` in normal mode to enter insert mode at `where`.
   The count repeats the typed text on <esc> (3ihi<esc>); for o and O it
   opens that many lines. The insert is recorded for `.`."
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

(define (operator-command! key op-key motion-key)
  "A command made of an operator and a motion, like x = dl."
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
  "`text` repeated `n` times."
  (let loop ([i 0] [acc '()])
    (if (< i n) (loop (+ i 1) (cons text acc)) (apply string-append acc))))

(define (paste! after? cursor-after?)
  "A command that puts the current register's text `count` times.
   `after?` puts it after the cursor (p) rather than before (P);
   `cursor-after?` leaves the cursor just after it (gp, gP). Returns #f,
   saying so, when the register is empty."
  (lambda (count)
    (let ([reg (register-get (current-register))])
      (if reg
          (begin (begin-change!) (put-text! (string-repeat (car reg) count) (cadr reg) after? cursor-after?) #t)
          (begin
            (set-status! (string-append "nothing in register " (string (current-register))))
            #f)))))

(define (put-text! text linewise? after? cursor-after?)
  "Puts text after or before the cursor (whole lines go below or above its
   line). The cursor ends on the last char put, or with gp just after it."
  (if (eq? linewise? 'block)
      (put-block! text after?)
      (put-text-at! text linewise? after? cursor-after?))
  (mark-set! "]" (max 0 (- (cursor) (if cursor-after? 1 0)))))

(define (put-text-at! text linewise? after? cursor-after?)
  "Puts characterwise or linewise `text` before or after the cursor.
   Whole lines go below or above the cursor's line, with the cursor on
   the first non-blank of the first one (or after them with
   `cursor-after?`). Sets the [ mark."
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
  "Binds `key` in normal mode to a put (see paste!), recorded for `.`."
  (define-key! 'normal key
    (lambda (count)
      (let ([paste (paste! after? cursor-after?)])
        (when (paste count) (record-change! paste count))))))

(paste-command! "p" #t #f)
(paste-command! "P" #f #f)
(paste-command! "gp" #t #t)
(paste-command! "gP" #f #t)

(define (undo-command step! message)
  "The u or C-r command: runs `step!` `count` times.
   The cursor goes where the text changed, like Vim; if nothing could
   be undone or redone, `message` goes on the status line."
  (lambda (count)
    (let loop ([i 0] [at #f])
      (let ([r (and (< i count) (step!))])
        (cond
          [r (loop (+ i 1) r)]
          [at (set-cursor! (min at (buffer-length))) (normal-clamp!) (set! *fold-open-wanted* #t)]
          [else (set-status! message)])))))

(define-key! 'normal "u" (undo-command undo! "already at oldest change"))
(define-key! 'normal "C-r" (undo-command redo! "already at newest change"))
;; g- and g+ go through the undo tree in the order changes were made,
;; across branches.
(define-key! 'normal "g-" (undo-command (lambda () (undo-step! #f)) "already at oldest change"))
(define-key! 'normal "g+" (undo-command (lambda () (undo-step! #t)) "already at newest change"))


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
  "Starts visual mode of `kind` (char, line or block) anchored at `anchor`."
  (set! *block-eol* #f)
  (set! *visual* kind)
  (set! *visual-anchor* anchor)
  (set-mode! 'visual))

(define (leave-visual!)
  "Leaves visual mode for normal, remembering the selection.
   Sets the < and > marks and what gv needs to select it again."
  (set! *last-visual* (list *visual* *visual-anchor* (cursor)))
  (mark-set! "visual-anchor" *visual-anchor*)
  (mark-set! "visual-cursor" (cursor))
  (mark-set! "<" (min *visual-anchor* (cursor)))
  (mark-set! ">" (max *visual-anchor* (cursor)))
  (set! *visual* #f)
  (set-mode! 'normal))

(define (visual-range)
  "The selection as (start end linewise?)."
  (let ([lo (min *visual-anchor* (cursor))] [hi (max *visual-anchor* (cursor))])
    (if (eq? *visual* 'line)
        (lines-range (offset->line lo) (offset->line hi))
        (list lo (min (+ hi 1) (buffer-length)) #f))))

(define (update-visual-highlight!)
  "Redraws the visual selection's highlight, or clears it.
   The selection stays shown while a search prompt opened from visual
   mode is up."
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
;;; A block is display columns, as Vim's virtual columns are: from the
;;; leftmost column the anchor's or the cursor's char covers to the
;;; rightmost, on every line between them (to each line's end after $). A
;;; tab or wide char the block's edge cuts through is turned into spaces
;;; where text is taken out or put in, as Vim does.

(define (col-span line col)
  "The display columns char `col` of `line` covers, as (start end) with
   end excluded. Past the line's end, the one column after it."
  (let ([x (line-display-col line col)])
    (list x (if (< col (buffer-line-length line)) (line-display-col line (+ col 1)) (+ x 1)))))

(define (block-bounds)
  "The visual block as (first-line last-line left right): display
   columns, right excluded, or #f after $."
  (let* ([a *visual-anchor*] [c (cursor)]
         [sa (col-span (offset->line a) (offset->col a))]
         [sc (col-span (offset->line c) (offset->col c))])
    (list (min (offset->line a) (offset->line c))
          (max (offset->line a) (offset->line c))
          (min (car sa) (car sc))
          (if *block-eol* #f (max (cadr sa) (cadr sc))))))

(define (block-line-segment line left right)
  "The part of `line` in display columns `left` to `right` (#f: the
   line's end), as (start end before after text). `start` and `end` are
   the offsets of the chars the columns touch; `before` and `after` are
   how many columns of a cut first or last char lie outside them; `text`
   is what a yank takes, a cut char's inside part as spaces. A line
   ending before `left` takes the block's width in spaces."
  (let* ([len (buffer-line-length line)]
         [first (line-col-at-display line left)])
    (if (= first len)
        (list (line-end line) (line-end line) 0 0
              (if (and right (< (line-display-col line len) left)) (make-string (- right left) #\space) ""))
        (let* ([last (if right (min (line-col-at-display line (- right 1)) (- len 1)) (- len 1))]
               [s1 (col-span line first)] [s2 (col-span line last)]
               [right (or right (cadr s2))]
               [before (- left (car s1))]
               [after (max 0 (- (cadr s2) right))]
               [start (line-col->offset line first)]
               [end (line-col->offset line (+ last 1))])
          (list start end before after
                (cond
                  [(and (= first last) (or (> before 0) (> after 0))) (make-string (- right left) #\space)]
                  [else
                   (string-append (if (> before 0) (make-string (- (cadr s1) left) #\space) "")
                                  (buffer-substring (if (> before 0) (+ start 1) start) (if (> after 0) (- end 1) end))
                                  (if (> after 0) (make-string (- right (car s2)) #\space) ""))]))))))

(define (block-segments)
  "Each line's part of the block, top to bottom (see block-line-segment)."
  (let* ([b (block-bounds)] [left (caddr b)] [right (cadddr b)])
    (map (lambda (l) (block-line-segment l left right))
         (range (car b) (+ (cadr b) 1)))))

(define (block-text segments)
  "The text a yank of block `segments` takes, one line per segment."
  (string-join (map (lambda (seg) (list-ref seg 4)) segments) "\n"))

(define (delete-segments! segments)
  "Deletes the segments, bottom first so offsets above stay right. The
   outside part of a cut tab or wide char is left as spaces."
  (for-each (lambda (seg)
              (replace-range! (car seg) (cadr seg)
                              (make-string (+ (caddr seg) (cadddr seg)) #\space)))
            (reverse segments)))

(define (insert-at-display! line x text pad?)
  "Puts `text` on `line` at display column `x` and returns the offset
   after it. A tab across `x` becomes spaces either side of the text; a
   wide char across it gets spaces before it, as Vim does. A line ending
   before `x` is padded with spaces when `pad?`, and otherwise left alone
   (returning #f)."
  (let* ([len (buffer-line-length line)] [width (line-display-col line len)])
    (if (>= x width)
        (and (or pad? (= x width))
             (let ([at (line-end line)] [new (string-append (make-string (- x width) #\space) text)])
               (buffer-insert! at new)
               (+ at (string-length new))))
        (let* ([col (line-col-at-display line x)] [span (col-span line col)]
               [at (line-col->offset line col)] [pad (make-string (- x (car span)) #\space)])
          (cond
            [(= (car span) x) (buffer-insert! at text) (+ at (string-length text))]
            [(equal? (buffer-substring at (+ at 1)) "\t")
             (replace-range! at (+ at 1)
                             (string-append pad text (make-string (- (cadr span) x) #\space)))
             (+ at (string-length pad) (string-length text))]
            [else
             (buffer-insert! at (string-append pad text))
             (+ at (string-length pad) (string-length text))])))))

(define (put-block! text after?)
  "Puts a block's lines at the cursor's display column (after its char
   with p), one per line downward, adding lines and padding short ones as
   needed."
  (let* ([lines (split-lines text)]
         [first (current-line)]
         [span (col-span first (current-col))]
         [x (if (and after? (> (buffer-line-length first) 0)) (cadr span) (car span))]
         [start #f])
    (let loop ([ls lines] [l first])
      (unless (null? ls)
        (when (> l (last-line))
          (buffer-insert! (buffer-length) (if (ends-with? (buffer-substring 0 (buffer-length)) "\n") "\n" "\n\n")))
        (let ([end (insert-at-display! l x (car ls) #t)])
          (unless start (set! start (- end (string-length (car ls))))))
        (loop (cdr ls) (+ l 1))))
    (mark-set! "[" start)
    (set-cursor! start)))

(define (block-operator! op-key to-eol?)
  "d y c and the rest on a block. d and y keep the text as a block register."
  (when to-eol? (set! *block-eol* #t))
  (let* ([segments (block-segments)] [b (block-bounds)]
         [top-left (car (car segments))])
    (leave-visual!)
    (begin-change!)
    (cond
      [(equal? op-key "y")
       (register-set! (current-register) (block-text segments) 'block 'yank)
       (set-cursor! top-left)]
      [(equal? op-key "d")
       (register-set! (current-register) (block-text segments) 'block 'delete)
       (delete-segments! segments)
       (set-cursor! (+ top-left (caddr (car segments))))]
      [(equal? op-key "c")
       (register-set! (current-register) (block-text segments) 'block 'delete)
       (delete-segments! segments)
       (start-block-insert! (car b) (cadr b) (caddr b) #f (+ top-left (caddr (car segments))))]
      [else
       (for-each (lambda (seg) ((hash-ref *operators* op-key) (car seg) (cadr seg) #f))
                 (reverse segments))
       (set-cursor! top-left)])
    (set! *block-eol* #f))
  void)

(define (start-block-insert! first last col append? at)
  "I, A and c on a block: type on the first line at offset `at`; on <esc>
   the same text goes into every other line of the block. `col` is a
   display column or 'eol; `append?` (A) pads lines too short to reach
   it."
  (set! *block-insert* (list first last col append?))
  (set-cursor! at)
  (set-mode! 'insert)
  (set! *insert-start* at)
  void)

(define (finish-block-insert!)
  "Copies the text typed on a block's first line into its other lines.
   Runs on <esc> after I, A or c on a block. Nothing is copied if the
   cursor left the first line or the text has a line break. Short lines
   are skipped, except by A, which pads them."
  (let* ([b *block-insert*] [first (car b)] [last (cadr b)] [col (caddr b)] [append? (cadddr b)])
    (set! *block-insert* #f)
    (when (and (= (current-line) first) (>= (cursor) *insert-start*))
      (let ([text (buffer-substring *insert-start* (cursor))])
        (unless (or (equal? text "") (string-contains? text "\n"))
          (let loop ([l (+ first 1)])
            (when (<= l last)
              (if (eq? col 'eol)
                  (buffer-insert! (line-end l) text)
                  (insert-at-display! l col text append?))
              (loop (+ l 1)))))))))

(define (block-insert-command append?)
  "The visual I (or A, with `append?`) command.
   In a block, types on every line at its left edge (or right edge, or
   line ends after $). In other visual modes, enters insert mode at the
   start or end of the selection."
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
               [col (cond [(not append?) (caddr b)] [(not (cadddr b)) 'eol] [else (cadddr b)])])
          (leave-visual!)
          (begin-change!)
          (set! *block-eol* #f)
          ;; The first line is split or padded (A) to reach the column, as
          ;; the others will be.
          (start-block-insert! first last col append?
                               (if (eq? col 'eol)
                                   (line-end first)
                                   (or (insert-at-display! first col "" append?) (line-end first))))))))

(define-key! 'visual "I" (block-insert-command #f))
(define-key! 'visual "A" (block-insert-command #t))

;; O in a block goes to the other corner on the same line: the same
;; display column, which may be a different char column there.
(define-key! 'visual "O"
  (lambda (count)
    (if (eq? *visual* 'block)
        (let* ([a *visual-anchor*] [c (cursor)] [la (offset->line a)] [lc (offset->line c)]
               [xa (line-display-col la (offset->col a))] [xc (line-display-col lc (offset->col c))])
          (set! *visual-anchor* (line-col->offset la (line-col-at-display la xc)))
          (set-cursor! (line-col->offset lc (line-col-at-display lc xa))))
        ((lookup-key 'visual "o") count))))

(define (visual-command! kind)
  "v, V and C-v: start a selection of `kind`, or switch to that kind.
   Leaves visual mode if the selection is already of that kind."
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

(define (visual-text-object! key count)
  "A text object in visual mode selects the object, taking in the current
   selection if it is larger than one char."
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

(define (visual-repeat op-key range)
  "How to repeat a visual operator with `.`: the same number of lines, or of
   chars, from wherever the cursor is then."
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
  "Runs operator `op-key` on the selection and leaves visual mode.
   `linewise?` makes it act on whole lines (as visual D and Y do); for a
   block it means to each line's end."
  (if (eq? *visual* 'block)
      (block-operator! op-key linewise?)
      (char-or-line-operator! op-key linewise?)))

(define (char-or-line-operator! op-key linewise?)
  "Runs operator `op-key` on a char or line selection, recording it for `.`.
   `linewise?` widens the selection to whole lines."
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
  "`text` without its final line break, if it has one."
  (if (ends-with? text "\n") (substring text 0 (- (string-length text) 1)) text))

;;; More operators and commands

;; Case operators: gu gU g~ g?, and ~ on chars.
(define (map-string f text)
  "`text` with each char replaced by `f` of it."
  (list->string (map f (string->list text))))

(define (toggle-case c)
  "`c` in the other case: capitals become small letters, and back."
  (if (equal? (char-upcase c) c) (char-downcase c) (char-upcase c)))

(define (rot13 c)
  "`c` rotated 13 places in the alphabet, for g?. Others stay as they are."
  (let ([n (char->integer c)])
    (cond [(and (>= n 97) (<= n 122)) (integer->char (+ 97 (modulo (+ (- n 97) 13) 26)))]
          [(and (>= n 65) (<= n 90)) (integer->char (+ 65 (modulo (+ (- n 65) 13) 26)))]
          [else c])))

(define (replace-range! start end text)
  "Replaces the text from `start` to `end` with `text`."
  (buffer-delete! start end)
  (buffer-insert! start text))

(define (case-operator f)
  "An operator that maps every char in its range through `f`.
   The cursor goes to the range's start (its first non-blank if
   linewise). gu gU g~ and g? are made with it."
  (lambda (start end linewise?)
    (replace-range! start end (map-string f (buffer-substring start end)))
    (set-cursor! (if linewise? (line-first-nonblank (offset->line start)) start))))

(define-operator! "gu" (case-operator char-downcase))
(define-operator! "gU" (case-operator char-upcase))
(define-operator! "g~" (case-operator toggle-case))
(define-operator! "g?" (case-operator rot13))

(define (tilde! count)
  "~: toggles the case of `count` chars from the cursor, then moves past.
   Stops at the end of the line."
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
  "Indent `cols` columns wide: spaces with expandtab, else tabs and spaces."
  (if (option 'expandtab)
      (make-string cols #\space)
      (let ([ts (option 'tabstop)])
        (string-append (make-string (quotient cols ts) #\tab) (make-string (modulo cols ts) #\space)))))

(define (shift-line! line dir)
  "Shifts `line` by `dir` shiftwidths, right if positive, left if negative.
   Indent never goes below zero, and empty lines are left alone."
  (let* ([start (line-start line)] [indent-end (line-first-nonblank line)]
         [cols (display-col indent-end)]
         [sw (option 'shiftwidth)]
         [new (max 0 (+ cols (* sw dir)))])
    (unless (= (buffer-line-length line) 0)
      (replace-range! start indent-end (indent-string new)))))

(define (shift-operator dir)
  "The > (`dir` 1) or < (`dir` -1) operator: shifts each line in the range.
   The cursor goes to the first line's first non-blank."
  (lambda (start end linewise?)
    (let ([first (offset->line start)] [last (offset->line (max start (- end 1)))])
      (let loop ([l first]) (when (<= l last) (shift-line! l dir) (loop (+ l 1))))
      (set-cursor! (line-first-nonblank first)))))

(define-operator! ">" (shift-operator 1))
(define-operator! "<" (shift-operator -1))

(define (visual-shift! dir)
  "In visual mode a count shifts that many times: 3> is three shiftwidths."
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

(define (replace-chars! count ch)
  "r{char}: replace `count` chars. r<ret> replaces them with a line break."
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

(define (join-lines! line count spaces?)
  "J joins lines with one space between them (none before a closing paren,
   or if the line already ends in white space); gJ joins them as they are."
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
  "The J command (gJ when `spaces?` is #f): joins `count` lines.
   Recorded for `.`."
  (lambda (count)
    (let ([change (lambda (n) (begin-change!) (join-lines! (current-line) n spaces?))])
      (change count)
      (record-change! change count))))

(define-key! 'normal "J" (join-command #t))
(define-key! 'normal "gJ" (join-command #f))

(define (visual-join spaces?)
  "Visual J (gJ when `spaces?` is #f): joins the selected lines.
   A selection on one line joins it with the next."
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
  "Whether `c` is a hex digit, 0-9 or a-f in either case. #f for #f."
  (and c (or (char-numeric-ascii? c) (memv (char-downcase c) (string->list "abcdef")))))

(define (number-at p)
  "The number at or after `p` on its line, as (start end value hex?).
   `start` includes any minus sign or 0x. #f if there is none."
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
  "`text` padded on the left with zeros to `width` chars."
  (if (< (string-length text) width)
      (string-append (make-string (- width (string-length text)) #\0) text)
      text))

(define (increment! delta)
  "Adds `delta` to the number at or after the cursor, for C-a and C-x.
   Hex keeps its width and letter case and wraps at 64 bits. The cursor
   ends on the number's last digit. Returns #t, or #f if no number was
   found on the line."
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
  "The C-a (`sign` 1) or C-x (`sign` -1) command, adding the count.
   Recorded for `.` when it found a number."
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

(define (settable-mark? c)
  "Whether m and :mark can set mark `c` (:help m): a-z A-Z ' ` [ ] < >."
  (or (letter? c) (memv c (string->list "'`[]<>"))))

(define (mark-char? c)
  "Whether ' and ` can go to mark `c`: a settable mark, one the editor
   sets (. ^), or one Vim keeps in its viminfo (\" 0-9), which imp never
   sets."
  (or (settable-mark? c) (and c (char-digit? c)) (memv c (string->list ".^\""))))

(define (mark-name c)
  "The name mark `c` is kept under: ` and ' are the same mark."
  (if (equal? c #\`) "'" (string c)))

(define (set-mark-char! c pos)
  "Sets mark `c` at `pos`, or says it isn't a mark m can set."
  (if (settable-mark? c)
      (mark-set! (mark-name c) pos)
      (set-status! (string-append "invalid mark " (if c (string c) "")))))

(define (mark-pos c)
  "The position of mark `c` (` meaning '), or #f after saying it is
   unknown or not set."
  (cond
    [(not (mark-char? c)) (set-status! (string-append "unknown mark " (if c (string c) ""))) #f]
    [(mark-get (mark-name c)) => (lambda (m) m)]
    [else (set-status! (string-append "mark not set: " (string c))) #f]))

(define-char-command! "m" (lambda (count c) (set-mark-char! c (cursor))))

(define-char-motion! "'" 'linewise
  (lambda (from n c) (let ([m (mark-pos c)]) (and m (line-first-nonblank (offset->line m))))))
(define-char-motion! "`" 'exclusive (lambda (from n c) (mark-pos c)))

(define (fold-opening-motion? key)
  "Whether motion `key` opens a closed fold it lands in.
   These are the motions of Vim's default 'foldopen': hor, mark,
   percent, search and block."
  (or (member key '("%" "{" "}" "n" "N" "*" "#" "g*" "g#" "(" ")"
                    "h" "l" "<left>" "<right>" "<bs>" "0" "^" "$" "|" "w" "W" "b" "B" "e" "E" "ge" "gE" ";" ","))
      (and (= (string-length key) 2) (member (substring key 0 1) '("'" "`" "f" "F" "t" "T")))))

(define (jump-motion? key)
  "Whether motion `key` counts as a jump.
   Jumps set the ' mark and go in the jump list."
  (or (member key '("G" "gg" "%" "{" "}" "n" "N" "*" "#" "g*" "g#" "H" "M" "L"))
      (and (= (string-length key) 2) (member (substring key 0 1) '("'" "`")))))

(define (jump-mark-line name)
  "The line of mark `name`, or 0 if it isn't set."
  (offset->line (or (mark-get name) 0)))

(define (with-buffer id thunk)
  "Runs `thunk` with buffer `id` current, then switches back."
  (let ([here (current-buffer)])
    (if (= id here)
        (thunk)
        (begin
          (switch-to-buffer! id)
          (let ([result (thunk)])
            (switch-to-buffer! here)
            result)))))

;; Jump list entries are (buffer-id . mark-name), so jumps cross buffers.
(define (jump-buffer j)
  "The buffer id of jump list entry `j`."
  (car j))
(define (jump-mark j)
  "The name of the mark that holds jump list entry `j`'s position."
  (cdr j))

(define (record-jump!)
  "Records the cursor as a jump. Like Vim, an older entry on the same line
   is dropped, and the list keeps the last 100."
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
    (set! *jump-index* (length *jumps*)))
  void)

;; C-o and C-i (<tab> in a terminal) move back and forth in the list.
(define (jump-older! count)
  "C-o: goes `count` entries back in the jump list.
   Leaving the newest position records it first, so C-i can return."
  (when (= *jump-index* (length *jumps*))
    ;; Leaving the newest position: remember it so C-i can come back.
    (record-jump!)
    (set! *jump-index* (- (length *jumps*) 1)))
  (jump-to-index! (- *jump-index* count)))

(define (jump-to-index! i)
  "Goes to entry `i` of the jump list, switching buffer if it is elsewhere.
   An index outside the list fails the command, which stops a macro."
  (if (or (< i 0) (>= i (length *jumps*)))
      (set! *command-failed* #t)
      (let ([j (list-ref *jumps* i)])
        (set! *jump-index* i)
        (when (and (not (= (jump-buffer j) (current-buffer))) (memv (jump-buffer j) (buffer-list)))
          (go-to-buffer! (jump-buffer j)))
        (set-cursor! (or (mark-get (jump-mark j)) (cursor)))))
  void)

(define-key! 'normal "C-o" (lambda (count) (jump-older! count)))
(define-key! 'normal "C-i" (lambda (count) (jump-to-index! (+ *jump-index* count))))
(define-key! 'normal "<tab>" (lambda (count) (jump-to-index! (+ *jump-index* count))))

;;; Popups: output longer than the status line

(define (show-popup! lines)
  "Shows `lines` in a popup that the next key closes."
  (set-popup! lines)
  (set! *popup-shown* #t)
  void)

(define (close-popup!)
  "Closes the popup."
  (set-popup! '())
  (set! *popup-shown* #f)
  void)

(define (printable text)
  "`text` as it would be typed: line breaks as ^J, tabs as ^I."
  (apply string-append
         (map (lambda (c) (cond [(equal? c #\newline) "^J"] [(equal? c #\tab) "^I"] [else (string c)]))
              (string->list text))))

(define (pad-right text width)
  "`text` padded on the right with spaces to `width` chars."
  (if (< (string-length text) width) (string-append text (make-string (- width (string-length text)) #\space)) text))

(define (clip text width)
  "`text` cut to at most `width` chars."
  (if (> (string-length text) width) (substring text 0 width) text))

;;; Macros
;;;
;;; q{reg} records keys into a register as text, in Vim's key notation
;;; ("<esc>", "<C-r>", "<lt>" for <), so a macro can be pasted, edited and
;;; yanked back. @{reg} plays it; @@ plays the last one again and @: repeats
;;; the last command line. A key that fails stops the macro, as in Vim.

(define (key->notation key)
  "`key` in Vim's key notation: \"<lt>\" for <, \"<C-r>\" for C-r."
  (cond [(equal? key "<") "<lt>"]
        [(= (string-length key) 1) key]
        [(starts-with? key "<") key]
        [else (string-append "<" key ">")]))

(define (keys->string keys)
  "`keys` written as text in Vim's key notation, as a macro register holds."
  (apply string-append (map key->notation keys)))

(define (string->keys text)
  "Splits `text` written in key notation back into keys.
   The inverse of keys->string; a line break becomes <ret>."
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
  "Starts recording keys into register `c`, as q{reg} does."
  (set! *recording* c)
  (set! *recorded-keys* '())
  (show-mode!))

(define (stop-recording!)
  "Stops recording and stores the recorded keys in the register.
   The keys are written in key notation, so the macro can be pasted
   and edited as text."
  (let ([c *recording*])
    (set! *recording* #f)
    (register-set! c (keys->string (reverse *recorded-keys*)) #f 'macro)
    (show-mode!)))

(define-char-command! "q"
  (lambda (count c)
    (if (or (letter? c) (char-numeric-ascii? c) (equal? c #\"))
        (start-recording! c)
        (set-status! (string-append "invalid register " (string c))))))

(define (play-keys! keys)
  "Feeds `keys` to the editor, stopping early if one fails."
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
  "Binds `key` to `proc` in both normal and visual mode."
  (define-key! 'normal key proc)
  (define-key! 'visual key proc))

(define (scroll-to! top)
  "Scrolls the window so that `top` is its first line, clamped to the buffer."
  (set-window-top! (clamp top 0 (last-line))))

(define (cursor-to-line! line)
  "Moves the cursor onto `line`'s first non-blank, as Vim's 'startofline'."
  (set-cursor! (line-first-nonblank (clamp line 0 (last-line)))))

(define (half-page-scroll! sign)
  "C-d and C-u: half a window, or `count` lines."
  (lambda (count)
    (let ([n (if *count-given* count (max 1 (quotient (window-height) 2)))])
      (scroll-to! (+ (window-top) (* sign n)))
      (cursor-to-line! (+ (current-line) (* sign n))))))

(define (page-scroll! sign)
  "C-f and C-b: a window less two lines, so some context stays on screen."
  (lambda (count)
    (let ([n (* count (max 1 (- (window-height) 2)))])
      (scroll-to! (+ (window-top) (* sign n)))
      (cursor-to-line! (if (> sign 0) (window-top) (window-bottom))))))

(define (line-scroll! sign)
  "C-e and C-y: the window moves a line; the cursor only if it must."
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

(define (cursor-line-at! where first-nonblank?)
  "zt zz zb put the cursor line at the top, middle or bottom of the window;
   z<ret> z. z- do the same and move to the first non-blank."
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

;;; Folds (fold.scm has how they're kept)

;; zf{motion} and visual zf make a closed fold of the lines covered.
(define-operator! "zf"
  (lambda (start end linewise?)
    (let ([first (offset->line start)]
          [last (offset->line (if linewise? (max start (- end 1)) end))])
      (fold-create! first last #t)
      (set-cursor! (line-first-nonblank first)))))

;; zF makes a fold of count lines.
(define-key! 'normal "zF"
  (lambda (count) (fold-create! (current-line) (fold-step (current-line) (- count 1)) #t)))

(define (fold-command! key proc)
  "Binds `key` in normal and visual mode to `proc` on the cursor's line.
   `proc` is (lambda (line) ...); the count is ignored."
  (define-normal-and-visual! key (lambda (count) (proc (current-line)))))

(define (fold-or-complain line ok? what)
  "The innermost fold at `line` that satisfies `ok?`, or #f.
   When there is none, says E490 on the status line, followed by `what`."
  (or (innermost-fold line ok?) (begin (set-status! (string-append "E490: No fold found" what)) #f)))

;; zo opens the fold under the cursor (the closed one showing there), zO
;; every fold there.
(fold-command! "zo"
  (lambda (line)
    (let ([f (closed-fold-at line)])
      (if f (fold-set-closed! (fold-id f) #f) (fold-or-complain line (lambda (f) #f) "")))))
(fold-command! "zO"
  (lambda (line) (for-each (lambda (f) (fold-set-closed! (fold-id f) #f)) (folds-at line))))
;; zc closes the innermost open fold there, zC every fold there.
(fold-command! "zc"
  (lambda (line)
    (let ([f (innermost-fold line (lambda (f) (not (fold-closed? f))))])
      (cond [f (fold-set-closed! (fold-id f) #t)]
            [(null? (folds-at line)) (fold-or-complain line (lambda (f) #f) "")]
            [else #f]))
    (set-cursor! (line-first-nonblank (shown-line line)))))
(fold-command! "zC"
  (lambda (line)
    (for-each (lambda (f) (fold-set-closed! (fold-id f) #t)) (folds-at line))
    (set-cursor! (line-first-nonblank (shown-line line)))))
;; za: open if closed, close if open.
(fold-command! "za"
  (lambda (line)
    (if (closed-fold-at line) ((lookup-key 'normal "zo") 1) ((lookup-key 'normal "zc") 1))))
(fold-command! "zA"
  (lambda (line)
    (if (closed-fold-at line) ((lookup-key 'normal "zO") 1) ((lookup-key 'normal "zC") 1))))
;; zR opens and zM closes every fold; zE deletes them all.
(fold-command! "zR"
  (lambda (line) (for-each (lambda (f) (fold-set-closed! (fold-id f) #f)) (buffer-folds))))
(fold-command! "zM"
  (lambda (line)
    (for-each (lambda (f) (fold-set-closed! (fold-id f) #t)) (buffer-folds))
    (set-cursor! (line-first-nonblank (shown-line line)))))
(fold-command! "zE"
  (lambda (line) (for-each (lambda (f) (fold-delete! (fold-id f))) (buffer-folds))))
;; zd deletes the innermost fold at the cursor (its text stays), zD every
;; one there.
(fold-command! "zd"
  (lambda (line)
    (let ([f (or (closed-fold-at line) (fold-or-complain line (lambda (f) #t) ""))])
      (when f (fold-delete! (fold-id f))))))
(fold-command! "zD"
  (lambda (line) (for-each (lambda (f) (fold-delete! (fold-id f))) (folds-at line))))
;; zj and zk move to the start of the next fold, and the end of the one
;; before.
(define-key! 'normal "zj"
  (lambda (count)
    (let ([starts (filter (lambda (l) (> l (current-line))) (map fold-first (buffer-folds)))])
      (if (null? starts) (set! *command-failed* #t) (cursor-to-line! (apply min starts))))))
(define-key! 'normal "zk"
  (lambda (count)
    (let ([ends (filter (lambda (l) (< l (current-line))) (map fold-last (buffer-folds)))])
      (if (null? ends) (set! *command-failed* #t) (cursor-to-line! (apply max ends))))))

;;; Normal mode dispatch

;;; Which-key labels

(define (binding-label state key)
  "The which-key label of `key` in `state` ('normal or 'visual): the label
   it was bound with, else the name of the command it runs, else #f.
   Looks where normal-key! does, in the same order, so the binding that
   would run is the one described."
  (let ([keymap-label
         (lambda (table)
           (let ([binding (hash-try-get (keymap table) key)])
             (and binding
                  (list (or (binding-label-in table key)
                            (and (symbol? binding) (symbol->string binding)))))))]
        [table-label
         (lambda (table found?)
           (and found? (list (binding-label-in table key))))])
    (let loop ([lookups
                (append
                 (map (lambda (m) (lambda () (keymap-label m))) (*local-keymaps* state))
                 (if (eq? state 'visual)
                     (list (lambda () (keymap-label 'visual))
                           (lambda () (table-label 'operator (hash-contains? *operators* key)))
                           (lambda () (table-label 'motion (find-motion key))))
                     (list (lambda () (table-label 'operator (hash-contains? *operators* key)))
                           (lambda () (table-label 'motion (find-motion key)))
                           (lambda () (keymap-label 'normal)))))])
      (cond [(null? lookups) #f]
            [((car lookups)) => car]
            [else (loop (cdr lookups))]))))

;; Keys that start a longer key: (define-prefix! "z") makes "zz", "zt" ...
;; reachable. Char motions and char commands are prefixes automatically.
(define *prefix-keys* (hash "g" #t "z" #t "Z" #t "[" #t "]" #t "\"" #t))

(define (define-prefix! key)
  "Makes `key` a prefix: in normal mode it waits for the next key.
   (define-prefix! \"z\") is what lets \"zz\" and \"zt\" be bound."
  (set! *prefix-keys* (hash-insert *prefix-keys* key #t))
  void)

(define (prefix-key? key)
  "Whether `key` waits for another key in normal mode.
   True for declared prefixes and char motions, and for char commands
   when no operator is pending."
  (or (hash-contains? *prefix-keys* key)
      (hash-contains? *char-motions* key)
      (and (not *operator*) (hash-contains? *char-commands* key))))

(define (digit? key)
  "Whether `key` is a single digit key, 0 to 9."
  (and (= (string-length key) 1)
       (char-numeric-ascii? (string-ref key 0))))

(define (char-numeric-ascii? c)
  "Whether `c` is an ASCII digit, 0 to 9."
  (let ([n (char->integer c)]) (and (>= n 48) (<= n 57))))

(define (count-value s)
  "The count typed as the digits `s`, 1 if none were typed."
  (if (equal? s "") 1 (string->number s)))

(define (normal-key! key)
  "Handles `key` in normal or visual mode.
   Builds up counts, prefixes, registers and pending operators, then
   runs the command, motion, operator or text object they make. Looks in
   the buffer's mode keys before Vim's own. Afterwards keeps the cursor
   on a char and updates the goal column."
  ;; The key after a prefix closes its which-key popup.
  (when *prefix* (*prefix-which-key* #f #f #f))
  (cond
    [(and (member key '("<esc>" "C-c")) (or *operator* *prefix* (not (equal? *count* ""))))
     (reset-pending!)]
    [(and (member key '("<esc>" "C-c")) (not (eq? *mode* 'visual)))
     (reset-pending!)]

    ;; Counts. A leading 0 is the motion, not a count, and a buffer's mode
    ;; can bind digits (the start screen's recent files).
    [(and (digit? key) (not *prefix*) (not (and (equal? key "0") (equal? *count* "")))
          (not (and (equal? *count* "") (not *operator*)
                    (local-key-proc (if (eq? *mode* 'visual) 'visual 'normal) key))))
     (set! *count* (string-append *count* key))]

    ;; Search prompts. With an operator pending, the search is its motion.
    ;; A buffer's mode can take / or ? over (? in the git status).
    [(and (not *prefix*) (member key '("/" "?"))
          (not (and (equal? *operator* "g?") (equal? key "?"))) ; g??
          (not (and (not *operator*) (local-key-proc (if (eq? *mode* 'visual) 'visual 'normal) key))))
     (let ([op *operator*]
           [count (* (count-value *operator-count*) (count-value *count*))])
       (reset-pending!)
       (start-search! (equal? key "/") op count))]

    ;; Prefix keys wait for the next key: `g`, `z`, char motions like `f`.
    ;; A buffer's mode can take one over (q in special buffers).
    [(and (not *prefix*) (prefix-key? key)
          (not (and (not *operator*) (local-key-proc (if (eq? *mode* 'visual) 'visual 'normal) key))))
     (set! *prefix* key)
     ;; which-key for g, z, C-w ...; not for registers, char motions or
     ;; an operator's motion.
     (when (and (hash-contains? *prefix-keys* key) (not (equal? key "\"")) (not *operator*))
       (*prefix-which-key* (if (eq? *mode* 'visual) 'visual 'normal) (string-append *count* key) key))]
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

         ;; A buffer's mode keys come before Vim's own, so special buffers
         ;; can bind operators and motions (c, d, l in git status).
         [(local-key-proc (if (eq? *mode* 'visual) 'visual 'normal) key)
          => (lambda (proc) (set! *count* "") (proc count))]

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
                    (when (fold-opening-motion? key) (set! *fold-open-wanted* #t))
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
      (set! *goal-col* (current-col))))
  void)

;;; Insert and replace mode

(define (keys->text keys)
  "The text that typing `keys` inserts, near enough for the \". register."
  (apply string-append
         (map (lambda (k)
                (cond [(= (string-length k) 1) k]
                      [(equal? k "<ret>") "\n"]
                      [(equal? k "<tab>") "\t"]
                      [else ""]))
              keys)))

(define (display-col p)
  "The display column of offset `p`, counting tabs to the next tab stop."
  (let ([ts (option 'tabstop)])
    (let loop ([q (line-start (offset->line p))] [col 0])
      (if (>= q p)
          col
          (loop (+ q 1) (if (equal? (buffer-char-at q) #\tab) (+ col (- ts (modulo col ts))) (+ col 1)))))))

(define (insert-tab!)
  "Inserts a tab, or spaces to the next tab stop when expandtab is on."
  (if (option 'expandtab)
      (let ([ts (option 'tabstop)])
        (insert-text! (make-string (- ts (modulo (display-col (cursor)) ts)) #\space)))
      (insert-text! "\t")))

(define (drop-unused-autoindent!)
  "If the cursor's line holds only indent that autoindent added, remove it:
   leaving the line or insert mode doesn't keep stray white space."
  (when (and *autoindent-line* (= *autoindent-line* (current-line)) (blank-line? (current-line)))
    (let ([start (line-start (current-line))])
      (buffer-delete! start (line-end (current-line)))
      (set-cursor! start)))
  (set! *autoindent-line* #f)
  void)

;; smartindent: after a line ending in an opening bracket the new line is
;; indented one shiftwidth more, and <ret> between a pair of brackets puts
;; the closing one on its own line. Modes set which brackets count.
(define-option! 'smartindent #f '(si))
(define-option! 'indent-open "{[(" '())
(define-option! 'indent-close "}])" '())

(define (char-before-cursor-on-line)
  "The last non-blank char before the cursor on its line, or #f."
  (let ([lo (line-start (current-line))])
    (let loop ([p (cursor)])
      (cond [(<= p lo) #f]
            [(char-whitespace? (buffer-char-at (- p 1))) (loop (- p 1))]
            [else (buffer-char-at (- p 1))]))))

(define (char-after-cursor-on-line)
  "The first non-blank char at or after the cursor on its line, or #f."
  (let ([hi (line-end (current-line))])
    (let loop ([p (cursor)])
      (cond [(>= p hi) #f]
            [(char-whitespace? (buffer-char-at p)) (loop (+ p 1))]
            [else (buffer-char-at p)]))))

(define (opens-indent? c)
  "Whether `c` is one of the indent-open brackets, for smartindent."
  (and c (memv c (string->list (option 'indent-open)))))
(define (closes-indent? c)
  "Whether `c` is one of the indent-close brackets, for smartindent."
  (and c (memv c (string->list (option 'indent-close)))))

(define (insert-newline!)
  "Inserts a line break in insert mode, indenting the new line.
   With autoindent it copies the indent; with smartindent it goes one
   shiftwidth deeper after an opening bracket, and between a pair of
   brackets puts the closing one on a line of its own."
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
        (begin
          (insert-text! (string-append "\n" deeper))
          (let ([inside (cursor)])
            (buffer-insert! inside (string-append "\n" indent))
            (set-cursor! inside)))
        (insert-text! (string-append "\n" deeper)))
    (set! *autoindent-line* (and (> (string-length deeper) 0) (current-line))))
  void)

(define (maybe-dedent-for! ch)
  "Typing a closing bracket first on a line takes one shiftwidth off it."
  (when (and (option 'smartindent) (closes-indent? ch)
             (= (cursor) (line-first-nonblank (current-line)))
             (> (cursor) (line-start (current-line))))
    (let* ([line (current-line)] [from-end (- (line-end line) (cursor))])
      (shift-line! line -1)
      (set-cursor! (- (line-end line) from-end)))))

;; auto-pairs: typing an opener also types its closer, before a gap
;; (docs/specs/auto-pairs.md). auto-pairs-chars lists each opener and its
;; closer, a quote being its own; modes set it locally.
(define-option! 'auto-pairs #t '())
(define-option! 'auto-pairs-chars "()[]{}\"\"''``" '())

(define (pair-partner c)
  "The closer of opener `c` in the buffer's pairs, or #f, wherever the
   cursor is; #f too with auto-pairs off."
  (and (option 'auto-pairs) (not *pasting*)
       (let loop ([cs (string->list (option 'auto-pairs-chars))])
         (cond [(or (null? cs) (null? (cdr cs))) #f]
               [(equal? (car cs) c) (cadr cs)]
               [else (loop (cddr cs))]))))

(define (pair-closer c)
  "The closer that typing opener `c` adds, or #f if it doesn't pair here.
   A bracket pairs before a gap; a quote also not after a letter or digit,
   nor inside a string or comment."
  (let ([closer (pair-partner c)])
    (and closer
         (gap-after-cursor?)
         (or (not (equal? c closer))
             (not (or (word-before-cursor?) (in-string-or-comment?))))
         closer)))

(define (pair-brackets-closing)
  "The closers of the pairs that aren't quotes, as chars."
  (let loop ([cs (string->list (option 'auto-pairs-chars))] [out '()])
    (cond [(or (null? cs) (null? (cdr cs))) out]
          [(equal? (car cs) (cadr cs)) (loop (cddr cs) out)]
          [else (loop (cddr cs) (cons (cadr cs) out))])))

(define (gap-after-cursor?)
  "Whether the char after the cursor leaves room for a pair: white space,
   the end of the line, a closing bracket, or , ; : ."
  (or (>= (cursor) (line-end (current-line)))
      (let ([c (buffer-char-at (cursor))])
        (or (char-whitespace? c)
            (memv c (list #\, #\; #\: #\.))
            (memv c (pair-brackets-closing))))))

(define (word-before-cursor?)
  "Whether the char before the cursor, on its line, is a letter or digit."
  (and (> (cursor) (line-start (current-line)))
       (let ([c (buffer-char-at (- (cursor) 1))])
         (and (char-word? c) (not (equal? c #\_))))))

(define (in-string-or-comment?)
  "Whether the cursor is inside a string or comment, by the syntax tree.
   Just past a string's closing quote is outside it; at the end of a
   comment is still in it, as a line comment runs to the line's end."
  (let ([p (cursor)])
    (define (around? at test)
      (let loop ([nodes (syntax-ancestors at)])
        (and (pair? nodes)
             (or (test (car (car nodes)) (caddr (car nodes)) (cadddr (car nodes)))
                 (loop (cdr nodes))))))
    (or (around? p (lambda (kind start end) (and (string-contains? kind "string") (< start p) (< p end))))
        ;; The char before the cursor, as the tree has none at a line's end.
        (and (> p 0)
             (around? (- p 1)
                      (lambda (kind start end) (and (string-contains? kind "comment") (< start p) (<= p end))))))))

(define (insert-pair! opener closer)
  "Types `opener` and puts `closer` after the cursor, remembering the pair
   so that typing the closer steps over it and <bs> deletes both."
  (insert-text! opener)
  (buffer-insert! (cursor) (string closer))
  (set! *pair-added* (list (- (cursor) 1) (cursor) (string-ref opener 0) closer))
  void)

;; A pair is (open close opener closer): the offsets of its two chars.
(define (pair-live? pair)
  "Whether `pair` is still in the buffer with the cursor inside it."
  (let ([open (car pair)] [close (cadr pair)])
    (and (< open (cursor)) (<= (cursor) close) (< close (buffer-length))
         (equal? (buffer-char-at open) (caddr pair))
         (equal? (buffer-char-at close) (cadddr pair)))))

(define (track-pairs! before len)
  "Moves the remembered pairs past an edit at the cursor, which was at
   `before` with the buffer `len` chars long, and forgets those the
   cursor has left."
  (let ([delta (- (buffer-length) len)])
    (set! *pairs*
          (filter pair-live?
                  (map (lambda (pair)
                         (let ([shift (lambda (p) (if (>= p before) (+ p delta) p))])
                           (list (shift (car pair)) (shift (cadr pair)) (caddr pair) (cadddr pair))))
                       *pairs*))))
  void)

(define (pair-closing-at-cursor c)
  "The pair whose closer `c` is the char at the cursor, or #f."
  (let loop ([ps *pairs*])
    (cond [(null? ps) #f]
          [(and (= (cadr (car ps)) (cursor)) (equal? (cadddr (car ps)) c)) (car ps)]
          [else (loop (cdr ps))])))

(define (delete-empty-pair!)
  "Deletes the empty pair around the cursor, both its chars."
  (buffer-delete! (- (cursor) 1) (+ (cursor) 1))
  (set-cursor! (- (cursor) 1))
  void)

(define (wrap-region! start end opener closer)
  "Puts `opener` before start..end and `closer` after it, the cursor
   just past the closer."
  (buffer-insert! end (string closer))
  (buffer-insert! start opener)
  (set-cursor! (+ end 2))
  void)

(define (empty-pair-around-cursor)
  "The pair that is empty with the cursor between its chars, or #f."
  (let loop ([ps *pairs*])
    (cond [(null? ps) #f]
          [(and (= (cadr (car ps)) (cursor)) (= (car (car ps)) (- (cursor) 1))) (car ps)]
          [else (loop (cdr ps))])))

(define (delete-word-before!)
  "C-w: the word (or white space run, or line break) before the cursor."
  (let* ([p (cursor)] [lo (line-start (current-line))])
    (if (= p lo)
        (when (> p 0) (buffer-delete! (- p 1) p) (set-cursor! (- p 1)))
        (let* ([q (let loop ([q p]) (if (and (> q lo) (blank-at? (- q 1))) (loop (- q 1)) q))]
               [q (if (> q lo) (run-start (- q 1) char-class lo) q)])
          (buffer-delete! q p)
          (set-cursor! q)))))

(define (delete-line-before!)
  "C-u: what was typed on this line, or if nothing was, the line before the
   cursor down to its indent."
  (let* ([p (cursor)] [line (current-line)]
         [q (cond [(and (< *insert-start* p) (= (offset->line *insert-start*) line)) *insert-start*]
                  [(> p (line-first-nonblank line)) (line-first-nonblank line)]
                  [else (line-start line)])])
    (buffer-delete! q p)
    (set-cursor! q)))

(define (shift-current-line! dir)
  "C-t and C-d: shift the line by shiftwidth, keeping the cursor on its text."
  (let* ([line (current-line)] [from-end (- (line-end line) (cursor))])
    (shift-line! line dir)
    (set-cursor! (max (line-first-nonblank line) (- (line-end line) from-end)))))

(define (replace-char! ch)
  "Types `ch` in replace mode, overwriting the char under the cursor.
   What it overwrote is remembered so <bs> can put it back. At the end of
   the line it just inserts."
  (let ([p (cursor)])
    (if (< p (line-end (current-line)))
        (begin
          (set! *replaced* (cons (cons p (buffer-char-at p)) *replaced*))
          (buffer-delete! p (+ p 1)))
        (set! *replaced* (cons (cons p #f) *replaced*)))
    (insert-text! ch)))

(define (replace-backspace!)
  "<bs> in replace mode puts back what was overwritten."
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
  "Handles one key typed in insert or replace mode.
   The buffer's mode keys come first, then the editing keys (<ret>,
   <bs>, C-w, C-u, C-t, C-d, arrows...), then plain chars, then the
   insert keymap."
  (unless (member key '("<ret>" "C-j" "C-m")) (set! *autoindent-line* #f))
  (with-pairs-tracked (lambda () (insert-key-edit! key))))

(define (with-pairs-tracked thunk)
  "Calls `thunk`, an edit at the cursor, keeping the pairs auto-pairs
   added in step with it. Insert mode and the Emacs state run each key
   through it."
  (let ([before (cursor)] [len (buffer-length)])
    (set! *pair-added* #f)
    (thunk)
    (track-pairs! before len)
    ;; A pair this edit added is where it belongs already; only older ones move.
    (when *pair-added*
      (set! *pairs* (cons *pair-added* *pairs*))
      (set! *pair-added* #f)))
  void)

(define (insert-key-edit! key)
  "What insert-key! does with `key`, past the pairs it keeps track of."
  (cond
    ;; A mode's own insert keys come first (the REPL's <ret>).
    [(local-key-binding 'insert key) => run-insert-binding!]
    [(member key '("<ret>" "C-j" "C-m")) (insert-newline!)]
    [(equal? key "<tab>") (insert-tab!)]
    [(and (member key '("<bs>" "C-h")) (eq? *mode* 'replace)) (replace-backspace!)]
    [(and (member key '("<bs>" "C-h")) (empty-pair-around-cursor)) (delete-empty-pair!)]
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
    [(and (= (string-length key) 1) (pair-closing-at-cursor (string-ref key 0)))
     (set-cursor! (+ (cursor) 1))]
    [(and (= (string-length key) 1) (pair-closer (string-ref key 0)))
     => (lambda (closer) (insert-pair! key closer))]
    [(and (= (string-length key) 1) (closes-indent? (string-ref key 0)))
     (maybe-dedent-for! (string-ref key 0))
     (insert-text! key)]
    [(= (string-length key) 1) (insert-typed-char! key)]
    [(key-binding 'insert key) => run-insert-binding!]
    [else #t]))

(define (insert-typed-char! key)
  "Types one plain char `key`, then lets *typed-char-handler* act on it,
   as closing an end tag after a start tag's > does."
  (insert-text! key)
  (when *typed-char-handler* (*typed-char-handler* (string-ref key 0)))
  void)

(define (run-insert-binding! binding)
  "Runs an insert-state binding: a command name as a command (count 1),
   a procedure with no arguments."
  (if (symbol? binding) (run-command binding) (binding)))

(define (insert-text! text)
  "Inserts `text` at the cursor and moves the cursor past it."
  (buffer-insert! (cursor) text)
  (set-cursor! (+ (cursor) (string-length text))))

(define (leave-insert!)
  "Goes back to normal mode from insert, Vim's way.
   The cursor steps back onto the last char typed. Sets the ^ mark and
   where gi resumes, and drops indent autoindent added to an empty line."
  (drop-unused-autoindent!)
  (set! *pairs* '())
  (mark-set! "^" (cursor))
  (set! *last-insert-pos* (cursor))
  (set-mode! 'normal)
  ;; Leaving insert mode steps back onto the last inserted char.
  (when (> (current-col) 0)
    (set-cursor! (- (cursor) 1)))
  (normal-clamp!)
  (set! *goal-col* (current-col))
  void)

(define (insert-mode-key! key)
  "Handles `key` in insert or replace mode, around insert-key!.
   Takes care of C-r {register}, C-o for one normal command, and <esc>,
   which repeats the text for a count, finishes a block insert, records
   the insert for `.` and leaves insert mode."
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
    [(and *insert-key-handler* (*insert-key-handler* key)) #t]
    [else
     (set! *insert-keys* (cons key *insert-keys*))
     (insert-key! key)])
  void)

;;; The command line
;;;
;;; One prompt serves `:`, `/` and `?`. Whoever opens it says what happens
;;; on each edit, on <ret> and on <esc>.

(define (open-cmdline! prompt initial on-submit on-change on-cancel)
  "Opens the command line with `prompt` and `initial` text.
   `on-submit` gets the text on <ret>; `on-change` (or #f) gets it after
   each edit; `on-cancel` (or #f) runs on <esc>. Closing it returns to
   the mode it was opened from."
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
  "Redraws the command line: the prompt, the text and the cursor."
  (set-cmdline! (string-append *cmdline-prompt* *cmdline*)
                (+ (string-length *cmdline-prompt*) *cmdline-pos*)))

(define (close-cmdline!)
  "Closes the command line and returns to the mode it was opened from.
   Also drops any completion list and clears the status line."
  (wild-reset!)
  (when *cmdline-completer* (*cmdline-completer* 'close #f))
  (set! *cmdline-key-handler* #f)
  (clear-cmdline!)
  (set-mode! *cmdline-return*)
  (set-status! ""))

(define (cmdline-edit! text pos)
  "Replaces the command line's text with `text`, its cursor at `pos`.
   Runs the prompt's on-change procedure, if it has one."
  (set! *cmdline* text)
  (set! *cmdline-pos* (clamp pos 0 (string-length text)))
  (show-cmdline!)
  (when *cmdline-change* (*cmdline-change* text))
  (when *cmdline-completer* (*cmdline-completer* 'edit #f)))

(define (cmdline-before)
  "The command line's text before the cursor."
  (substring *cmdline* 0 *cmdline-pos*))
(define (cmdline-after)
  "The command line's text from the cursor on."
  (substring *cmdline* *cmdline-pos* (string-length *cmdline*)))

(define (cmdline-insert! text)
  "Inserts `text` at the command line's cursor."
  (cmdline-edit! (string-append (cmdline-before) text (cmdline-after))
                 (+ *cmdline-pos* (string-length text))))

(define (cmdline-delete-back! from)
  "Deletes the command line's text from index `from` to the cursor."
  (cmdline-edit! (string-append (substring *cmdline* 0 from) (cmdline-after)) from))

(define (drop-last-word text)
  "The text with its last word (and the white space after it) removed."
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

(define (history prompt)
  "The history entries for `prompt`, newest first."
  (or (hash-try-get *history* prompt) '()))

(define (add-history! prompt text)
  "Adds `text` to `prompt`'s history as the newest entry.
   An earlier copy of it is dropped, empty text isn't kept, and each
   prompt keeps 200 entries."
  (unless (equal? text "")
    (let* ([old (filter (lambda (h) (not (equal? h text))) (history prompt))]
           [new (cons text old)])
      (set! *history* (hash-insert *history* prompt
                                   (if (> (length new) 200) (take new 200) new)))))
  void)


(define (history-step! dir)
  "Steps `dir` entries through the prompt's history (1 is older).
   Only entries starting with what was typed before the first step are
   visited; stepping past the newest brings that text back."
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
  "Handles `key` on the command line: editing, history and completion.
   <ret> submits and <esc> cancels, both adding the line to history; <bs>
   on an empty line cancels too. C-r {register} inserts a register and
   C-r C-w the word under the cursor."
  (unless (member key '("<tab>" "<s-tab>")) (wild-reset!))
  (cond
    ;; Completion menus and the like take the keys they want first.
    [(and *cmdline-key-handler* (*cmdline-key-handler* key)) #t]
    [(and *cmdline-completer* (*cmdline-completer* 'key key)) #t]
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
    [(equal? key "<tab>") (cmdline-complete! 1)]
    [(equal? key "<s-tab>") (cmdline-complete! -1)]
    [(= (string-length key) 1) (cmdline-insert! key)]
    [else #t])
  void)

;;; <tab> on the command line completes the command's name, or its
;;; argument: a file for :e, a buffer for :b, an option for :set. More with
;;; (define-ex-completion! '("name" ...) proc), proc taking the argument
;;; typed so far and returning candidates. The first <tab> extends what is
;;; typed as far as the candidates agree and lists them in the popup; more
;;; <tab>s (and <s-tab>) step through them.

(define *ex-completions* (hash))  ; ex command name -> proc

(define (define-ex-completion! names proc)
  "Makes <tab> complete the argument of the ex commands `names`.
   `proc` takes the argument typed so far and returns the candidates."
  (for-each (lambda (n) (set! *ex-completions* (hash-insert *ex-completions* n proc))) names))

(define *wild* '())       ; the candidates being stepped through
(define *wild-index* -1)  ; the one inserted, -1 for none yet
(define *wild-start* 0)   ; where the completed word starts in the line

(define (wild-reset!)
  "Ends command-line completion: forgets the candidates and their popup."
  (when (pair? *wild*)
    (set! *wild* '())
    (set! *wild-index* -1)
    (set-popup! '())))

(define (common-prefix a b)
  "The longest start that strings `a` and `b` share."
  (let loop ([i 0])
    (if (and (< i (string-length a)) (< i (string-length b)) (equal? (string-ref a i) (string-ref b i)))
        (loop (+ i 1))
        (substring a 0 i))))

(define (ex-completion-context text)
  "What <tab> completes in `text` (the line up to the cursor): (start
   candidates), or #f."
  (let* ([i (with-handler (lambda (e) #f) (skip-spaces text (caddr (parse-range text 0))))]
         [name-end (and i (let loop ([j i])
                            (if (or (letter? (char-at text j))
                                    (and (> j i) (equal? (char-at text j) #\-) (letter? (char-at text (+ j 1)))))
                                (loop (+ j 1))
                                j)))])
    (cond
      [(not i) #f]
      [(= name-end (string-length text))
       (let* ([typed (substring text i name-end)]
              [names (filter (lambda (n) (starts-with? n typed)) (hash-keys->list *ex-commands*))]
              ;; Full names only, as Vim lists them: "noh" goes,
              ;; "nohlsearch" stays.
              [full (filter (lambda (n)
                              (null? (filter (lambda (m) (and (> (string-length m) (string-length n))
                                                              (starts-with? m n)))
                                             names)))
                            names)]
              ;; And the commands : runs by name (see lore:decision/0019).
              [commands (filter (lambda (n) (and (starts-with? n typed) (not (member n full))))
                                (map symbol->string (command-names)))])
         (list i (sort (append full commands) string<?)))]
      [else
       (let* ([name (substring text i name-end)]
              [proc (hash-try-get *ex-completions* name)]
              [start (let loop ([j (string-length text)])
                       (if (and (> j name-end) (not (char-whitespace? (string-ref text (- j 1))))) (loop (- j 1)) j))])
         (and proc (> start name-end)
              (list start (proc (substring text start (string-length text))))))])))

(define (complete-path typed)
  "Files and directories (with a /) whose path starts with `typed`."
  (let* ([slash (let loop ([j (- (string-length typed) 1)])
                  (cond [(< j 0) #f] [(equal? (string-ref typed j) #\/) j] [else (loop (- j 1))]))]
         [dir (if slash (substring typed 0 (+ slash 1)) "")]
         [prefix (substring typed (string-length dir) (string-length typed))]
         [listing (directory-entries (if (equal? dir "") (current-dir) (expand-path dir)))])
    (if (string? listing)
        '()
        (map (lambda (e) (string-append dir (car e) (if (cadr e) "/" "")))
             (filter (lambda (e)
                       (and (starts-with? (car e) prefix)
                            (or (starts-with? prefix ".") (not (starts-with? (car e) ".")))))
                     listing)))))

(define-ex-completion! '("e" "edit" "w" "write" "sav" "saveas" "sp" "split" "vs" "vsplit" "r" "read"
                         "so" "source" "wq" "x" "xit" "Ex" "Explore")
  complete-path)
(define-ex-completion! '("b" "bu" "buf" "buffer" "bd" "bdelete" "bw" "bwipeout")
  (lambda (typed)
    (filter (lambda (n) (string-contains? n typed))
            (map (lambda (id) (car (buffer-info id))) (buffer-list)))))
(define-ex-completion! '("se" "set" "setl" "setlocal")
  (lambda (typed)
    (let ([names (map symbol->string (hash-keys->list *options*))])
      (sort (filter (lambda (n) (starts-with? n typed))
                    (if (starts-with? typed "no")
                        (append names (map (lambda (n) (string-append "no" n)) names))
                        names))
            string<?))))

(define (wild-label candidate)
  "The last part of a path, as the popup lists it."
  (let* ([n (string-length candidate)]
         [end (if (and (> n 1) (ends-with? candidate "/")) (- n 1) n)]
         [slash (let loop ([j (- end 1)])
                  (cond [(< j 0) #f] [(equal? (string-ref candidate j) #\/) j] [else (loop (- j 1))]))])
    (if slash (substring candidate (+ slash 1) n) candidate)))

(define (wild-show!)
  "Lists the completion candidates in a popup, in columns.
   The selected one is highlighted, and the page holding it is shown."
  (let* ([labels (map wild-label *wild*)]
         [width (+ 2 (apply max (map string-length labels)))]
         [columns (max 1 (quotient (- (window-width) 1) width))]
         [rows (min 10 (quotient (+ (length labels) (- columns 1)) columns))]
         [shown (* rows columns)]
         ;; The page holding the selected one.
         [first (* shown (quotient (max 0 *wild-index*) shown))]
         [cell (lambda (i)
                 (if (< i (length labels))
                     (list (list (pad-right (list-ref labels i) width)
                                 (if (= i *wild-index*) "popup-selected" "popup")))
                     '()))])
    ;; Not show-popup!: keys go on to the command line, not to closing it.
    (set-popup!
     (append
      (map (lambda (r)
             (cons " " (apply append (map (lambda (c) (cell (+ first (* r columns) c))) (range 0 columns)))))
           (range 0 rows))
      (if (> (length labels) shown)
          (list (list (list (string-append " " (number->string (length labels)) " matches") "popup.detail")))
          '())))))

(define (wild-select! i)
  "Puts candidate `i` in place of the word being completed."
  (set! *wild-index* i)
  (wild-replace! (list-ref *wild* i))
  (wild-show!))

(define (wild-replace! text)
  "Replaces the word being completed on the command line with `text`."
  (let ([after (substring *cmdline* *cmdline-pos* (string-length *cmdline*))])
    (cmdline-edit! (string-append (substring *cmdline* 0 *wild-start*) text after)
                   (+ *wild-start* (string-length text)))))

(define (cmdline-complete! step)
  "<tab> (`step` 1) and <s-tab> (`step` -1) on the : command line.
   The first press extends the word as far as the candidates agree and
   lists them, or fills in the only one; more presses step through them."
  (cond
    [(not (equal? *cmdline-prompt* ":")) #f]
    [(pair? *wild*) (wild-select! (modulo (+ *wild-index* step) (length *wild*)))]
    [else
     (let ([ctx (ex-completion-context (cmdline-before))])
       (cond
         [(or (not ctx) (null? (cadr ctx))) (set-status! "no completions")]
         [else
          (let* ([start (car ctx)] [candidates (cadr ctx)]
                 [typed (substring *cmdline* start *cmdline-pos*)]
                 [common (foldl (lambda (c acc) (common-prefix acc c)) (car candidates) (cdr candidates))])
            (set! *wild-start* start)
            (cond
              [(null? (cdr candidates)) (wild-replace! (car candidates))]
              [else
               (set! *wild* candidates)
               (set! *wild-index* -1)
               (if (> (string-length common) (string-length typed))
                   (begin (wild-replace! common) (wild-show!))
                   (wild-select! (if (> step 0) 0 (- (length candidates) 1))))]))]))]))

;;; Search

(define (pattern-quote text)
  "Escapes the chars that are special in a Vim pattern."
  (list->string
   (let loop ([cs (string->list text)])
     (cond
       [(null? cs) '()]
       [(memv (car cs) (list #\\ #\/ #\. #\* #\$ #\^ #\~ #\[ #\]))
        (cons #\\ (cons (car cs) (loop (cdr cs))))]
       [else (cons (car cs) (loop (cdr cs)))]))))

(define (refresh-search-highlight!)
  "Highlights the last search's matches, or clears them.
   Matches show while hlsearch is on and :noh hasn't hidden them."
  (if (and *hlsearch* *last-search* (option 'hlsearch))
      (highlight-pattern! "search" *last-search* "search")
      (highlight-clear! "search")))

(define (search-target pattern from forward? count)
  "Where the `count`th match of `pattern` from `from` is, or #f. Says on the
   status line when the search wraps or fails."
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

(define (search-motion! pattern forward? from count)
  "Searches for `pattern` and makes it the last search, so n, N and the
   highlight follow it."
  (set! *last-search* pattern)
  (set! *last-search-forward* forward?)
  (set! *hlsearch* #t)
  (refresh-search-highlight!)
  (search-target pattern from forward? count))

(define (repeat-search from count reverse?)
  "The target of n (or N with `reverse?`): the `count`th match from `from`.
   Returns `from` when there is no previous search or no match, so
   the cursor stays put."
  (cond
    [(not *last-search*) (set-status! "no previous regular expression") from]
    [else
     (set! *hlsearch* #t)
     (refresh-search-highlight!)
     (or (search-target *last-search* from (if reverse? (not *last-search-forward*) *last-search-forward*) count)
         from)]))

(define-motion! "n" 'exclusive (lambda (from n) (repeat-search from n #f)))
(define-motion! "N" 'exclusive (lambda (from n) (repeat-search from n #t)))

(define (word-at from)
  "The word under or after the cursor on its line, as (start end), or #f."
  (let* ([hi (line-end (offset->line from))]
         [p (let loop ([p from]) (if (and (< p hi) (blank-at? p)) (loop (+ p 1)) p))])
    (and (< p hi)
         (list (run-start p char-class (line-start (offset->line p)))
               (run-end p char-class hi)))))

(define (star-motion forward? whole?)
  "* and #: search for the word under the cursor. Like Vim, they ignore case
   even when smartcase would not."
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

(define (operate! op-key from target type)
  "Runs operator `op-key` over the text a motion of `type` covers."
  (let ([range (motion-range from target type)])
    (begin-change!)
    ((hash-ref *operators* op-key) (car range) (cadr range) (caddr range))))

(define (start-search! forward? op count)
  "/ and ?: prompt for a pattern, moving to matches as it is typed. With an
   operator pending, the search is the operator's (exclusive) motion."
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
                [else (record-jump!) (set! *fold-open-wanted* #t) (set-cursor! target)]))])))
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

(define (define-ex! names proc)
  "Defines an ex command under one name or a list of names (abbreviations
   are spelled out, as in (define-ex! '(\"s\" \"substitute\") ...))."
  (for-each (lambda (name) (set! *ex-commands* (hash-insert *ex-commands* name proc)))
            (if (list? names) names (list names))))

(define (ex-range ex)
  "The lines of parsed command `ex`, as (first last), 0-based."
  (car ex))          ; (first-line last-line), 0-based
(define (ex-range-given? ex)
  "Whether the user typed a range for parsed command `ex`."
  (cadr ex))
(define (ex-bang? ex)
  "Whether parsed command `ex` was given with ! (as :w!)."
  (caddr ex))
(define (ex-args ex)
  "The argument text of parsed command `ex`, after its name."
  (cadddr ex))
(define (ex-range-text ex)
  "The range of parsed command `ex` as typed (\"3\", \"%\"), or \"\"."
  (list-ref ex 4))

(define (char-at s i)
  "The char at index `i` of `s`, or #f past its end."
  (and (< i (string-length s)) (string-ref s i)))

(define (skip-spaces s i)
  "The index of the first non-white-space char of `s` at or after `i`."
  (if (and (char-at s i) (char-whitespace? (char-at s i))) (skip-spaces s (+ i 1)) i))

(define (digits-end s i)
  "The index just past the run of digits in `s` starting at `i`."
  (if (and (char-at s i) (char-numeric-ascii? (char-at s i))) (digits-end s (+ i 1)) i))

(define (visual-mark-line which)
  "The '< and '> marks: the lines of the last visual selection."
  (let ([m (mark-get (if (eq? which 'start) "<" ">"))])
    (and m (offset->line m))))

(define (read-delimited s i delim)
  "Reads `s` from index `i` up to an unescaped `delim`.
   Returns (text . next-i), next-i being just past the delimiter (or the
   end of the string). A backslash before `delim` is dropped; other
   backslashes are kept."
  (let loop ([i i] [acc '()])
    (let ([c (char-at s i)])
      (cond
        [(not c) (cons (list->string (reverse acc)) i)]
        [(equal? c delim) (cons (list->string (reverse acc)) (+ i 1))]
        [(and (equal? c #\\) (equal? (char-at s (+ i 1)) delim))
         (loop (+ i 2) (cons delim acc))]
        [(equal? c #\\) (loop (+ i 2) (if (char-at s (+ i 1)) (cons (char-at s (+ i 1)) (cons c acc)) (cons c acc)))]
        [else (loop (+ i 1) (cons c acc))]))))

(define (parse-address s i)
  "One address, as (line . next-i), line #f if there is none. Errors are
   raised with (error ...) and shown by the caller."
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

(define (parse-range s i)
  "Parses the range at index `i` of `s`, as ((first last) given? next-i).
   With no range typed it is the cursor's line and given? is #f."
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
  "Whether `c` is an ASCII letter. #f for #f."
  (and c (let ([n (char->integer (char-downcase c))]) (and (>= n 97) (<= n 122)))))

(define (parse-ex line)
  "Parses a command line into (name ex), ex being (range given? bang args
   range-text), range-text being the range as typed."
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
    (list name (list range (cadr r) bang? args (trim (substring line 0 (caddr r)))))))

(define (run-ex! line)
  "Parses and runs the command line `line`, as typed after :.
   It becomes the \": register. Errors show on the status line. A range on
   its own goes to its last line."
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
            [(command-proc (string->symbol name))
             (run-command-from-ex! name ex)]
            [else (set-status! (string-append "not an editor command: " line))])))))

(define *command-text* #f)   ; text after :NAME while NAME runs, or #f
(define *command-text-read* #f)

(define (command-argument)
  "The text typed after the command's name at the : line (:org-export html
   gives \"html\"), or #f, as when it runs from M-x or a key. A command
   whose question isn't a prompt, such as a menu of keys, reads its
   answer here; one that asks with a prompt gets it there instead."
  (set! *command-text-read* #t)
  *command-text*)

(define (run-command-from-ex! name ex)
  "Runs command `name` (a string) for command line `ex`, when no ex
   command has that name: a number before it is the count, and any other
   range is refused. Text after the name answers the first question the
   command asks, as if typed at its prompt and submitted; a command shows
   it asks by leaving a prompt open, or by reading command-argument (see
   lore:decision/0019)."
  (let ([range (ex-range-text ex)] [text (trim-end (ex-args ex))])
    (if (or (equal? range "") (string->number range))
        (begin
          (set! *command-text* (if (equal? text "") #f text))
          (set! *command-text-read* #f)
          (with-handler (lambda (e) (set-status! (error-message e)))
                        (begin
                          (run-command (string->symbol name)
                                       (let ([n (string->number range)]) (if (and n (> n 0)) n 1)))
                          (set! *command-text* #f)
                          (unless (or (equal? text "") *command-text-read*)
                            (if (eq? *mode* 'cmdline)
                                (begin (cmdline-edit! text (string-length text))
                                       (cmdline-key! "<ret>"))
                                (set-status! (string-append name " takes no argument"))))))
          (set! *command-text* #f)
          void)
        (set-status! (string-append name " takes no range")))))

(define (error-message e)
  "The message of a caught error, without the space Steel puts in front."
  (let* ([m (error-object-message e)] [m (if (string? m) m (to-string m))])
    (substring m (skip-spaces m 0) (string-length m))))

(define (mark-line c)
  "The line of mark `c`, for ex addresses like 'a."
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

(define (save-buffer! . force)
  "Saves the current buffer, running the save hooks. Returns #t if saved.
   A file changed on disk since it was read isn't overwritten unless
   `force` is given and true (as :w! does)."
  (cond
    [(and (buffer-changed-on-disk?) (file-exists? (or (buffer-path) "")) (or (null? force) (not (car force))))
     (message (string-append (buffer-name) " changed on disk since it was read (:w! to overwrite, :e! to reload)"))
     #f]
    [else
     (run-hooks 'before-save)
     (set-backup! (option 'backup))
     (and (save!)
          (begin (run-hooks 'after-save) #t))]))

(define (write-buffer! ex)
  ":w writes the buffer; :w FILE writes a copy (or names the buffer, if it
   had no file)."
  (let ([file (ex-args ex)])
    (cond
      ;; A buffer that isn't a file says what saving means (the file
      ;; browser applies its changes).
      [(and (equal? file "") (buffer-local 'write-handler)) ((buffer-local 'write-handler))]
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

(define (quit-if-saved! ex)
  "Quits unless some buffer has unsaved changes (or ! was given)."
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
(define (quit-window-or-editor! ex)
  "Closes the window if there are several, else quits as :q does.
   So :wq and :x close the window too when there are several."
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
(define-command! 'kill-server
  (lambda (count)
    "Stop the daemon, for every client attached to it. Without a daemon, quit."
    (kill-server!)))

(define-ex! '("wqa" "wqall" "xa" "xall")
  (lambda (ex) (when (write-all!) (quit-if-saved! ex))))

(define-ex! '("noh" "nohlsearch")
  (lambda (ex) (set! *hlsearch* #f) (refresh-search-highlight!)))

(define (ex-lines-operator op-key)
  ":d and :y over lines, into the register like dd and yy."
  (lambda (ex)
    (let* ([range (ex-range ex)] [r (lines-range (car range) (cadr range))])
      (begin-change!)
      ((hash-ref *operators* op-key) (car r) (cadr r) #t))))

(define-ex! '("d" "de" "del" "delete") (ex-lines-operator "d"))
;; :[range]fold, :[range]foldopen[!], :[range]foldclose[!]
(define-ex! '("fo" "fold") (lambda (ex) (fold-create! (car (ex-range ex)) (cadr (ex-range ex)) #t)))
(define (ex-fold-set! closed?)
  "The :foldopen (`closed?` #f) or :foldclose command over its range.
   With ! it acts on every fold in the range; without, only on those
   not already in that state."
  (lambda (ex)
    (let ([first (car (ex-range ex))] [last (cadr (ex-range ex))])
      (for-each (lambda (f)
                  (when (and (<= (fold-first f) last) (>= (fold-last f) first)
                             (or (ex-bang? ex) (eq? (fold-closed? f) (not closed?))))
                    (fold-set-closed! (fold-id f) closed?)))
                (buffer-folds)))))
(define-ex! '("foldo" "foldopen") (ex-fold-set! #f))
(define-ex! '("foldc" "foldclose") (ex-fold-set! #t))
(define-ex! '("y" "ya" "yank") (lambda (ex) (let ([c (cursor)]) ((ex-lines-operator "y") ex) (set-cursor! c))))

(define (substitute-command ex)
  ":s/pattern/replacement/flags. Flags: g (every match on a line), i and I
   (ignore or match case). An empty pattern is the last search; :s alone
   repeats the last substitute."
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

(define (set-one-option! arg)
  ":set opt, :set noopt, :set opt=value, :set opt? and :set opt! (toggle)."
  (set-one-option-with! set-option! arg))

(define (set-one-option-with! setter arg)
  "Applies one :set argument `arg`, setting with `setter`.
   `setter` is set-option! or set-local-option!. See set-one-option!
   for the forms `arg` takes."
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

(define (go-to-buffer! id)
  "Makes buffer `id` current, remembering the one left for C-^."
  (unless (= id (current-buffer))
    (when (eq? *mode* 'visual) (leave-visual!))
    (set! *alternate-buffer* (current-buffer))
    (switch-to-buffer! id)
    (normal-clamp!)
    (set! *goal-col* (current-col))
    (run-hooks 'buffer-enter)))

;; What opening a directory does; the file browser (dired.scm) sets it.
(define *open-directory* #f)

(define (open-file! path)
  "Opens `path`, or switches to the buffer that has it, returning its id.
   Returns #f after saying why on the status line. A directory goes to
   the file browser when one is set up."
  (if (and *open-directory* (file-directory? (expand-path path)))
      (*open-directory* (expand-path path))
      (open-file-buffer! path)))

;; Moves out of a popup window before a file opens; special.scm sets it.
(define *leave-popup-window!* (lambda () #f))

(define (open-file-buffer! path)
  "Opens `path` in a buffer and makes it current, recording a jump.
   Returns the buffer id, or #f after saying why on the status line. The
   buffer-open hooks run the first time a buffer is shown."
  (*leave-popup-window!*)
  (let ([r (buffer-open! (expand-path path))])
    (if (string? r)
        (begin (set-status! r) #f)
        (begin
          (record-jump!)
          (let ([new? (not (buffer-seen? r))])
            (go-to-buffer! r)
            (when new? (mark-buffer-seen! r) (run-hooks 'buffer-open)))
          r))))

(define (imp-open-files paths)
  "Called when a daemon client asks for files (imp --connect FILE...)."
  (for-each open-file! paths))

(define *seen-buffers* (hash))
(define (buffer-seen? id)
  "Whether buffer `id` has been shown before."
  (hash-contains? *seen-buffers* id))
(define (mark-buffer-seen! id)
  "Remembers that buffer `id` has been shown."
  (set! *seen-buffers* (hash-insert *seen-buffers* id #t))
  void)

(define (expand-path path)
  "`path` with a leading ~ replaced by the home directory."
  (cond
    [(equal? path "~") (home-dir)]
    [(starts-with? path "~/") (string-append (home-dir) (substring path 1 (string-length path)))]
    [else path]))

(define (abbreviate-path path)
  "`path` with the home directory shown as ~, for display."
  (let ([home (home-dir)])
    (if (and (> (string-length home) 1) (starts-with? path (string-append home "/")))
        (string-append "~" (substring path (string-length home) (string-length path)))
        path)))

(define (buffer-for-path path)
  "The buffer visiting `path`, or #f."
  (let loop ([ids (buffer-list)])
    (cond [(null? ids) #f]
          [(let ([p (cadr (buffer-info (car ids)))]) (and p (equal? (absolute-path p) path))) (car ids)]
          [else (loop (cdr ids))])))

(define (buffer-modified-by-id? id)
  "Whether buffer `id` has unsaved changes."
  (let ([info (buffer-info id)]) (and info (caddr info))))

(define (modified-buffers)
  "The ids of the buffers with unsaved changes."
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
        ;; A buffer that isn't a file says how to re-read it (the file
        ;; browser lists its directory again).
        [(buffer-local 'revert-handler)
         (if (and (buffer-modified?) (not (ex-bang? ex)))
             (set-status! "unsaved changes (add ! to discard them)")
             ((buffer-local 'revert-handler)))]
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
  "The line :ls shows for buffer `id`: number, flags and name, the name
   a path run so a long one is shortened from the start. %a marks the
   current buffer, # the alternate one, + unsaved changes."
  (let ([info (buffer-info id)])
    (list (list (string-append (pad-right (number->string id) 4)
                               (cond [(= id (current-buffer)) "%a "]
                                     [(equal? id *alternate-buffer*) "#  "]
                                     [else "   "])
                               (if (caddr info) "+ " "  ")
                               "\"")
                "")
          (list (car info) "popup.path")
          "\"")))

(define-ex! '("ls" "buffers" "files")
  (lambda (ex) (show-popup! (map buffer-line (buffer-list)))))

(define (find-buffer arg)
  "The buffer :b `arg` means: a number, or any unique part of a name.
   Returns #f if there is none, saying why when a name matched no
   buffer or several."
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

(define (buffer-step step)
  "The buffer `step` places after (or before) the current one, wrapping."
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
        [else (kill-buffer! id)]))))

(define (kill-buffer! id)
  "Closes buffer `id`, unsaved changes and all. If it is current, the
   alternate buffer takes its place, as in Vim."
  (let ([alt *alternate-buffer*])
    (when (and (= id (current-buffer)) alt (not (= alt id)) (memv alt (buffer-list)))
      (go-to-buffer! alt))
    (run-hooks 'buffer-kill id)
    (buffer-kill! id)
    (kill-buffer-locals! id)
    (when (equal? *alternate-buffer* id) (set! *alternate-buffer* #f))
    (set! *jumps* (filter (lambda (j) (not (= (jump-buffer j) id))) *jumps*))
    (set! *jump-index* (length *jumps*))
    (normal-clamp!)))

(define-key! 'normal "C-^"
  (lambda (count)
    (if (and *alternate-buffer* (memv *alternate-buffer* (buffer-list)))
        (go-to-buffer! *alternate-buffer*)
        (set-status! "no alternate file"))))
(define-key! 'normal "C-6" (lookup-key 'normal "C-^"))

(define (write-all!)
  "Writes every modified buffer that has a file. Returns #t if all went."
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
  "Leaves visual mode, if in it, before focus moves to another window."
  (when (eq? *mode* 'visual) (leave-visual!)))

(define (split! vertical?)
  "Splits the current window, focusing the new one.
   `vertical?` splits side by side. The new window goes above or to the
   left unless splitbelow or splitright is set."
  (leave-pending-states!)
  (split-window! (if vertical?
                     (if (option 'splitright) "right" "left")
                     (if (option 'splitbelow) "below" "above")))
  (after-window-change!))

(define (after-window-change!)
  "After focus moves to another window: its buffer may differ, so the
   buffer's options and mode line come back, as on switching buffers."
  (normal-clamp!)
  (set! *goal-col* (current-col))
  (run-hooks 'buffer-enter))

(define (go-to-window! id)
  "Focuses window `id`. Does nothing when `id` is #f."
  (when id
    (leave-pending-states!)
    (unless (= id (current-window))
      (focus-window! id)
      (after-window-change!))))

(define (window-step step)
  "The window `step` places after (or before) the current one, wrapping."
  (let* ([ws (window-list)] [n (length ws)]
         [i (let loop ([l ws] [i 0]) (if (= (car l) (current-window)) i (loop (cdr l) (+ i 1))))])
    (list-ref ws (modulo (+ i step) n))))

(define (close-current-window!)
  "Closes the current window, or says it can't if it is the last one."
  (if (close-window! (current-window))
      (after-window-change!)
      (message "can't close the last window")))

(define (split-ex vertical?)
  ":sp FILE and :vs FILE split and open FILE in the new window."
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
  "Binds C-w followed by each of `keys` to `proc`, in normal and visual."
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

(define (lines-text first last)
  "The text of lines `first` through `last`, each with its line break."
  (let ([r (lines-range first last)])
    (let ([text (buffer-substring (car r) (cadr r))])
      (if (ends-with? text "\n") text (string-append text "\n")))))

(define (delete-lines! first last)
  "Deletes lines `first` through `last`, keeping the final newline."
  (let ([r (lines-range first last)])
    (if (and (= (cadr r) (buffer-length)) (> (car r) 0))
        (buffer-delete! (- (car r) 1) (without-final-break (car r) (cadr r)))
        (buffer-delete! (car r) (cadr r)))))

(define (insert-lines-after! line text)
  "Inserts whole lines (text ending in a line break) after line `line`, or
   before the first line if `line` is -1."
  (cond
    [(< line 0) (buffer-insert! 0 text)]
    [(< line (last-line)) (buffer-insert! (line-start (+ line 1)) text)]
    [(and (> (buffer-length) 0) (not (equal? (buffer-substring (- (buffer-length) 1) (buffer-length)) "\n")))
     (buffer-insert! (buffer-length) (string-append "\n" (without-final-newline text)))]
    [else (buffer-insert! (buffer-length) text)]))

(define (address-arg text)
  "The line an address argument names (as for :m and :t), 0 meaning
   \"before the first line\" and so -1 here."
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

(define (ex-shift dir)
  ":> and :< shift once per > or < (:>> twice)."
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

(define (pad-spaces text width)
  "`text` with spaces before it to make `width` chars."
  (string-append (make-string (max 0 (- width (string-length text))) #\space) text))

(define (seconds-ago n)
  "`n` seconds as :undolist says how long ago: \"5 seconds ago\"."
  (cond [(< n 100) (string-append (number->string n) " seconds ago")]
        [(< n 6000) (string-append (number->string (quotient n 60)) " minutes ago")]
        [else (string-append (number->string (quotient n 3600)) " hours ago")]))

(define-ex! '("undol" "undolist")
  (lambda (ex)
    (let ([tips (undo-list)])
      (if (null? tips)
          (message "Nothing to undo")
          (show-popup!
           (cons "number changes  when"
                 (map (lambda (t)
                        (string-append (pad-spaces (number->string (car t)) 6)
                                       (pad-spaces (number->string (cadr t)) 8)
                                       "  " (seconds-ago (caddr t))))
                      tips)))))))

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
  "`text` split into lines, without a trailing empty one."
  ;; split-many is native: a char-by-char loop here was most of the time
  ;; M-x spent reading doc comments.
  (let ([lines (split-many text "\n")])
    (if (equal? (last lines) "") (reverse (cdr (reverse lines))) lines)))

(define-ex! '("k" "ma" "mark")
  (lambda (ex)
    (let ([arg (ex-args ex)])
      (if (equal? arg "")
          (set-status! "mark needs a name")
          (set-mark-char! (string-ref arg 0) (line-start (cadr (ex-range ex))))))))

;; :p and :nu show lines in a popup; :g with no command collects them.
(define *print-lines* #f)

(define (print-lines! ex numbered?)
  "Shows the lines of `ex`'s range in a popup, for :p and :nu.
   `numbered?` puts line numbers in front. Under :g the lines are
   collected instead, to show all at once."
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
  "The first run of digits in `text` as a number, or #f if it has none."
  (let loop ([cs (string->list text)] [digits '()])
    (cond
      [(and (null? cs) (null? digits)) #f]
      [(and (pair? cs) (char-numeric-ascii? (car cs))) (loop (cdr cs) (cons (car cs) digits))]
      [(null? digits) (loop (cdr cs) '())]
      [else (string->number (list->string (reverse digits)))])))

(define (dedupe lines same?)
  "`lines` with runs of neighbours that are `same?` reduced to one."
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
  "Plays `keys` as if typed in normal mode, for :normal.
   Afterwards finishes what they left half done: leaves insert,
   command-line or visual mode and forgets pending keys."
  (play-keys! keys)
  ;; Finish whatever the keys left half done, as Vim does.
  (when (typing-mode?) (process-key! "<esc>"))
  (when (eq? *mode* 'cmdline) (process-key! "<esc>"))
  (when (eq? *mode* 'visual) (leave-visual!))
  (reset-pending!)
  (set! *command-failed* #f)
  void)

(define (for-each-line-mark first last thunk)
  "Runs `thunk` with the cursor at the start of lines `first` to `last`.
   Lines are marked first, so the thunk may add or delete lines."
  (for-each-marked-line (range first (+ last 1)) thunk))

(define (for-each-marked-line lines thunk)
  "Runs `thunk` with the cursor at the start of each of `lines`.
   The lines are marked first, so `thunk` may add or delete lines; a
   line already deleted is skipped."
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

(define (global-command invert?)
  ":g/pattern/command runs command on every line matching pattern (:g! and
   :v on the others). The default command is :p. Without a range, the
   whole file."
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
  "Whether `pattern` matches somewhere on `line`."
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

(define (show-result! value)
  "Shows `value` on the status line, or in a popup if it is long."
  (let ([text (if (string? value) value (to-string value))])
    (if (or (string-contains? text "\n") (> (string-length text) 100))
        (show-popup! (split-lines text))
        (message text))))

(define (eval-and-show! text)
  "Evaluates `text`, showing the value or the error. No value shows
   nothing, so a message the code showed stays."
  (let ([v (with-handler (lambda (e) (string-append "error: " (error-message e)))
                         (imp-eval-string text))])
    (unless (eq? v void) (show-result! v))))


(define-ex! '("so" "source")
  (lambda (ex)
    (let ([path (expand-path (if (equal? (ex-args ex) "") (or (buffer-path) "") (ex-args ex)))])
      (show-result!
       (with-handler (lambda (e) (string-append "error: " (error-message e)))
                     (begin (imp-load-file path) (string-append "sourced " path)))))))

(define-ex! '("mes" "messages")
  (lambda (ex) (show-popup! (if (null? *messages*) (list "no messages") (reverse *messages*)))))

(define (delimiter? c)
  "Whether `c` ends a symbol: white space, brackets, quotes, ; or ,.
   #f (past the buffer's end) counts too."
  (or (not c) (char-whitespace? c) (memv c (string->list "()[]\"';`,"))))

(define (form-at p)
  "The form at the cursor, as (start end): the list whose ( or ) the cursor
   is on, the symbol or number under it, or else the innermost list around
   it."
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

(define (top-level-form-at p)
  "The top-level form around the cursor: the outermost list containing it."
  (let loop ([o (if (equal? (buffer-char-at p) #\() p (find-open #\( #\) p 1))])
    (and o
         (let ([outer (and (> o 0) (find-open #\( #\) (- o 1) 1))])
           (if outer (loop outer) (form-at o))))))

(define (eval-range-command range-of)
  "A command that evaluates the text `range-of` finds at the cursor.
   `range-of` takes the cursor and returns (start end), or #f, in which
   case it says there is no form."
  (lambda (count)
    (let ([r (range-of (cursor))])
      (if r
          (eval-and-show! (buffer-substring (car r) (cadr r)))
          (message "no form at the cursor")))))

;; Evaluate the form at the cursor (Emacs's C-x C-e).
(define-command! 'eval-last-sexp (eval-range-command form-at))
;; Evaluate the top-level form around the cursor (C-M-x).
(define-command! 'eval-defun (eval-range-command top-level-form-at))
(define-command! 'eval-buffer
  (lambda (count)
    "Evaluate the whole buffer."
    (eval-and-show! (buffer-substring 0 (buffer-length)))))
(define-command! 'eval-region
  (lambda (count)
    "Evaluate the visual selection."
    (if (eq? *mode* 'visual)
        (let ([r (visual-range)])
          (leave-visual!)
          (eval-and-show! (buffer-substring (car r) (cadr r))))
        (run-command 'eval-last-sexp))))
(define-command! 'eval-expression
  (lambda (count)
    "Prompt for an expression and evaluate it (M-:)."
    (open-cmdline! "Eval: " "" eval-and-show! #f #f)))
(define-command! 'eval
  (lambda (count)
    "Evaluate a Scheme expression, asked for: :eval (+ 1 2) runs it at once."
    (open-cmdline! "Eval: " "" eval-and-show! #f #f)))

;;; Entry points

(define (imp-init)
  "Starts the editor in normal mode and runs the startup hooks."
  (set-mode! 'normal)
  (normal-clamp!)
  (run-hooks 'startup))

(define *last-version* #f)  ; buffer and version after the last key

(define (imp-handle-key key)
  "Handles one key from the user: Rust calls this for every key.
   Records it while a macro is being recorded, then runs the
   after-change hooks if it changed the buffer and the post-command
   hooks always."
  (when (and *recording* (not (stops-recording? key)))
    (set! *recorded-keys* (cons key *recorded-keys*)))
  (handle-top-level-key! key)
  (after-input!))

(define (after-input!)
  "Runs the hooks that follow a key or a paste: after-change if it
   changed the current buffer, then post-command always."
  (let ([now (cons (current-buffer) (buffer-version))])
    (when (and *last-version* (= (car now) (car *last-version*)) (not (= (cdr now) (cdr *last-version*))))
      (run-hooks 'after-change))
    (set! *last-version* now))
  (run-hooks 'post-command))

(define (after-change-range)
  "In an after-change hook, what the key changed as one (start old-end
   new-end): old-end where the changed text ended before, new-end where
   it ends now, as Emacs's after-change-functions get. #f when that
   isn't known (an undo, redo or reload) or outside the hook."
  (let ([changes (and *last-version* (equal? (car *last-version*) (current-buffer))
                      (buffer-changes-since (cdr *last-version*)))])
    (and (pair? changes) (merge-changes changes))))

(define (merge-changes changes)
  "One (start old-end new-end) covering `changes`, edits made one after
   another as buffer-changes-since lists them."
  (let loop ([cs (cdr changes)]
             [start (car (car changes))] [old-end (cadr (car changes))] [new-end (caddr (car changes))])
    (if (null? cs)
        (list start old-end new-end)
        (let* ([c (car cs)] [s (car c)] [oe (cadr c)] [ne (caddr c)]
               ;; How much longer the range so far made the text.
               [grown (- new-end old-end)])
          (loop (cdr cs)
                (min start s)
                ;; An end past the range so far, in the text before it.
                (max old-end (- oe grown))
                (+ (max new-end oe) (- ne oe)))))))

;; Sees a paste first, as its text; #t from it means handled. term.scm
;; sets it to give pastes to the program in the terminal state.
(define *paste-handler* #f)

(define (imp-handle-paste text)
  "Handles text pasted whole (the terminal client's bracketed paste).
   Insert and Emacs state insert it as it is, with no autoindent; normal
   and visual state insert it at the cursor as one change; the command
   line types it, line breaks as spaces; anywhere else it is typed key
   by key. An empty paste (the window client's, when the clipboard gave
   nothing) only says so."
  (let ([chars (map string (string->list text))])
    (cond
      [(equal? text "") (message "Nothing to paste")]
      [(and *paste-handler* (*paste-handler* text)) #t]
      [(member *mode* '(insert replace emacs))
       (insert-text! text)
       (when (typing-mode?)
         ;; Marked, so `.` types it again without pairing its brackets.
         (set! *insert-keys* (append (list "<paste-end>")
                                     (reverse (map (lambda (c) (if (equal? c "\n") "<ret>" c)) chars))
                                     (list "<paste-start>")
                                     *insert-keys*)))]
      [(member *mode* '(normal visual))
       (when (eq? *mode* 'visual) (leave-visual!))
       (begin-change!)
       (insert-text! text)
       (set-cursor! (max 0 (- (cursor) 1)))
       (normal-clamp!)]
      [(eq? *mode* 'cmdline)
       (for-each (lambda (c) (process-key! (if (equal? c "\n") " " c))) chars)]
      [else (for-each process-key! chars)]))
  (after-input!))

(define (handle-top-level-key! key)
  "Handles a key, closing the popup first if one is up.
   The key that closes a popup also runs, unless it is <ret>, <esc>,
   space or C-c, as at Vim's \"Press ENTER\" prompt."
  (if *popup-shown*
      ;; Any key closes a popup; <ret>, <esc> and space only do that, other
      ;; keys also run, as at Vim's "Press ENTER" prompt.
      (begin
        (close-popup!)
        (unless (member key '("<ret>" "<esc>" " " "C-c")) (process-key! key)))
      (process-key! key)))

(define (stops-recording? key)
  "q stops recording, when it isn't part of a longer command."
  (and *recording* (equal? key "q") (member *mode* '(normal visual))
       (not *operator*) (not *prefix*) (equal? *count* "")))

(define (process-key! key)
  "Handles one key without recording it; macros play keys through here."
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

;; A mode's key sequence that starts with a control or meta key, as
;; Emacs's C-c C-c, in normal, visual or insert state, or with a letter
;; that isn't a Vim prefix, as the agenda's ct, in normal or visual
;; state: the keys so far.
(define *local-prefix* #f)

(define (local-prefix-state)
  "The state whose keymaps a mode's key sequence is looked up in.
   It is 'insert while typing, 'visual in visual mode, else 'normal."
  (cond [(typing-mode?) 'insert] [(eq? *mode* 'visual) 'visual] [else 'normal]))

(define (local-prefix? state keys)
  "Whether `keys` begin a longer binding in the buffer's modes: keys
   starting with a control or meta key, as C-c C-c, or, outside insert
   state, a letter that isn't one of Vim's prefixes, as the agenda's ct
   (g and z keys go through Vim's prefixes)."
  (let* ([control? (or (starts-with? keys "C-") (starts-with? keys "M-"))]
         [letter? (and (not control?) (not (eq? state 'insert)) (= (string-length keys) 1)
                       (let ([c (char->integer (string-ref keys 0))])
                         (or (<= 65 c 90) (<= 97 c 122)))
                       (not (hash-contains? *prefix-keys* keys)))]
         ;; A longer binding, its next key not part of this one's name:
         ;; C-c C-c doesn't start with the key C.
         [longer? (lambda (k) (and (> (string-length k) (string-length keys)) (starts-with? k keys)
                                   (or control? (not (equal? (string-ref k (string-length keys)) #\-)))))])
    (and (or control? letter?)
         (let loop ([maps (*local-keymaps* state)])
           (cond [(null? maps) #f]
                 [(pair? (filter longer? (hash-keys->list (keymap (car maps))))) #t]
                 [else (loop (cdr maps))])))))

(define (run-local-binding! state proc)
  "Runs a mode's binding for a whole sequence: insert state's take no
   count, as in insert-key!."
  (if (eq? state 'insert) (proc) (proc 1)))

(define (local-prefix-key! key)
  "Handles `key` after the start of a mode's key sequence (C-c C-c).
   Runs the binding if the keys so far make one, waits for more if they
   begin a longer one, and otherwise says they are undefined."
  (let* ([state (local-prefix-state)] [keys (string-append *local-prefix* key)])
    (set! *local-prefix* #f)
    (cond [(member key '("<esc>" "C-g")) (message "")]
          [(local-key-proc state keys) => (lambda (proc) (message "") (run-local-binding! state proc))]
          [(local-prefix? state keys) (set! *local-prefix* keys) (set-status! (string-append keys "-"))]
          [else (message (string-append keys " is undefined"))])))

(define (handle-key! key)
  "Sends `key` to whatever handles it in the current mode.
   A mode's control or meta key sequence comes first, then extra
   states, insert, the command line, and normal or visual mode."
  (cond
    [*local-prefix* (local-prefix-key! key)]
    [(and (memq *mode* '(normal visual insert replace))
          (not *operator*) (not *prefix*) (equal? *count* "")
          (not (local-key-proc (local-prefix-state) key))
          (local-prefix? (local-prefix-state) key))
     (set! *local-prefix* key)
     (set-status! (string-append key "-"))]
    [(hash-try-get *extra-states* *mode*) => (lambda (s) ((caddr s) key))]
    [(typing-mode?) (insert-mode-key! key)]
    [(eq? *mode* 'cmdline) (cmdline-key! key)]
    [else
     ;; A fresh command clears the last message.
     (when (and (not *operator*) (not *prefix*) (equal? *count* ""))
       (set-status! ""))
     (normal-key! key)]))

;;; Which-key labels for the keys after Vim's prefixes. Binding a key again
;;; without a label forgets its label here; tests/leader.rs fails on a
;;; built-in key after a prefix without one.

(for-each
 (lambda (e) (set-binding-label! 'motion (car e) (cadr e)))
 '(("gg" "first line") ("ge" "end of previous word") ("gE" "end of previous WORD")
   ("gj" "down a screen line") ("gk" "up a screen line")
   ("g*" "search word, partial") ("g#" "search word back, partial")))

(for-each
 (lambda (e) (set-binding-label! 'operator (car e) (cadr e)))
 '(("gu" "lowercase") ("gU" "uppercase") ("g~" "toggle case") ("g?" "rot13")
   ("zf" "create fold")))

(for-each
 (lambda (e) (for-each (lambda (state) (set-binding-label! state (car e) (cadr e))) (caddr e)))
 '(("gI" "insert at column 0" (normal))
   ("gi" "insert at last insert" (normal))
   ("gp" "paste after, cursor after" (normal))
   ("gP" "paste before, cursor after" (normal))
   ("gv" "reselect last selection" (normal))
   ("g-" "older undo state" (normal))
   ("g+" "newer undo state" (normal))
   ("gJ" "join without spaces" (normal visual))
   ("ZZ" "save and quit" (normal))
   ("ZQ" "quit without saving" (normal))
   ("zt" "line to top" (normal visual))
   ("zz" "line to middle" (normal visual))
   ("zb" "line to bottom" (normal visual))
   ("z<ret>" "top, first non-blank" (normal visual))
   ("z." "middle, first non-blank" (normal visual))
   ("z-" "bottom, first non-blank" (normal visual))
   ("zF" "fold lines" (normal))
   ("zo" "open fold" (normal visual))
   ("zO" "open folds under cursor" (normal visual))
   ("zc" "close fold" (normal visual))
   ("zC" "close folds under cursor" (normal visual))
   ("za" "toggle fold" (normal visual))
   ("zA" "toggle folds under cursor" (normal visual))
   ("zR" "open all folds" (normal visual))
   ("zM" "close all folds" (normal visual))
   ("zE" "delete all folds" (normal visual))
   ("zd" "delete fold" (normal visual))
   ("zD" "delete folds under cursor" (normal visual))
   ("zj" "start of next fold" (normal))
   ("zk" "end of previous fold" (normal))))

(for-each
 (lambda (e)
   (for-each (lambda (key)
               (for-each (lambda (state) (set-binding-label! state (string-append "C-w" key) (cadr e)))
                         '(normal visual)))
             (car e)))
 '((("s" "S" "C-s") "split") (("v" "C-v") "split vertically") (("n" "C-n") "new window")
   (("w" "C-w") "next window") (("W") "previous window")
   (("h" "C-h" "<left>") "window left") (("l" "C-l" "<right>") "window right")
   (("k" "C-k" "<up>") "window above") (("j" "C-j" "<down>") "window below")
   (("c" "C-c" "q" "C-q") "close window") (("o" "C-o") "close other windows")
   (("=") "equal sizes") (("+") "taller") (("-") "shorter") ((">") "wider") (("<") "narrower")))
