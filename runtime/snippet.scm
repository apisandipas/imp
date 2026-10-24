;;; snippet.scm -- snippets: text with tab stops to fill in, as VS Code's
;;; and LSP's (and LuaSnip's, vim.snippet's).
;;;
;;;   (define-snippet! 'rust-mode "fn" "fn ${1:name}(${2}) {\n\t$0\n}" "function")
;;;   (define-snippet! 'all "date" "${CURRENT_YEAR}-${CURRENT_MONTH}-${CURRENT_DATE}")
;;;   (load-snippets! 'rust-mode "~/snippets/rust.json")  ; VS Code format
;;;
;;; A snippet's prefix completes like any word (the snippets source, in
;;; the completion menu), and accepting it expands the body; a language
;;; server's snippets expand the same way. The body's syntax is LSP's:
;;;
;;;   $1 ${1}            a tab stop; $0 is where the cursor ends up
;;;   ${1:default}       a placeholder, its text selected (typing replaces it)
;;;   ${1|one,two|}      a choice, picked from a menu
;;;   $1 again           a mirror: it repeats what was typed at the first
;;;   $TM_FILENAME ${CURRENT_YEAR}  variables (see snippet-variable)
;;;   \$ \} \\           literally $, } and \
;;;
;;; A tab in the body indents by one level ('expandtab, 'shiftwidth), and
;;; each new line keeps the indentation of the line the snippet starts on.
;;; While filling it in, <tab> and <s-tab> go to the next and previous
;;; stop; reaching $0, or leaving insert state, ends it.

;;; Parsing

