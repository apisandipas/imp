;;; completion.scm -- choosing from a list by typing a few letters.
;;;
;;; (completing-read prompt candidates on-select) opens the prompt with a
;;; menu of candidates under it. Typing narrows the menu: the text is split
;;; on spaces and every part must match, in any order, as a substring or a
;;; fuzzy subsequence (fuzzy-filter, in Rust, does the matching and ranks
;;; the results). C-n/C-p, <down>/<up> and <tab>/<s-tab> move; <ret>
;;; picks the selected candidate, or the typed text if nothing matches.
;;; Choosing a file, <tab> first completes the path typed, as in Emacs:
;;; "s<tab>" becomes "src/" when that is the only name starting with s.
;;; A path starting with /, ~/, ./ or ../ lists that directory instead.
;;;
;;; M-x, find-file, switch-buffer and the describe commands are built on
;;; it.

(define *completion-candidates* '())
(define *completion-matches* '())
(define *completion-index* 0)
(define *completion-limit* 500)  ; matches kept per keystroke
(define *completion-annotate* #f)  ; candidate -> text shown dimmed beside it, or #f
;; What the open menu lists, for packages that decorate it: 'command,
;; 'file, 'buffer, 'symbol, 'option, 'project, or #f. A caller sets it
;; just before completing-read; closing the menu clears it.
(define *completion-category* #f)
;; Ranking by use (history.scm keeps the history): whether this menu is
;; ranked (a caller whose order is already by use sets #f, as it sets
;; *completion-category*), what a candidate is remembered as (find-file
;; gives full paths), and the open menu's name and its candidates' scores.
(define *completion-ranked* #t)
(define *completion-key* (lambda (candidate) candidate))
(define *completion-menu* #f)
(define *completion-uses* '())
;; history.scm sets these: (menu keys) -> a score per key, and (menu key)
;; to record a pick.
(define *completion-scores* (lambda (menu keys) '()))
(define *completion-picked* (lambda (menu key) void))

;; (lambda (category candidate)) -> a short string (an icon) drawn before
;; the candidate, or #f. The nerd-icons package sets it.
(define *completion-icon* (lambda (category candidate) #f))
;; Where the menu is drawn, as set-popup-place! takes it: "bottom", or
;; "center" and a width in percent for a box in the middle of the screen
;; with the prompt inside (the posframe package sets that).
(define *completion-place* (list "bottom" 0))

(define (refilter! text)
  "Narrows the menu to the candidates matching `text`, best first.
   Called as the prompt's text changes; selects the first match."
  (set! *completion-matches*
        (if (and (eq? *completion-category* 'file) (outside-path? text))
            (directory-matches text)
            (fuzzy-filter-ranked text *completion-candidates* *completion-uses* *completion-limit*)))
  (set! *completion-index* 0)
  (show-completions!))

(define (outside-path? text)
  "Whether `text`, typed for a file, is a path of its own rather than a
   search of the candidates: it starts with /, ~/, ./ or ../."
  (or (starts-with? text "/") (starts-with? text "~/")
      (starts-with? text "./") (starts-with? text "../")))

(define (directory-matches text)
  "The entries of the directory `text` names that match its last part,
   best first, each as `text`'s directory and the name (a directory with
   a /). Names starting with . only once the last part does."
  (let* ([slash (let loop ([i (- (string-length text) 1)])
                  (if (equal? (string-ref text i) #\/) i (loop (- i 1))))]
         [dir (substring text 0 (+ slash 1))]
         [part (substring text (+ slash 1) (string-length text))]
         [names (map (lambda (p) (substring p (string-length dir) (string-length p)))
                     (complete-path (string-append dir (if (starts-with? part ".") "." ""))))])
    (map (lambda (name) (string-append dir name))
         (fuzzy-filter part (sort names string<?) *completion-limit*))))

(define (completion-row c)
  "Candidate `c` as a menu row's runs: a path (with a /) is a path run,
   so a long one is shortened from the start rather than cut."
  (list (string-append " " (completion-icon-prefix c))
        (if (string-contains? c "/") (list c "popup.path") c)))

(define (completion-rows-shown top rows)
  "The menu's rows from match `top`, `rows` of them, with their notes."
  (let ([shown (take (list-tail *completion-matches* top) (min rows (- (length *completion-matches*) top)))])
    (if *completion-annotate*
        (let ([width (+ 3 (apply max (cons 0 (map string-length shown))))])
          (map (lambda (c)
                 (let ([note (*completion-annotate* c)])
                   (append (completion-row c)
                           (if note
                               (list (make-string (- width (string-length c)) #\space)
                                     (list note "popup.detail"))
                               '()))))
               shown))
        (map completion-row shown))))

(define (show-completions!)
  "Draws the menu, scrolled so the selection is visible."
  (let* ([n (length *completion-matches*)]
         [lines (if (= n 0) (list (list (list "  (no matches)" "popup.detail"))) completion-rows-shown)]
         [selected (and (> n 0) *completion-index*)]
         ;; Titled with the prompt, without its colon.
         [title (trim (let ([p (trim *cmdline-prompt*)])
                        (if (ends-with? p ":") (substring p 0 (- (string-length p) 1)) p)))])
    ;; No 'keys: the prompt reads them and moves the selection.
    (if (overlay-open? 'completing-read)
        (overlay-update! 'completing-read lines 'count n 'selected selected 'title title)
        (overlay-open! 'completing-read lines 'count n 'selected selected 'title title
                       'place (string->symbol (car *completion-place*))
                       'column (cadr *completion-place*) 'width (cadr *completion-place*)))
    (set-cmdline! (string-append *cmdline-prompt* *cmdline*
                                 (if (null? *completion-matches*)
                                     ""
                                     (string-append "   [" (number->string (+ 1 *completion-index*))
                                                    "/" (number->string n) "]")))
                  (+ (string-length *cmdline-prompt*) *cmdline-pos*))))

(define (move-selection! step)
  "Moves the menu's selection `step` rows, down for positive.
   It wraps around at either end."
  (let ([n (length *completion-matches*)])
    (when (> n 0)
      (set! *completion-index* (modulo (+ *completion-index* step) n))
      (show-completions!))))

(define (completion-key key)
  "Handles `key` if it moves the menu's selection, returning #t.
   #f for any other key, which the prompt then handles itself."
  (cond
    [(equal? key "<tab>") (unless (complete-typed-path!) (move-selection! 1)) #t]
    [(member key '("C-n" "<down>" "C-j")) (move-selection! 1) #t]
    [(member key '("C-p" "<up>" "<s-tab>" "C-k")) (move-selection! -1) #t]
    [(equal? key "<pagedown>") (move-selection! (overlay-rows (length *completion-matches*))) #t]
    [(equal? key "<pageup>") (move-selection! (- (overlay-rows (length *completion-matches*)))) #t]
    [else #f]))

(define (complete-typed-path!)
  "Completes the file path typed in the prompt, returning #t if it did.
   Only while choosing a file with the cursor at the end: the last part
   of the path is extended as far as the names it could be agree, and a
   directory that is the only one gets its /. #f leaves it to <tab>."
  (and (eq? *completion-category* 'file)
       (= *cmdline-pos* (string-length *cmdline*))
       (let ([done (completed-path *cmdline* *completion-candidates*)])
         (and done (begin (cmdline-edit! done (string-length done)) #t)))))

(define (completed-path text candidates)
  "`text` with its last path part completed, or #f if it can't grow.
   The names come from `candidates` (paths under the directory searched),
   or from the disk for a path starting with /, ~/, ./ or ../. Text with a
   space in it is a fuzzy search, not a path, and isn't completed."
  (let* ([n (string-length text)]
         [names (cond
                  [(string-contains? text " ") '()]
                  [(outside-path? text) (complete-path text)]
                  [else
                   (let loop ([cs candidates] [acc '()])
                     (cond [(null? cs) acc]
                           [(starts-with? (car cs) text)
                            (loop (cdr cs) (cons (path-part-after (car cs) n) acc))]
                           [else (loop (cdr cs) acc)]))])])
    (and (pair? names)
         (let ([common (foldl (lambda (c acc) (common-prefix acc c)) (car names) (cdr names))])
           (and (> (string-length common) n) common)))))

(define (path-part-after path from)
  "`path` up to and including the first / at or after index `from`, or
   all of it: \"src/a/b.rs\" from 1 is \"src/\"."
  (let loop ([i from])
    (cond [(>= i (string-length path)) path]
          [(equal? (string-ref path i) #\/) (substring path 0 (+ i 1))]
          [else (loop (+ i 1))])))

(define (completion-icon-prefix candidate)
  "The icon *completion-icon* gives `candidate` and a space, or \"\"."
  (let ([icon (*completion-icon* *completion-category* candidate)])
    (if icon (string-append icon " ") "")))

(define (close-completions!)
  "Closes the completion menu."
  (set! *completion-category* #f)
  (set! *completion-ranked* #t)
  (set! *completion-key* (lambda (candidate) candidate))
  (overlay-close! 'completing-read))

(define (completing-read prompt candidates on-select . annotate)
  "Asks for one of `candidates` with `prompt`, narrowing as you type.
   `candidates` is a list of strings. `on-select` gets the chosen
   string, or the typed text when nothing matches (but not \"\"). An
   `annotate` procedure, if given, returns text to show beside each
   candidate (or #f).

     (completing-read \"Open: \" '(\"notes.org\" \"todo.org\") open-file!)"
  (set! *completion-candidates* candidates)
  (set! *completion-annotate* (if (null? annotate) #f (car annotate)))
  ;; Each kind of menu has its own history: its category's, or its prompt's.
  (set! *completion-menu*
        (and *completion-ranked*
             (if *completion-category* (symbol->string *completion-category*) (trim prompt))))
  (set! *completion-uses*
        (if *completion-menu*
            (map exact->inexact (*completion-scores* *completion-menu* (map *completion-key* candidates)))
            '()))
  (open-cmdline!
   prompt ""
   (lambda (text)
     (let* ([picked? (pair? *completion-matches*)]
            [choice (if picked? (list-ref *completion-matches* *completion-index*) text)]
            [menu *completion-menu*]
            [key *completion-key*])
       (close-completions!)
       (when (and picked? menu) (*completion-picked* menu (key choice)))
       (unless (equal? choice "") (on-select choice))))
   refilter!
   close-completions!)
  (set! *cmdline-key-handler* completion-key)
  (refilter! ""))

;;; Commands built on it

;; The keys bound to commands, for M-x to show: a hash of command name
;; (a string) -> key labels. Normal mode's (or Emacs's) keys here; the
;; leader adds its own through *more-command-keys* (leader.scm).
(define *more-command-keys* (lambda () '()))  ; -> list of (name label)
;; Short descriptions of commands, for those without a doc comment: the
;; leader's which-key labels (leader.scm).
(define *command-labels* (lambda () '()))  ; -> list of (name description)

(define (command-keys-table)
  "The keys bound to each command, for M-x: a hash of command name
   (a string) -> list of key labels. Normal mode's keys (Emacs's in
   Emacs mode), then those *more-command-keys* adds."
  (let* ([mode (if (eq? *mode* 'emacs) 'emacs 'normal)]
         [m (keymap mode)]
         [pairs (append (map (lambda (k) (list (hash-ref m k) (if (equal? k " ") "SPC" k)))
                             (filter (lambda (k) (symbol? (hash-ref m k))) (hash-keys->list m)))
                        (map (lambda (p) (list (car p) (cadr p))) (*more-command-keys*)))])
    (foldl (lambda (p table)
             (let ([name (symbol->string (car p))])
               (hash-insert table name (append (or (hash-try-get table name) '()) (list (cadr p))))))
           (hash) pairs)))

(define-command! 'execute-command
  (lambda (count)
    "Run a command by name, chosen from a list (Emacs's M-x).
     Beside each are its keys and what it does: the first line of its
     docstring, else its which-key label."
    (let ([keys (command-keys-table)]
          [docs (doc-lines)]
          [labels (foldl (lambda (p h) (hash-insert h (symbol->string (car p)) (sentence-case (cadr p))))
                         (hash) (*command-labels*))])
      (set! *completion-category* 'command)
      (completing-read "M-x " (sort (map symbol->string (command-names)) string<?)
                       (lambda (name) (run-command (string->symbol name)))
                       (lambda (name)
                         (command-annotation (hash-try-get keys name)
                                             (or (command-doc name docs) (hash-try-get labels name))))))))

(define (sentence-case text)
  "`text` with its first letter upper case: \"last buffer\" -> \"Last buffer\".
   Which-key labels then sit among docstrings' first lines in M-x."
  (if (equal? text "")
      text
      (string-append (string-upcase (substring text 0 1)) (substring text 1 (string-length text)))))

(define (command-annotation key-labels doc)
  "The M-x annotation for a command: up to three of its keys, then `doc`.
   \"KEYS  description\", the description in a column of its own; #f
   when there are neither keys nor `doc`."
  (let ([keys (if key-labels (string-join (take-at-most-keys key-labels 3) "  ") "")])
    (cond [(not doc) (and key-labels keys)]
          [(equal? keys "") (string-append (make-string 14 #\space) doc)]
          [else (string-append (pad-right (string-append keys "  ") 14) doc)])))

(define (take-at-most-keys items n)
  "The first `n` elements of `items`, or all of them if fewer."
  (if (or (null? items) (= n 0)) '() (cons (car items) (take-at-most-keys (cdr items) (- n 1)))))

(define-command! 'switch-buffer
  (lambda (count)
    "Switch to another buffer by name."
    (let* ([ids (filter (lambda (id) (not (= id (current-buffer)))) (buffer-list))]
           [ids (if *alternate-buffer*
                    (cons *alternate-buffer* (filter (lambda (id) (not (equal? id *alternate-buffer*))) ids))
                    ids)]
           [ids (filter (lambda (id) (memv id (buffer-list))) ids)]
           [names (map (lambda (id) (car (buffer-info id))) ids)])
      (set! *completion-category* 'buffer)
      ;; Already in order of use: the alternate buffer first.
      (set! *completion-ranked* #f)
      (completing-read "Switch to buffer: " names
                       (lambda (name)
                         (let ([hit (filter (lambda (id) (equal? (car (buffer-info id)) name)) ids)])
                           (if (null? hit)
                               (message (string-append "no buffer " name))
                               (go-to-buffer! (car hit)))))
                       ;; A terminal's title beside its name.
                       (lambda (name)
                         (let ([hit (filter (lambda (id) (equal? (car (buffer-info id)) name)) ids)])
                           (and (pair? hit) (buffer-local-of (car hit) 'term-title))))))))

(define *all-definitions* '())
(define *all-definitions-key* #f)  ; the sources they were read from

(define (all-definitions)
  "Every name defined in the loaded sources, for the describe commands
   and completion in Scheme buffers. Read again when a source changes."
  (let ([key (sources-key)])
    (unless (equal? key *all-definitions-key*)
      (set! *all-definitions* (apropos ""))
      (set! *all-definitions-key* key))
    *all-definitions*))

;; Built shortly after startup, with the docstrings (help.scm), so the
;; first describe or Scheme completion doesn't wait for it.
(run-after! 1500 (lambda () (all-definitions)))

(define-command! 'describe-function
  (lambda (count)
    "Describe a function, chosen from every definition in the sources."
    (set! *completion-category* 'symbol)
    (completing-read "Describe function: " (all-definitions) describe-function)))

(define-command! 'describe-option
  (lambda (count)
    "Describe an option, chosen from a list: its value and documentation."
    (set! *completion-category* 'option)
    (completing-read "Describe option: "
                     (sort (map symbol->string (hash-keys->list *options*)) string<?)
                     describe-option)))

(define-command! 'find-definition
  (lambda (count)
    "Open the source of a definition chosen from a list."
    (set! *completion-category* 'symbol)
    (completing-read "Find definition: " (all-definitions) find-definition)))

(define-command! 'describe-command
  (lambda (count)
    "Describe a command, chosen from a list: its source and documentation."
    (set! *completion-category* 'command)
    (completing-read "Describe command: " (sort (map symbol->string (command-names)) string<?)
                     describe-function)))

;; M-x runs a command by name from Vim's states too, not just Emacs's.
(define-key! 'normal "M-x" 'execute-command)
(define-key! 'visual "M-x" 'execute-command)
(define-key! 'insert "M-x" 'execute-command)
