;;; completion.scm -- choosing from a list by typing a few letters.
;;;
;;; (completing-read prompt candidates on-select) opens the prompt with a
;;; menu of candidates under it. Typing narrows the menu: the text is split
;;; on spaces and every part must match, in any order, as a substring or a
;;; fuzzy subsequence (fuzzy-filter, in Rust, does the matching and ranks
;;; the results). C-n/C-p, <down>/<up> and <tab>/<s-tab> move; <ret>
;;; picks the selected candidate, or the typed text if nothing matches.
;;;
;;; M-x, find-file, switch-buffer and the describe commands are built on
;;; it.

(define *completion-candidates* '())
(define *completion-matches* '())
(define *completion-index* 0)
(define *completion-limit* 500)  ; matches kept per keystroke
(define *completion-annotate* #f)  ; candidate -> text shown dimmed beside it, or #f

(define (completion-rows)
  "Menu height: up to ten rows, less in a small window."
  (max 1 (min 10 (- (window-height) 2))))

(define (refilter! text)
  "Narrows the menu to the candidates matching `text`, best first.
   Called as the prompt's text changes; selects the first match."
  (set! *completion-matches* (fuzzy-filter text *completion-candidates* *completion-limit*))
  (set! *completion-index* 0)
  (show-completions!))

(define (show-completions!)
  "Draws the menu, scrolled so the selection is visible."
  (let* ([n (length *completion-matches*)]
         [rows (completion-rows)]
         [top (max 0 (min (- *completion-index* (- rows 1)) (- n rows)))]
         [top (max 0 (min top *completion-index*))]
         [shown (take (list-tail *completion-matches* top) (min rows (- n top)))])
    (set-popup! (cond
                  [(null? shown) (list (list (list "  (no matches)" "popup.detail")))]
                  [*completion-annotate*
                   (let ([width (+ 3 (apply max (map string-length shown)))])
                     (map (lambda (c)
                            (let ([note (*completion-annotate* c)])
                              (if note
                                  (list (string-append " " (pad-right c width)) (list note "popup.detail"))
                                  (string-append " " c))))
                          shown))]
                  [else (map (lambda (c) (string-append " " c)) shown)]))
    ;; Titled with the prompt, without its colon.
    (set-popup-place! "bottom" 0 (trim (let ([p (trim *cmdline-prompt*)])
                                         (if (ends-with? p ":") (substring p 0 (- (string-length p) 1)) p))))
    (set-popup-selected! (if (null? shown) -1 (- *completion-index* top)))
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
    [(member key '("C-n" "<down>" "<tab>" "C-j")) (move-selection! 1) #t]
    [(member key '("C-p" "<up>" "<s-tab>" "C-k")) (move-selection! -1) #t]
    [(equal? key "<pagedown>") (move-selection! (completion-rows)) #t]
    [(equal? key "<pageup>") (move-selection! (- (completion-rows))) #t]
    [else #f]))

(define (close-completions!)
  "Closes the completion menu."
  (set-popup! '())
  (set-popup-selected! -1))

(define (completing-read prompt candidates on-select . annotate)
  "Asks for one of `candidates` with `prompt`, narrowing as you type.
   `candidates` is a list of strings. `on-select` gets the chosen
   string, or the typed text when nothing matches (but not \"\"). An
   `annotate` procedure, if given, returns text to show beside each
   candidate (or #f).

     (completing-read \"Open: \" '(\"notes.org\" \"todo.org\") open-file!)"
  (set! *completion-candidates* candidates)
  (set! *completion-annotate* (if (null? annotate) #f (car annotate)))
  (open-cmdline!
   prompt ""
   (lambda (text)
     (close-completions!)
     (let ([choice (if (null? *completion-matches*)
                       text
                       (list-ref *completion-matches* *completion-index*))])
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

(define-command! 'find-file
  (lambda (count)
    "Open a file under the current directory, skipping what .gitignore does."
    (completing-read "Find file: " (list-files (current-dir) 50000) open-file!)))

(define-command! 'switch-buffer
  (lambda (count)
    "Switch to another buffer by name."
    (let* ([ids (filter (lambda (id) (not (= id (current-buffer)))) (buffer-list))]
           [ids (if *alternate-buffer*
                    (cons *alternate-buffer* (filter (lambda (id) (not (equal? id *alternate-buffer*))) ids))
                    ids)]
           [ids (filter (lambda (id) (memv id (buffer-list))) ids)]
           [names (map (lambda (id) (car (buffer-info id))) ids)])
      (completing-read "Switch to buffer: " names
                       (lambda (name)
                         (let ([hit (filter (lambda (id) (equal? (car (buffer-info id)) name)) ids)])
                           (if (null? hit)
                               (message (string-append "no buffer " name))
                               (go-to-buffer! (car hit)))))))))

(define (all-definitions)
  "Every name defined in the loaded sources, for the describe commands."
  (apropos ""))

(define-command! 'describe-function
  (lambda (count)
    "Describe a function, chosen from every definition in the sources."
    (completing-read "Describe function: " (all-definitions) describe-function)))

(define-command! 'describe-option
  (lambda (count)
    "Describe an option, chosen from a list: its value and documentation."
    (completing-read "Describe option: "
                     (sort (map symbol->string (hash-keys->list *options*)) string<?)
                     describe-option)))

(define-command! 'find-definition
  (lambda (count)
    "Open the source of a definition chosen from a list."
    (completing-read "Find definition: " (all-definitions) find-definition)))

(define-command! 'describe-command
  (lambda (count)
    "Describe a command, chosen from a list: its source and documentation."
    (completing-read "Describe command: " (sort (map symbol->string (command-names)) string<?)
                     describe-function)))

;; M-x runs a command by name from Vim's states too, not just Emacs's.
(define-key! 'normal "M-x" 'execute-command)
(define-key! 'visual "M-x" 'execute-command)
(define-key! 'insert "M-x" (lambda () (run-command 'execute-command)))