(define (snippet-variable name)
  "The value of snippet variable `name` (a string), or #f for one
   unknown: TM_FILENAME, TM_FILENAME_BASE, TM_DIRECTORY, TM_FILEPATH,
   TM_LINE_NUMBER, TM_CURRENT_LINE, TM_CURRENT_WORD, TM_SELECTED_TEXT,
   CLIPBOARD, CURRENT_YEAR, CURRENT_YEAR_SHORT, CURRENT_MONTH,
   CURRENT_DATE, CURRENT_HOUR, CURRENT_MINUTE, CURRENT_SECOND,
   CURRENT_DAY_NAME, CURRENT_MONTH_NAME, UUID (empty), LINE_COMMENT."
  (let* ([path (buffer-path)]
         [date (lambda (fmt) (trim (cadr (run-shell (string-append "date " (shell-quote (string-append "+" fmt))) ""))))])
    (cond
      [(equal? name "TM_FILENAME") (if path (file-name-of path) "")]
      [(equal? name "TM_FILENAME_BASE")
       (if path (let* ([n (file-name-of path)] [e (extension-of n)])
                  (if e (substring n 0 (- (string-length n) (string-length e) 1)) n))
           "")]
      [(equal? name "TM_DIRECTORY") (if path (directory-of (absolute-path path)) (current-dir))]
      [(equal? name "TM_FILEPATH") (if path (absolute-path path) "")]
      [(equal? name "TM_LINE_NUMBER") (number->string (+ (current-line) 1))]
      [(equal? name "TM_CURRENT_LINE") (line-text (current-line))]
      [(equal? name "TM_CURRENT_WORD") ""]
      [(equal? name "TM_SELECTED_TEXT") ""]
      [(equal? name "CLIPBOARD") (let ([r (register-get #\+)]) (if r (car r) ""))]
      [(equal? name "CURRENT_YEAR") (date "%Y")]
      [(equal? name "CURRENT_YEAR_SHORT") (date "%y")]
      [(equal? name "CURRENT_MONTH") (date "%m")]
      [(equal? name "CURRENT_DATE") (date "%d")]
      [(equal? name "CURRENT_HOUR") (date "%H")]
      [(equal? name "CURRENT_MINUTE") (date "%M")]
      [(equal? name "CURRENT_SECOND") (date "%S")]
      [(equal? name "CURRENT_DAY_NAME") (date "%A")]
      [(equal? name "CURRENT_MONTH_NAME") (date "%B")]
      [(equal? name "UUID") ""]
      [(equal? name "LINE_COMMENT") (trim (car (split-many (option 'commentstring) "%s")))]
      [else #f])))

(define (snippet-var-char? c)
  "Whether `c` can be part of a snippet variable's name."
  (char-word? c))

(define (snippet-parse body indent tab)
  "Snippet `body` as (text stops): the text it inserts, and its tab stops
   as (number start end choices) with offsets into the text, in the order
   they appear. Line breaks in the body are followed by `indent`, and tabs
   become `tab`."
  (let ([out '()] [len 0] [stops '()])
    (define (emit! c)
      (let ([s (cond [(equal? c #\newline) (string-append "\n" indent)]
                     [(equal? c #\tab) tab]
                     [else (string c)])])
        (set! out (cons s out))
        (set! len (+ len (string-length s)))))
    (define (digits cs)
      ;; (number . rest) for the digits `cs` starts with.
      (let loop ([cs cs] [n 0])
        (if (and (pair? cs) (char-digit? (car cs)))
            (loop (cdr cs) (+ (* n 10) (- (char->integer (car cs)) 48)))
            (cons n cs))))
    (define (choices cs)
      ;; (options . rest) for a choice's options up to its |}.
      (let loop ([cs cs] [word '()] [acc '()])
        (cond [(null? cs) (cons (reverse (cons (list->string (reverse word)) acc)) cs)]
              [(and (equal? (car cs) #\\) (pair? (cdr cs))) (loop (cddr cs) (cons (cadr cs) word) acc)]
              [(equal? (car cs) #\,) (loop (cdr cs) '() (cons (list->string (reverse word)) acc))]
              [(and (equal? (car cs) #\|) (pair? (cdr cs)) (equal? (cadr cs) #\}))
               (cons (reverse (cons (list->string (reverse word)) acc)) (cddr cs))]
              [else (loop (cdr cs) (cons (car cs) word) acc)])))
    (define (after-brace cs)
      (if (and (pair? cs) (equal? (car cs) #\})) (cdr cs) cs))
    (define (parse cs closer?)
      ;; Emits `cs` up to an unescaped } when `closer?`; returns the rest.
      (cond
        [(null? cs) cs]
        [(and closer? (equal? (car cs) #\})) cs]
        [(and (equal? (car cs) #\\) (pair? (cdr cs)) (memv (cadr cs) '(#\$ #\} #\\ #\, #\|)))
         (emit! (cadr cs)) (parse (cddr cs) closer?)]
        [(and (equal? (car cs) #\$) (pair? (cdr cs)) (char-digit? (cadr cs)))
         (let ([n (digits (cdr cs))])
           (set! stops (cons (list (car n) len len '()) stops))
           (parse (cdr n) closer?))]
        [(and (equal? (car cs) #\$) (pair? (cdr cs)) (equal? (cadr cs) #\{) (pair? (cddr cs))
              (char-digit? (caddr cs)))
         (let* ([n (digits (cddr cs))] [rest (cdr n)] [start len])
           (cond
             [(and (pair? rest) (equal? (car rest) #\:))
              (let ([rest (parse (cdr rest) #t)])
                (set! stops (cons (list (car n) start len '()) stops))
                (parse (after-brace rest) closer?))]
             [(and (pair? rest) (equal? (car rest) #\|))
              (let ([c (choices (cdr rest))])
                (for-each emit! (string->list (car (car c))))
                (set! stops (cons (list (car n) start len (car c)) stops))
                (parse (cdr c) closer?))]
             [else
              (set! stops (cons (list (car n) start start '()) stops))
              (parse (after-brace rest) closer?)]))]
        [(and (equal? (car cs) #\$) (pair? (cdr cs)) (equal? (cadr cs) #\{))
         ;; ${NAME} or ${NAME:default}
         (let* ([name (take-while snippet-var-char? (cddr cs))]
                [rest (drop-while snippet-var-char? (cddr cs))]
                [value (snippet-variable (list->string name))])
           (when value (for-each emit! (string->list value)))
           (if (and (pair? rest) (equal? (car rest) #\:))
               (let ([saved (list out len stops)])
                 (let ([rest (parse (cdr rest) #t)])
                   ;; A known variable's default isn't used.
                   (when value
                     (set! out (car saved)) (set! len (cadr saved)) (set! stops (caddr saved)))
                   (parse (after-brace rest) closer?)))
               (parse (after-brace rest) closer?)))]
        [(and (equal? (car cs) #\$) (pair? (cdr cs)) (snippet-var-char? (cadr cs)))
         (let* ([name (take-while snippet-var-char? (cdr cs))]
                [value (snippet-variable (list->string name))])
           (when value (for-each emit! (string->list value)))
           (parse (drop-while snippet-var-char? (cdr cs)) closer?))]
        [else (emit! (car cs)) (parse (cdr cs) closer?)]))
    (let loop ([cs (string->list body)])
      (let ([rest (parse cs #f)])
        ;; A stray } at the top level is text.
        (when (pair? rest) (emit! (car rest)) (loop (cdr rest)))))
    (list (apply string-append (reverse out)) (reverse stops))))

;;; Expanding, and moving between the stops

;; The snippet being filled in: (buffer groups index), each group
;; (number marks...) with the marks of that stop's places, the first the
;; one typed in and the rest mirrors; or #f.
(define *snippet* #f)
(define *snippet-runs* 0)  ; for naming each expansion's marks

(define (snippet-indent-unit)
  "What a tab in a snippet body becomes: 'shiftwidth spaces with
   'expandtab, else a tab."
  (if (option 'expandtab) (make-string (option 'shiftwidth) #\space) "\t"))

(define (snippet-insert! start end body)
  "Replaces the text from `start` to `end` with snippet `body` expanded,
   and goes to its first stop."
  (snippet-end!)
  (let* ([line (line-text (offset->line start))]
         [col (- start (line-start (offset->line start)))]
         [indent (let loop ([i 0])
                   (if (and (< i col) (< i (string-length line)) (memv (string-ref line i) '(#\space #\tab)))
                       (loop (+ i 1))
                       (substring line 0 i)))]
         [parsed (snippet-parse body indent (snippet-indent-unit))]
         [text (car parsed)]
         [stops (cadr parsed)]
         [stops (if (assv 0 stops) stops (append stops (list (list 0 (string-length text) (string-length text) '()))))]
         [numbers (let ([ns (sort (filter (lambda (n) (> n 0)) (map car stops)) <)])
                    (append (let dedup ([ns ns]) (cond [(null? ns) '()]
                                                       [(and (pair? (cdr ns)) (= (car ns) (cadr ns))) (dedup (cdr ns))]
                                                       [else (cons (car ns) (dedup (cdr ns)))]))
                            (list 0)))])
    (set! *snippet-runs* (+ *snippet-runs* 1))
    (buffer-delete! start end)
    (buffer-insert! start text)
    (set-cursor! (+ start (string-length text)))
    (let ([groups
           (map (lambda (n)
                  (cons n
                        (let loop ([ss stops] [k 0] [acc '()])
                          (cond [(null? ss) (reverse acc)]
                                [(= (car (car ss)) n)
                                 (let ([m (string-append "snippet:" (number->string *snippet-runs*) ":" (number->string n) ":" (number->string k))]
                                       [s (car ss)])
                                   (mark-set-sticky! (string-append m ":s") (+ start (cadr s)))
                                   (mark-set! (string-append m ":e") (+ start (caddr s)))
                                   (loop (cdr ss) (+ k 1) (cons (list m (cadddr s)) acc)))]
                                [else (loop (cdr ss) (+ k 1) acc)]))))
                numbers)])
      (set! *snippet* (list (current-buffer) groups -1))
      (minor-mode-on! 'snippet-mode)
      (snippet-go! 0))))

(define (snippet-range place)
  "Where a stop's place (mark choices) is now, as (start end)."
  (let ([s (mark-get (string-append (car place) ":s"))] [e (mark-get (string-append (car place) ":e"))])
    (list s (max s e))))

(define (snippet-group i)
  "Group `i` of the snippet being filled in: (number places...)."
  (list-ref (cadr *snippet*) i))

(define (snippet-sync-mirrors! i)
  "Copies what was typed at group `i`'s first place to its mirrors."
  (let* ([places (cdr (snippet-group i))]
         [r (snippet-range (car places))]
         [text (buffer-substring (car r) (cadr r))])
    (for-each (lambda (p)
                (let ([m (snippet-range p)])
                  (unless (equal? (buffer-substring (car m) (cadr m)) text)
                    (buffer-delete! (car m) (cadr m))
                    (buffer-insert! (car m) text))))
              (cdr places))))

(define (snippet-go! i)
  "Goes to stop group `i`: the cursor at its place, its placeholder
   selected so typing replaces it, a choice's options in a menu. Group
   $0, the last, ends the snippet there."
  (let* ([groups (cadr *snippet*)]
         [place (cadr (snippet-group i))]
         [r (snippet-range place)])
    (set! *snippet* (list (car *snippet*) groups i))
    (buffer-highlight-clear! "snippet")
    (if (= i (- (length groups) 1))
        (begin (set-cursor! (car r)) (snippet-end!))
        (cond
          [(pair? (cadr place))
           ;; A choice: the options in the menu, in place of the text.
           (buffer-delete! (car r) (cadr r))
           (set-cursor! (car r))
           (set! *snippet-choices* (cadr place))
           (complete-with! 'snippet-choice #t)]
          [(< (car r) (cadr r))
           (set-cursor! (car r))
           (buffer-highlight-add! "snippet" (car r) (cadr r) "visual")
           (set! *key-interceptor* (snippet-placeholder-key (car r) (cadr r)))]
          [else (set-cursor! (car r))])))
  void)

(define (snippet-placeholder-key start end)
  "The key interceptor while a placeholder (`start` to `end`) is
   selected: a char typed, <bs> or <del> replaces it; <tab> and <s-tab>
   move on; anything else leaves it be."
  (lambda (key)
    (set! *key-interceptor* #f)
    (buffer-highlight-clear! "snippet")
    (cond
      [(member key '("<tab>" "<s-tab>")) (snippet-jump! (if (equal? key "<tab>") 1 -1))]
      [(or (member key '("<bs>" "C-h" "<del>")) (and (key-char key) (not (member key '("<ret>")))))
       (buffer-delete! start end)
       (set-cursor! start)
       (unless (member key '("<bs>" "C-h" "<del>")) (handle-key! key))]
      [else (handle-key! key)])))

(define (snippet-jump! step)
  "Goes `step` stops on (back when negative) in the snippet being filled
   in, mirrors updated first; past the last, it ends."
  (when *snippet*
    (let ([i (caddr *snippet*)] [n (length (cadr *snippet*))])
      (snippet-sync-mirrors! i)
      (snippet-go! (max 0 (min (- n 1) (+ i step)))))))

(define (snippet-end!)
  "Stops filling in the snippet: its marks go, and <tab> is <tab> again."
  (when *snippet*
    (let ([buf (car *snippet*)] [groups (cadr *snippet*)])
      (set! *snippet* #f)
      (when (memv buf (buffer-list))
        (with-buffer buf
          (lambda ()
            (buffer-highlight-clear! "snippet")
            (for-each (lambda (g)
                        (for-each (lambda (p)
                                    (mark-delete! (string-append (car p) ":s"))
                                    (mark-delete! (string-append (car p) ":e")))
                                  (cdr g)))
                      groups)
            (minor-mode-off! 'snippet-mode)))))))

(define-minor-mode! 'snippet-mode #f #f)
(define-mode-key! 'snippet-mode 'insert "<tab>" (lambda () (snippet-jump! 1)))
(define-mode-key! 'snippet-mode 'insert "<s-tab>" (lambda () (snippet-jump! -1)))
(add-hook! 'insert-leave (lambda () (snippet-end!)))

;; A choice stop's options, for the snippet-choice source.
(define *snippet-choices* '())

(define-completion-source! 'snippet-choice
  (lambda (manual? done)
    "The options of the snippet choice being filled in."
    (let ([choices *snippet-choices*])
      (set! *snippet-choices* '())
      (and *snippet* (pair? choices)
           (begin (done (cursor) (map completion-candidate choices)) #t))))
  'exclusive #t)

;;; Snippets of your own

;; Major mode (or 'all) -> its snippets, as (prefix body description).
(define *snippets* (hash))

(define (define-snippet! modes prefix body . description)
  "Defines a snippet that `prefix` completes to and expands to `body`, in
   buffers of `modes` (a major mode, a list of them, or 'all) and their
   children; `description` shows beside it in the menu. Replaces one with
   the same prefix and mode."
  (for-each (lambda (mode)
              (let ([others (filter (lambda (s) (not (equal? (car s) prefix)))
                                    (or (hash-try-get *snippets* mode) '()))])
                (set! *snippets*
                      (hash-insert *snippets* mode
                                   (append others (list (list prefix body (if (null? description) "" (car description)))))))))
            (if (list? modes) modes (list modes))))

(define (load-snippets! modes path)
  "Defines the snippets in VS Code snippet file `path` (JSON: name ->
   prefix, body, description) for `modes`, as define-snippet! does.
   Returns how many it read."
  (let* ([text (read-file (expand-path path))]
         [json (and (string? text) (json-decode text))])
    (if (not (hash? json))
        (begin (message (string-append "can't read snippets from " path)) 0)
        (foldl (lambda (name count)
                 (let* ([s (hash-ref json name)]
                        [get (lambda (k) (and (hash? s) (let ([v (hash-try-get s k)]) (and (not (equal? v 'null)) v))))]
                        [prefixes (let ([p (get "prefix")]) (cond [(string? p) (list p)] [(list? p) p] [else '()]))]
                        [body (let ([b (get "body")])
                                (cond [(string? b) b]
                                      [(list? b) (let join ([ls b])
                                                   (cond [(null? ls) ""]
                                                         [(null? (cdr ls)) (car ls)]
                                                         [else (string-append (car ls) "\n" (join (cdr ls)))]))]
                                      [else #f]))]
                        [desc (let ([d (get "description")]) (if (string? d) d name))])
                   (if body
                       (begin (for-each (lambda (p) (define-snippet! modes p body desc)) prefixes)
                              (+ count (length prefixes)))
                       count)))
               0 (hash-keys->list json)))))

(define (snippets-here)
  "The snippets for the current buffer: its mode's, its parents', then
   'all's, the nearer mode winning a prefix."
  (let loop ([modes (append (mode-lineage (major-mode)) (list 'all))] [seen (hash)] [acc '()])
    (if (null? modes)
        (reverse acc)
        (let ([new (filter (lambda (s) (not (hash-contains? seen (car s))))
                           (or (hash-try-get *snippets* (car modes)) '()))])
          (loop (cdr modes)
                (foldl (lambda (s h) (hash-insert h (car s) #t)) seen new)
                (append (reverse new) acc))))))

(define-completion-source! 'snippets
  (lambda (manual? done)
    "The snippets for this buffer's mode whose prefix completes the word
     before the cursor; accepting one expands it."
    (let ([mine (snippets-here)])
      (and (pair? mine)
           (begin
             (done (word-start-before (cursor))
                   (map (lambda (s) (list (car s) (if (equal? (caddr s) "") "snippet" (caddr s)) (car s) #f s)) mine)
                   'on-accept (lambda (s)
                                (snippet-insert! (- (cursor) (string-length (car s))) (cursor) (cadr s))))
             #t))))
  'priority 60
  'before 'words)
