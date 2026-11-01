;;; emacs.scm -- Emacs ("holy") bindings, a supported alternative to Vim's.
;;;
;;; An `emacs` state sits beside normal, insert and visual. In it, keys
;;; insert text and the usual Emacs keys edit, with Emacs's mark and region,
;;; kill ring, universal argument and incremental search. C-z toggles
;;; between Vim and Emacs state, as in Evil; set editing-style to "emacs"
;;; in init.scm to start in it:
;;;
;;;   (set-option! 'editing-style "emacs")
;;;
;;; Bindings live in the 'emacs keymap, written as Emacs writes them, keys
;;; separated by spaces: (define-key! 'emacs "C-x C-s" 'save-buffer).
;;; Major modes can add their own with (define-mode-key! mode 'emacs ...).

;; The state imp starts in: "vim" (normal state) or "emacs". Set it in
;; init.scm.
(define-option! 'editing-style "vim" '())

(define *emacs-prefix* "")      ; keys of an unfinished sequence ("C-x")
(define *emacs-arg* #f)         ; the universal argument, if any
(define *emacs-arg-digits* #f)  ; digits typed after C-u
(define *mark* #f)              ; mark name when the region is active
(define *kill-ring* '())
(define *kill-ring-index* 0)    ; where M-y is in the kill ring
(define *last-yank* #f)         ; (start end) of the text the last C-y put
(define *this-command* #f)
(define *last-command* #f)      ; so kills join up and M-y follows C-y

(define (emacs-key-binding keys)
  "What `keys` are bound to in the emacs keymap, or #f."
  (key-binding 'emacs keys))

(define (emacs-prefix? keys)
  "Whether `keys` starts a longer binding, as \"C-x\" does."
  (let ([prefix (string-append keys " ")])
    (let loop ([maps (append (*local-keymaps* 'emacs) (list 'emacs))])
      (and (pair? maps)
           (or (let any ([ks (hash-keys->list (keymap (car maps)))])
                 (and (pair? ks) (or (starts-with? (car ks) prefix) (any (cdr ks)))))
               (loop (cdr maps)))))))

(define (emacs-count)
  "The universal argument for the next command, or 1 without one."
  (or *emacs-arg* 1))

(define (emacs-key! key)
  "Handle `key` in Emacs state: the state's key handler.
   C-u, C-u digits and M-digit set the universal argument; C-g quits;
   a bound sequence runs; a prefix such as C-x waits for more keys and
   shows which-key; a printable key inserts itself."
  (let ([keys (if (equal? *emacs-prefix* "") key (string-append *emacs-prefix* " " key))])
    (cond
      ;; C-u: 4, 16, ... or the digits typed after it.
      [(and (equal? *emacs-prefix* "") (equal? key "C-u"))
       (set! *emacs-arg* (* 4 (or *emacs-arg* 1)))
       (set! *emacs-arg-digits* #f)
       (set-status! (string-append "C-u " (number->string *emacs-arg*)))]
      [(and *emacs-arg* (equal? *emacs-prefix* "") (digit? key))
       (set! *emacs-arg-digits* (string-append (or *emacs-arg-digits* "") key))
       (set! *emacs-arg* (string->number *emacs-arg-digits*))
       (set-status! (string-append "C-u " *emacs-arg-digits*))]
      [(and (equal? *emacs-prefix* "") (= (string-length key) 3) (starts-with? key "M-")
            (digit? (substring key 2 3)))
       (set! *emacs-arg* (string->number (substring key 2 3)))]
      [(member key '("C-g"))
       (keyboard-quit!)]
      [(emacs-key-binding keys)
       => (lambda (binding)
            (set! *emacs-prefix* "")
            (overlay-close! 'emacs-prefix)
            (run-emacs-command! binding))]
      [(emacs-prefix? keys)
       (set! *emacs-prefix* keys)
       (set-status! (string-append keys "-"))
       ;; No 'keys: emacs-key! reads the rest of the sequence itself.
       (if (<= (option 'which-key-delay) 0)
           (overlay-open! 'emacs-prefix (emacs-which-key keys) 'title keys)
           (run-after! (option 'which-key-delay)
                       (lambda ()
                         (when (equal? *emacs-prefix* keys)
                           (overlay-open! 'emacs-prefix (emacs-which-key keys) 'title keys)))))]
      [(and (equal? *emacs-prefix* "") (key-char key) (not (equal? key "<ret>")))
       (run-emacs-command! (lambda (n) (self-insert! key n)))]
      [else
       (set! *emacs-prefix* "")
       (overlay-close! 'emacs-prefix)
       (set! *emacs-arg* #f)
       (message (string-append keys " is undefined"))]))
  void)

(define (run-emacs-command! binding)
  "Run `binding`, a command name or a procedure, with the argument.
   Clears the universal argument and records the command as the last
   one, so kills join up and M-y can follow C-y."
  (let ([proc (if (symbol? binding) (command-proc binding) binding)]
        [count (emacs-count)])
    (set! *this-command* binding)
    (set! *emacs-arg* #f)
    (set! *emacs-arg-digits* #f)
    (if proc
        (with-pairs-tracked (lambda () (proc count)))
        (message (string-append "no command " (symbol->string binding))))
    (set! *last-command* *this-command*))
  void)

(define (emacs-which-key prefix)
  "The bindings after `prefix`, for the popup."
  (let* ([start (string-append prefix " ")]
         [keys (filter (lambda (k) (starts-with? k start)) (hash-keys->list (keymap 'emacs)))])
    (which-key-table
     (map (lambda (k)
            (let ([b (hash-ref (keymap 'emacs) k)])
              (cons (substring k (string-length start) (string-length k))
                    (if (symbol? b) (symbol->string b) "command"))))
          (sort keys string<?)))))

(define (keyboard-quit!)
  "Cancel a pending key sequence, the argument and the region (C-g)."
  (set! *emacs-prefix* "")
  (set! *emacs-arg* #f)
  (overlay-close! 'emacs-prefix)
  (deactivate-mark!)
  (message "Quit"))

;;; Inserting text

(define (self-insert! key n)
  "Inserts `key` `n` times at the cursor (<tab> as a tab).
   Typing goes into one undo step until another command runs, roughly as
   Emacs groups self-inserts. Brackets and quotes pair, and with the
   region active wrap it."
  (unless (eq? *last-command* 'self-insert) (begin-change!))
  (set! *this-command* 'self-insert)
  (let ([r (region)] [c (and (= (string-length key) 1) (string-ref key 0))])
    (deactivate-mark!)
    ;; Pairs as insert mode makes them (docs/specs/auto-pairs.md).
    (cond
      [(and r c (pair-partner c))
       => (lambda (closer)
            ;; Wrapping the region is a step of its own.
            (begin-change!)
            (set! *this-command* 'wrap-region)
            (wrap-region! (car r) (cadr r) key closer))]
      [(and c (= n 1) (pair-closing-at-cursor c)) (set-cursor! (+ (cursor) 1))]
      [(and c (= n 1) (pair-closer c)) => (lambda (closer) (insert-pair! key closer))]
      [(and c (= n 1)) (insert-typed-char! key)]
      [else (insert-text! (string-repeat (if (equal? key "<tab>") "\t" key) n))]))
  void)

(define (emacs-edit! thunk)
  "Call `thunk` as one undo step, dropping the region first."
  (begin-change!)
  (deactivate-mark!)
  (thunk))

;;; The mark and the region

(define (set-mark!)
  "Set the mark at the cursor and make the region active."
  (mark-set! "emacs-mark" (cursor))
  (set! *mark* #t)
  (message "Mark set"))

(define (deactivate-mark!)
  "Make the region inactive; the mark itself stays where it is."
  (set! *mark* #f)
  void)

(define (region)
  "The active region as (start end), or #f."
  (and *mark* (let ([m (mark-get "emacs-mark")]) (and m (list (min m (cursor)) (max m (cursor)))))))

(define (show-region!)
  "Highlight the active region in Emacs state, after each command."
  (when (eq? *mode* 'emacs)
    (highlight-clear! "visual")
    (let ([r (region)])
      (when (and r (< (car r) (cadr r)))
        (highlight-add! "visual" (car r) (cadr r) "visual")))))

(add-hook! 'post-command show-region!)

;;; The kill ring. Kills also go to the unnamed register, so Vim's p sees
;;; them; consecutive kills join into one entry, as in Emacs.

(define (kill-text! text forward?)
  "Push `text` onto the kill ring and into the unnamed register.
   Right after another kill it joins the last entry instead: appended
   when `forward?`, prepended otherwise. The ring keeps 60 entries."
  (if (and (memq *last-command* '(kill-line kill-word backward-kill-word kill-region))
           (pair? *kill-ring*))
      (set! *kill-ring* (cons (if forward? (string-append (car *kill-ring*) text)
                                  (string-append text (car *kill-ring*)))
                              (cdr *kill-ring*)))
      (set! *kill-ring* (cons text (take *kill-ring* (min 59 (length *kill-ring*))))))
  (set! *kill-ring-index* 0)
  (register-set! #\" (car *kill-ring*) #f 'delete))

(define (kill-range! start end forward? name)
  "Kill the text from `start` to `end` as the command `name`.
   `forward?` says which way it joins a kill just before it. The region
   is dropped either way."
  (when (< start end)
    (set! *this-command* name)
    (begin-change!)
    (kill-text! (buffer-substring start end) forward?)
    (buffer-delete! start end)
    (set-cursor! start))
  (deactivate-mark!))

(define (yank! count)
  "Insert the `count`th most recent kill at the cursor (C-y).
   With an empty kill ring, the unnamed register's text. Sets the mark
   at the start, so the yanked text is the region, and remembers where
   it went for M-y."
  (let ([text (if (pair? *kill-ring*)
                  (list-ref *kill-ring* (min (- count 1) (- (length *kill-ring*) 1)))
                  (let ([r (register-get #\")]) (and r (car r))))])
    (if (not text)
        (message "Kill ring is empty")
        (begin
          (begin-change!)
          (mark-set! "emacs-mark" (cursor))
          (let ([start (cursor)])
            (insert-text! text)
            (set! *last-yank* (list start (cursor))))
          (set! *this-command* 'yank))))
  void)

(define (yank-pop! count)
  "M-y right after C-y: replace what was yanked with the previous kill."
  (if (not (and (memq *last-command* '(yank yank-pop)) *last-yank* (pair? *kill-ring*)))
      (message "Previous command was not a yank")
      (begin
        (set! *kill-ring-index* (modulo (+ *kill-ring-index* count) (length *kill-ring*)))
        (let ([start (car *last-yank*)] [text (list-ref *kill-ring* *kill-ring-index*)])
          (buffer-delete! start (cadr *last-yank*))
          (set-cursor! start)
          (insert-text! text)
          (set! *last-yank* (list start (cursor))))
        (set! *this-command* 'yank-pop)))
  void)

;;; Moving

(define (forward-word p)
  "The end of the word after `p`, Emacs-style.
   Emacs words are runs of word chars; punctuation and space are skipped."
  (let* ([len (buffer-length)]
         [p (let loop ([q p]) (if (and (< q len) (not (char-word? (buffer-char-at q)))) (loop (+ q 1)) q))])
    (let loop ([q p]) (if (and (< q len) (char-word? (buffer-char-at q))) (loop (+ q 1)) q))))

(define (backward-word p)
  "The start of the word before `p`, Emacs-style."
  (let* ([p (let loop ([q p]) (if (and (> q 0) (not (char-word? (buffer-char-at (- q 1))))) (loop (- q 1)) q))])
    (let loop ([q p]) (if (and (> q 0) (char-word? (buffer-char-at (- q 1)))) (loop (- q 1)) q))))

(define (repeat-move n step)
  "A command that moves the cursor by `step`, `n` times its count."
  (lambda (count) (set-cursor! (repeat-motion (* n count) step (cursor)))))

(define (emacs-vertical! n)
  "Move `n` lines down (up when negative), keeping the goal column."
  (let ([col (if (memq *last-command* '(next-line previous-line)) *goal-col* (current-col))])
    (set! *goal-col* col)
    (set-cursor! (line-col->offset (clamp (+ (current-line) n) 0 (last-line)) col))))

(define (commands! specs)
  "Define a command for each (name proc) in `specs`."
  (for-each (lambda (spec) (define-command! (car spec) (cadr spec))) specs))

(commands!
 (list
  (list 'forward-char (lambda (n) (set-cursor! (min (buffer-length) (+ (cursor) n)))))
  (list 'backward-char (lambda (n) (set-cursor! (max 0 (- (cursor) n)))))
  (list 'next-line (lambda (n) (emacs-vertical! n)))
  (list 'previous-line (lambda (n) (emacs-vertical! (- n))))
  (list 'move-beginning-of-line (lambda (n) (set-cursor! (line-start (current-line)))))
  (list 'move-end-of-line (lambda (n) (set-cursor! (line-end (current-line)))))
  (list 'back-to-indentation (lambda (n) (set-cursor! (line-first-nonblank (current-line)))))
  (list 'forward-word (repeat-move 1 forward-word))
  (list 'backward-word (repeat-move 1 backward-word))
  (list 'beginning-of-buffer (lambda (n) (record-jump!) (mark-set! "emacs-mark" (cursor)) (set-cursor! 0)))
  (list 'end-of-buffer (lambda (n) (record-jump!) (mark-set! "emacs-mark" (cursor)) (set-cursor! (buffer-length))))
  (list 'scroll-up-command (lambda (n) ((page-scroll! 1) 1)))
  (list 'scroll-down-command (lambda (n) ((page-scroll! -1) 1)))
  (list 'recenter (lambda (n) ((lookup-key 'normal "zz") 1)))
  (list 'goto-line
        (lambda (n)
          (open-cmdline! "Goto line: " ""
                         (lambda (text)
                           (let ([l (string->number text)])
                             (when l (record-jump!) (set-cursor! (line-start (clamp (- l 1) 0 (last-line)))))))
                         #f #f)))))

;;; Editing

(define (transpose-chars!)
  "Swap the chars around the cursor and move past them.
   At the end of a line, the two chars before the cursor."
  (let* ([p (cursor)]
         [p (if (and (= p (line-end (current-line))) (> p (line-start (current-line)))) (- p 1) p)])
    (when (> p 0)
      (let ([a (buffer-substring (- p 1) p)] [b (buffer-substring p (+ p 1))])
        (replace-range! (- p 1) (+ p 1) (string-append b a))
        (set-cursor! (+ p 1))))))

(define (case-word! f)
  "A command that replaces `count` words from the cursor with `f` of
   them, leaving the cursor after them."
  (lambda (n)
    (emacs-edit!
     (lambda ()
       (let* ([start (cursor)] [end (repeat-motion n forward-word start)])
         (replace-range! start end (f (buffer-substring start end)))
         (set-cursor! end))))))

(define (capitalize text)
  "`text` with each word's first char upper-cased and the rest lower."
  (let loop ([cs (string->list text)] [start? #t] [acc '()])
    (cond [(null? cs) (list->string (reverse acc))]
          [(char-word? (car cs))
           (loop (cdr cs) #f (cons (if start? (char-upcase (car cs)) (char-downcase (car cs))) acc))]
          [else (loop (cdr cs) #t (cons (car cs) acc))])))

(commands!
 (list
  (list 'delete-char
        (lambda (n) (emacs-edit! (lambda () (buffer-delete! (cursor) (min (buffer-length) (+ (cursor) n)))))))
  (list 'delete-backward-char
        (lambda (n)
          (let ([r (region)])
            (cond
              [r (kill-range! (car r) (cadr r) #t 'kill-region)]
              [(and (= n 1) (empty-pair-around-cursor)) (emacs-edit! delete-empty-pair!)]
              [else (emacs-edit! (lambda () (let ([p (max 0 (- (cursor) n))]) (buffer-delete! p (cursor)) (set-cursor! p))))]))))
  (list 'newline (lambda (n) (emacs-edit! (lambda () (let loop ([i 0]) (when (< i n) (insert-newline!) (loop (+ i 1))))))))
  (list 'open-line (lambda (n) (emacs-edit! (lambda () (let ([p (cursor)]) (buffer-insert! p (make-string n #\newline)) (set-cursor! p))))))
  (list 'transpose-chars (lambda (n) (emacs-edit! transpose-chars!)))
  (list 'upcase-word (case-word! string-upcase))
  (list 'downcase-word (case-word! string-downcase))
  (list 'capitalize-word (case-word! capitalize))
  (list 'kill-line
        (lambda (n)
          (let* ([p (cursor)] [end (line-end (current-line))]
                 ;; At the end of a line, kill the line break; with a count,
                 ;; that many whole lines.
                 [stop (cond [(> n 1) (min (buffer-length) (line-start (min (last-line) (+ (current-line) n))))]
                             [(= p end) (min (buffer-length) (+ p 1))]
                             [else end])])
            (kill-range! p stop #t 'kill-line))))
  (list 'kill-word (lambda (n) (kill-range! (cursor) (repeat-motion n forward-word (cursor)) #t 'kill-word)))
  (list 'backward-kill-word
        (lambda (n) (let ([start (repeat-motion n backward-word (cursor))]) (kill-range! start (cursor) #f 'backward-kill-word))))
  (list 'kill-region
        (lambda (n) (let ([r (region)]) (if r (kill-range! (car r) (cadr r) #t 'kill-region) (message "The mark is not active")))))
  (list 'kill-ring-save
        (lambda (n)
          (let ([r (region)])
            (if r
                (begin (kill-text! (buffer-substring (car r) (cadr r)) #t) (deactivate-mark!) (message "Copied"))
                (message "The mark is not active")))))
  (list 'yank yank!)
  (list 'yank-pop yank-pop!)
  (list 'set-mark-command (lambda (n) (set-mark!)))
  (list 'mark-whole-buffer (lambda (n) (set-cursor! 0) (mark-set! "emacs-mark" (buffer-length)) (set! *mark* #t)))
  (list 'exchange-point-and-mark
        (lambda (n) (let ([m (mark-get "emacs-mark")])
                      (when m (mark-set! "emacs-mark" (cursor)) (set-cursor! m) (set! *mark* #t)))))
  (list 'emacs-undo (lambda (n) (deactivate-mark!) ((lookup-key 'normal "u") n)))
  (list 'emacs-redo (lambda (n) ((lookup-key 'normal "C-r") n)))
  (list 'comment-dwim
        (lambda (n)
          (let ([r (region)])
            (begin-change!)
            (if r
                (comment-lines! (offset->line (car r)) (offset->line (max (car r) (- (cadr r) 1))))
                (comment-lines! (current-line) (current-line)))
            (deactivate-mark!))))
  (list 'write-file
        (lambda (n) (open-cmdline! "Write file: " "" (lambda (f) (run-ex! (string-append "w " f))) #f #f)))
  (list 'save-some-buffers (lambda (n) (run-ex! "wa")))
  (list 'save-buffers-kill-emacs (lambda (n) (run-ex! "qa")))
  (list 'emacs-eval-last-sexp
        ;; Point is between chars in Emacs: the form ends just before it.
        (lambda (n)
          (let ([r (form-at (max 0 (- (cursor) 1)))])
            (if r (eval-and-show! (buffer-substring (car r) (cadr r))) (message "no form before point")))))))

;; What the commands above do, for M-x and describe-function: they have no
;; definition line of their own for a comment to sit above.
(for-each
 (lambda (d) (document-command! (car d) (cadr d)))
 '((forward-char "Move forward a char.")
   (backward-char "Move back a char.")
   (next-line "Move down a line, keeping the column.")
   (previous-line "Move up a line, keeping the column.")
   (move-beginning-of-line "Move to the start of the line.")
   (move-end-of-line "Move to the end of the line.")
   (back-to-indentation "Move to the line's first non-blank char.")
   (forward-word "Move to the end of the next word.")
   (backward-word "Move to the start of the previous word.")
   (beginning-of-buffer "Move to the start of the buffer, leaving the mark behind.")
   (end-of-buffer "Move to the end of the buffer, leaving the mark behind.")
   (scroll-up-command "Scroll down a page (the text moves up).")
   (scroll-down-command "Scroll up a page (the text moves down).")
   (recenter "Scroll so the cursor's line is in the middle.")
   (goto-line "Ask for a line number and go there.")
   (delete-char "Delete the char after the cursor.")
   (delete-backward-char "Delete the char before the cursor, or kill the region if there is one.")
   (newline "Break the line at the cursor.")
   (open-line "Break the line at the cursor, staying before the break.")
   (transpose-chars "Swap the chars around the cursor.")
   (upcase-word "Upper-case to the end of the word.")
   (downcase-word "Lower-case to the end of the word.")
   (capitalize-word "Capitalize to the end of the word.")
   (kill-line "Kill to the end of the line; at the end, kill the line break.")
   (kill-word "Kill to the end of the word.")
   (backward-kill-word "Kill to the start of the word.")
   (kill-region "Kill the text between the mark and the cursor.")
   (kill-ring-save "Copy the text between the mark and the cursor to the kill ring.")
   (yank "Paste the most recent kill.")
   (yank-pop "Replace the text just yanked with the kill before it.")
   (set-mark-command "Set the mark at the cursor, starting a region.")
   (mark-whole-buffer "Select the whole buffer.")
   (exchange-point-and-mark "Swap the cursor and the mark.")
   (emacs-undo "Undo the last change.")
   (emacs-redo "Redo the last undone change.")
   (comment-dwim "Comment or uncomment the region's lines, or the current line.")
   (write-file "Save the buffer under another name.")
   (save-some-buffers "Save every modified buffer.")
   (save-buffers-kill-emacs "Quit imp, as :qa does.")
   (emacs-eval-last-sexp "Evaluate the Scheme form before the cursor and show the result.")))

;;; Incremental search: C-s and C-r, again to go to the next match.

(define (isearch! forward?)
  "Search incrementally as the user types, `forward?` or backward.
   The cursor follows the first match from where the search started;
   C-s and C-r step to the next match, C-g or Esc go back to the start,
   and Enter keeps the search for n and N."
  (let ([origin (cursor)] [found (cursor)])
    (open-cmdline!
     (if forward? "I-search: " "I-search backward: ") ""
     (lambda (text)
       (unless (equal? text "")
         (set! *last-search* text)
         (set! *last-search-forward* forward?)
         (record-jump!)))
     (lambda (text)
       (if (or (equal? text "") (pattern-error text))
           (set-cursor! origin)
           (let ([r (search-next text (if forward? (- origin 1) (+ origin 1)) forward?)])
             (highlight-pattern! "search" text "search")
             (when r (set-cursor! (car r))))))
     (lambda () (set-cursor! origin) (refresh-search-highlight!)))
    (set! *cmdline-key-handler*
          (lambda (key)
            (cond
              [(member key '("C-s" "C-r"))
               (unless (equal? *cmdline* "")
                 (let ([r (search-next *cmdline* (cursor) (equal? key "C-s"))])
                   (when r (set-cursor! (car r)))))
               #t]
              [(equal? key "C-g") (cmdline-key! "<esc>") #t]
              [else #f]))))
  void)

(define-command! 'isearch-forward (lambda (n)
                                    "Search forward as you type; C-s again for the next match."
                                    (isearch! #t)))
(define-command! 'isearch-backward (lambda (n)
                                     "Search backward as you type; C-r again for the previous match."
                                     (isearch! #f)))

;;; Switching between Vim and Emacs

(define-command! 'emacs-state
  (lambda (n)
    "Switch to Emacs keys (C-z switches back)."
    (when (eq? *mode* 'visual) (leave-visual!))
    (when (typing-mode?) (leave-insert!))
    (set! *pairs* '())
    (set-mode! 'emacs)
    (message "Emacs state (C-z for Vim)")))

(define-command! 'vim-state
  (lambda (n)
    "Switch to Vim keys (C-z switches back)."
    (deactivate-mark!)
    (highlight-clear! "visual")
    (set-mode! 'normal)
    (normal-clamp!)
    (message "Vim state (C-z for Emacs)")))

(define-state! 'emacs "EMACS" "bar" emacs-key!)

(define-key! 'normal "C-z" 'emacs-state)
(define-key! 'visual "C-z" 'emacs-state)
(define-key! 'insert "C-z" 'emacs-state)

(add-hook! 'startup
           (lambda ()
             (when (equal? (option 'editing-style) "emacs")
               (set-mode! 'emacs))))

;;; The keys

(for-each
 (lambda (b) (define-key! 'emacs (car b) (cadr b)))
 (list
  (list "C-f" 'forward-char) (list "<right>" 'forward-char)
  (list "C-b" 'backward-char) (list "<left>" 'backward-char)
  (list "C-n" 'next-line) (list "<down>" 'next-line)
  (list "C-p" 'previous-line) (list "<up>" 'previous-line)
  (list "C-a" 'move-beginning-of-line) (list "<home>" 'move-beginning-of-line)
  (list "C-e" 'move-end-of-line) (list "<end>" 'move-end-of-line)
  (list "M-m" 'back-to-indentation)
  (list "M-f" 'forward-word) (list "M-b" 'backward-word)
  (list "M-<" 'beginning-of-buffer) (list "M->" 'end-of-buffer)
  (list "C-v" 'scroll-up-command) (list "<pagedown>" 'scroll-up-command)
  (list "M-v" 'scroll-down-command) (list "<pageup>" 'scroll-down-command)
  (list "C-l" 'recenter)
  (list "M-g g" 'goto-line) (list "M-g M-g" 'goto-line)
  (list "C-d" 'delete-char) (list "<del>" 'delete-char)
  (list "<bs>" 'delete-backward-char) (list "C-h" 'delete-backward-char)
  (list "<ret>" 'newline) (list "C-j" 'newline) (list "C-m" 'newline)
  (list "C-o" 'open-line)
  (list "C-t" 'transpose-chars)
  (list "M-u" 'upcase-word) (list "M-l" 'downcase-word) (list "M-c" 'capitalize-word)
  (list "C-k" 'kill-line)
  (list "M-d" 'kill-word) (list "M-<bs>" 'backward-kill-word) (list "C-<bs>" 'backward-kill-word)
  (list "C-w" 'kill-region) (list "M-w" 'kill-ring-save)
  (list "C-y" 'yank) (list "M-y" 'yank-pop)
  (list "C- " 'set-mark-command) (list "C-@" 'set-mark-command)
  (list "C-x h" 'mark-whole-buffer) (list "C-x C-x" 'exchange-point-and-mark)
  (list "C-/" 'emacs-undo) (list "C-_" 'emacs-undo) (list "C-x u" 'emacs-undo)
  (list "C-?" 'emacs-redo) (list "M-_" 'emacs-redo)
  (list "M-;" 'comment-dwim)
  (list "C-s" 'isearch-forward) (list "C-r" 'isearch-backward)
  (list "M-x" 'execute-command) (list "M-:" 'eval-expression)
  (list "C-x C-e" 'emacs-eval-last-sexp)
  (list "C-x C-s" 'save-buffer) (list "C-x C-w" 'write-file) (list "C-x s" 'save-some-buffers)
  (list "C-x C-f" 'find-file) (list "C-x b" 'switch-buffer) (list "C-x k" 'kill-buffer)
  (list "C-x C-b" 'list-buffers) (list "C-x <left>" 'previous-buffer) (list "C-x <right>" 'next-buffer)
  (list "C-x C-c" 'save-buffers-kill-emacs)
  (list "C-h k" 'describe-key) (list "C-h f" 'describe-function) (list "C-h o" 'describe-option)
  (list "C-h a" 'apropos)
  (list "C-z" 'vim-state)))
