;;; map.scm -- Vim's :map family.
;;;
;;; :nmap gb :ls<CR> binds gb to typing :ls and <ret>. Mappings live in
;;; their own keymaps, checked after the buffer's mode keymaps, so they
;;; win over Vim's own keys as mode keys do. Loaded after modes.scm,
;;; whose *local-keymaps* it extends, and leader.scm, for <Leader>.

;;; Vim key notation

;; Vim's names for keys (lowercase) -> imp's.
(define *vim-key-names*
  (hash "cr" "<ret>" "enter" "<ret>" "return" "<ret>" "nl" "<ret>"
        "esc" "<esc>" "tab" "<tab>" "s-tab" "<s-tab>" "bs" "<bs>" "backspace" "<bs>"
        "space" " " "leader" " " "lt" "<" "bar" "|" "bslash" "\\"
        "del" "<del>" "insert" "<insert>" "up" "<up>" "down" "<down>"
        "left" "<left>" "right" "<right>" "home" "<home>" "end" "<end>"
        "pageup" "<pageup>" "pagedown" "<pagedown>"))

(define (vim-key-name name)
  "imp's name for the key Vim writes as <name>, or #f if it isn't one:
   \"CR\" -> \"<ret>\", \"C-X\" -> \"C-x\", \"F5\" -> \"<f5>\"."
  (let ([lower (string-downcase name)])
    (cond
      [(hash-try-get *vim-key-names* lower) => (lambda (k) k)]
      ;; <C-x> is the same key as <C-X>; <M-x> and <A-x> keep their case.
      [(and (= (string-length name) 3) (starts-with? lower "c-"))
       (string-append "C-" (substring lower 2 3))]
      [(and (= (string-length name) 3) (or (starts-with? lower "m-") (starts-with? lower "a-")))
       (string-append "M-" (substring name 2 3))]
      [(and (> (string-length lower) 1) (equal? (string-ref lower 0) #\f)
            (string->number (substring lower 1 (string-length lower))))
       (string-append "<" lower ">")]
      [else #f])))

(define (vim-keys text)
  "The keys `text` names in Vim's key notation, as a list of imp keys.
   <...> names are case-insensitive; anything else is typed as it is:
   \"<C-w>j:w<CR>\" -> (\"C-w\" \"j\" \":\" \"w\" \"<ret>\")."
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
                 [key (and close (vim-key-name (substring text (+ i 1) close)))])
            (if key
                (loop (+ close 1) (cons key acc))
                (loop (+ i 1) (cons (string (string-ref text i)) acc))))))))
