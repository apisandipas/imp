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
  "Whether `key` alone already does something in normal or visual `state`
   other than wait for another key, as resolve-key says."
  (let ([b (resolve-key state key)])
    (and b (not (eq? (binding-record-kind b) 'prefix)))))

(define (key-waits? state key)
  "Whether `key` waits for another in normal or visual `state`: a Vim
   prefix, or i and a before a text object in visual state."
  (or (prefix-key? key)
      (let ([b (resolve-key state key)])
        (and b (eq? (binding-record-kind b) 'prefix)))))

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
            (not (key-waits? state (car keys))) (key-does-something? state (car keys)))
       (string-append "can't map " lhs ": " (car keys) " already does something")]
      [(and (eq? state 'insert) (> (length keys) 1))
       (set! *insert-sequences* (hash-insert *insert-sequences* joined (list keys rhs-keys noremap?)))
       (remember! state)
       #f]
      [else
       (when (and (not (eq? state 'insert)) (= (length keys) 2) (not (key-waits? state (car keys))))
         (define-prefix! (car keys)))
       (define-key! (map-keymap state) joined
                    (if (eq? state 'insert)
                        (lambda () (play-mapping! rhs-keys noremap? 1))
                        (lambda (count) (play-mapping! rhs-keys noremap? count)))
                    rhs)
       (remember! state)
       #f])))

;;; Insert mappings of several keys: jk inserts j, and if k follows within
;;; timeoutlen the j is removed and the {rhs} runs, as Vim shows it.

(define-option! 'timeoutlen 1000 '())
;; lhs keys joined -> (lhs-keys rhs-keys noremap?)
(define *insert-sequences* (hash))
;; While a sequence is half typed: (keys-so-far start timer), else #f.
(define *insert-pending* #f)

(define (insert-sequences-from keys)
  "The insert sequences whose keys start with `keys`, longer than them."
  (filter (lambda (seq) (and (> (length (car seq)) (length keys))
                             (equal? (take (car seq) (length keys)) keys)))
          (hash-values->list *insert-sequences*)))

(define (insert-pending-clear!)
  "Forgets a half-typed insert sequence."
  (when *insert-pending*
    (let ([timer (caddr *insert-pending*)]) (when timer (cancel-timer! timer)))
    (set! *insert-pending* #f))
  void)

(define (insert-pending-start! keys start)
  "Waits timeoutlen for the rest of a sequence begun with `keys` at `start`."
  (insert-pending-clear!)
  (set! *insert-pending*
        (list keys start
              (run-after! (option 'timeoutlen)
                          (lambda ()
                            (when (and *insert-pending* (eq? (car *insert-pending*) keys))
                              (set! *insert-pending* #f))))))
  void)

(define (insert-sequence-key! key)
  "Handles typed `key` for insert sequences; #t if it completed one and
   was used up. Other keys are typed as usual."
  (cond
    [(or *noremap* (not (eq? *mode* 'insert)) (= (hash-length *insert-sequences*) 0))
     (insert-pending-clear!)
     #f]
    [*insert-pending*
     (let* ([keys (append (car *insert-pending*) (list key))]
            [start (cadr *insert-pending*)]
            [seq (hash-try-get *insert-sequences* (apply string-append keys))])
       (cond
         [seq
          (insert-pending-clear!)
          ;; Take back what the first keys typed, and their record for `.`.
          (when (> (cursor) start)
            (buffer-delete! start (cursor))
            (set-cursor! start))
          (set! *insert-keys* (list-tail-safe *insert-keys* (- (length keys) 1)))
          (play-mapping! (cadr seq) (caddr seq) 1)
          #t]
         [(pair? (insert-sequences-from keys))
          (insert-pending-start! keys start)
          #f]
         [else
          (insert-pending-clear!)
          (insert-sequence-key! key)]))]
    [(pair? (insert-sequences-from (list key)))
     (insert-pending-start! (list key) (cursor))
     #f]
    [else #f]))

(define (list-tail-safe items n)
  "`items` without its first `n`, or '() if it has fewer."
  (if (or (<= n 0) (null? items)) items (list-tail-safe (cdr items) (- n 1))))

(set! *insert-key-handler* insert-sequence-key!)
(add-hook! 'insert-leave insert-pending-clear!)

(define (map-ex states noremap?)
  "An ex command that maps in each of `states`: :nmap, :noremap..."
  (lambda (ex)
    (let* ([args (map-args (ex-args ex))])
      (cond
        [(string? args) (message args)]
        [(equal? (car args) "") (show-mappings! states #f)]
        [(equal? (cadr args) "") (show-mappings! states (apply string-append (vim-keys (car args))))]
        [else
         (let loop ([states states])
           (when (pair? states)
             (let ([why (define-mapping! (car states) (car args) (cadr args) noremap?)])
               (if why (message why) (loop (cdr states))))))]))))

(define (mapping-places states)
  "Where mappings for `states` are kept: the states, and 'leader for
   normal or visual."
  (if (or (memq 'normal states) (memq 'visual states)) (append states '(leader)) states))

(define (show-mappings! states joined)
  "Lists the mappings for `states`, or only the one for keys `joined`:
   state, lhs, * for noremap, rhs, as :map does."
  (let* ([places (mapping-places states)]
         [entries (sort (filter (lambda (e) (and (memq (car (car e)) places)
                                                 (or (not joined) (equal? (cdr (car e)) joined))))
                                (map (lambda (k) (cons k (hash-ref *mappings* k))) (hash-keys->list *mappings*)))
                        (lambda (a b) (string<? (cadr a) (cadr b))))]
         [line (lambda (e)
                 (let ([state (car (car e))] [lhs (cadr e)] [rhs (caddr e)] [noremap? (cadddr e)])
                   (string-append (case state [(normal) "n "] [(visual) "v "] [(insert) "i "] [else "nv"])
                                  "  " lhs (make-string (max 1 (- 14 (string-length lhs))) #\space)
                                  (if noremap? "* " "  ") rhs)))])
    (cond [(null? entries) (message "No mapping found")]
          [(null? (cdr entries)) (message (line (car entries)))]
          [else (show-popup! (map line entries))])))

(define (remove-mapping! state lhs)
  "Removes the mapping of `lhs` in `state`. Returns #f, or why it can't."
  (let* ([keys (vim-keys lhs)]
         [joined (apply string-append keys)]
         [leader? (and (not (eq? state 'insert)) (pair? keys) (equal? (car keys) " ") (pair? (cdr keys)))]
         [place (if leader? 'leader state)])
    (cond
      [(not (hash-contains? *mappings* (cons place joined))) (string-append "No such mapping: " lhs)]
      [else
       (set! *mappings* (hash-remove *mappings* (cons place joined)))
       (cond [leader? (undefine-leader! (apply string-append (cdr keys)))]
             [(and (eq? state 'insert) (> (length keys) 1))
              (set! *insert-sequences* (hash-remove *insert-sequences* joined))]
             [else
              (let ([km (map-keymap state)])
                (set! *keymaps* (hash-insert *keymaps* km (hash-remove (keymap km) joined)))
                (set-binding-label! km joined #f))])
       #f])))

(define (unmap-ex states)
  "An ex command that removes a mapping in each of `states`: :unmap..."
  (lambda (ex)
    (let ([lhs (car (map-args (ex-args ex)))])
      (if (equal? lhs "")
          (message "Argument required")
          ;; :unmap removes it wherever it is among `states`.
          (let ([why (map (lambda (state) (remove-mapping! state lhs)) states)])
            (when (= (length (filter (lambda (w) w) why)) (length states))
              (message (car why))))))))

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
(define-ex! '("im" "imap") (map-ex '(insert) #f))
(define-ex! '("ino" "inoremap") (map-ex '(insert) #t))
(define-ex! '("unm" "unmap") (unmap-ex '(normal visual)))
(define-ex! '("nun" "nunmap") (unmap-ex '(normal)))
(define-ex! '("vu" "vunmap") (unmap-ex '(visual)))
(define-ex! '("iu" "iunmap") (unmap-ex '(insert)))
