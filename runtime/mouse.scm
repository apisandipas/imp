;;; mouse.scm -- clicking, dragging and the scroll wheel, as in Neovim.
;;;
;;; The client reports mouse events; Rust only says what is under a screen
;;; cell (screen-position: the window, and the buffer offset or #f on its
;;; status line). What a click does is decided here:
;;;
;;; - a left click focuses the window under it and moves the cursor there,
;;;   ending visual mode; insert mode stays in insert mode;
;;; - dragging selects, in visual mode, from where the button went down;
;;; - dragging the border between side-by-side windows, or a status line
;;;   with a window below it, resizes the windows (window-divider-width
;;;   makes that border wider, so easier to grab);
;;; - the wheel scrolls the window under the mouse by mouse-scroll lines.
;;;
;;; :set nomouse ignores the mouse. While the terminal reports it, most
;;; terminals still select text for copying with shift held down.

(define-option! 'mouse #t '())
(define-option! 'mouse-scroll 3 '())

(define *mouse-press* #f)  ; (window offset) where the left button went down
;; The border being dragged: (what at other grab), where `what` is "width"
;; or "height", `at` the border's column or row, `other` the row or column
;; it was grabbed at, and `grab` how far into the border.
(define *mouse-border* #f)

(define (imp-handle-mouse action button x y)
  "Handles a mouse event from the client, `action` with `button` at
   screen cell `x`, `y`: press, drag, release, scroll-up or scroll-down.
   Ignored with nomouse, on the command line, and while something else
   is reading keys."
  (when (and (option 'mouse) (not (eq? *mode* 'cmdline))
             ;; Something reading keys (the leader menu, describe-key)
             ;; owns the next input, except the completion menu.
             (or (not *key-interceptor*) *menu-open*))
    (let ([at (screen-position x y)])
      (cond
        [(and (equal? action "press") (equal? button "left") (border-at x y))
         (mouse-grab-border! x y)
         ;; A status line's press focuses its window too.
         (when at (mouse-click! (car at) (cadr at)))]
        [(and *mouse-border* (equal? action "drag")) (mouse-drag-border! x y)]
        [(equal? action "release") (set! *mouse-press* #f) (set! *mouse-border* #f)]
        [at
         (cond
          [(and (equal? action "press") (equal? button "left")) (mouse-click! (car at) (cadr at))]
          [(and (equal? action "drag") (equal? button "left")) (mouse-drag! (car at) (cadr at))]
          [(equal? action "release") (set! *mouse-press* #f)]
          [(equal? action "scroll-up") (mouse-scroll! (car at) -1)]
          [(equal? action "scroll-down") (mouse-scroll! (car at) 1)]
          [else #f])]
        [else #f])
      (update-visual-highlight!)
      (run-hooks 'post-command))))

(define (mouse-grab-border! x y)
  "Starts dragging the border at screen cell `x`, `y`."
  (let ([what (border-at x y)])
    (set! *mouse-border*
          (if (equal? what "width")
              (let ([at (move-border! x y 0)]) (list what at y (- x at)))
              (list what y x 0))))
  void)

(define (mouse-drag-border! x y)
  "Moves the border being dragged to follow the mouse at `x`, `y`."
  (let* ([what (car *mouse-border*)] [at (cadr *mouse-border*)]
         [other (caddr *mouse-border*)] [grab (cadddr *mouse-border*)]
         [width? (equal? what "width")]
         [delta (- (if width? (- x grab) y) at)])
    (unless (= delta 0)
      (let ([now (if width? (move-border! at other delta) (move-border! other at delta))])
        (when now (set! *mouse-border* (list what now other grab))))))
  void)

(define (mouse-click! window offset)
  "Focuses `window` and moves the cursor to `offset` there.
   Closes menus and popups and ends visual mode; insert mode stays.
   `offset` is #f on a status line, which only focuses the window.
   Remembers the press for a drag."
  (close-menu!)
  (when *popup-shown* (close-popup!))
  (reset-pending!)
  (let ([typing? (typing-mode?)])
    (if typing?
        (unless (= window (current-window)) (focus-window! window) (run-hooks 'buffer-enter))
        (go-to-window! window))
    (when (eq? *mode* 'visual) (leave-visual!))
    (when offset
      (set-cursor! offset)
      (unless typing? (normal-clamp!))
      (set! *goal-col* (current-col)))
    (set! *mouse-press* (and offset (list window (cursor)))))
  void)

(define (mouse-drag! window offset)
  "Moves the cursor to `offset` as the left button drags in `window`.
   The first drag away from the press starts a selection there."
  (when (and *mouse-press* offset (= window (car *mouse-press*)) (= window (current-window)))
    (unless (eq? *mode* 'visual)
      (when (typing-mode?) (leave-insert!))
      (enter-visual! 'char (cadr *mouse-press*)))
    (set-cursor! (min offset (max 0 (- (buffer-length) 1))))
    (set! *goal-col* (current-col)))
  void)

(define (mouse-scroll! window sign)
  "Scrolls `window` (focusing it for the moment if it isn't current); the
   cursor stays put unless it would leave the window, as with C-e and C-y."
  (let ([here (current-window)] [n (option 'mouse-scroll)])
    (unless (= window here) (focus-window! window))
    (scroll-to! (+ (window-top) (* sign n)))
    (cond
      [(< (current-line) (window-top)) (cursor-to-line! (window-top))]
      [(> (current-line) (window-bottom)) (cursor-to-line! (window-bottom))]
      [else #t])
    (unless (= window here) (focus-window! here))))
