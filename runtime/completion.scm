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

;; Menu height: up to ten rows, less in a small window.
(define (completion-rows) (max 1 (min 10 (- (window-height) 2))))

(define (refilter! text)
  (set! *completion-matches* (fuzzy-filter text *completion-candidates* *completion-limit*))
  (set! *completion-index* 0)
  (show-completions!))

;; Draws the menu, scrolled so the selection is visible.
(define (show-completions!)
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
  (let ([n (length *completion-matches*)])
    (when (> n 0)
      (set! *completion-index* (modulo (+ *completion-index* step) n))
      (show-completions!))))

(define (completion-key key)
  (cond
    [(member key '("C-n" "<down>" "<tab>" "C-j")) (move-selection! 1) #t]
    [(member key '("C-p" "<up>" "<s-tab>" "C-k")) (move-selection! -1) #t]
    [(equal? key "<pagedown>") (move-selection! (completion-rows)) #t]
    [(equal? key "<pageup>") (move-selection! (- (completion-rows))) #t]
    [else #f]))

(define (close-completions!)
  (set-popup! '())
  (set-popup-selected! -1))

;; `candidates` is a list of strings. `on-select` gets the chosen string.
;; An `annotate` procedure, if given, returns text to show beside each
;; candidate (or #f).
(define (completing-read prompt candidates on-select . annotate)
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

(define (command-keys-table)
  (let* ([mode (if (eq? *mode* 'emacs) 'emacs 'normal)]
         [m (keymap mode)]
         [pairs (append (map (lambda (k) (list (hash-ref m k) (if (equal? k " ") "SPC" k)))
                             (filter (lambda (k) (symbol? (hash-ref m k))) (hash-keys->list m)))
                        (map (lambda (p) (list (car p) (cadr p))) (*more-command-keys*)))])
    (foldl (lambda (p table)
             (let ([name (symbol->string (car p))])
               (hash-insert table name (append (or (hash-try-get table name) '()) (list (cadr p))))))
           (hash) pairs)))

;; Run a command by name (Emacs's M-x), its keys shown beside it.
(define-command! 'execute-command
  (lambda (count)
    (let ([keys (command-keys-table)])
      (completing-read "M-x " (sort (map symbol->string (command-names)) string<?)
                       (lambda (name) (run-command (string->symbol name)))
                       (lambda (name)
                         (let ([labels (hash-try-get keys name)])
                           (and labels (string-join (take-at-most-keys labels 3) "  "))))))))

(define (take-at-most-keys items n)
  (if (or (null? items) (= n 0)) '() (cons (car items) (take-at-most-keys (cdr items) (- n 1)))))

;; Open a file under the current directory, skipping what .gitignore does.
(define-command! 'find-file
  (lambda (count)
    (completing-read "Find file: " (list-files (current-dir) 50000) open-file!)))

;; Switch to another buffer by name.
(define-command! 'switch-buffer
  (lambda (count)
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

;; Every name defined in the loaded sources, for the describe commands.
(define (all-definitions) (apropos ""))

(define-command! 'describe-function
  (lambda (count) (completing-read "Describe function: " (all-definitions) describe-function)))

(define-command! 'describe-option
  (lambda (count)
    (completing-read "Describe option: "
                     (sort (map symbol->string (hash-keys->list *options*)) string<?)
                     describe-option)))

(define-command! 'find-definition
  (lambda (count) (completing-read "Find definition: " (all-definitions) find-definition)))

(define-command! 'describe-command
  (lambda (count)
    (completing-read "Describe command: " (sort (map symbol->string (command-names)) string<?)
                     describe-function)))

;; M-x runs a command by name from Vim's states too, not just Emacs's.
(define-key! 'normal "M-x" 'execute-command)
(define-key! 'visual "M-x" 'execute-command)
(define-key! 'insert "M-x" (lambda () (run-command 'execute-command)))
