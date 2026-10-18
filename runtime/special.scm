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

;; Leaves a special buffer for the one before it, keeping it for later.
(define-command! 'quit-window
  (lambda (count)
    (if (and *alternate-buffer* (memv *alternate-buffer* (buffer-list))
             (not (= *alternate-buffer* (current-buffer))))
        (go-to-buffer! *alternate-buffer*)
        (set-status! "no other buffer"))))

(define-major-mode! 'special-mode #f '()
  (lambda () (set-buffer-read-only! #t)))
(define-mode-key! 'special-mode 'normal "q" 'quit-window)
