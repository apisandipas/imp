;;; overlay.scm -- the one owner of what opens over the windows for a
;;; moment: which-key, menus, completion menus, show-and-close popups and
;;; prompts. One overlay is open at a time; opening another closes it.
;;; The owner keeps its lines, selection and scrolling, place and title,
;;; the keys it takes, and draws it with the popup primitives.
;;;
;;;   (overlay-open! 'my-menu lines 'title "Pick" 'selected 0
;;;                  'keys (lambda (key) ... #t)       ; #f lets the key go on
;;;                  'on-close (lambda () ...))
;;;   (overlay-update! 'my-menu lines 'selected 1)
;;;   (overlay-close! 'my-menu)

;; The open overlay, a hash of its fields, or #f.
(define *overlay* #f)
;; A show-popup! popup waiting for an overlay that takes keys to close:
;; (lines . options), or #f.
(define *overlay-waiting* #f)

(define (overlay-option options key default)
  "The value after `key` in the 'key value pairs `options`, else `default`."
  (cond [(or (null? options) (null? (cdr options))) default]
        [(eq? (car options) key) (cadr options)]
        [else (overlay-option (cddr options) key default)]))

(define (overlay-field key)
  "Field `key` of the open overlay."
  (hash-ref *overlay* key))

(define (overlay-open! name lines . options)
  "Opens the overlay `name` (a symbol) showing `lines`, closing the one
   open. Each line is a list of (text face) runs. `lines` can also be a
   procedure (lambda (top rows) lines) giving the rows shown from line
   `top`, with 'count the number of lines. The other options, as 'key
   value pairs:
     'place     'bottom (default), 'cursor or 'center
     'column    for 'cursor, the offset from the cursor's column
     'width     for 'center, the percent of the screen it takes
     'title     the popup's title, \"\" by default
     'selected  the index of the selected line, or #f
     'keys      (lambda (key) ...) called with each key while it is open;
                #f lets the key go on as usual
     'on-close  (lambda () ...) run once when it closes, however it does
     'click-closes  whether a mouse click closes it
   Nothing is kept from the overlay before."
  (if (and (overlay-option options 'waits #f) *overlay* (overlay-field 'keys)
           (not (overlay-field 'waits)))
      (set! *overlay-waiting* (cons lines options))
      (begin
        (when *overlay* (overlay-close! (overlay-field 'name)))
        (set! *overlay*
              (hash 'name name
                    'lines lines
                    'count (overlay-option options 'count #f)
                    'place (overlay-option options 'place 'bottom)
                    'column (overlay-option options 'column 0)
                    'width (overlay-option options 'width 60)
                    'title (overlay-option options 'title "")
                    'selected (overlay-option options 'selected #f)
                    'keys (overlay-option options 'keys #f)
                    'on-close (overlay-option options 'on-close #f)
                    'click-closes (overlay-option options 'click-closes #f)
                    'waits (overlay-option options 'waits #f)
                    'top 0))
        (overlay-draw!)))
  void)

(define (overlay-update! name lines . options)
  "Changes the lines of overlay `name`, and any of the options given, as
   overlay-open! takes them, if it is the one open."
  (when (overlay-open? name)
    (set! *overlay* (hash-insert *overlay* 'lines lines))
    (let loop ([os options])
      (when (and (pair? os) (pair? (cdr os)))
        (set! *overlay* (hash-insert *overlay* (car os) (cadr os)))
        (loop (cddr os))))
    (overlay-draw!))
  void)

(define (overlay-close! name)
  "Closes overlay `name` if it is the one open and runs its 'on-close;
   otherwise does nothing. A popup waiting for it shows then."
  (when (overlay-open? name)
    (let ([on-close (overlay-field 'on-close)])
      (set! *overlay* #f)
      (set-popup! '())
      (set-popup-selected! -1)
      (when on-close (on-close))
      (when (and (not *overlay*) *overlay-waiting*)
        (let ([waiting *overlay-waiting*])
          (set! *overlay-waiting* #f)
          (apply overlay-open! 'popup (car waiting) (cdr waiting))))))
  void)

(define (overlay-open? . name)
  "Whether overlay `name` is the one open; with no name, whether any is."
  (and *overlay*
       (or (null? name) (eq? (overlay-field 'name) (car name)))))

(define (overlay-key! key)
  "Gives `key` to the open overlay's 'keys. Whether it used the key up."
  (let ([keys (and *overlay* (overlay-field 'keys))])
    (and keys (not (eq? (keys key) #f)))))

(define (overlay-rows count)
  "How many of `count` lines an overlay with a selected line shows: up
   to 10, and no more than the window height less 2."
  (max 0 (min count 10 (max 1 (- (window-height) 2)))))

(define (overlay-scroll top selected count rows)
  "The first line shown, from `top` before: moved only as far as it must
   to keep line `selected` in view."
  (let* ([top (cond [(not selected) top]
                    [(< selected top) selected]
                    [(>= selected (+ top rows)) (+ (- selected rows) 1)]
                    [else top])])
    (max 0 (min top (- count rows)))))

(define (overlay-draw!)
  "Draws the open overlay with the popup primitives, scrolled so its
   selected line is in view, setting every field of the popup."
  (let* ([lines (overlay-field 'lines)]
         [count (if (procedure? lines) (or (overlay-field 'count) 0) (length lines))]
         [selected (overlay-field 'selected)]
         [selected (and selected (>= selected 0) (< selected count) selected)]
         ;; A list to move through scrolls; a page shows every line.
         [rows (if (or selected (procedure? lines)) (overlay-rows count) count)]
         [top (overlay-scroll (overlay-field 'top) selected count rows)]
         [place (overlay-field 'place)])
    (set! *overlay* (hash-insert *overlay* 'top top))
    (set-popup! (if (procedure? lines)
                    (lines top rows)
                    (take (list-tail lines top) rows)))
    (set-popup-place! (symbol->string place)
                      (cond [(eq? place 'cursor) (overlay-field 'column)]
                            [(eq? place 'center) (overlay-field 'width)]
                            [else 0])
                      (overlay-field 'title))
    (set-popup-selected! (if selected (- selected top) -1)))
  void)

(define (overlay-top)
  "The index of the open overlay's first line shown, 0 if none is open."
  (if *overlay* (overlay-field 'top) 0))

;;; Show-and-close popups: output longer than the status line

(define (show-popup! lines . options)
  "Shows `lines` in a popup that the next key closes; <esc>, <ret>, space
   and C-c only close it, other keys also run. It waits while a menu or
   the leader takes keys. `options` are overlay-open!'s, as 'place 'cursor."
  (apply overlay-open! 'popup lines
         'keys (lambda (key)
                 (close-popup!)
                 (and (member key '("<ret>" "<esc>" " " "C-c")) #t))
         'click-closes #t
         'waits #t
         options))

(define (close-popup!)
  "Closes the popup show-popup! opened, if it is open."
  (overlay-close! 'popup))
