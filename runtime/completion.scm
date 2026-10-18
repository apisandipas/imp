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
    (set-popup! (if (null? shown) (list "  (no matches)") shown))
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
(define (completing-read prompt candidates on-select)
  (set! *completion-candidates* candidates)
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

;; Run a command by name (Emacs's M-x).
(define-command! 'execute-command
  (lambda (count)
    (completing-read "M-x " (sort (map symbol->string (command-names)) string<?)
                     (lambda (name) (run-command (string->symbol name))))))

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
