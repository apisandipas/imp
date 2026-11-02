;;; posframe.scm -- completion in a box in the middle of the screen, after
;;; Emacs's vertico-posframe.
;;;
;;; With it loaded, M-x, find-file, switch-buffer, the describe commands
;;; and every other completing-read draw their prompt and menu in a
;;; bordered box across the middle of the screen, rather than along the
;;; bottom. Other prompts (: and /) stay at the bottom.
;;;
;;;   (use-package! 'posframe
;;;     'config (lambda () (set-option! 'posframe-width 70)))
;;;
;;; M-x posframe-mode turns it off and on again.

;; How wide the box is, in percent of the screen's width.
(define-option! 'posframe-width 60 '())

(define *posframe-on* #f)

(define (posframe-on!)
  "Puts completion menus in a centred box, posframe-width percent wide."
  (set! *posframe-on* #t)
  (set! *completion-place* (list "center" (option 'posframe-width)))
  void)

(define (posframe-off!)
  "Puts completion menus back along the bottom of the screen."
  (set! *posframe-on* #f)
  (set! *completion-place* (list "bottom" 0))
  void)

(define-command! 'posframe-mode
  (lambda (count)
    "Turn the centred completion box on or off."
    (if *posframe-on* (posframe-off!) (posframe-on!))
    (message (if *posframe-on* "posframe on" "posframe off"))))

;; A new width applies to the next menu.
(watch-option! 'posframe-width (lambda (value) (when *posframe-on* (posframe-on!))))

(posframe-on!)
