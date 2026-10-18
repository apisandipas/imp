;;; special.scm -- buffers a package generates: git status, the agenda, a
;;; directory listing, search results.
;;;
;;; Such a buffer has a name, a major mode derived from special-mode
;;; (read-only, q to leave), and text the package replaces whole:
;;;
;;;   (define-major-mode! 'thing-mode 'special-mode '() #f)
;;;   (go-to-buffer! (special-buffer "*thing*" 'thing-mode))
;;;   (set-buffer-contents! "line one\nline two\n")
;;;
;;; Faces go on with buffer-highlight-add! (ranges, redrawn with the text)
;;; or buffer-highlight-pattern! (follows edits).

;; The directory part of `path`, without a trailing slash ("." for none).
(define (directory-of path)
  (let loop ([i (- (string-length path) 1)])
    (cond [(< i 0) "."]
          [(equal? (string-ref path i) #\/) (if (= i 0) "/" (substring path 0 i))]
          [else (loop (- i 1))])))

;; The first item of `items` that `pred` accepts, or #f.
(define (list-find pred items)
  (cond [(null? items) #f]
        [(pred (car items)) (car items)]
        [else (list-find pred (cdr items))]))

(define-computed-option! 'modifiable '(ma)
  (lambda () (not (buffer-read-only?)))
  (lambda (value) (set-buffer-read-only! (not value))))

;; Calls `thunk` with the current buffer writable, then puts back how it was.
(define (with-writable thunk)
  (let ([was (buffer-read-only?)])
    (set-buffer-read-only! #f)
    (let ([result (with-handler (lambda (e) (set-buffer-read-only! was) (raise-error e)) (thunk))])
      (set-buffer-read-only! was)
      result)))

;; The buffer called `name`, made with major mode `mode` if there is none.
;; It isn't made current.
(define (special-buffer name mode)
  (or (list-find (lambda (id) (equal? (car (buffer-info id)) name)) (buffer-list))
      (let ([id (buffer-new! name)] [here (current-buffer)])
        (switch-to-buffer! id)
        (set-major-mode! mode)
        (switch-to-buffer! here)
        id)))

;; Replaces the current buffer's text, keeping the cursor on its line and
;; column where they still exist. The buffer stays unmodified.
(define (set-buffer-contents! text)
  (let ([line (current-line)] [col (current-col)])
    (with-writable
     (lambda ()
       (buffer-delete! 0 (buffer-length))
       (buffer-insert! 0 text)))
    (set-buffer-unmodified!)
    (let ([line (min line (max 0 (- (buffer-line-count) 1)))])
      (set-cursor! (line-col->offset line (min col (max 0 (- (buffer-line-length line) 1))))))))

(define (special-buffer?) (and (memq 'special-mode (mode-lineage (major-mode))) #t))

;; Each special buffer remembers the buffer it was opened from, and q goes
;; back there (so q from a diff opened from git status returns to the
;; status, and q again to the file).
(define *quitting-window* #f)

(add-hook! 'buffer-enter
  (lambda ()
    (when (and (special-buffer?) (not *quitting-window*) *alternate-buffer*)
      (set-buffer-local! 'return-to *alternate-buffer*))))

;; Leaves a special buffer for the one it was opened from, keeping it.
(define-command! 'quit-window
  (lambda (count)
    (let* ([live? (lambda (id) (and id (memv id (buffer-list)) (not (= id (current-buffer)))))]
           [target (cond [(live? (buffer-local 'return-to)) (buffer-local 'return-to)]
                         [(live? *alternate-buffer*) *alternate-buffer*]
                         [else #f])])
      (if target
          (begin (set! *quitting-window* #t)
                 (go-to-buffer! target)
                 (set! *quitting-window* #f))
          (set-status! "no other buffer")))))

(define-major-mode! 'special-mode #f '()
  (lambda () (set-buffer-read-only! #t)))
(define-mode-key! 'special-mode 'normal "q" 'quit-window)

;;; Menus: a popup of keys, the next key picks one (Magit's transients).
;;;
;;;   (menu! "Commit" (list (list "c" "commit" commit!) (list "a" "amend" amend!)))

(define *menu-entries* '())

(define (menu-done!)
  (set! *key-interceptor* #f)
  (set! *menu-entries* '())
  (set-popup! '()))

(define (menu-input! key)
  (let ([entry (list-find (lambda (e) (equal? (car e) key)) *menu-entries*)])
    (menu-done!)
    (cond [entry (message "") ((caddr entry))]
          [(member key '("<esc>" "C-g" "C-c" "q")) (message "")]
          [else (message (string-append (key-label key) " is undefined"))])))

(define (menu! title entries)
  (set! *menu-entries* entries)
  (set! *key-interceptor* menu-input!)
  (show-which-key-popup! (which-key-table (map (lambda (e) (cons (key-label (car e)) (cadr e))) entries))
                         title))

;; Asks a yes-or-no question on the message line; `thunk` runs on y.
(define (confirm! question thunk)
  (message (string-append question " (y or n)"))
  (set! *key-interceptor*
        (lambda (key)
          (set! *key-interceptor* #f)
          (message "")
          (when (equal? key "y") (thunk)))))

;; The lines of `text`, without the empty one after a final line break.
(define (text-lines text)
  (let ([lines (split-many text "\n")])
    (if (and (pair? lines) (equal? (last lines) ""))
        (reverse (cdr (reverse lines)))
        lines)))
