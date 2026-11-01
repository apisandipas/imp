;;; claude.scm -- Claude Code beside your code: one instance per project,
;;; in a terminal window down the right of the frame.
;;;
;;;   SPC a a, M-a   show this project's Claude (starting it the first
;;;                  time) and type to it; from inside it, hide it. Hidden,
;;;                  it keeps running. M-a works inside the terminal too.
;;;   SPC a s        send the selection (in visual), or the current line
;;;   SPC a b        send the whole buffer
;;;   SPC a f        send a reference to the file (@path), for Claude to read
;;;   SPC a k        stop this project's Claude
;;;
;;; What you send lands in Claude's prompt, labelled with its file and
;;; lines, and the window comes up for you to say what to do with it.
;;; Nothing is submitted until you press <ret>. Sent while Claude is still
;;; starting, it waits until Claude takes input.
;;;
;;; Claude runs claude-command in the project root (the current directory
;;; outside a project). It is a toggled terminal (term.scm), as the
;;; project's shell is, and sends with terminal-paste! as SPC o s does;
;;; this file adds waiting for Claude to take input. Its window's place is a
;;; popup rule, so
;;;   (define-popup-rule! "*claude" 'side 'bottom 'size 0.3)
;;; moves it.

;; The program the Claude terminal runs, in the project root.
(define-option! 'claude-command "claude" '())

(define *claude-pending* (hash))  ; Claude buffer -> texts waiting for it to take input
(define *claude-ready* '())       ; Claude buffers known to take input
(define claude-ready-ms 200)      ; how often to look, while waiting
(define claude-ready-tries 100)   ; and how many times, before giving up
;; Claude Code asks for bracketed paste a moment before it reads its
;; input, and drops what arrives in between; this long after is safe.
(define claude-settle-ms 1000)

(define-popup-rule! "*claude" 'side 'right 'size 0.4)

(define (claude-root)
  "The project the current buffer belongs to; in a Claude buffer, its own."
  (or (buffer-local 'claude-root) (project-root) (current-dir)))

(define (claude-show! root)
  "Shows project `root`'s Claude, starting it if it isn't running.
   Puts you in the terminal state there. Returns its buffer, or #f if it
   couldn't start."
  (let ([buf (toggled-terminal-show! 'claude root)])
    (when buf (set-buffer-local! 'claude-root root))
    buf))

(define (claude-toggle!)
  "Hides Claude when in its window; else shows this project's Claude."
  (if (buffer-local 'claude-root)
      (toggled-terminal-hide!)
      (claude-show! (claude-root))))

;;; Sending

(define (claude-flush! buf tries)
  "Pastes what is waiting for `buf` once its Claude takes input.
   Until then, looks again every claude-ready-ms, `tries` more times,
   and gives up saying so."
  (let ([id (buffer-terminal buf)] [texts (hash-try-get *claude-pending* buf)])
    (cond
      [(or (not id) (not texts)) (set! *claude-pending* (hash-remove *claude-pending* buf))]
      [(memv buf *claude-ready*)
       (set! *claude-pending* (hash-remove *claude-pending* buf))
       ;; As the project's terminal's sends, but never <ret>: you say what
       ;; to do with it.
       (for-each (lambda (text) (terminal-paste! id text #f)) texts)]
      [(term-bracketed-paste? id)
       (run-after! claude-settle-ms
                   (lambda ()
                     (unless (memv buf *claude-ready*) (set! *claude-ready* (cons buf *claude-ready*)))
                     (claude-flush! buf tries)))]
      [(> tries 0) (run-after! claude-ready-ms (lambda () (claude-flush! buf (- tries 1))))]
      [else
       (set! *claude-pending* (hash-remove *claude-pending* buf))
       (message "Claude didn't start taking input, so nothing was sent")]))
  void)

(define (claude-send! text)
  "Puts `text` in the prompt of the current project's Claude and goes there."
  (let ([buf (claude-show! (claude-root))])
    (when buf
      (set! *claude-pending*
            (hash-insert *claude-pending* buf
                         (append (or (hash-try-get *claude-pending* buf) '()) (list text))))
      (claude-flush! buf claude-ready-tries))))

(define (claude-path root)
  "The current buffer's file relative to `root`, or its name if it has none."
  (let ([path (and (buffer-path) (absolute (buffer-path)))])
    (cond [(not path) (buffer-name-of (current-buffer))]
          [(starts-with? path (string-append root "/"))
           (substring path (+ (string-length root) 1) (string-length path))]
          [else path])))

(define (claude-quote label text)
  "`text` labelled with where it came from, in a fenced block."
  (string-append label "\n```\n" text
                 (if (or (equal? text "") (ends-with? text "\n")) "" "\n")
                 "```\n"))

(define (claude-source?)
  "Whether the current buffer is something to send from.
   Claude's own buffer isn't; says so and returns #f."
  (if (buffer-local 'claude-root)
      (begin (message "this is Claude's own window") #f)
      #t))

(define (claude-send-region! count)
  "Sends the selection, or the current line, to Claude in a fenced block.
   It is labelled with the file and line numbers it came from."
  (when (claude-source?)
    (let* ([r (if (eq? *mode* 'visual) (visual-range) (lines-range (current-line) (current-line)))]
           [first (+ (offset->line (car r)) 1)]
           [last (+ (offset->line (max (car r) (- (cadr r) 1))) 1)]
           [lines (if (= first last)
                      (number->string first)
                      (string-append (number->string first) "-" (number->string last)))]
           [label (string-append (claude-path (claude-root)) ":" lines)]
           [text (buffer-substring (car r) (cadr r))])
      (when (eq? *mode* 'visual) (leave-visual!))
      (claude-send! (claude-quote label text)))))

(define (claude-send-buffer! count)
  "Sends the whole buffer to Claude, labelled with its file."
  (when (claude-source?)
    (let ([label (claude-path (claude-root))])
      (claude-send! (claude-quote label (buffer-substring 0 (buffer-length)))))))

(define (claude-send-file! count)
  "Puts an @path reference to the current file in Claude's prompt.
   Claude reads the file itself; a buffer without a file can't be sent
   this way."
  (when (claude-source?)
    (if (buffer-path)
        (claude-send! (string-append "@" (claude-path (claude-root)) " "))
        (message "this buffer has no file; SPC a b sends its text"))))

(define (claude-kill! count)
  "Stops the current project's Claude and kills its buffer."
  (let ([buf (toggled-terminal-buffer 'claude (claude-root))])
    (if buf
        (begin
          (when (= buf (current-buffer)) (toggled-terminal-hide!))
          (kill-buffer! buf)
          (message "Claude stopped"))
        (message "no Claude running for this project"))))

(add-hook! 'buffer-kill
  (lambda (id) (set! *claude-ready* (filter (lambda (b) (not (= b id))) *claude-ready*))))

;; A toggled terminal (term.scm), with its own docstring for M-x.
(define-toggled-terminal! 'claude 'claude-command "*claude")
(define-command! 'claude
  (lambda (count)
    "Show this project's Claude (starting it), or hide it from inside."
    (claude-toggle!)))
(define-command! 'claude-send-region claude-send-region!)
(define-command! 'claude-send-buffer claude-send-buffer!)
(define-command! 'claude-send-file claude-send-file!)
(define-command! 'claude-kill claude-kill!)

(define-leader-group! "a" "claude")
(define-leader! "aa" 'claude "show or hide Claude")
(define-leader! "as" 'claude-send-region "send selection or line to Claude")
(define-leader! "ab" 'claude-send-buffer "send buffer to Claude")
(define-leader! "af" 'claude-send-file "send file reference to Claude")
(define-leader! "ak" 'claude-kill "stop Claude")

(for-each (lambda (state) (define-key! state "M-a" 'claude)) '(normal visual insert))
(define-terminal-key! "M-a" claude-toggle!)
