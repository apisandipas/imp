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

;;; Mappings

(define *noremap* #f)   ; true while a noremap {rhs} plays: mappings are hidden
(define *map-depth* 0)  ; how deep mappings are playing other mappings
;; (state . lhs keys joined) -> (lhs-text rhs-text noremap?), for :map's
;; listing and :unmap. State is 'normal, 'visual, 'insert or 'leader.
(define *mappings* (hash))

(define (map-keymap state)
  "The keymap mappings for `state` live in: map:normal, map:visual..."
  (string->symbol (string-append "map:" (symbol->string state))))

;; Mappings come after the buffer's mode keymaps; a noremap {rhs} sees none.
(let ([mode-keymaps *local-keymaps*])
  (set! *local-keymaps*
        (lambda (state)
          (if *noremap*
              (mode-keymaps state)
              (append (mode-keymaps state) (list (map-keymap state)))))))

(define (play-mapping! keys noremap? count)
  "Plays a mapping's {rhs} `keys`, after the count typed before it.
   A noremap {rhs} runs imp's own keys; a recursive one stops at 100
   levels."
  (if (>= *map-depth* 100)
      (begin (set! *command-failed* #t) (message "error: recursive mapping"))
      (let ([old *noremap*]
            [keys (if (and *count-given* (> count 1))
                      (append (map string (string->list (number->string count))) keys)
                      keys)])
        (set! *map-depth* (+ *map-depth* 1))
        (set! *noremap* (or old noremap?))
        (with-handler (lambda (e)
                        (set! *noremap* old)
                        (set! *map-depth* (- *map-depth* 1))
                        (raise-error e))
                      (play-keys! keys))
        (set! *noremap* old)
        (set! *map-depth* (- *map-depth* 1))))
  void)

(define (key-does-something? state key)
  "Whether `key` alone already does something in normal or visual `state`."
  (or (local-key-proc state key) (lookup-key state key) (find-motion key)
      (hash-contains? *operators* key) (hash-contains? *char-commands* key)
      (prefix-key? key)))

(define (define-mapping! state lhs rhs noremap?)
  "Maps `lhs` to typing `rhs` in `state`, both in Vim's key notation.
   Returns #f, or why it can't be mapped."
  (let* ([keys (vim-keys lhs)]
         [rhs-keys (vim-keys rhs)]
         [joined (apply string-append keys)]
         [remember! (lambda (where)
                      (set! *mappings* (hash-insert *mappings* (cons where joined) (list lhs rhs noremap?))))])
    (cond
      [(null? keys) "no keys to map"]
      ;; <Leader>x joins the leader tree, in normal and visual alike.
      [(and (not (eq? state 'insert)) (equal? (car keys) " ") (pair? (cdr keys)))
       (define-leader! (apply string-append (cdr keys))
                       (lambda (count) (play-mapping! rhs-keys noremap? count))
                       rhs)
       (remember! 'leader)
       #f]
      [(and (not (eq? state 'insert)) (> (length keys) 2))
       (string-append "can't map " lhs ": only two keys, or <Leader> and more")]
      [(and (not (eq? state 'insert)) (= (length keys) 2)
            (not (prefix-key? (car keys))) (key-does-something? state (car keys)))
       (string-append "can't map " lhs ": " (car keys) " already does something")]
      [else
       (when (and (not (eq? state 'insert)) (= (length keys) 2) (not (prefix-key? (car keys))))
         (define-prefix! (car keys)))
       (define-key! (map-keymap state) joined
                    (if (eq? state 'insert)
                        (lambda () (play-mapping! rhs-keys noremap? 1))
                        (lambda (count) (play-mapping! rhs-keys noremap? count)))
                    rhs)
       (remember! state)
       #f])))

(define (map-ex states noremap?)
  "An ex command that maps in each of `states`: :nmap, :noremap..."
  (lambda (ex)
    (let* ([args (map-args (ex-args ex))])
      (cond
        [(string? args) (message args)]
        [(equal? (car args) "") (message "listing mappings comes later")]
        [(equal? (cadr args) "") (message "listing mappings comes later")]
        [else
         (let loop ([states states])
           (when (pair? states)
             (let ([why (define-mapping! (car states) (car args) (cadr args) noremap?)])
               (if why (message why) (loop (cdr states))))))]))))

(define (map-args text)
  "(lhs rhs) from a map command's arguments, \"\" for a missing one,
   after <silent>; or why they can't be used, as a string."
  (let loop ([text (trim-left text)])
    (let* ([space (let find ([i 0])
                    (cond [(>= i (string-length text)) i]
                          [(char-whitespace? (string-ref text i)) i]
                          [else (find (+ i 1))]))]
           [word (substring text 0 space)]
           [rest (trim-left (substring text space (string-length text)))]
           [lower (string-downcase word)])
      (cond
        [(equal? lower "<silent>") (loop rest)]
        [(member lower '("<buffer>" "<expr>" "<script>" "<unique>" "<nowait>" "<special>"))
         (string-append word " isn't supported")]
        [else (list word rest)]))))

(define-ex! '("map") (map-ex '(normal visual) #f))
(define-ex! '("nm" "nmap") (map-ex '(normal) #f))
(define-ex! '("vm" "vmap") (map-ex '(visual) #f))
(define-ex! '("no" "noremap") (map-ex '(normal visual) #t))
(define-ex! '("nn" "nnoremap") (map-ex '(normal) #t))
(define-ex! '("vn" "vnoremap") (map-ex '(visual) #t))
