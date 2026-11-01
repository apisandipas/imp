;;; olivetti.scm -- a comfortable column of text, after Emacs's olivetti.
;;;
;;; olivetti-mode gives a buffer blank margins either side, so its text
;;; is a column olivetti-body-width wide in the middle of each window,
;;; however wide the window is. Long lines wrap in the column between
;;; words (wrap and linebreak, for that buffer) unless olivetti-wrap is off.
;;;
;;;   (use-package! 'olivetti
;;;     'config (lambda ()
;;;               (set-option! 'olivetti-body-width 72)
;;;               (set-option! 'olivetti-modes '(org-mode markdown-mode))))
;;;
;;;   SPC t o        olivetti-mode in this buffer, on or off
;;;   C-c } / C-c {  a wider or narrower column, in this buffer
;;;
;;; Buffers in olivetti-modes turn it on by themselves when they open.

;; How wide the column of text is, in columns.
(define-option! 'olivetti-body-width 80 '())
;; Major modes whose buffers turn olivetti-mode on when they open.
(define-option! 'olivetti-modes '() '())
;; Wrap long lines between words in olivetti-mode's buffers.
(define-option! 'olivetti-wrap #t '())

(define (olivetti-width)
  "This buffer's column width: its own if C-c } or C-c { changed it, else
   olivetti-body-width."
  (or (buffer-local 'olivetti-width) (option 'olivetti-body-width)))

(define (olivetti-setup!)
  "Centres the buffer's text and, with olivetti-wrap, wraps it between
   words, remembering wrap and linebreak as they were."
  (set-body-width! (olivetti-width))
  (when (option 'olivetti-wrap)
    (set-buffer-local! 'olivetti-was (list (option 'wrap) (option 'linebreak)))
    (set-local-option! 'wrap #t)
    (set-local-option! 'linebreak #t)))

(define (olivetti-teardown!)
  "Lets the buffer's text fill the window again, with wrap and linebreak
   as they were before."
  (set-body-width! 0)
  (let ([was (buffer-local 'olivetti-was)])
    (when was
      (set-local-option! 'wrap (car was))
      (set-local-option! 'linebreak (cadr was))
      (set-buffer-local! 'olivetti-was #f))))

(define-minor-mode! 'olivetti-mode olivetti-setup! olivetti-teardown!)

(define (olivetti-resize! by)
  "Makes this buffer's column `by` columns wider (narrower if negative),
   keeping it at least 20 wide, and says how wide it is."
  (let ([width (max 20 (+ (olivetti-width) by))])
    (set-buffer-local! 'olivetti-width width)
    (set-body-width! width)
    (message (string-append "olivetti: " (number->string width) " columns"))))

(define-command! 'olivetti-mode
  (lambda (count)
    "Turn olivetti-mode on or off: a centred column of text in this buffer."
    (toggle-minor-mode! 'olivetti-mode)))

(define-command! 'olivetti-wider
  (lambda (count)
    "Make this buffer's olivetti column wider by 4 columns (count times)."
    (olivetti-resize! (* 4 count))))

(define-command! 'olivetti-narrower
  (lambda (count)
    "Make this buffer's olivetti column narrower by 4 columns (count times)."
    (olivetti-resize! (* -4 count))))

(define-leader! "to" 'olivetti-mode "olivetti")
(for-each (lambda (state)
            (define-mode-key! 'olivetti-mode state "C-c}" 'olivetti-wider)
            (define-mode-key! 'olivetti-mode state "C-c{" 'olivetti-narrower))
          '(normal visual))

;; Buffers of the modes in olivetti-modes start with it on.
(add-hook! 'major-mode
  (lambda (mode)
    (when (and (memq mode (option 'olivetti-modes)) (not (memq 'olivetti-mode (minor-modes))))
      (minor-mode-on! 'olivetti-mode))))
