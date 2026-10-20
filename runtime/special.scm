;;; special.scm -- buffers a package generates: git status, the agenda, a
;;; directory listing, search results.
;;;
;;; Such a buffer has a name, a major mode derived from special-mode
;;; (read-only, q to leave), and text the package replaces whole:
;;;
;;;   (define-major-mode! 'thing-mode 'special-mode '() #f)
;;;   (display-buffer! (special-buffer "*thing*" 'thing-mode))
;;;   (set-buffer-contents! "line one\nline two\n")
;;;
;;; Faces go on with buffer-highlight-add! (ranges, redrawn with the text)
;;; or buffer-highlight-pattern! (follows edits).

(define (directory-of path)
  "The directory part of `path`, without a trailing slash (\".\" for none)."
  (let loop ([i (- (string-length path) 1)])
    (cond [(< i 0) "."]
          [(equal? (string-ref path i) #\/) (if (= i 0) "/" (substring path 0 i))]
          [else (loop (- i 1))])))

(define (list-find pred items)
  "The first item of `items` that `pred` accepts, or #f."
  (cond [(null? items) #f]
        [(pred (car items)) (car items)]
        [else (list-find pred (cdr items))]))

(define-computed-option! 'modifiable '(ma)
  (lambda () (not (buffer-read-only?)))
  (lambda (value) (set-buffer-read-only! (not value))))

(define (with-writable thunk)
  "Calls `thunk` with the current buffer writable, then puts back how it was."
  (let ([was (buffer-read-only?)])
    (set-buffer-read-only! #f)
    (let ([result (with-handler (lambda (e) (set-buffer-read-only! was) (raise-error e)) (thunk))])
      (set-buffer-read-only! was)
      result)))

(define (special-buffer name mode)
  "The buffer called `name`, made with major mode `mode` if there is none.
   It isn't made current."
  (or (list-find (lambda (id) (equal? (car (buffer-info id)) name)) (buffer-list))
      (let ([id (buffer-new! name)] [here (current-buffer)])
        (switch-to-buffer! id)
        (set-major-mode! mode)
        (switch-to-buffer! here)
        id)))

(define (set-buffer-contents! text)
  "Replaces the current buffer's text, keeping the cursor on its line and
   column where they still exist. The buffer stays unmodified."
  (let ([line (current-line)] [col (current-col)])
    (with-writable
     (lambda ()
       (buffer-delete! 0 (buffer-length))
       (buffer-insert! 0 text)))
    (set-buffer-unmodified!)
    (let ([line (min line (max 0 (- (buffer-line-count) 1)))])
      (set-cursor! (line-col->offset line (min col (max 0 (- (buffer-line-length line) 1))))))))

(define (special-buffer?)
  "Whether the current buffer's major mode derives from special-mode."
  (and (memq 'special-mode (mode-lineage (major-mode))) #t))

;; Each special buffer remembers the buffer it was opened from, and q goes
;; back there (so q from a diff opened from git status returns to the
;; status, and q again to the file).
(define *quitting-window* #f)

(add-hook! 'buffer-enter
  (lambda ()
    (when (and (special-buffer?) (not *quitting-window*) *alternate-buffer*)
      (set-buffer-local! 'return-to *alternate-buffer*))))

;;; Popup rules: where a generated buffer opens. Without a rule it takes
;;; over the current window; with one it opens in a window along an edge
;;; of the frame, and q closes that window:
;;;
;;;   (define-popup-rule! "*grep*" 'side 'right 'size 0.3)
;;;
;;; The first argument is a buffer name prefix, or a procedure given the
;;; name. Properties, all optional:
;;;   'side    'bottom (the default), 'top, 'left or 'right
;;;   'size    the part of the frame it takes, 0.3 by default
;;;   'select  #t (the default) to move to it, #f to stay where you were
;;;   'quit    #t (the default) for q to close the window; #f for q to go
;;;            back to the previous buffer in it, as without a rule
;;; A later rule for the same name replaces the earlier; (remove-popup-rule!
;;; "*grep*") makes it take over the window again. Opening a file from a
;;; popup (<ret> on a match) opens it in the window the popup came from.

(define *popup-rules* '())    ; (match props), newest first
(define *popup-windows* '())  ; (window origin-window rule)

(define (popup-props args)
  "The alist of the 'key value pairs in `args`; an odd one out is dropped."
  (if (or (null? args) (null? (cdr args)))
      '()
      (cons (cons (car args) (cadr args)) (popup-props (cddr args)))))

(define (define-popup-rule! match . props)
  "Says where buffers whose name starts with `match` open.
   `match` can also be a procedure given the name. `props` are 'key
   value pairs: 'side ('bottom, 'top, 'left, 'right), 'size (the part
   of the frame, 0.3), 'select (#t) and 'quit (#t). A rule for the same
   `match` replaces the old one:

     (define-popup-rule! \"*grep*\" 'side 'right 'size 0.3)"
  (remove-popup-rule! match)
  (set! *popup-rules* (cons (list match (popup-props props)) *popup-rules*)))

(define (remove-popup-rule! match)
  "Drops the popup rule for `match`, so its buffers take over the
   current window again:

     (remove-popup-rule! \"*grep*\")"
  (set! *popup-rules* (filter (lambda (r) (not (equal? (car r) match))) *popup-rules*)))

(define (popup-prop rule key default)
  "Property `key` of popup rule `rule`, or `default` if it has none."
  (let ([p (assq key (cadr rule))]) (if p (cdr p) default)))

(define (popup-rule name)
  "The rule for buffer name `name`, or #f."
  (list-find (lambda (r) (if (string? (car r)) (starts-with? name (car r)) ((car r) name)))
             *popup-rules*))

(define (buffer-name-of id)
  "The name of buffer `id`."
  (car (buffer-info id)))

(define (live-popup-windows)
  "The popup windows still open, as (window origin rule)."
  (set! *popup-windows* (filter (lambda (p) (memv (car p) (window-list))) *popup-windows*))
  *popup-windows*)

(define (popup-window-entry window)
  "The (window origin rule) entry for `window` if it is an open popup,
   or #f."
  (assv window (live-popup-windows)))

(define (display-buffer! id)
  "Shows buffer `id` where its popup rule says, or in the current window."
  (let ([rule (popup-rule (buffer-name-of id))]
        [shown (list-find (lambda (w) (eqv? (window-buffer w) id)) (window-list))])
    (cond
      [(not rule) (go-to-buffer! id)]
      [shown (go-to-window! shown)]
      [(popup-window-entry (current-window)) (go-to-buffer! id)]
      [else
       (let* ([origin (current-window)]
              [side (popup-prop rule 'side 'bottom)]
              [reuse (list-find (lambda (p) (eq? (popup-prop (caddr p) 'side 'bottom) side)) (live-popup-windows))])
         (if reuse
             (go-to-window! (car reuse))
             (begin
               (leave-pending-states!)
               (split-frame! (case side [(top) "above"] [(left) "left"] [(right) "right"] [else "below"])
                             (exact->inexact (popup-prop rule 'size 0.3)))
               (set! *popup-windows* (cons (list (current-window) origin rule) *popup-windows*))
               (after-window-change!)))
         (go-to-buffer! id)
         (unless (popup-prop rule 'select #t) (go-to-window! origin)))])))

;; The defaults: search results along the bottom, git and the face list
;; down the right.
(define-popup-rule! "*grep*" 'side 'bottom 'size 0.35)
(define-popup-rule! "*git" 'side 'right 'size 0.5)
(define-popup-rule! "*faces*" 'side 'right 'size 0.4)

;; Before a file opens from a popup window: back to the window it came from.
(set! *leave-popup-window!*
      (lambda ()
        (let ([entry (popup-window-entry (current-window))])
          (when entry
            (go-to-window! (if (memv (cadr entry) (window-list))
                               (cadr entry)
                               (list-find (lambda (w) (not (popup-window-entry w))) (window-list))))))))

(define-command! 'quit-window
  (lambda (count)
    "Leaves a special buffer for the one it was opened from, keeping it. In
     a popup window, leaving for a buffer that isn't a popup closes the
     window instead."
    (let* ([live? (lambda (id) (and id (memv id (buffer-list)) (not (= id (current-buffer)))))]
           [target (cond [(live? (buffer-local 'return-to)) (buffer-local 'return-to)]
                         [(live? *alternate-buffer*) *alternate-buffer*]
                         [else #f])]
           [popup (popup-window-entry (current-window))])
      (cond
        [(and popup (popup-prop (caddr popup) 'quit #t)
              (not (and target (popup-rule (buffer-name-of target)))))
         (let ([origin (cadr popup)])
           (close-window! (current-window))
           (go-to-window! (if (memv origin (window-list)) origin (current-window)))
           (after-window-change!))]
        [target
         (set! *quitting-window* #t)
         (go-to-buffer! target)
         (set! *quitting-window* #f)]
        [else (set-status! "no other buffer")]))))

(define-major-mode! 'special-mode #f '()
  (lambda () (set-buffer-read-only! #t)))
(define-mode-key! 'special-mode 'normal "q" 'quit-window)

;;; Menus: a popup of keys, the next key picks one (Magit's transients).
;;;
;;;   (menu! "Commit" (list (list "c" "commit" commit!) (list "a" "amend" amend!)))

(define *menu-entries* '())

(define (menu-done!)
  "Closes the menu: its popup goes and keys work as usual again."
  (set! *key-interceptor* #f)
  (set! *menu-entries* '())
  (set-popup! '()))

(define (menu-input! key)
  "Runs the menu entry for `key`, the key typed while a menu is open.
   Esc, C-g, C-c and q just close the menu; any other key says it is
   undefined."
  (let ([entry (list-find (lambda (e) (equal? (car e) key)) *menu-entries*)])
    (menu-done!)
    (cond [entry (message "") ((caddr entry))]
          [(member key '("<esc>" "C-g" "C-c" "q")) (message "")]
          [else (message (string-append (key-label key) " is undefined"))])))

(define (menu! title entries)
  "Shows a popup menu titled `title`; the next key runs its entry.
   Each of `entries` is (key label thunk):

     (menu! \"Commit\" (list (list \"c\" \"commit\" commit!)
                           (list \"a\" \"amend\" amend!)))"
  (set! *menu-entries* entries)
  (set! *key-interceptor* menu-input!)
  (show-which-key-popup! (which-key-table (map (lambda (e) (cons (key-label (car e)) (cadr e))) entries))
                         title))

(define (ask prompt default done)
  "Asks for a value on the command line, starting from `default`."
  (open-cmdline! prompt default (lambda (text) (unless (equal? text "") (done text))) #f #f))

(define (confirm! question thunk)
  "Asks a yes-or-no question on the message line; `thunk` runs on y."
  (message (string-append question " (y or n)"))
  (set! *key-interceptor*
        (lambda (key)
          (set! *key-interceptor* #f)
          (message "")
          (when (equal? key "y") (thunk)))))

(define (text-lines text)
  "The lines of `text`, without the empty one after a final line break."
  (let ([lines (split-many text "\n")])
    (if (and (pair? lines) (equal? (last lines) ""))
        (reverse (cdr (reverse lines)))
        lines)))

;;; Drawing a buffer line by line, each line with the item it is about
;;; (what <ret> or s acts on) and faces for its parts:
;;;
;;;   (draw-begin!)
;;;   (draw-line! (list (list "Head: " "git.head") (list "main" #f)) '(head))
;;;   (draw-finish!)   ; into the current buffer; (line-item) reads it back

(define *draw-lines* '())  ; newest first
(define *draw-items* '())
(define *draw-faces* '())  ; (start end face)
(define *draw-at* 0)

(define (draw-begin!)
  "Starts drawing a buffer afresh, for draw-line! and draw-finish!."
  (set! *draw-lines* '()) (set! *draw-items* '()) (set! *draw-faces* '()) (set! *draw-at* 0))

(define (draw-line! parts item)
  "Adds a line made of (text face) parts, about `item`."
  (let loop ([parts parts] [at *draw-at*] [text ""])
    (if (null? parts)
        (begin (set! *draw-lines* (cons text *draw-lines*))
               (set! *draw-items* (cons item *draw-items*))
               (set! *draw-at* (+ at 1)))
        (let* ([t (car (car parts))] [face (cadr (car parts))] [n (string-length t)])
          (when (and face (> n 0)) (set! *draw-faces* (cons (list at (+ at n) face) *draw-faces*)))
          (loop (cdr parts) (+ at n) (string-append text t))))))

(define (draw-finish!)
  "Puts what was drawn into the current buffer, keeping the cursor on the
   same item if it is still there."
  (let* ([old (line-item)]
         [items (list->vector (reverse *draw-items*))])
    (set-buffer-contents! (string-append (string-join (reverse *draw-lines*) "\n") "\n"))
    (buffer-highlight-clear! "drawn")
    (for-each (lambda (f) (buffer-highlight-add! "drawn" (car f) (cadr f) (caddr f))) *draw-faces*)
    (set-buffer-local! 'line-items items)
    (when old
      (let loop ([i 0])
        (when (< i (vector-length items))
          (if (equal? (vector-ref items i) old)
              (set-cursor! (line-first-nonblank i))
              (loop (+ i 1))))))))

(define (line-item)
  "What the cursor's line is about: (head), (section S), (file S PATH),
   (hunk S PATH I), (hunk-line S PATH I J), (stash REF), (commit HASH), or #f."
  (let ([items (buffer-local 'line-items)] [line (current-line)])
    (and items (< line (vector-length items)) (vector-ref items line))))
