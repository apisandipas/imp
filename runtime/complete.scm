;;; complete.scm -- completion at point, in insert state.
;;;
;;; A menu of candidates in a box at the cursor, gathered from completion
;;; sources (as nvim-cmp's, or Emacs's completion-at-point-functions):
;;;
;;;   file     a path being typed (~/, ./, ../, /, or a word with a /)
;;;   lsp      the language server, when the buffer has one (lsp.scm)
;;;   scheme   in Scheme buffers, the names imp defines, with their docs
;;;   words    words from this buffer, nearest first, then the others
;;;
;;; Sources come in groups, tried in turn: the menu shows what the first
;;; group with anything to offer found, its sources' candidates merged and
;;; ranked by how well they match, then by source priority. The default
;;; groups are (file (lsp scheme words)): a path completes on its own,
;;; anything else from the other three together. Per major mode:
;;;
;;;   (set-completion-sources! 'markdown-mode '(file words))   ; 2 groups
;;;   (set-completion-sources! 'org-mode '((file words)))      ; 1 group
;;;
;;; C-n and C-p open it (C-p selecting the last candidate), as does C-x
;;; C-o; C-x C-f completes a file name and C-x C-n / C-x C-p words only, as
;;; in Vim. With completion-auto it also opens by itself after
;;; completion-delay of quiet: in completion-auto-modes once
;;; completion-auto-min characters of a word are typed (a source can ask
;;; for fewer), or after a / in a path; where a language server is
;;; attached, after a word character or one of its trigger characters.
;;;
;;; While it is open, other keys type as usual and narrow it: to the
;;; candidates that start with what's typed in a menu that opened by
;;; itself (language servers' excepted), to fuzzy matches in one you
;;; asked for. completion-keys picks how it takes keys:
;;;
;;;   vim    C-n C-p <tab> <s-tab> move, C-y accepts, <ret> accepts only
;;;          once something is selected, C-e closes (the default)
;;;   tab    <tab> accepts (the selected candidate, else the first),
;;;          C-n C-p <s-tab> move, <ret> is a new line
;;;   enter  <ret> accepts (the selected candidate, else the first),
;;;          <tab> <s-tab> C-n C-p move
;;;
;;; completion-menu-columns picks what each row shows, from icon, label,
;;; detail and source. The hot loops, the word index and filtering and
;;; ranking on each key, are Rust's (buffer-words, completion-store-*).
;;;
;;; A source of your own:
;;;
;;;   (define-completion-source! 'emoji
;;;     (lambda (manual? done)
;;;       (and (text-before-cursor-ends-with? ":")   ; does it apply here?
;;;            (begin (done (cursor) (list (completion-candidate "🙂"))) #t)))
;;;     'priority 10)

(define-option! 'completion-auto #t '())
(define-option! 'completion-auto-min 3 '())
;; Milliseconds of quiet before the menu opens by itself; 0 opens it
;; as soon as the key is drawn, as blink.cmp and nvim-cmp's local
;; sources do.
(define-option! 'completion-delay 0 '())
;; Major modes (and their children) where the menu opens by itself.
(define-option! 'completion-auto-modes '(prog-mode) '())
;; vim, tab or enter: see the top of complete.scm.
(define-option! 'completion-keys 'vim '())
;; What a menu row shows, in order, from: icon label detail source.
(define-option! 'completion-menu-columns '(icon label detail) '())
;; Where the words source looks: all (every file buffer) or current.
(define-option! 'completion-words-scope 'all '())
;; Characters besides letters, digits and _ that words are made of here
;; (Scheme buffers set their own, for names like set-option!).
(define-option! 'completion-word-chars "" '())

(define (completion-candidate text . detail)
  "A menu candidate that inserts `text`, shown with `detail` (a string)
   beside it if given."
  (list text (if (null? detail) "" (car detail)) text #f #f))

(define (word-start-before p)
  "Where the word ending at `p` starts, on `p`'s line; `p` if none does."
  (start-before p char-word?))

(define (start-before p word-char?)
  "Where the run of chars satisfying `word-char?` that ends at `p` starts,
   on `p`'s line; `p` if there is none."
  (let ([lo (line-start (offset->line p))])
    (let loop ([q p]) (if (and (> q lo) (word-char? (buffer-char-at (- q 1)))) (loop (- q 1)) q))))

(define (drop-while pred cs)
  "List `cs` without its leading items that satisfy `pred`."
  (if (and (pair? cs) (pred (car cs))) (drop-while pred (cdr cs)) cs))
(define (take-while pred cs)
  "The leading items of list `cs` that satisfy `pred`."
  (if (and (pair? cs) (pred (car cs))) (cons (car cs) (take-while pred (cdr cs))) '()))

(define (keyword-option options key default)
  "The value after `key` in the keyword list `options`, or `default`."
  (let loop ([o options])
    (cond [(or (null? o) (null? (cdr o))) default]
          [(eq? (car o) key) (cadr o)]
          [else (loop (cddr o))])))

;;; Sources

;; Each: (name procedure options), options a keyword list; in order.
(define *completion-sources* '())
;; Major mode -> its groups, as set-completion-sources! takes them.
(define *mode-completion-sources* (hash))

(define (define-completion-source! name proc . options)
  "Adds completion source `name`, replacing one of that name. `proc` is
   called as (proc manual? done): it returns #f if it has nothing for the
   text before the cursor, else #t, calling (done start candidates)
   then or later; `start` is where the text it completes begins.
   `manual?` is #t when asked by a key rather than as you type.

   done takes optional keywords after that: 'incomplete #t (ask again as
   more is typed), 'word-char? PRED (what the typed part is made of; its
   candidates go once something else is typed), 'on-accept PROC (called
   with the chosen candidate's item), 'fuzzy #t (fuzzy matches as you
   type, even in a menu that opened by itself).

   `options` are keywords too: 'priority N (higher ranks first among
   equally good matches; default 0), 'min-length N (characters of a word
   typed before it is asked as you type; default completion-auto-min),
   'auto PRED (called with the char just typed: #t asks it now whatever
   the mode or length, 'never keeps the menu shut, #f leaves it to the
   usual rules), 'exclusive #t (a group of its own, tried before the
   others), 'before OTHER (placed before source OTHER)."
  (let* ([others (filter (lambda (s) (not (eq? (car s) name))) *completion-sources*)]
         [before (keyword-option options 'before #f)]
         [entry (list name proc options)])
    (set! *completion-sources*
          (if (and before (assq before others))
              (let loop ([l others])
                (cond [(null? l) (list entry)]
                      [(eq? (car (car l)) before) (cons entry l)]
                      [else (cons (car l) (loop (cdr l)))]))
              (append others (list entry))))))

(define (source-option name key default)
  "Option `key` source `name` was defined with, or `default`."
  (let ([s (assq name *completion-sources*)])
    (if s (keyword-option (caddr s) key default) default)))

(define (default-completion-groups)
  "The groups buffers complete from unless their mode has its own: each
   'exclusive source alone, then all the others together."
  (let ([alone? (lambda (s) (keyword-option (caddr s) 'exclusive #f))])
    (append (map (lambda (s) (list (car s))) (filter alone? *completion-sources*))
            (list (map car (filter (lambda (s) (not (alone? s))) *completion-sources*))))))

(define (set-completion-sources! mode groups)
  "Makes buffers of major mode `mode` (and its children) complete from
   `groups`: a list whose items are source names or lists of them, each
   a group, tried in turn until one has candidates. '(file words) tries
   file then words; '((file words)) merges the two. #f restores the
   default."
  (set! *mode-completion-sources*
        (if groups
            (hash-insert *mode-completion-sources* mode groups)
            (hash-remove *mode-completion-sources* mode))))

(define (completion-groups-here)
  "The groups of source names the current buffer completes from."
  (let ([own (list-find (lambda (m) (hash-contains? *mode-completion-sources* m)) (mode-lineage (major-mode)))])
    (if own
        (map (lambda (g) (if (list? g) g (list g))) (hash-ref *mode-completion-sources* own))
        (default-completion-groups))))

;;; The sources that come with imp

(define (word-char-here? c)
  "Whether `c` is part of a word in this buffer: a letter, digit, _ or one
   of completion-word-chars."
  (or (char-word? c) (string-contains? (option 'completion-word-chars) (string c))))

(define (word-buffers)
  "The buffers the words source reads, current first: with
   completion-words-scope all, then every other file buffer."
  (let ([here (current-buffer)])
    (cons here
          (if (eq? (option 'completion-words-scope) 'all)
              (filter (lambda (id) (and (not (= id here)) (cadr (buffer-info id)))) (buffer-list))
              '()))))

(define-completion-source! 'words
  (lambda (manual? done)
    "Words from this buffer, nearest the cursor first, then from the other
     buffers, that complete the one before the cursor."
    (let* ([start (start-before (cursor) word-char-here?)]
           [words (buffer-words (word-buffers) (buffer-substring start (cursor))
                                (option 'completion-word-chars) (cursor) 500)])
      (done start (map (lambda (w) (list w "" w #f #f)) words) 'word-char? word-char-here?)
      #t)))

(define-completion-source! 'file
  (lambda (manual? done)
    "A path before the cursor: the entries of its directory."
    (let* ([start (start-before (cursor) path-char?)]
           [typed (buffer-substring start (cursor))])
      (and (path-like? typed)
           (let* ([slash (last-slash typed)]
                  [dir (if slash (substring typed 0 (+ slash 1)) "./")]
                  [entries (directory-entries (completion-dir dir))])
             (and (list? entries)
                  (begin
                    (done (+ start (if slash (+ slash 1) 0))
                          (map (lambda (e) (let ([name (if (cadr e) (string-append (car e) "/") (car e))])
                                             (list name (if (cadr e) "dir" "") name #f #f)))
                               (filter (lambda (e) (or (not (starts-with? (car e) "."))
                                                       (starts-with? (substring typed (if slash (+ slash 1) 0) (string-length typed)) ".")))
                                       entries))
                          'word-char? file-name-char?)
                    #t))))))
  'exclusive #t
  'before 'words
  'auto (lambda (c)
          (and (equal? c #\/) (auto-mode-here?)
               (path-like? (buffer-substring (start-before (cursor) path-char?) (cursor))))))

(define (completion-dir dir)
  "Directory `dir`, as typed, as a path to read: ~ expanded, and a
   relative one taken from the buffer's directory (the current directory
   for a buffer without a file)."
  (let ([d (expand-path dir)])
    (if (starts-with? d "/")
        d
        (string-append (if (buffer-path) (directory-of (absolute-path (buffer-path))) (current-dir)) "/" d))))

(define (path-char? c)
  "Whether `c` can be part of a path being typed."
  (or (char-word? c) (memv c '(#\/ #\. #\- #\~ #\+ #\@ #\%))))

(define (file-name-char? c)
  "Whether `c` can be part of a file name (not a /)."
  (and (path-char? c) (not (equal? c #\/))))

(define (path-like? text)
  "Whether `text` looks like a path being typed: it starts with ~/, ./,
   ../ or / and something after it, or has a / after a word; never with
   // in it (a comment, more likely)."
  (and (not (string-contains? text "//"))
       (not (equal? text "/"))
       (or (starts-with? text "~/") (starts-with? text "./") (starts-with? text "../")
           (starts-with? text "/")
           (and (last-slash text) (> (last-slash text) 0)))))

(define (last-slash text)
  "The index of the last / in `text`, or #f."
  (let loop ([i (- (string-length text) 1)])
    (cond [(< i 0) #f] [(equal? (string-ref text i) #\/) i] [else (loop (- i 1))])))

(define (scheme-symbol-char? c)
  "Whether `c` can be part of a Scheme name."
  (or (char-word? c) (memv c '(#\- #\! #\? #\* #\< #\> #\= #\/ #\+ #\: #\. #\%))))

;; Scheme buffers' words are names like set-option!.
(add-hook! 'major-mode
  (lambda (mode)
    (when (memq 'scheme-mode (mode-lineage mode))
      (set-local-option! 'completion-word-chars "-!?*<>=+:.%"))))

;; The scheme source's candidates, built again when the definitions
;; change: (definitions candidates).
(define *scheme-candidates* (list #f '()))

(define (scheme-candidates)
  "A candidate for every name imp defines, its docstring's first line
   beside it."
  (let ([names (all-definitions)])
    (unless (eq? names (car *scheme-candidates*))
      (let ([docs (doc-lines)])
        (set! *scheme-candidates*
              (list names (map (lambda (n) (list n (or (hash-try-get docs n) "") n #f #f)) names)))))
    (cadr *scheme-candidates*)))

(define-completion-source! 'scheme
  (lambda (manual? done)
    "In Scheme buffers: the names imp defines, with their docstrings'
     first lines."
    (and (memq 'scheme-mode (mode-lineage (major-mode)))
         (begin
           (done (start-before (cursor) scheme-symbol-char?) (scheme-candidates)
                 'word-char? scheme-symbol-char?)
           #t)))
  'priority 50
  'before 'words)

;;; The menu

;; Its sources' answers: source number -> (name start word-char? fuzzy?
;; incomplete? on-accept candidates), candidates a vector.
(define *menu-sources* (hash))
(define *menu-hits* '())        ; the candidates shown, as (candidate . source number)
(define *menu-matches* '())     ; the same candidates, without the numbers
(define *menu-index* -1)
(define *menu-open* #f)
(define *menu-auto* #f)         ; it opened by itself, as you typed
(define *menu-select* #f)       ; 'first or 'last: select it when the menu opens
(define *menu-request* 0)       ; answers to older requests are dropped
(define *complete-timer* #f)
(define *accepted-at* #f)  ; (buffer . cursor) just after accepting: don't reopen there

(define (menu-source-field n i)
  "Field `i` of what source number `n` answered (see *menu-sources*)."
  (list-ref (hash-ref *menu-sources* n) i))

(define (menu-source-name n)
  "The name of the menu's source number `n`."
  (menu-source-field n 0))

(define (menu-add! n name start candidates options)
  "Puts source `name`'s `candidates` in the menu as its number `n`, for
   the text from `start` to the cursor, replacing what it had; opens the
   menu if it isn't open."
  (let ([own-starts (if (list-find cadddr candidates)
                        (map (lambda (c) (or (cadddr c) start)) candidates)
                        '())])
    (completion-store-set! n (source-option name 'priority 0) (map car candidates) start own-starts)
    (set! *menu-sources*
          (hash-insert *menu-sources* n
                       (list name start
                             (keyword-option options 'word-char? char-word?)
                             (keyword-option options 'fuzzy #f)
                             (keyword-option options 'incomplete #f)
                             (keyword-option options 'on-accept #f)
                             (list->vector candidates))))
    (unless *menu-open*
      (set! *menu-open* #t)
      (set! *menu-index* -1)
      (set! *key-interceptor* menu-key!))
    (refilter-menu!)))

(define (menu-live-sources)
  "The menu's source numbers whose text still runs to the cursor: the
   cursor not before its start, on its line, after one of its word chars."
  (filter (lambda (n)
            (let ([start (menu-source-field n 1)] [word-char? (menu-source-field n 2)])
              (and (>= (cursor) start)
                   (= (offset->line (cursor)) (offset->line start))
                   (or (= (cursor) start) (word-char? (buffer-char-at (- (cursor) 1)))))))
          (hash-keys->list *menu-sources*)))

(define (menu-candidate n i)
  "Candidate `i` of the menu's source number `n`, its start filled in."
  (let ([c (vector-ref (menu-source-field n 6) i)])
    (if (cadddr c) c (list (car c) (cadr c) (caddr c) (menu-source-field n 1) (car (cddddr c))))))

(define (refilter-menu!)
  "Narrows the menu to what has been typed (the filtering and ranking are
   completion-store-filter's). Closes it when nothing matches, or only the
   text already typed does."
  (let* ([live (menu-live-sources)]
         [selected (and (>= *menu-index* 0) (< *menu-index* (length *menu-matches*))
                        (list-ref *menu-matches* *menu-index*))]
         [flat (if (null? live)
                   '()
                   (completion-store-filter *menu-auto* live (filter (lambda (n) (menu-source-field n 3)) live) 200))])
    (set! *menu-hits*
          (let loop ([f flat])
            (if (null? f) '() (cons (cons (menu-candidate (car f) (cadr f)) (car f)) (loop (cddr f))))))
    (set! *menu-matches* (map car *menu-hits*))
    (cond
      [(null? *menu-hits*) (close-menu!)]
      ;; Only the text already typed: nothing left to offer (unless its
      ;; source does more on accepting it, as a snippet expands).
      [(and (null? (cdr *menu-hits*))
            (not (menu-source-field (cdr (car *menu-hits*)) 5))
            (let ([c (car *menu-matches*)])
              (equal? (caddr c) (buffer-substring (min (cadddr c) (cursor)) (cursor)))))
       (close-menu!)]
      [else
       (set! *menu-index*
             (cond [(eq? *menu-select* 'first) 0]
                   [(eq? *menu-select* 'last) (- (length *menu-hits*) 1)]
                   [selected (let loop ([h *menu-matches*] [i 0])
                               (cond [(null? h) (min *menu-index* (- (length *menu-hits*) 1))]
                                     [(equal? (car h) selected) i]
                                     [else (loop (cdr h) (+ i 1))]))]
                   [else -1]))
       (set! *menu-select* #f)
       (draw-menu!)])))

(define (menu-rows)
  "How many rows the completion menu shows: up to 10, to fit the window."
  (max 1 (min 10 (- (window-height) 2))))

;; (lambda (source candidate)) -> a short string (an icon) drawn before a
;; candidate from `source` (its name: 'lsp, 'file...), or #f. The
;; nerd-icons package sets it.
(define *menu-icon* (lambda (source candidate) #f))

(define (menu-line hit width)
  "A menu row for `hit` (candidate . source number), its columns as
   completion-menu-columns says, the label padded to `width`."
  (let ([c (car hit)] [source (menu-source-name (cdr hit))])
    (filter (lambda (part) part)
            (map (lambda (column)
                   (case column
                     [(icon) (let ([icon (*menu-icon* source c)]) (and icon (list (string-append icon " ") "")))]
                     [(label) (list (pad-right (car c) width) "")]
                     [(detail) (and (not (equal? (cadr c) "")) (list (string-append "  " (clip (cadr c) 40)) "popup.detail"))]
                     [(source) (list (string-append "  [" (symbol->string source) "]") "popup.detail")]
                     [else #f]))
                 (option 'completion-menu-columns)))))

(define *menu-width* 0)  ; the widest the open menu has been

(define (pad-menu-lines lines)
  "`lines` (menu rows, lists of (text face)) padded to the widest the
   open menu has been, so it doesn't narrow and widen as you type."
  (let* ([row-width (lambda (line) (apply + (map (lambda (part) (string-length (car part))) line)))]
         [widest (apply max (cons *menu-width* (map row-width lines)))])
    (set! *menu-width* widest)
    (map (lambda (line)
           (let ([pad (- widest (row-width line))])
             (if (> pad 0) (append line (list (list (make-string pad #\space) ""))) line)))
         lines)))

(define (draw-menu!)
  "Draws the completion menu at the cursor, scrolled to the selection,
   its labels lined up with the text they complete."
  (let* ([n (length *menu-hits*)] [rows (menu-rows)]
         [i (max *menu-index* 0)]
         [top (max 0 (min (- i (- rows 1)) (- n rows)))]
         [top (max 0 (min top i))]
         [shown (take (list-tail *menu-hits* top) (min rows (- n top)))]
         [width (min 30 (apply max (cons 1 (map (lambda (h) (string-length (car (car h)))) shown))))]
         [start (cadddr (car (list-ref *menu-hits* i)))]
         [icon (and (eq? (car (option 'completion-menu-columns)) 'icon)
                    (*menu-icon* (menu-source-name (cdr (car shown))) (car (car shown))))])
    (set-popup! (pad-menu-lines (map (lambda (h) (menu-line h width)) shown)))
    (set-popup-place! "cursor" (- -1 (- (cursor) start) (if icon (+ 1 (string-length icon)) 0)) "")
    (set-popup-selected! (if (< *menu-index* 0) -1 (- *menu-index* top)))))

(define (close-menu!)
  "Closes the completion menu, if it is open, and gives the keys back."
  (when *menu-open*
    (set! *menu-open* #f)
    (set! *menu-width* 0)
    (set! *menu-hits* '())
    (set! *menu-matches* '())
    (set! *menu-sources* (hash))
    (completion-store-clear!)
    (set-popup! '())
    (set-popup-selected! -1)
    (when (eq? *key-interceptor* menu-key!) (set! *key-interceptor* #f))))

(define (move-menu! step)
  "Moves the menu's selection by `step`, wrapping around.
   With nothing selected, a step forward selects the first and one back
   the last."
  (let ([n (length *menu-hits*)])
    (when (> n 0)
      (set! *menu-index* (if (< *menu-index* 0)
                             (if (> step 0) 0 (- n 1))
                             (modulo (+ *menu-index* step) n)))
      (draw-menu!))))

(define (accept-candidate! hit)
  "Replaces the typed text with `hit`'s candidate, as if typed, so .
   repeats it; then lets its source finish (a server's extra edits, say).
   A directory's name ending in / asks again for what's in it."
  (let* ([c (car hit)] [n (cdr hit)]
         [start (min (cadddr c) (cursor))] [old (buffer-substring start (cursor))] [text (caddr c)]
         [item (car (cddddr c))] [on-accept (menu-source-field n 5)] [source (menu-source-name n)])
    (close-menu!)
    (buffer-delete! start (cursor))
    (set-cursor! start)
    (insert-text! text)
    (set! *insert-keys* (append (reverse (map string (string->list text)))
                                (map (lambda (ch) "<bs>") (string->list old))
                                *insert-keys*))
    (when on-accept (on-accept item))
    ;; What went in ends in a word, which would open the menu again.
    (set! *accepted-at* (cons (current-buffer) (cursor)))
    (when (and (eq? source 'file) (ends-with? text "/"))
      (complete-with! 'file #f))))

(define (menu-key-action key)
  "What `key` does in the open menu under completion-keys: 'next,
   'previous, 'accept (the selected candidate or the first),
   'accept-selected, 'close, or #f to type it."
  (let ([preset (option 'completion-keys)])
    (cond
      [(member key '("C-n" "<down>")) 'next]
      [(member key '("C-p" "<up>" "<s-tab>")) 'previous]
      [(equal? key "C-y") 'accept]
      [(equal? key "C-e") 'close]
      [(equal? key "<tab>") (if (eq? preset 'tab) 'accept 'next)]
      [(member key '("<ret>" "C-m"))
       (case preset [(enter) 'accept] [(tab) #f] [else 'accept-selected])]
      [else #f])))

(define (menu-key! key)
  "Handles `key` while the completion menu is open: moves, accepts or
   closes it as completion-keys says; other keys type as usual and narrow
   the menu (asking sources again whose lists were incomplete, or for a
   new directory after a /). Leaving insert state closes it."
  (let ([action (and (memq *mode* '(insert replace)) (menu-key-action key))])
    (cond
      [(not (memq *mode* '(insert replace))) (close-menu!) (handle-key! key)]
      [(eq? action 'next) (move-menu! 1)]
      [(eq? action 'previous) (move-menu! -1)]
      [(eq? action 'accept) (accept-candidate! (list-ref *menu-hits* (max 0 *menu-index*)))]
      [(and (eq? action 'accept-selected) (>= *menu-index* 0))
       (accept-candidate! (list-ref *menu-hits* *menu-index*))]
      [(eq? action 'close) (close-menu!)]
      [(member key '("<esc>" "C-c" "<ret>" "C-m")) (close-menu!) (handle-key! key)]
      [(and (equal? key "/") (memq 'file (map menu-source-name (menu-live-sources))))
       (close-menu!) (handle-key! key) (complete-with! 'file #f)]
      [else
       (handle-key! key)
       (when *menu-open* (refilter-menu!))
       (when (and *menu-open* (list-find (lambda (n) (menu-source-field n 4)) (menu-live-sources)))
         (schedule-completion! #t))])))

;;; Asking the sources

(define (typed-word-length)
  "How many characters of a word are typed before the cursor."
  (- (cursor) (start-before (cursor) word-char-here?)))

(define (auto-mode-here?)
  "Whether the current buffer's mode is one of completion-auto-modes."
  (list-find (lambda (m) (memq m (option 'completion-auto-modes))) (mode-lineage (major-mode))))

(define (source-auto name c)
  "What source `name`'s 'auto rule says of char `c` just typed: #t,
   'never or #f."
  (let ([rule (source-option name 'auto #f)])
    (and rule c (rule c))))

(define (ask-now? name manual?)
  "Whether to ask source `name` now: always when asked by a key; as you
   type, if its 'auto rule says so, or in completion-auto-modes once its
   min-length of a word is typed."
  (or manual?
      (let ([c (and (> (cursor) 0) (buffer-char-at (- (cursor) 1)))])
        (or (eq? (source-auto name c) #t)
            (and c (auto-mode-here?) (word-char-here? c)
                 (>= (typed-word-length) (source-option name 'min-length (option 'completion-auto-min))))))))

(define (source-number name)
  "The number source `name` goes by in the menu: its place in
   *completion-sources*."
  (let loop ([s *completion-sources*] [i 0])
    (cond [(null? s) 0] [(eq? (car (car s)) name) i] [else (loop (cdr s) (+ i 1))])))

(define (run-source! name manual? request on-answer)
  "Asks source `name` for candidates at the cursor and returns what it
   does (#f for nothing to offer). Its answer goes in the menu if the
   request is still current and the cursor where it can use it;
   `on-answer` is called after."
  (let ([entry (assq name *completion-sources*)] [id (current-buffer)])
    (and entry
         ((cadr entry) manual?
                       (lambda (start candidates . options)
                         (when (and (= request *menu-request*) (= id (current-buffer))
                                    (memq *mode* '(insert replace)) (>= (cursor) start))
                           (unless (null? candidates)
                             (menu-add! (source-number name) name start candidates options))
                           (on-answer)))))))

(define (run-groups! groups manual? request)
  "Asks the sources of the first of `groups` (lists of source names);
   once they have all answered, if the menu is still shut, the next
   group. Says so when none has anything and `manual?`."
  (if (null? groups)
      (when manual? (message "no completions"))
      (let* ([names (filter (lambda (name) (ask-now? name manual?)) (car groups))]
             [waiting names]
             [answered! (lambda (name)
                          (when (memq name waiting)
                            (set! waiting (filter (lambda (w) (not (eq? w name))) waiting))
                            (when (and (null? waiting) (not *menu-open*) (= request *menu-request*))
                              (run-groups! (cdr groups) manual? request))))])
        (if (null? names)
            (run-groups! (cdr groups) manual? request)
            (for-each (lambda (name)
                        (unless (run-source! name manual? request (lambda () (answered! name)))
                          (answered! name)))
                      names)))))

(define (complete-from! groups manual? select-last?)
  "Opens the menu from `groups` of sources. `manual?` selects the first
   candidate (the last with `select-last?`) and says so when there are
   none; otherwise the menu opened by itself."
  (close-menu!)
  (set! *menu-request* (+ *menu-request* 1))
  (set! *menu-auto* (not manual?))
  (set! *menu-select* (and manual? (if select-last? 'last 'first)))
  (run-groups! groups manual? *menu-request*))

(define (complete-at-point! manual? . select-last)
  "Opens the menu from this buffer's completion sources."
  (complete-from! (completion-groups-here) manual? (and (pair? select-last) (car select-last))))

(define (complete-with! name manual? . select-last)
  "Opens the menu from completion source `name` only."
  (complete-from! (list (list name)) manual? (and (pair? select-last) (car select-last))))

(define (refresh-incomplete!)
  "Asks the open menu's sources whose lists were incomplete again, for
   what is typed now."
  (for-each (lambda (n)
              (when (menu-source-field n 4)
                (run-source! (menu-source-name n) (not *menu-auto*) *menu-request* (lambda () #f))))
            (menu-live-sources)))

(define (complete-command step)
  "The insert key C-n (`step` 1) or C-p (-1): completes the text before
   the cursor, C-p selecting the last candidate."
  (lambda () (complete-at-point! #t (< step 0))))

(define-key! 'insert "C-n" (complete-command 1))
(define-key! 'insert "C-p" (complete-command -1))

;; C-x starts Vim's completion keys: C-x C-o completes at point, C-x C-f
;; file names, C-x C-n and C-x C-p words. The key after C-x isn't typed.
(define-key! 'insert "C-x"
  (lambda ()
    (set! *key-interceptor*
          (lambda (key)
            (set! *key-interceptor* #f)
            (cond [(equal? key "C-o") (complete-at-point! #t)]
                  [(equal? key "C-f") (complete-with! 'file #t)]
                  [(equal? key "C-n") (complete-with! 'words #t)]
                  [(equal? key "C-p") (complete-with! 'words #t #t)]
                  [else (handle-key! key)])))))

;;; Completing as you type

(define (schedule-completion! refresh?)
  "Completes at point after completion-delay of quiet, if the cursor
   hasn't moved and no menu is open; `refresh?` asks an open menu's
   incomplete sources again instead."
  (when *complete-timer* (cancel-timer! *complete-timer*))
  (let ([id (current-buffer)] [at (cursor)])
    (set! *complete-timer*
          (run-after! (option 'completion-delay)
                      (lambda ()
                        (set! *complete-timer* #f)
                        (when (and (= id (current-buffer)) (= at (cursor)) (eq? *mode* 'insert)
                                   (if refresh? *menu-open* (not (or *menu-open* *key-interceptor*))))
                          (if refresh?
                              (refresh-incomplete!)
                              (complete-at-point! #f))))))))

(define (auto-complete-char? c)
  "Whether `c`, just typed, should open the menu after a pause: when a
   source here would be asked (see ask-now?), unless one says 'never."
  (let ([names (apply append (completion-groups-here))])
    (and (not (list-find (lambda (name) (eq? (source-auto name c) 'never)) names))
         (list-find (lambda (name) (ask-now? name #f)) names))))

(add-hook! 'after-change
           (lambda ()
             (when (and (eq? *mode* 'insert) (option 'completion-auto) (not *menu-open*) (> (cursor) 0)
                        (not (equal? *accepted-at* (cons (current-buffer) (cursor))))
                        (auto-complete-char? (buffer-char-at (- (cursor) 1))))
               (schedule-completion! #f))
             (set! *accepted-at* #f)))

(add-hook! 'insert-leave (lambda () (close-menu!)))

;;; Completing on the command line
;;;
;;; On the : line, the same menu (above the line) completes the command's
;;; name and then its argument, from the completions define-ex-completion!
;;; gives (files for :e, buffers for :b, options for :set, with their
;;; docs...); after / and ?, words from the buffer. It opens by itself as
;;; you type (cmdline-completion-auto), or with <tab>. <tab> and C-n, or
;;; <s-tab> and C-p, step through it putting each in the line; C-y keeps
;;; the one chosen and closes it, C-e puts back what was typed. With
;;; cmdline-completion off, <tab> is Vim's wildmenu instead.

(define-option! 'cmdline-completion #t '())
(define-option! 'cmdline-completion-auto #t '())

(define *cmd-open* #f)
(define *cmd-start* 0)          ; where the completed text starts in the line
(define *cmd-labels* (vector))  ; the candidates, and their docs
(define *cmd-details* (vector))
(define *cmd-hits* '())         ; the matching candidates' indices, best first
(define *cmd-index* -1)         ; the one put in the line, -1 for none
(define *cmd-typed* "")         ; what was typed before stepping through them
(define *cmd-manual* #f)        ; opened with <tab>: fuzzy matching
(define *cmd-editing* #f)       ; the menu is editing the line itself

(define (cmdline-context text)
  "What the menu completes in `text`, the command line up to the cursor:
   (start candidates details), or #f."
  (cond
    [(equal? *cmdline-prompt* ":")
     (let ([ctx (ex-completion-context text)])
       (and ctx (pair? (cadr ctx))
            (let ([docs (doc-lines)])
              (list (car ctx) (cadr ctx)
                    (map (lambda (c)
                           (or (hash-try-get docs c)
                               (and (starts-with? c "no") (hash-try-get docs (substring c 2 (string-length c))))
                               ""))
                         (cadr ctx))))))]
    [(member *cmdline-prompt* '("/" "?"))
     (let* ([start (let loop ([i (string-length text)])
                     (if (and (> i 0) (char-word? (string-ref text (- i 1)))) (loop (- i 1)) i))]
            [word (substring text start (string-length text))]
            [words (if (equal? word "") '() (buffer-words (list (current-buffer)) word "" (- -1 (cursor)) 200))])
       (and (pair? words) (list start words (map (lambda (w) "") words))))]
    [else #f]))

(define (cmd-close!)
  "Closes the command line's menu."
  (when *cmd-open*
    (set! *cmd-open* #f)
    (set! *cmd-hits* '())
    (set! *cmd-index* -1)
    (set-popup! '())
    (set-popup-selected! -1)))

(define (cmd-refresh! manual?)
  "Fills the command line's menu for what is typed before the cursor, or
   closes it when nothing matches (or only what is already typed)."
  (let* ([text (cmdline-before)] [ctx (cmdline-context text)])
    (if (not ctx)
        (cmd-close!)
        (let* ([start (car ctx)] [typed (substring text start (string-length text))])
          (cmdline-store-set! (cadr ctx))
          (set! *cmd-labels* (list->vector (cadr ctx)))
          (set! *cmd-details* (list->vector (caddr ctx)))
          (set! *cmd-start* start)
          (set! *cmd-manual* manual?)
          (set! *cmd-typed* typed)
          (set! *cmd-index* -1)
          (set! *cmd-hits* (let loop ([f (cmdline-store-filter typed (not manual?) 200)])
                             (if (null? f) '() (cons (cadr f) (loop (cddr f))))))
          (if (or (null? *cmd-hits*)
                  (and (null? (cdr *cmd-hits*)) (equal? (vector-ref *cmd-labels* (car *cmd-hits*)) typed)))
              (cmd-close!)
              (begin (set! *cmd-open* #t) (cmd-draw!)))))))

(define (cmd-draw!)
  "Draws the command line's menu above the line, scrolled to the one
   chosen: a path's last part, then its doc dimmed."
  (let* ([n (length *cmd-hits*)] [rows (min 10 n)]
         [i (max *cmd-index* 0)]
         [top (max 0 (min (- i (- rows 1)) (- n rows)))]
         [shown (take (list-tail *cmd-hits* top) rows)]
         [label (lambda (k) (wild-label (vector-ref *cmd-labels* k)))]
         [width (min 40 (apply max (cons 1 (map (lambda (k) (string-length (label k))) shown))))]
         [icon (lambda (k) (*menu-icon* (if (member *cmdline-prompt* '("/" "?")) 'words 'cmdline)
                                        (list (vector-ref *cmd-labels* k) "" "" 0 #f)))])
    (set-popup-place! "bottom" 0 "")
    (set-popup! (map (lambda (k)
                       (let ([detail (vector-ref *cmd-details* k)] [ic (icon k)])
                         (list (list (string-append " " (if ic (string-append ic " ") "") (pad-right (label k) width)) "")
                               (list (if (equal? detail "") "" (string-append "  " (clip detail 60))) "popup.detail"))))
                     shown))
    (set-popup-selected! (if (< *cmd-index* 0) -1 (- *cmd-index* top)))))

(define (cmd-put! text)
  "Puts `text` in the line in place of what the menu completes."
  (set! *cmd-editing* #t)
  (cmdline-edit! (string-append (substring *cmdline* 0 *cmd-start*) text (cmdline-after))
                 (+ *cmd-start* (string-length text)))
  (set! *cmd-editing* #f))

(define (cmd-select! step)
  "Steps `step` through the menu, putting the one chosen in the line."
  (let ([n (length *cmd-hits*)])
    (set! *cmd-index* (if (< *cmd-index* 0)
                          (if (> step 0) 0 (- n 1))
                          (modulo (+ *cmd-index* step) n)))
    (cmd-put! (vector-ref *cmd-labels* (list-ref *cmd-hits* *cmd-index*)))
    (cmd-draw!)))

(define (cmd-auto?)
  "Whether the menu should open by itself for what is typed: on the :
   line once a command's name is begun, or at its argument; after / or ?
   once 3 characters of a word are typed."
  (let* ([text (cmdline-before)] [ctx (and (option 'cmdline-completion-auto) (cmdline-context text))])
    (and ctx
         (let ([typed (substring text (car ctx) (string-length text))])
           (if (equal? *cmdline-prompt* ":")
               (or (> (string-length typed) 0)
                   (and (> (car ctx) 0) (char-whitespace? (string-ref text (- (car ctx) 1)))))
               (>= (string-length typed) 3))))))

(set! *cmdline-completer*
      (lambda (event arg)
        (and (option 'cmdline-completion)
             (member *cmdline-prompt* '(":" "/" "?"))
             (cond
               [(eq? event 'close) (cmd-close!) #f]
               [(eq? event 'edit)
                (unless *cmd-editing*
                  (cond [*cmd-open* (cmd-refresh! *cmd-manual*)]
                        [(cmd-auto?) (cmd-refresh! #f)]))
                #f]
               [(not (eq? event 'key)) #f]
               [*cmd-open*
                (cond [(member arg '("<tab>" "C-n")) (cmd-select! 1) #t]
                      [(member arg '("<s-tab>" "C-p")) (cmd-select! -1) #t]
                      [(equal? arg "C-y") (cmd-close!) #t]
                      [(equal? arg "C-e") (let ([typed *cmd-typed*]) (cmd-close!) (cmd-put! typed)) #t]
                      [else #f])]
               [(member arg '("<tab>" "<s-tab>"))
                (cmd-refresh! #t)
                (cond [(not *cmd-open*) (set-status! "no completions")]
                      [(null? (cdr *cmd-hits*))
                       ;; The only one: put it in, and go on into a directory.
                       (cmd-put! (vector-ref *cmd-labels* (car *cmd-hits*)))
                       (cmd-close!)
                       (when (ends-with? (cmdline-before) "/") (cmd-refresh! #f))]
                      [else (cmd-select! (if (equal? arg "<tab>") 1 -1))])
                #t]
               [else #f]))))
