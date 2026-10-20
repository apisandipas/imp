;;; term.scm -- terminal buffers: a shell (or any program) in a buffer.
;;;
;;; :terminal [CMD] (:term, SPC o t) runs CMD, or your shell, in a new
;;; buffer, in the TERMINAL state: keys go to the program. C-\ C-n goes
;;; back to normal state, where the output can be searched and yanked like
;;; any text; i or a returns to the program. When it exits, the buffer
;;; stays, saying so. The terminal is sized to its window.

(define *terminals* (hash))  ; terminal id -> buffer
(define *term-redraw* #f)    ; a pending redraw timer
(define *term-prefix* #f)    ; after C-\ in the terminal state
(define term-redraw-ms 15)

(define (term-id) (buffer-local 'term-id))

;; The bytes a key sends to a program.
(define (term-key-bytes key id)
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
(define (define-terminal-key! key proc) (set! *terminal-keys* (hash-insert *terminal-keys* key proc)))
(define (remove-terminal-key! key) (set! *terminal-keys* (hash-remove *terminal-keys* key)))

;; Keys in the terminal state.
(define (terminal-key! key)
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
      [else (term-send! id (term-key-bytes key id))])))

(define-state! 'terminal "TERMINAL" "bar" terminal-key!)

;; Redraws terminal `id` into its buffer, sized to the window if it's the
;; current buffer. In the terminal state the cursor follows the program's.
(define (term-redraw! id)
  (let ([buf (hash-try-get *terminals* id)])
    (when (and buf (memv buf (buffer-list)))
      (when (= buf (current-buffer))
        (term-resize! id (window-height) (window-text-width)))
      (let ([at (term-render! id buf)])
        (when (and at (= buf (current-buffer)) (eq? *mode* 'terminal))
          (set-cursor! at))))))

;; Output arrives in chunks; redraw once they pause for a moment.
(define (imp-term-output id)
  (unless *term-redraw*
    (set! *term-redraw*
          (run-after! term-redraw-ms
                      (lambda ()
                        (set! *term-redraw* #f)
                        (for-each term-redraw! (hash-keys->list *terminals*)))))))

(define (imp-term-exit id code)
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

;; Runs `command` (your shell if "") in `cwd`, in buffer `buf`, which must
;; be the current buffer, sized to its window. Returns the terminal's id,
;; or #f after saying why it couldn't start (and killing `buf`).
(define (start-terminal! buf command cwd)
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
    (set-local-option! 'cursorline #f)))

(define (term-resume! count)
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
(define-command! 'terminal (lambda (count) (terminal! "")))
(define-leader! "ot" 'terminal "terminal")
