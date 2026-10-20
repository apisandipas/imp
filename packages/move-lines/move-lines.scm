;;; move-lines.scm -- J and K move the selected lines, after the
;;; `:m '>+1<CR>gv` mappings and Emacs's drag-stuff.
;;;
;;;   (use-package! 'move-lines)
;;;
;;; In visual line mode (V), J moves the selected lines down a line and K
;;; up (a count moves them further), keeping them selected so you can
;;; press again. Each move is one undo step. In the other visual modes J
;;; and K keep their Vim meanings: J joins lines and K looks up the word.

(define (move-lines-by! n)
  "Moves the lines of the visual line selection `n` lines down (up when
   negative), stopping at the top and bottom of the buffer, and selects
   them again where they landed."
  (let* ([r (visual-range)]
         [first (offset->line (car r))]
         [last (offset->line (max (car r) (- (cadr r) 1)))]
         [count (+ 1 (- last first))]
         [n (max (- first) (min n (- (last-line) last)))]
         [cursor-at-end? (>= (cursor) *visual-anchor*)])
    (when (not (= n 0))
      (let ([text (lines-text first last)])
        (begin-change!)
        (delete-lines! first last)
        (insert-lines-after! (+ first n -1) text)))
    (let ([first (+ first n)] [last (+ last n)])
      (if cursor-at-end?
          (begin (set! *visual-anchor* (line-start first)) (set-cursor! (line-start last)))
          (begin (set! *visual-anchor* (line-start last)) (set-cursor! (line-start first))))
      (update-visual-highlight!))))

(define (move-lines-key down? fallback)
  "The visual J or K: in visual line mode, move the selection down (or up)
   by the count; otherwise what `fallback`, the key's earlier binding,
   does."
  (lambda (count)
    (cond
      [(eq? *visual* 'line) (move-lines-by! (if down? count (- count)))]
      [(symbol? fallback) (run-command fallback count)]
      [fallback (fallback count)]
      [else #f])))

(define-key! 'visual "J" (move-lines-key #t (key-binding 'visual "J")))
(define-key! 'visual "K" (move-lines-key #f (key-binding 'visual "K")))
