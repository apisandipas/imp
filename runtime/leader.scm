;;; leader.scm -- the leader key and which-key.
;;;
;;; In normal and visual mode the leader (space by default) starts a key
;;; sequence from a tree of bindings, as in Spacemacs and Doom Emacs. While
;;; a sequence is unfinished, a popup lists the keys that can come next and
;;; what they do, so the tree can be learned by looking.
;;;
;;;   (define-leader! "ff" 'find-file "find file")
;;;   (define-leader-group! "f" "file")
;;;
;;; Keys after the leader are written run together as typed ("ff",
;;; "b<tab>"); the command is a command name or a procedure taking a count.

(define *leader-bindings* (hash))  ; keys -> (command description)
(define *leader-groups* (hash))    ; keys -> group name
(define *leader-keys* "")          ; typed so far in the current sequence

(define (define-leader! keys command description)
  (set! *leader-bindings* (hash-insert *leader-bindings* keys (list command description))))

(define (define-leader-group! keys name)
  (set! *leader-groups* (hash-insert *leader-groups* keys name)))

(define (undefine-leader! keys)
  (set! *leader-bindings* (hash-remove *leader-bindings* keys)))

;; The first key of `text` in key notation: "<tab>", "C-x" or one char.
(define (first-key text)
  (cond
    [(and (starts-with? text "<") (string-contains? text ">"))
     (let loop ([i 1]) (if (equal? (string-ref text i) #\>) (substring text 0 (+ i 1)) (loop (+ i 1))))]
    [(and (>= (string-length text) 3) (or (starts-with? text "C-") (starts-with? text "M-")))
     (substring text 0 3)]
    [else (substring text 0 1)]))

;; The keys that can follow `prefix`, as (key . description) pairs.
(define (leader-continuations prefix)
  (let ([seen (hash)] [n (string-length prefix)])
    (for-each
     (lambda (keys)
       (when (and (starts-with? keys prefix) (> (string-length keys) n))
         (let* ([rest (substring keys n (string-length keys))]
                [key (first-key rest)]
                [full (string-append prefix key)]
                [desc (cond
                        [(hash-try-get *leader-groups* full) => (lambda (g) (string-append "+" g))]
                        [(and (equal? full keys) (hash-try-get *leader-bindings* keys))
                         => (lambda (b) (cadr b))]
                        [else "+prefix"])])
           (unless (hash-contains? seen key)
             (set! seen (hash-insert seen key desc))))))
     (append (hash-keys->list *leader-bindings*) (hash-keys->list *leader-groups*)))
    (sort (map (lambda (k) (cons k (hash-ref seen k))) (hash-keys->list seen))
          (lambda (a b) (string<? (car a) (car b))))))

(define (key-label key) (if (equal? key " ") "SPC" key))

;; The which-key popup for `prefix`: entries in columns across the window.
(define (which-key-lines prefix)
  (let* ([entries (map (lambda (e) (string-append (pad-right (key-label (car e)) 4) "→ " (cdr e)))
                       (leader-continuations prefix))]
         [width (max 20 (+ 2 (apply max (cons 0 (map string-length entries)))))]
         [columns (max 1 (quotient (window-width) width))]
         [rows (quotient (+ (length entries) (- columns 1)) columns)])
    (map (lambda (r)
           (apply string-append
                  (map (lambda (c)
                         (let ([i (+ (* c rows) r)])
                           (if (< i (length entries)) (pad-right (list-ref entries i) width) "")))
                       (range 0 columns))))
         (range 0 rows))))

(define (leader-prompt)
  (string-append "SPC " (apply string-append (map (lambda (k) (string-append (key-label k) " "))
                                                  (split-keys *leader-keys*)))))

(define (split-keys text)
  (if (equal? text "")
      '()
      (let ([k (first-key text)]) (cons k (split-keys (substring text (string-length k) (string-length text)))))))

(define (leader-done!)
  (set! *leader-keys* "")
  (set! *key-interceptor* #f)
  (set-popup! '()))

;; Each key typed after the leader comes here.
(define (leader-input! key)
  (if (member key '("<esc>" "C-g" "C-c"))
      (begin (leader-done!) (message ""))
      (let* ([keys (string-append *leader-keys* key)]
             [binding (hash-try-get *leader-bindings* keys)])
        (cond
          [binding
           (leader-done!)
           (message "")
           (let ([command (car binding)])
             (if (symbol? command) (run-command command) (command 1)))]
          [(pair? (leader-continuations keys))
           (set! *leader-keys* keys)
           (show-which-key!)]
          [else
           (leader-done!)
           (message (string-append (leader-prompt) (key-label key) " is undefined"))]))))

(define (show-which-key!)
  (set-popup! (which-key-lines *leader-keys*))
  (message (leader-prompt)))

;; Start a leader sequence.
(define-command! 'leader
  (lambda (count)
    (set! *leader-keys* "")
    (set! *key-interceptor* leader-input!)
    (show-which-key!)))

(define-key! 'normal " " 'leader)
(define-key! 'visual " " 'leader)

;;; The default tree, close to Doom Emacs.

(define-leader! " " 'find-file "find file")
(define-leader! "." 'find-file "find file")
(define-leader! ":" 'execute-command "M-x")
(define-leader! "," 'switch-buffer "switch buffer")
(define-leader! "`" 'alternate-buffer "last buffer")

(define-command! 'alternate-buffer (lambda (count) ((lookup-key 'normal "C-^") count)))
(define-command! 'save-buffer (lambda (count) (run-ex! "w")))
(define-command! 'save-all-buffers (lambda (count) (run-ex! "wa")))
(define-command! 'kill-buffer (lambda (count) (run-ex! "bd")))
(define-command! 'next-buffer (lambda (count) (run-ex! "bn")))
(define-command! 'previous-buffer (lambda (count) (run-ex! "bp")))
(define-command! 'list-buffers (lambda (count) (run-ex! "ls")))
(define-command! 'new-buffer (lambda (count) (run-ex! "enew")))
(define-command! 'quit (lambda (count) (run-ex! "qa")))
(define-command! 'quit-without-saving (lambda (count) (run-ex! "qa!")))
(define-command! 'save-and-quit (lambda (count) (run-ex! "wqa")))
(define-command! 'clear-search-highlight (lambda (count) (run-ex! "noh")))
(define-command! 'show-messages (lambda (count) (run-ex! "messages")))
(define-command! 'show-registers (lambda (count) (run-ex! "registers")))
(define-command! 'show-marks (lambda (count) (run-ex! "marks")))
(define-command! 'search-forward (lambda (count) (process-key! "/")))

(define-leader-group! "b" "buffer")
(define-leader! "bb" 'switch-buffer "switch buffer")
(define-leader! "bd" 'kill-buffer "kill buffer")
(define-leader! "bk" 'kill-buffer "kill buffer")
(define-leader! "bn" 'next-buffer "next buffer")
(define-leader! "bp" 'previous-buffer "previous buffer")
(define-leader! "bl" 'list-buffers "list buffers")
(define-leader! "bN" 'new-buffer "new buffer")
(define-leader! "bs" 'save-buffer "save buffer")

(define-leader-group! "f" "file")
(define-leader! "ff" 'find-file "find file")
(define-leader! "fs" 'save-buffer "save file")
(define-leader! "fS" 'save-all-buffers "save all files")

(define-leader-group! "e" "eval")
(define-leader! "ee" 'eval-last-sexp "form at cursor")
(define-leader! "ed" 'eval-defun "top-level form")
(define-leader! "eb" 'eval-buffer "buffer")
(define-leader! "er" 'eval-region "region")
(define-leader! "ex" 'eval-expression "expression")

(define-leader-group! "h" "help")
(define-leader! "hk" 'describe-key "describe key")
(define-leader! "hf" 'describe-function "describe function")
(define-leader! "ho" 'describe-option "describe option")
(define-leader! "hc" 'describe-command "describe command")
(define-leader! "ha" 'apropos "apropos")
(define-leader! "hd" 'find-definition "find definition")
(define-leader! "hm" 'show-messages "messages")
(define-leader! "hr" 'show-registers "registers")

(define-leader-group! "s" "search")
(define-leader! "ss" 'search-forward "search")
(define-leader! "sc" 'clear-search-highlight "clear highlight")
(define-leader! "sm" 'show-marks "marks")

(define-leader-group! "q" "quit")
(define-leader! "qq" 'quit "quit")
(define-leader! "qQ" 'quit-without-saving "quit without saving")
(define-leader! "qs" 'save-and-quit "save all and quit")

(define-leader-group! "t" "toggle")
