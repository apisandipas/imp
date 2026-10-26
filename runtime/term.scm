;;; term.scm -- terminal buffers: a shell (or any program) in a buffer.
;;;
;;; :terminal [CMD] (:term, SPC o t) runs CMD, or your shell, in a new
;;; buffer, in the TERMINAL state: keys go to the program. C-\ C-n goes
;;; back to normal state, where the output can be searched and yanked like
;;; any text; i or a returns to the program. When it exits, the buffer
;;; stays, saying so. The terminal is sized to the windows showing it.

(define *terminals* (hash))  ; terminal id -> buffer
(define *term-redraw* #f)    ; a pending redraw timer
(define *term-prefix* #f)    ; after C-\ in the terminal state
(define term-redraw-ms 15)

(define (term-id)
  "The id of the terminal running in the current buffer, or #f.
   It is #f in a buffer that isn't a terminal or whose program exited."
  (buffer-local 'term-id))

(define (term-key-bytes key id)
  "The bytes `key` sends to the program in terminal `id`.
   Arrows follow the program's application-cursor mode; a key with no
   encoding gives \"\"."
  (let ([app? (term-application-cursor? id)]
        [esc (string (integer->char 27))])
    (cond
      [(= (string-length key) 1) key]
      [(equal? key "<ret>") (string (integer->char 13))]
      [(equal? key "<tab>") (string #\tab)]
      [(equal? key "<s-tab>") (string-append esc "[Z")]
      [(equal? key "<bs>") (string (integer->char 127))]
      [(equal? key "<esc>") esc]
      [(equal? key "<del>") (string-append esc "[3~")]
      [(equal? key "<up>") (string-append esc (if app? "OA" "[A"))]
      [(equal? key "<down>") (string-append esc (if app? "OB" "[B"))]
      [(equal? key "<right>") (string-append esc (if app? "OC" "[C"))]
      [(equal? key "<left>") (string-append esc (if app? "OD" "[D"))]
      [(equal? key "<home>") (string-append esc "[H")]
      [(equal? key "<end>") (string-append esc "[F")]
      [(equal? key "<pageup>") (string-append esc "[5~")]
      [(equal? key "<pagedown>") (string-append esc "[6~")]
      [(equal? key "<insert>") (string-append esc "[2~")]
      [(equal? key "C- ") (string (integer->char 0))]
      ;; C-a .. C-z, and C-[ C-\ C-] C-^ C-_
      [(and (starts-with? key "C-") (= (string-length key) 3))
       (let ([n (char->integer (char-downcase (string-ref key 2)))])
         (cond [(and (>= n 97) (<= n 122)) (string (integer->char (- n 96)))]
               [(and (>= n 91) (<= n 95)) (string (integer->char (- n 64)))]
               [else ""]))]
      [(and (starts-with? key "M-") (= (string-length key) 3)) (string-append esc (substring key 2 3))]
      [(equal? key "M-<ret>") (string-append esc (string (integer->char 13)))]
      [else ""])))

;; Keys the terminal state keeps for the editor instead of sending them to
;; the program: key -> procedure of no arguments.
;;
;;   (define-terminal-key! "M-a" claude-toggle!)
(define *terminal-keys* (hash))
(define (define-terminal-key! key proc)
  "Keeps `key` for the editor in the terminal state: it runs `proc`.
   `proc` takes no arguments; the key no longer reaches the program."
  (set! *terminal-keys* (hash-insert *terminal-keys* key proc))
  void)
(define (remove-terminal-key! key)
  "Sends `key` to the program again in the terminal state."
  (set! *terminal-keys* (hash-remove *terminal-keys* key))
  void)

(define (terminal-key! key)
  "Handles `key` in the terminal state, mostly by sending it on.
   Keys from define-terminal-key! stay with the editor; C-\\ C-n goes to
   normal state, and C-\\ C-\\ sends one C-\\."
  (let ([id (term-id)])
    (cond
      [(not id) (set-mode! 'normal)]
      [(and (not *term-prefix*) (hash-try-get *terminal-keys* key)) ((hash-ref *terminal-keys* key))]
      [*term-prefix*
       (set! *term-prefix* #f)
       (cond [(equal? key "C-n") (set-mode! 'normal) (normal-clamp!)]
             ;; C-\ C-\ sends one C-\.
             [else (term-send! id (string-append (term-key-bytes "C-\\" id) (term-key-bytes key id)))])]
      [(equal? key "C-\\") (set! *term-prefix* #t)]
      [else (term-send! id (term-key-bytes key id))]))
  void)

(define-state! 'terminal "TERMINAL" "bar" terminal-key!)

;;; The mouse, for programs that ask for it (less, htop, vim).

(define (term-mouse! action button x y)
  "Passes a mouse event to the program in the current terminal, if it
   asked for that kind of event and the event is on its screen in the
   current window, in the terminal state. #t if it was passed."
  (let* ([id (and (eq? *mode* 'terminal) (term-id))]
         [mouse (and id (term-mouse-mode id))]
         [mode (and mouse (car mouse))]
         [cell (and mouse (not (equal? mode "none")) (window-cell x y))]
         [row (and cell (= (car cell) (current-window)) (- (cadr cell) (term-screen-top id)))]
         [wanted? (cond [(member action '("press" "scroll-up" "scroll-down")) #t]
                        [(equal? action "release") (not (equal? mode "press"))]
                        [(equal? action "drag") (member mode '("button-motion" "any-motion"))]
                        [else #f])])
    (and row (>= row 0) wanted?
         (begin
           (term-send! id (term-mouse-bytes action button (+ (caddr cell) 1) (+ row 1) (cadr mouse)))
           #t))))

(define (term-mouse-bytes action button x y encoding)
  "The bytes reporting a mouse event at 1-based cell `x`, `y`, in
   `encoding`: \"sgr\" (ESC [ < b ; x ; y M, m on release) or the classic
   ESC [ M and three chars, \"utf8\" letting them go past 223."
  (let* ([esc (string (integer->char 27))]
         [code (+ (cond [(equal? action "scroll-up") 64]
                        [(equal? action "scroll-down") 65]
                        [(equal? button "middle") 1]
                        [(equal? button "right") 2]
                        [else 0])
                  (if (equal? action "drag") 32 0))])
    (if (equal? encoding "sgr")
        (string-append esc "[<" (number->string code) ";" (number->string x) ";" (number->string y)
                       (if (equal? action "release") "m" "M"))
        (let* ([most (if (equal? encoding "utf8") 2015 223)]
               [char (lambda (n) (string (integer->char (+ 32 (min n most)))))])
          (string-append esc "[M" (char (if (equal? action "release") 3 code)) (char x) (char y))))))

(set! *mouse-handler* term-mouse!)

(define (term-paste! text)
  "Gives pasted `text` to the program in the terminal state, bracketed
   if it asked for that, line breaks as returns as terminals send them.
   #t if it did."
  (let ([id (and (eq? *mode* 'terminal) (term-id))]
        [text (list->string (map (lambda (c) (if (equal? c #\newline) (integer->char 13) c)) (string->list text)))])
    (and id
         (let ([esc (string (integer->char 27))])
           (term-send! id (if (term-bracketed-paste? id)
                              (string-append esc "[200~" text esc "[201~")
                              text))
           #t))))

(set! *paste-handler* term-paste!)

(define (term-fit! id)
  "Sizes terminal `id` to the windows showing it: the smallest rows and
   columns among them, as Neovim does. Unshown, it keeps its size."
  (let* ([buf (hash-try-get *terminals* id)]
         [sizes (filter pair?
                        (map window-text-size
                             (filter (lambda (w) (eqv? (if (= w (current-window)) (current-buffer) (window-buffer w))
                                                       buf))
                                     (window-list))))])
    (when (pair? sizes)
      (term-resize! id (apply min (map car sizes)) (apply min (map cadr sizes))))))

;; A command can split, close or resize windows: refit every terminal
;; (term-resize! does nothing when the size is the same).
(add-hook! 'post-command (lambda () (for-each term-fit! (hash-keys->list *terminals*))))

(define (term-redraw! id)
  "Redraws terminal `id` into its buffer, sized to its windows.
   In the terminal state the cursor follows the program's."
  (let ([buf (hash-try-get *terminals* id)])
    (when (and buf (memv buf (buffer-list)))
      (term-fit! id)
      (let ([at (term-render! id buf)])
        (when (and at (= buf (current-buffer)) (eq? *mode* 'terminal))
          (set-cursor! at))))))

(define (imp-term-output id)
  "Called when terminal `id` has output: redraws terminals shortly.
   Output arrives in chunks, so the redraw waits term-redraw-ms for them
   to pause."
  (unless *term-redraw*
    (set! *term-redraw*
          (run-after! term-redraw-ms
                      (lambda ()
                        (set! *term-redraw* #f)
                        (for-each term-redraw! (hash-keys->list *terminals*))))))
  void)

(define (imp-term-exit id code)
  "Called when terminal `id`'s program exits with status `code`.
   The buffer stays, read-only, with a line saying how it exited, and
   leaves the terminal state."
  (term-redraw! id)
  (let ([buf (hash-try-get *terminals* id)])
    (set! *terminals* (hash-remove *terminals* id))
    (term-kill! id)
    (when (and buf (memv buf (buffer-list)))
      (let ([here (current-buffer)])
        (switch-to-buffer! buf)
        (with-writable
         (lambda () (buffer-insert! (buffer-length) (string-append "[process exited " (number->string code) "]\n"))))
        (set-buffer-unmodified!)
        (set-buffer-local! 'term-id #f)
        (when (eq? *mode* 'terminal) (set-mode! 'normal))
        (set-cursor! (line-start (last-line)))
        (switch-to-buffer! here)
        (when (= here buf) (set-cursor! (line-start (last-line))))))))

(define *term-count* 0)

(define (start-terminal! buf command cwd)
  "Runs `command` (your shell if \"\") in `cwd`, in buffer `buf`.
   `buf` must be the current buffer; the terminal is sized to its window.
   Returns the terminal's id, or #f after saying why it couldn't start
   (and killing `buf`)."
  (set-major-mode! 'term-mode)
  (let ([id (term-start! command cwd (window-height) (window-text-width))])
    (if (string? id)
        (begin (message id) (buffer-kill! buf) #f)
        (begin
          (set-buffer-local! 'term-id id)
          (set! *terminals* (hash-insert *terminals* id buf))
          (set-mode! 'terminal)
          id))))

(define (terminal! command)
  "Runs `command` (your shell if \"\") in a new terminal buffer.
   It starts in the directory of the current file or file browser, else
   the current directory. Returns the terminal's id, or #f."
  (set! *term-count* (+ *term-count* 1))
  (let* ([cwd (cond [(buffer-local 'dired-dir) (buffer-local 'dired-dir)]
                    [(buffer-path) (directory-of (absolute (buffer-path)))]
                    [else (current-dir)])]
         [name (string-append "*terminal " (number->string *term-count*)
                              (if (equal? command "") "" (string-append ": " command)) "*")]
         [buf (buffer-new! name)])
    (go-to-buffer! buf)
    (start-terminal! buf command cwd)))

(define-major-mode! 'term-mode #f '()
  (lambda ()
    (set-buffer-read-only! #t)
    (set-local-option! 'number #f)
    (set-local-option! 'relativenumber #f)
    (set-local-option! 'cursorline #f)
    (set-local-option! 'signcolumn "no")))

(define (term-resume! count)
  "Goes back to the terminal state, if the program is still running."
  (if (term-id)
      (begin (set-mode! 'terminal) (term-redraw! (term-id)))
      (message "the program has exited")))
(for-each (lambda (k) (define-mode-key! 'term-mode 'normal k term-resume!)) '("i" "a" "I" "A"))

(add-hook! 'buffer-kill
  (lambda (id)
    (for-each (lambda (t) (when (= (hash-ref *terminals* t) id)
                            (term-kill! t)
                            (set! *terminals* (hash-remove *terminals* t))))
              (hash-keys->list *terminals*))))

;; Coming back to a terminal buffer: show its latest output.
(add-hook! 'buffer-enter (lambda () (when (term-id) (term-redraw! (term-id)))))

(define-ex! '("ter" "terminal") (lambda (ex) (terminal! (trim (ex-args ex)))))
(define-command! 'terminal
  (lambda (count)
    "Run your shell in a new terminal buffer."
    (terminal! "")))
(define-leader! "ot" 'terminal "terminal")
