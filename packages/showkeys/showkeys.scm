;;; showkeys.scm -- the last few keys pressed, in a box in a corner of the
;;; screen, for screencasts and demos, after nvzone/showkeys.
;;;
;;;   (use-package! 'showkeys
;;;     'config (lambda ()
;;;               (set-option! 'showkeys-position 'top-right)
;;;               (set-option! 'showkeys-excluded-states '(insert))))
;;;
;;; M-x showkeys-mode turns it on and off. Each key pressed goes on the
;;; right of the box, which shows the last showkeys-max of them and hides
;;; after showkeys-timeout seconds without a key. Keys a paste or a macro
;;; replays don't come through imp-handle-key, so only keys pressed show.

;; How many keys the box shows.
(define-option! 'showkeys-max 3 '())
;; Seconds with no key before the box hides.
(define-option! 'showkeys-timeout 3 '())
;; Where the box goes: bottom-right, bottom-left, bottom-center,
;; top-right, top-left or top-center.
(define-option! 'showkeys-position 'bottom-right '())
;; Show a key pressed again right after itself once, with a count, as
;; "j ×4".
(define-option! 'showkeys-count #f '())
;; States whose keys aren't shown: '(insert) hides what is typed.
(define-option! 'showkeys-excluded-states '() '())
;; How keys are shown, as (key text) lists that replace imp's names for
;; them: '(("<esc>" "⎋")).
(define-option! 'showkeys-format '() '())

;; Whether it's on; the keys shown, newest first, each (name count); and
;; the timer that hides them.
(define *showkeys-on* #f)
(define *showkeys-keys* '())
(define *showkeys-timer* #f)

;; Named keys shown as a symbol.
(define showkeys-symbols
  '(("<bs>" "⌫") ("<ret>" "⏎") ("<tab>" "⇥") ("<del>" "⌦")
    ("<up>" "↑") ("<down>" "↓") ("<left>" "←") ("<right>" "→")))

(define (showkeys-name key)
  "How `key` is shown: its text in showkeys-format if it has one, SPC for
   space, a symbol for a few named keys, and other named keys without
   their brackets and capitalised (<esc> is Esc), after any modifiers
   (M-<ret> is M-⏎)."
  (let ([own (assoc key (option 'showkeys-format))])
    (cond
      [own (cadr own)]
      [(equal? key " ") "SPC"]
      [else
       (let loop ([mods ""] [rest key])
         (cond
           [(and (> (string-length rest) 2)
                 (or (starts-with? rest "C-") (starts-with? rest "M-") (starts-with? rest "S-")))
            (loop (string-append mods (substring rest 0 2)) (substring rest 2 (string-length rest)))]
           [(and (> (string-length rest) 2) (starts-with? rest "<") (ends-with? rest ">"))
            (let ([symbol (assoc rest showkeys-symbols)]
                  [name (substring rest 1 (- (string-length rest) 1))])
              (string-append mods
                             (if symbol
                                 (cadr symbol)
                                 (string-append (string-upcase (substring name 0 1))
                                                (substring name 1 (string-length name))))))]
           [else key]))])))

(define (showkeys-text)
  "The keys shown, oldest first, separated by spaces; a key with a count
   as \"j ×4\"."
  (string-join (map (lambda (k)
                      (if (> (cadr k) 1)
                          (string-append (car k) " ×" (number->string (cadr k)))
                          (car k)))
                    (reverse *showkeys-keys*))
               " "))

(define (showkeys-hide!)
  "Hides the box and forgets its keys."
  (when *showkeys-timer* (cancel-timer! *showkeys-timer*) (set! *showkeys-timer* #f))
  (set! *showkeys-keys* '())
  (float-hide! "showkeys")
  void)

(define (showkeys-key! key)
  "Before each key pressed: adds it to the box, unless the state it was
   pressed in is excluded, and waits showkeys-timeout seconds to hide it."
  (unless (member *mode* (option 'showkeys-excluded-states))
    (let ([name (showkeys-name key)]
          [keys *showkeys-keys*])
      (set! *showkeys-keys*
            (if (and (option 'showkeys-count) (pair? keys) (equal? (car (car keys)) name))
                (cons (list name (+ 1 (cadr (car keys)))) (cdr keys))
                ;; The newest showkeys-max, which may have been lowered.
                (let* ([keys (cons (list name 1) keys)]
                       [over (- (length keys) (max 1 (option 'showkeys-max)))])
                  (if (> over 0)
                      (reverse (list-tail (reverse keys) over))
                      keys)))))
    (float-show! "showkeys" (list (list (list (showkeys-text) "showkeys")))
                 (option 'showkeys-position)
                 ;; The floating box's border unless the theme sets one.
                 (and (face-spec "showkeys.border") "showkeys.border"))
    (when *showkeys-timer* (cancel-timer! *showkeys-timer*))
    (set! *showkeys-timer*
          (run-after! (exact (round (* 1000 (option 'showkeys-timeout))))
                      (lambda () (set! *showkeys-timer* #f) (showkeys-hide!)))))
  void)

(define-command! 'showkeys-mode
  (lambda (count)
    "Turn showing the keys you press on or off, in a box in a corner."
    (if *showkeys-on*
        (begin
          (advice-remove! 'imp-handle-key showkeys-key!)
          (set! *showkeys-on* #f)
          (showkeys-hide!)
          (message "showkeys-mode off"))
        (begin
          (advice-add! 'imp-handle-key 'before showkeys-key!)
          (set! *showkeys-on* #t)
          (message "showkeys-mode on")))))
