;;; term.scm -- terminal buffers: a shell (or any program) in a buffer.
;;;
;;; :terminal [CMD] (:term, SPC o T) runs CMD, or your shell, in a new
;;; buffer, in the TERMINAL state: keys go to the program. C-\ C-n goes
;;; back to normal state, where the output can be searched and yanked like
;;; any text; i or a returns to the program. When it exits, the buffer
;;; stays, saying so. The terminal is sized to the windows showing it.
;;;
;;; SPC o t (or M-`) toggles the project's own shell in a window down the
;;; right; define-toggled-terminal! makes a toggle like it for any program.

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

;;; Toggled terminals: one program per project, shown in a popup window
;;; and hidden again from inside it, running all the while. The shell's is
;;; toggle-terminal; claude.scm's is Claude's.
;;;
;;;   (define-toggled-terminal! 'lazygit "lazygit" "*lazygit")
;;;   (define-popup-rule! "*lazygit" 'side 'right 'size 0.5)
;;;   (define-leader! "gl" 'lazygit "lazygit")

(define *toggled-terminals* (hash))  ; toggle name -> (hash project root -> buffer)
(define *toggles* (hash))            ; toggle name -> (command buffer-name-prefix)

(define (toggled-terminal-root)
  "The project the current buffer belongs to; in a toggled terminal, its
   own. Outside any project, imp's current directory."
  (or (buffer-local 'toggled-root) (project-root) (current-dir)))

(define (toggled-terminal-buffer name root)
  "The buffer of toggle `name` for project `root`, or #f."
  (let* ([table (hash-try-get *toggled-terminals* name)]
         [buf (and table (hash-try-get table root))])
    (and buf (memv buf (buffer-list)) buf)))

(define (buffer-terminal buf)
  "The terminal running in buffer `buf`, or #f once it has exited."
  (list-find (lambda (id) (= (hash-ref *terminals* id) buf)) (hash-keys->list *terminals*)))

(define (toggled-terminal-start! name command prefix root)
  "Starts toggle `name`'s program for project `root` in a new buffer and
   shows it. Returns the buffer, or #f if it couldn't start."
  (let ([buf (buffer-new! (string-append prefix ": " (file-name-of root) "*"))]
        [command (if (symbol? command) (option command) command)])
    (display-buffer! buf)
    (set-buffer-local! 'toggled-name name)
    (set-buffer-local! 'toggled-root root)
    (set-buffer-local! 'mode-line-label (symbol->string name))
    (and (start-terminal! buf command root)
         (begin
           (set! *toggled-terminals*
                 (hash-insert *toggled-terminals* name
                              (hash-insert (or (hash-try-get *toggled-terminals* name) (hash)) root buf)))
           buf))))

(define (toggled-terminal-show! name root)
  "Shows toggle `name`'s program for project `root`, starting it if it
   isn't running, and puts you in the terminal state there. Returns its
   buffer, or #f if it couldn't start."
  (let ([buf (toggled-terminal-buffer name root)] [spec (hash-ref *toggles* name)])
    (cond
      [(and buf (buffer-terminal buf))
       (display-buffer! buf)
       (set-mode! 'terminal)
       (term-redraw! (term-id))
       buf]
      [else
       ;; It exited: start again in a fresh buffer.
       (when buf (kill-buffer! buf))
       (toggled-terminal-start! name (car spec) (cadr spec) root)])))

(define (toggled-terminal-hide!)
  "Leaves the current window's toggled terminal, closing the window, but
   not the program."
  (set-mode! 'normal)
  (let ([popup (popup-window-entry (current-window))])
    (cond
      [(> (length (window-list)) 1)
       (close-window! (current-window))
       (when (and popup (memv (cadr popup) (window-list))) (focus-window! (cadr popup)))
       (after-window-change!)]
      [(and *alternate-buffer* (memv *alternate-buffer* (buffer-list)))
       (go-to-buffer! *alternate-buffer*)]
      [else (message "no other buffer to show")]))
  void)

(define (toggled-terminal-toggle! name)
  "Hides toggle `name`'s program when in its window; else shows this
   project's."
  (if (eq? (buffer-local 'toggled-name) name)
      (toggled-terminal-hide!)
      (toggled-terminal-show! name (toggled-terminal-root)))
  void)

(define (define-toggled-terminal! name command prefix)
  "Makes command `name` toggle a program per project: it shows the
   current project's in a window placed by the popup rule for `prefix`,
   starting it the first time in the project root, and from inside hides
   it while it keeps running. `command` is what runs: a string (\"\" for
   your shell) or a symbol naming an option that holds one. Its buffers
   are named `prefix`: PROJECT*."
  (set! *toggles* (hash-insert *toggles* name (list command prefix)))
  (define-command! name
    (lambda (count)
      "Show this project's program in its window (starting it), or hide it from inside."
      (toggled-terminal-toggle! name)))
  void)

(add-hook! 'buffer-kill
  (lambda (id)
    (for-each (lambda (name)
                (let ([table (hash-ref *toggled-terminals* name)])
                  (for-each (lambda (root)
                              (when (= (hash-ref table root) id)
                                (set! *toggled-terminals*
                                      (hash-insert *toggled-terminals* name (hash-remove table root)))))
                            (hash-keys->list table))))
              (hash-keys->list *toggled-terminals*))))

;; The project's shell, down the right as Claude's window is.
(define-toggled-terminal! 'toggle-terminal "" "*terminal")
(define-popup-rule! "*terminal:" 'side 'right 'size 0.4)

(define-leader! "ot" 'toggle-terminal "toggle terminal")
(define-leader! "oT" 'terminal "terminal here")
(for-each (lambda (state) (define-key! state "M-`" 'toggle-terminal)) '(normal visual insert emacs))
(define-terminal-key! "M-`" (lambda () (toggled-terminal-toggle! 'toggle-terminal)))
