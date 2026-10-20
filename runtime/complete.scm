;;; complete.scm -- completion at point, in insert state.
;;;
;;; A menu of candidates in a box at the cursor, filled by the first
;;; completion source that has something for the text before the cursor
;;; (as Emacs's completion-at-point-functions). The sources, in order:
;;;
;;;   file     a path being typed (~/, ./, ../, /, or a word with a /)
;;;   lsp      the language server, when the buffer has one (lsp.scm)
;;;   scheme   in Scheme buffers, the names imp defines, with their docs
;;;   words    words from this buffer, then from the other buffers
;;;
;;; C-n and C-p open it (C-p selecting the last candidate), as does C-x
;;; C-o; C-x C-f completes a file name and C-x C-n / C-x C-p words only, as
;;; in Vim. With completion-auto it also opens by itself after a pause:
;;; where a language server is attached, after a word character or one of
;;; its trigger characters; elsewhere in programming modes once
;;; completion-auto-min characters of a word are typed, or after a / in a
;;; path. While it is open: C-n C-p <tab> <s-tab> <down> <up> move, C-y or
;;; <ret> accepts (<ret> only once something is selected in a menu that
;;; opened by itself), C-e closes it; other keys type as usual and narrow
;;; it.
;;;
;;; A source of your own:
;;;
;;;   (define-completion-source! 'emoji
;;;     (lambda (manual? done)
;;;       (and (text-before-cursor-ends-with? ":")   ; does it apply here?
;;;            (begin (done (cursor) (list (completion-candidate "🙂"))) #t))))

(define-option! 'completion-auto #t '())
(define-option! 'completion-auto-min 3 '())
(define-option! 'completion-delay 150 '())

;; Each candidate: (label detail text start item), `text` being what to
;; insert from offset `start` to the cursor; `item` is the source's own.
(define *menu-candidates* '())
(define *menu-matches* '())
(define *menu-index* -1)
(define *menu-start* 0)        ; where the typed part starts
(define *menu-open* #f)
(define *menu-source* #f)      ; the source the candidates came from
(define *menu-incomplete* #f)  ; the source has more: ask again as you type
(define *menu-word-char?* char-word?) ; what the typed part is made of
(define *menu-on-accept* #f)   ; (lambda (item)) after a candidate goes in
(define *complete-timer* #f)
(define *complete-request* 0)  ; answers to older requests are dropped
(define *completion-sources* '())  ; (name procedure), tried in order

(define (completion-candidate text . detail)
  "A menu candidate that inserts `text`, shown with `detail` (a string)
   beside it if given."
  (list text (if (null? detail) "" (car detail)) text #f #f))

(define (define-completion-source! name proc . where)
  "Adds completion source `name`, replacing one of that name. `proc` is
   called as (proc manual? done): it returns #f if it has nothing for the
   text before the cursor, else #t, calling (done start candidates)
   then or later; `start` is where the text it completes begins. done
   takes optional keywords after that: 'incomplete #t (ask again as more
   is typed), 'word-char? PRED (what the typed part is made of; the menu
   closes on anything else), 'on-accept PROC (called with the chosen
   candidate's item). `manual?` is #t when asked by a key rather than as
   you type. It goes last, or (define-completion-source! name proc
   'before 'words) before another."
  (let* ([others (filter (lambda (s) (not (eq? (car s) name))) *completion-sources*)]
         [before (and (pair? where) (eq? (car where) 'before) (cadr where))]
         [entry (list name proc)])
    (set! *completion-sources*
          (if (and before (assq before others))
              (let loop ([l others])
                (cond [(null? l) (list entry)]
                      [(eq? (car (car l)) before) (cons entry l)]
                      [else (cons (car l) (loop (cdr l)))]))
              (append others (list entry))))))

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

;;; The sources that come with imp

(define (words-in-range prefix start lo hi seen)
  "The words from offset `lo` to `hi` of the current buffer that start
   with `prefix`, top to bottom, leaving out those in hash `seen` and the
   one being typed at `start`; returns (words seen)."
  (let loop ([p lo] [words '()] [seen seen])
    (if (>= p hi)
        (list (reverse words) seen)
        (if (char-word? (buffer-char-at p))
            (let* ([e (let run ([q p]) (if (and (< q hi) (char-word? (buffer-char-at q))) (run (+ q 1)) q))]
                   [w (buffer-substring p e)])
              (if (and (starts-with? w prefix) (not (hash-contains? seen w)) (not (= p start)))
                  (loop e (cons w words) (hash-insert seen w #t))
                  (loop e words seen)))
            (loop (+ p 1) words seen)))))

(define (buffer-word-candidates start . everywhere)
  "Candidates for completing the word from `start` to the cursor: the
   words that start with it in the 500 lines around the cursor, top to
   bottom; with `everywhere` #t, then those in the other file buffers
   (their first 2000 lines), which takes longer."
  (let* ([prefix (buffer-substring start (cursor))]
         [line (current-line)]
         [here (words-in-range prefix start (line-start (max 0 (- line 500)))
                               (line-end (min (last-line) (+ line 500))) (hash prefix #t))]
         [buf (current-buffer)]
         [others (foldl (lambda (id acc)
                          (if (or (= id buf) (not (buffer-path-of id))
                                  (not (and (pair? everywhere) (car everywhere))))
                              acc
                              (with-buffer id
                                (lambda ()
                                  (let ([r (words-in-range prefix -1 0 (line-end (min (last-line) 2000)) (cadr acc))])
                                    (list (append (car acc) (car r)) (cadr r)))))))
                        (list '() (cadr here)) (buffer-list))])
    (map (lambda (w) (list w "" w start #f)) (append (car here) (car others)))))

(define (buffer-path-of id)
  "The file of buffer `id`, or #f: only file buffers lend their words."
  (cadr (buffer-info id)))

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
                    #t)))))))

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

(define-completion-source! 'scheme
  (lambda (manual? done)
    "In Scheme buffers: the names imp defines, with their docstrings'
     first lines, then words from the buffers."
    (and (memq 'scheme-mode (mode-lineage (major-mode)))
         (let* ([start (start-before (cursor) scheme-symbol-char?)]
                [typed (buffer-substring start (cursor))]
                [docs (doc-lines)]
                [names (filter (lambda (n) (starts-with? n typed)) (all-definitions))]
                [seen (foldl (lambda (n h) (hash-insert h n #t)) (hash) names)]
                [words (filter (lambda (c) (not (hash-contains? seen (car c))))
                               (buffer-word-candidates (word-start-before (cursor)) manual?))])
           (done start
                 (append (map (lambda (n) (list n (or (hash-try-get docs n) "") n start #f)) names)
                         (filter (lambda (c) (= (cadddr c) start)) words))
                 'word-char? scheme-symbol-char?)
           #t))))

(define-completion-source! 'words
  (lambda (manual? done)
    "Words from this buffer, then the other buffers, that complete the
     one before the cursor."
    (let ([start (word-start-before (cursor))])
      (done start (buffer-word-candidates start manual?))
      #t)))

;;; The menu

(define (menu-rows)
  "How many rows the completion menu shows: up to 10, to fit the window."
  (max 1 (min 10 (- (window-height) 2))))

;; (lambda (source candidate)) -> a short string (an icon) drawn before a
;; candidate from `source` (its name: 'lsp, 'file...), or #f. The
;; nerd-icons package sets it.
(define *menu-icon* (lambda (source candidate) #f))

(define (menu-line c width)
  "A menu row for candidate `c`: its icon if any, the label, then its
   detail dimmed."
  (let ([detail (cadr c)] [icon (*menu-icon* *menu-source* c)])
    (list (list (string-append (if icon (string-append icon " ") "") (pad-right (car c) width)) "")
          (list (if (equal? detail "") "" (string-append "  " (clip detail 40))) "popup.detail"))))

(define (draw-menu!)
  "Draws the completion menu at the cursor, scrolled to the selection."
  (let* ([n (length *menu-matches*)] [rows (menu-rows)]
         [i (max *menu-index* 0)]
         [top (max 0 (min (- i (- rows 1)) (- n rows)))]
         [top (max 0 (min top i))]
         [shown (take (list-tail *menu-matches* top) (min rows (- n top)))])
    (let ([width (min 30 (apply max (cons 1 (map (lambda (c) (string-length (car c))) shown))))])
      (set-popup! (map (lambda (c) (menu-line c width)) shown)))
    ;; In a box at the cursor, its labels lined up with the text typed.
    (set-popup-place! "cursor" (- -1 (- (cursor) *menu-start*)) "")
    (set-popup-selected! (if (< *menu-index* 0) -1 (- *menu-index* top)))))

(define (refilter-menu!)
  "Narrows the menu to what has been typed since it opened.
   Closes it when nothing matches or the cursor left the text."
  (if (or (< (cursor) *menu-start*)
          (not (= (offset->line (cursor)) (offset->line *menu-start*)))
          (and (> (cursor) *menu-start*) (not (*menu-word-char?* (buffer-char-at (- (cursor) 1))))))
      (close-menu!)
      (let* ([typed (buffer-substring *menu-start* (cursor))]
             [labels (map car *menu-candidates*)]
             [by-label (foldl (lambda (c h) (if (hash-contains? h (car c)) h (hash-insert h (car c) c)))
                              (hash) *menu-candidates*)]
             [hits (fuzzy-filter typed labels 200)])
        (set! *menu-matches* (map (lambda (l) (hash-ref by-label l)) hits))
        (cond [(null? *menu-matches*) (close-menu!)]
              ;; Only the text already typed: nothing left to offer.
              [(and (null? (cdr *menu-matches*)) (equal? (caddr (car *menu-matches*)) typed)
                    (= (cadddr (car *menu-matches*)) *menu-start*))
               (close-menu!)]
              [else
               (set! *menu-index* (if (< *menu-index* 0) -1 (min *menu-index* (- (length *menu-matches*) 1))))
               (draw-menu!)]))))

(define (open-menu! candidates start select?)
  "Opens the completion menu on `candidates` for the text at `start`.
   It takes the keys while open. `select?` selects the first candidate
   and says so when there are none."
  ;; A candidate without its own start replaces from `start`.
  (set! *menu-candidates*
        (map (lambda (c) (if (cadddr c) c (list (car c) (cadr c) (caddr c) start (car (cddddr c)))))
             candidates))
  (set! *menu-start* start)
  (set! *menu-index* (if select? 0 -1))
  (set! *menu-open* #t)
  (set! *key-interceptor* menu-key!)
  (refilter-menu!)
  (when (and select? (not *menu-open*)) (message "no completions")))

(define (close-menu!)
  "Closes the completion menu, if it is open, and gives the keys back."
  (when *menu-open*
    (set! *menu-open* #f)
    (set! *menu-matches* '())
    (set-popup! '())
    (set-popup-selected! -1)
    (when (eq? *key-interceptor* menu-key!) (set! *key-interceptor* #f))))

(define (move-menu! step)
  "Moves the menu's selection by `step`, wrapping around.
   With nothing selected, a step forward selects the first and one back
   the last."
  (let ([n (length *menu-matches*)])
    (when (> n 0)
      (set! *menu-index* (if (< *menu-index* 0)
                             (if (> step 0) 0 (- n 1))
                             (modulo (+ *menu-index* step) n)))
      (draw-menu!))))

(define (accept-candidate! c)
  "Replaces the typed text with candidate `c`, as if typed, so . repeats
   it; then lets the source finish (a server's extra edits, say). A
   directory's name ending in / asks again for what's in it."
  (let* ([start (min (cadddr c) (cursor))] [old (buffer-substring start (cursor))] [text (caddr c)]
         [item (car (cddddr c))] [on-accept *menu-on-accept*] [source *menu-source*])
    (close-menu!)
    (buffer-delete! start (cursor))
    (set-cursor! start)
    (insert-text! text)
    (set! *insert-keys* (append (reverse (map string (string->list text)))
                                (map (lambda (ch) "<bs>") (string->list old))
                                *insert-keys*))
    (when on-accept (on-accept item))
    (when (and (eq? source 'file) (ends-with? text "/"))
      (complete-with! 'file #f))))

(define (menu-key! key)
  "Handles `key` while the completion menu is open.
   Moves, accepts or closes it; other keys type as usual and narrow the
   menu (asking the source again if its list was incomplete, or for a
   new directory after a /). Leaving insert state closes it."
  (cond
    [(not (memq *mode* '(insert replace))) (close-menu!) (handle-key! key)]
    [(member key '("C-n" "<down>" "<tab>")) (move-menu! 1)]
    [(member key '("C-p" "<up>" "<s-tab>")) (move-menu! -1)]
    [(equal? key "C-y") (accept-candidate! (list-ref *menu-matches* (max 0 *menu-index*)))]
    [(and (member key '("<ret>" "C-m")) (>= *menu-index* 0))
     (accept-candidate! (list-ref *menu-matches* *menu-index*))]
    [(equal? key "C-e") (close-menu!)]
    [(member key '("<esc>" "C-c" "<ret>" "C-m")) (close-menu!) (handle-key! key)]
    [(and (equal? key "/") (eq? *menu-source* 'file))
     (close-menu!) (handle-key! key) (complete-with! 'file #f)]
    [else
     (handle-key! key)
     (when *menu-open* (refilter-menu!))
     (when (and *menu-open* *menu-incomplete*) (schedule-completion! #t))]))

;;; Asking the sources

(define (done-option options key default)
  "The value after `key` in the keyword list `options`, or `default`."
  (let loop ([o options])
    (cond [(or (null? o) (null? (cdr o))) default]
          [(eq? (car o) key) (cadr o)]
          [else (loop (cddr o))])))

(define (run-source! entry manual? select-last?)
  "Asks completion source `entry` (name procedure) for candidates at the
   cursor; returns what it does (#f for nothing to offer). Its answer
   opens the menu if the cursor is still where it asked."
  (set! *complete-request* (+ *complete-request* 1))
  (let ([request *complete-request*] [id (current-buffer)] [at (cursor)] [was-open *menu-open*]
        [selected (and *menu-open* (>= *menu-index* 0))])
    ((cadr entry) manual?
                  (lambda (start candidates . options)
                    (when (and (= request *complete-request*) (= id (current-buffer))
                               (memq *mode* '(insert replace)) (>= (cursor) start))
                      (set! *menu-source* (car entry))
                      (set! *menu-incomplete* (done-option options 'incomplete #f))
                      (set! *menu-word-char?* (done-option options 'word-char? char-word?))
                      (set! *menu-on-accept* (done-option options 'on-accept #f))
                      (open-menu! candidates start (or manual? selected))
                      (when (and *menu-open* select-last?)
                        (set! *menu-index* (- (length *menu-matches*) 1))
                        (draw-menu!)))))))

(define (complete-at-point! manual? . select-last)
  "Opens the menu from the first completion source with something for
   the text before the cursor. `manual?` selects the first candidate
   (the last with select-last #t) and says so when there are none."
  (let loop ([sources *completion-sources*])
    (cond [(null? sources) (when manual? (message "no completions"))]
          [(run-source! (car sources) manual? (and (pair? select-last) (car select-last))) #t]
          [else (loop (cdr sources))])))

(define (complete-with! name manual? . select-last)
  "Opens the menu from completion source `name` only."
  (let ([entry (assq name *completion-sources*)])
    (unless (and entry (run-source! entry manual? (and (pair? select-last) (car select-last))))
      (when manual? (message "no completions")))))

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
   hasn't moved and no menu is open; `refresh?` asks again for an open
   menu whose list was incomplete."
  (when *complete-timer* (cancel-timer! *complete-timer*))
  (let ([id (current-buffer)] [at (cursor)])
    (set! *complete-timer*
          (run-after! (option 'completion-delay)
                      (lambda ()
                        (set! *complete-timer* #f)
                        (when (and (= id (current-buffer)) (= at (cursor)) (eq? *mode* 'insert)
                                   (if refresh? *menu-open* (not (or *menu-open* *key-interceptor*))))
                          (if refresh?
                              (complete-with! *menu-source* #f)
                              (complete-at-point! #f))))))))

;; Whether typing char `c` should open the menu, decided first by a
;; source with its own rules (lsp.scm's, with a server attached): #t,
;; 'never, or #f to leave it to the rules below.
(define *auto-complete-here?* (lambda (c) #f))

(define (auto-complete-char? c)
  "Whether `c`, just typed, should open the menu after a pause."
  (let ([verdict (*auto-complete-here?* c)])
    (cond [(eq? verdict 'never) #f]
          [verdict #t]
          [else (auto-complete-by-default? c)])))

(define (auto-complete-by-default? c)
  "Whether `c`, just typed, opens the menu in a programming mode: after a
   / in a path, or once completion-auto-min chars of a word are typed."
  (and (memq 'prog-mode (mode-lineage (major-mode)))
       (or (equal? c #\/)
           (and (char-word? c)
                (>= (- (cursor) (word-start-before (cursor))) (option 'completion-auto-min))))))

(add-hook! 'after-change
           (lambda ()
             (when (and (eq? *mode* 'insert) (option 'completion-auto) (not *menu-open*) (> (cursor) 0)
                        (auto-complete-char? (buffer-char-at (- (cursor) 1))))
               (schedule-completion! #f))))

(add-hook! 'insert-leave (lambda () (close-menu!)))
