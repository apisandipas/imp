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
;;; SPC o s and SPC o b send it the line or selection, or the buffer, to run.

(define *terminals* (hash))  ; terminal id -> buffer
(define *term-redraw* #f)    ; a pending redraw timer
(define *term-prefix* #f)    ; after C-\ in the terminal state
(define *terminals-heard* '()) ; terminals that have printed something
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
         (begin
           (term-send! id (if (term-bracketed-paste? id) (bracketed text) text))
           #t))))

(set! *paste-handler* term-paste!)

(define (bracketed text)
  "`text` wrapped in bracketed-paste escapes.
   Programs that asked for bracketed paste take it as one paste rather
   than as typing, so its line breaks don't submit anything."
  (let ([esc (string (integer->char 27))])
    (string-append esc "[200~" text esc "[201~")))

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

(define (term-follow! id buf)
  "Keeps what terminal `id`'s program reported in its buffer `buf`, so it
   outlives the program: the shell's directory (OSC 7), and its title
   (OSC 0 or 2), shown as the status line's %{title}."
  (let ([dir (term-directory id)] [title (term-title id)])
    (when (and dir (not (equal? dir (buffer-local-of buf 'term-dir))))
      (set-buffer-local-of! buf 'term-dir dir))
    (when (and title (not (equal? title (or (buffer-local-of buf 'term-title) ""))))
      (set-buffer-local-of! buf 'term-title (if (equal? title "") #f title))
      (set-buffer-status-value! buf "title"
                                (if (equal? title "")
                                    ""
                                    (string-append "%#status.dim#  " (apply string-append (map (lambda (c) (if (equal? c #\%) "%%" (string c))) (string->list title))) "%*"))))))

(define (term-redraw! id)
  "Redraws terminal `id` into its buffer, sized to its windows.
   In the terminal state the cursor follows the program's."
  (let ([buf (hash-try-get *terminals* id)])
    (when (and buf (memv buf (buffer-list)))
      (term-fit! id)
      (term-follow! id buf)
      (let ([at (term-render! id buf)])
        (when (and at (= buf (current-buffer)) (eq? *mode* 'terminal))
          (set-cursor! at))))))

(define (imp-term-output id)
  "Called when terminal `id` has output: redraws terminals shortly.
   Output arrives in chunks, so the redraw waits term-redraw-ms for them
   to pause."
  (unless (memv id *terminals-heard*) (set! *terminals-heard* (cons id *terminals-heard*)))
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
    (set! *terminals-heard* (filter (lambda (t) (not (= t id))) *terminals-heard*))
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

;; Killing a buffer with a running program, or quitting, asks first.
(define-option! 'terminal-confirm-kill #t '())

(define (terminal-confirm-kill? buf)
  "terminal-confirm-kill for buffer `buf`: its own, set with
   set-local-option!, else the global one."
  (let ([locals (or (hash-try-get *buffer-locals* buf) (hash))] [key (list 'option 'terminal-confirm-kill)])
    (if (hash-contains? locals key) (hash-ref locals key) (hash-ref *options* 'terminal-confirm-kill))))

(set! *running-buffers*
      (lambda ()
        (filter (lambda (buf) (and (memv buf (buffer-list)) (terminal-confirm-kill? buf)))
                (map (lambda (id) (hash-ref *terminals* id)) (hash-keys->list *terminals*)))))

;; In a daemon, stops it for every client (:q only detaches one), asking
;; first when that stops running programs.
(define-command! 'kill-server
  (lambda (count)
    "Stop the daemon, for every client attached to it. Without a daemon, quit."
    (let ([running (*running-buffers*)])
      (if (null? running)
          (kill-server!)
          (confirm! (string-append "stop the programs running in " (number->string (length running))
                                   (if (= (length running) 1) " terminal?" " terminals?"))
                    kill-server!)))))

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
          (set-buffer-local! 'term-command command)
          (set-buffer-local! 'term-dir (absolute cwd))
          (set! *terminals* (hash-insert *terminals* id buf))
          (set-mode! 'terminal)
          id))))

(define (terminal! command)
  "Runs `command` (your shell if \"\") in a new terminal buffer.
   It starts in the current buffer's directory: a terminal's, a file
   browser's or the file's, else the current directory. Returns the
   terminal's id, or #f."
  (terminal-named! command #f (buffer-directory)))

(define (unused-buffer-name name)
  "`name`, or with <2>, <3> ... after it if a buffer has it already."
  (let ([taken (map buffer-name-of (buffer-list))])
    (let loop ([n 1])
      (let ([candidate (if (= n 1) name (string-append name "<" (number->string n) ">"))])
        (if (member candidate taken) (loop (+ n 1)) candidate)))))

(define (terminal-named! command name cwd)
  "Runs `command` (your shell if \"\") in `cwd`, in a new terminal buffer
   named `name`, or *terminal N* if it is #f. Returns the terminal's id,
   or #f."
  (let* ([name (or (and name (unused-buffer-name name))
                   (begin
                     (set! *term-count* (+ *term-count* 1))
                     (string-append "*terminal " (number->string *term-count*)
                                    (if (equal? command "") "" (string-append ": " command)) "*")))]
         [buf (buffer-new! name)])
    (go-to-buffer! buf)
    (start-terminal! buf command cwd)))

(define (terminal-ex! args)
  ":terminal [++name=NAME] [++cwd=DIR] [CMD]: the ++ options, in either
   order, before the command, as Vim's ++ options are. DIR is taken from
   the current buffer's directory when relative."
  (let loop ([args (trim args)] [name #f] [cwd #f])
    (let* ([space (let find ([i 0]) (cond [(>= i (string-length args)) i]
                                           [(char-whitespace? (string-ref args i)) i]
                                           [else (find (+ i 1))]))]
           [word (substring args 0 space)]
           [rest (trim (substring args space (string-length args)))]
           [value (lambda (prefix) (substring word (string-length prefix) (string-length word)))])
      (cond
        [(starts-with? word "++name=") (loop rest (value "++name=") cwd)]
        [(starts-with? word "++cwd=") (loop rest name (value "++cwd="))]
        [(starts-with? word "++") (message (string-append "unknown option " word))]
        [else
         (let ([dir (cond [(not cwd) (buffer-directory)]
                          [(starts-with? (expand-path cwd) "/") (expand-path cwd)]
                          [else (string-append (buffer-directory) "/" cwd)])])
           (if (file-directory? dir)
               (terminal-named! args name dir)
               (message (string-append dir ": no such directory"))))]))))

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

(define-ex! '("ter" "terminal") (lambda (ex) (terminal-ex! (ex-args ex))))
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

;;; Sending text to the project's terminal
;;;
;;;   SPC o s   send the selection (in visual), or the current line
;;;   SPC o b   send the whole buffer
;;;   gz        an operator: gzap a paragraph, gzz the line, gz in visual
;;;             the selection; . sends the same again
;;;
;;; It goes as a paste and then runs: <ret> follows it unless
;;; terminal-send-enter is off. You stay in your buffer.

(define-option! 'terminal-send-enter #t '())
(define terminal-ready-ms 100)   ; how often to look for a new shell's prompt
(define terminal-ready-tries 50) ; and how many times, before giving up

(define (terminal-paste! id text enter?)
  "Sends `text` to terminal `id` as a paste: bracketed if its program
   asked for that, else typed, line breaks as returns. Then a return if
   `enter?`."
  (let ([ret (string (integer->char 13))])
    (term-send! id (if (term-bracketed-paste? id)
                       (bracketed text)
                       (list->string (map (lambda (c) (if (equal? c #\newline) (integer->char 13) c))
                                          (string->list text)))))
    (when enter? (term-send! id ret))))

(define (terminal-paste-when-heard! buf text enter? tries)
  "Pastes `text` to the terminal in `buf` once it has printed something
   (a new shell's prompt), so the text isn't lost while it starts. Looks
   every terminal-ready-ms, `tries` more times, then gives up saying so."
  (let ([id (buffer-terminal buf)])
    (cond
      [(not id) (message "the terminal exited, so nothing was sent")]
      [(memv id *terminals-heard*) (terminal-paste! id text enter?)]
      [(> tries 0)
       (run-after! terminal-ready-ms (lambda () (terminal-paste-when-heard! buf text enter? (- tries 1))))]
      [else (message "the terminal printed nothing, so nothing was sent")]))
  void)

(define (terminal-send! text)
  "Sends `text` to the current project's terminal to run, a final line
   break dropped. Shows the terminal, starting it if need be, and leaves
   you in the window you were in, in normal state."
  (let* ([origin (current-window)]
         [buf (toggled-terminal-show! 'toggle-terminal (toggled-terminal-root))]
         [text (if (ends-with? text "\n") (substring text 0 (- (string-length text) 1)) text)])
    (when (memv origin (window-list)) (go-to-window! origin))
    (set-mode! 'normal)
    (when buf (terminal-paste-when-heard! buf text (option 'terminal-send-enter) terminal-ready-tries))))

(define (terminal-source?)
  "Whether the current buffer is something to send from.
   The project's terminal isn't; says so and returns #f."
  (if (eq? (buffer-local 'toggled-name) 'toggle-terminal)
      (begin (message "this is the terminal's own window") #f)
      #t))

(define (terminal-send-region! count)
  "Sends the selection, or the current line, to the project's terminal.
   Sending the line moves the cursor to the next, to send that one next."
  (when (terminal-source?)
    (let* ([visual? (eq? *mode* 'visual)]
           [r (if visual? (visual-range) (lines-range (current-line) (current-line)))]
           [text (buffer-substring (car r) (cadr r))])
      (if visual?
          (leave-visual!)
          (let ([down (vertical (cursor) 1)]) (when down (set-cursor! down))))
      (terminal-send! text))))

(define (terminal-send-buffer! count)
  "Sends the whole buffer to the project's terminal."
  (when (terminal-source?)
    (terminal-send! (buffer-substring 0 (buffer-length)))))

(define-operator! "gz"
  (lambda (start end linewise?)
    (when (terminal-source?) (terminal-send! (buffer-substring start end))))
  "send to terminal")
(define-key! 'visual "gz" (lambda (count) (visual-operator! "gz" #f)) "send to terminal")

;;; Picking a terminal (SPC o l)

(define (terminal-buffers)
  "The terminal buffers, running or exited, in buffer-list order."
  (filter (lambda (buf) (buffer-local-of buf 'term-command)) (buffer-list)))

(define (terminal-annotation buf)
  "What switch-terminal shows beside terminal buffer `buf`: its command
   (or shell), its directory, and whether its program has exited."
  (let ([command (buffer-local-of buf 'term-command)] [dir (buffer-local-of buf 'term-dir)])
    (string-append (pad-right (if (equal? command "") "shell" command) 20) "  "
                   (if dir (abbreviate-path dir) "")
                   (if (buffer-terminal buf) "" "  exited"))))

(define (show-terminal! buf)
  "Shows terminal buffer `buf`: a toggled one in its popup window, else in
   the current window. If its program is running, in the TERMINAL state."
  (if (buffer-local-of buf 'toggled-name) (display-buffer! buf) (go-to-buffer! buf))
  (when (buffer-terminal buf)
    (set-mode! 'terminal)
    (term-redraw! (buffer-terminal buf))))

(define-command! 'switch-terminal
  (lambda (count)
    "Switch to a terminal, picked from a list of them."
    (let* ([bufs (terminal-buffers)]
           [named (map (lambda (buf) (cons (buffer-name-of buf) buf)) bufs)])
      (if (null? bufs)
          (message "no terminals")
          (completing-read "Switch to terminal: " (map car named)
                           (lambda (name)
                             (let ([hit (assoc name named)])
                               (when hit (show-terminal! (cdr hit)))))
                           (lambda (name)
                             (let ([hit (assoc name named)])
                               (and hit (terminal-annotation (cdr hit))))))))))
(define-leader! "ol" 'switch-terminal "switch to terminal")

(define-command! 'terminal-send-region terminal-send-region!)
(define-command! 'terminal-send-buffer terminal-send-buffer!)
(define-leader! "os" 'terminal-send-region "send selection or line to terminal")
(define-leader! "ob" 'terminal-send-buffer "send buffer to terminal")
