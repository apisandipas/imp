;;; org.scm -- Org mode: outlines, TODOs, checkboxes, links, tables, and an
;;; agenda over your .org files.
;;;
;;; In a .org buffer (normal state; SPC m has the same under the leader):
;;;
;;;   <tab>      on a heading, cycle its subtree: folded, children, all;
;;;              in a table, align it and go to the next cell; on a
;;;              drawer (:PROPERTIES:), open or close it
;;;   <s-tab>    cycle the whole buffer: overview, contents, all
;;;   <ret>      do what the line means: follow a link, toggle a checkbox,
;;;              cycle a heading's TODO keyword, align a table
;;;   M-<ret>    new heading (or list item) after this one, in insert state
;;;   M-h M-l    promote, demote the heading or list item (M-H M-L: subtree)
;;;   M-k M-j    move the subtree up, down
;;;   gx         follow the link at the cursor
;;;
;;; SPC o c captures: a TODO, a note or a journal entry, from templates
;;; (see Capture below).
;;;
;;;   C-c C-s    schedule the heading (SCHEDULED:), from a calendar
;;;   C-c C-d    give it a deadline (DEADLINE:)
;;;   C-c .      put a timestamp at the cursor, or change the one there
;;;   C-c C-x p  set a property of the heading (SPC m P); empty removes it
;;;   C-c C-x C-i, C-o, C-q, C-j   clock in on the heading, clock out,
;;;              cancel the clock, go to it (SPC m c i, o, c, g)
;;;
;;; A timestamp ending in a repeater, <2026-10-24 Sat +1w> (or ++1w, .+1w),
;;; moves on when its heading is marked done, and the heading goes back
;;; to its first TODO keyword.

;; Where Org files are: the agenda's files are under it, and capture's
;; inbox.org.
(define-option! 'org-directory "~/org" '())
;; The files the agenda reads, relative ones under org-directory; empty
;; reads every .org file under org-directory.
(define-option! 'org-agenda-files '() '())
;; Empty means inbox.org in org-directory.
(define-option! 'org-default-notes-file "" '())
;; The TODO keywords a heading cycles through. As in Org, a "|" splits
;; them into not done and done, as in '("TODO" "NEXT" "|" "DONE"
;; "CANCELLED"); with no "|" only the last is done.
(define-option! 'org-todo-keywords '("TODO" "DONE") '())
;; Links show just their description, [[target][like this]] as "like
;; this" and [[target]] as "target", except on the cursor's line, where
;; they show whole to edit (as org-appear does). #f shows them as written.
(define-option! 'org-link-descriptive #t '())
;; Drawers (:PROPERTIES: to :END:, :LOGBOOK: and the like) start closed
;; when a file opens and close again as headings cycle open, as in Org.
;; <tab> on one opens or closes it.
(define-option! 'org-fold-drawers #t '())
;; Draw each section indented under its heading, as Org's org-indent-mode
;; does: text lines up with its heading's title, and a heading's leading
;; stars but the last are drawn blank. Only the display changes, not the
;; file. org-indent-per-level is the columns a level adds.
(define-option! 'org-indent #f '())
;; Columns each heading level adds with org-indent.
(define-option! 'org-indent-per-level 2 '())
;; How much bigger headings are drawn, from level 1 down: 1.4 is 1.4
;; times the font. Levels past the list are the font's size; '() makes
;; them all so. Window clients only: a terminal draws one size.
(define-option! 'org-heading-heights '(1.4 1.25 1.1) '())
;; Marking a heading done adds CLOSED: [stamp] to its planning line
;; ('time, as Doom); #f doesn't. Leaving done removes it.
(define-option! 'org-log-done 'time '())
;; Marking a repeating heading done sets its LAST_REPEAT property and
;; logs the state change at the top of its :LOGBOOK: ('time); #f doesn't.
(define-option! 'org-log-repeat 'time '())

;;; Headings and subtrees

(define (org-level-of text)
  "The level of heading text `text` (how many stars), or #f."
  (let ([n (string-length text)])
    (let loop ([i 0])
      (cond [(and (< i n) (equal? (string-ref text i) #\*)) (loop (+ i 1))]
            [(and (> i 0) (< i n) (equal? (string-ref text i) #\space)) i]
            [else #f]))))

(define (org-level line)
  "The level of the heading on buffer line `line`, or #f if it isn't one."
  (org-level-of (line-text line)))

(define (org-heading-line line)
  "The heading at or above `line`, or #f."
  (let loop ([l line]) (cond [(< l 0) #f] [(org-level l) l] [else (loop (- l 1))])))

(define (org-subtree-end line)
  "The last line under the heading on `line`, before a heading of its
   level or higher."
  (let ([level (org-level line)])
    (let loop ([l (+ line 1)])
      (cond [(> l (last-line)) (last-line)]
            [(let ([lv (org-level l)]) (and lv (<= lv level))) (- l 1)]
            [else (loop (+ l 1))]))))

(define (org-body-end line)
  "The last line of the heading's own text, before any heading."
  (let loop ([l (+ line 1)])
    (cond [(> l (last-line)) (last-line)]
          [(org-level l) (- l 1)]
          [else (loop (+ l 1))])))

(define (org-children line)
  "The headings directly under the one on `line`."
  (let ([end (org-subtree-end line)])
    (let loop ([l (+ line 1)] [acc '()] [child-level #f])
      (if (> l end)
          (reverse acc)
          (let ([lv (org-level l)])
            (if (and lv (or (not child-level) (<= lv child-level)))
                (loop (+ l 1) (cons l acc) lv)
                (loop (+ l 1) acc child-level)))))))

(define (org-headings)
  "Every heading line in the buffer, in order."
  (filter org-level (range 0 (buffer-line-count))))

;;; Visibility, with folds (fold.scm)

(define (org-folds-from first last)
  "The folds that start on a line from `first` to `last`."
  (filter (lambda (f) (and (>= (fold-first f) first) (<= (fold-first f) last))) (buffer-folds)))

(define (org-unfold! first last)
  "Deletes every fold starting between lines `first` and `last`."
  (for-each (lambda (f) (fold-delete! (fold-id f))) (org-folds-from first last)))

(define (org-fold! first last)
  "Folds lines `first` to `last` closed, unless that is a single line."
  (when (> last first) (fold-create! first last #t)))

(define (org-drawer-start? text)
  "Whether `text` opens a drawer: a line that is just :NAME:, not :END:."
  (let* ([t (trim text)] [n (string-length t)])
    (and (> n 2) (starts-with? t ":") (ends-with? t ":") (not (equal? (string-upcase t) ":END:"))
         (let loop ([i 1])
           (cond [(= i (- n 1)) #t]
                 [(let ([c (string-ref t i)]) (or (char-word? c) (equal? c #\-))) (loop (+ i 1))]
                 [else #f])))))

(define (org-drawer-end line)
  "The :END: line of the drawer opening on `line`, or #f when a heading
   or the end of the buffer comes first."
  (let loop ([l (+ line 1)])
    (cond [(> l (last-line)) #f]
          [(org-level l) #f]
          [(equal? (string-upcase (trim (line-text l))) ":END:") l]
          [else (loop (+ l 1))])))

(define (org-drawer-fold? f)
  "Whether fold `f` is a drawer's."
  (org-drawer-start? (line-text (fold-first f))))

(define (org-close-drawers! first last)
  "Closes every drawer opening between lines `first` and `last`, when
   org-fold-drawers is on."
  (when (option 'org-fold-drawers)
    (let loop ([l first])
      (when (<= l last)
        (let ([end (and (org-drawer-start? (line-text l)) (org-drawer-end l))])
          (if end
              (begin
                (unless (list-find (lambda (f) (= (fold-first f) l)) (buffer-folds))
                  (fold-create! l end #t))
                (loop (+ end 1)))
              (loop (+ l 1))))))))

(define (org-toggle-drawer! line)
  "Opens or closes the drawer opening on `line`."
  (let ([fold (list-find (lambda (f) (= (fold-first f) line)) (buffer-folds))]
        [end (org-drawer-end line)])
    (cond [fold (fold-delete! (fold-id fold))]
          [end (fold-create! line end #t)]
          [else (message "no :END: for this drawer")])))

(define (org-cycle! line)
  "Cycles the subtree under the heading on `line`: FOLDED, CHILDREN (the
   child headings, their text hidden), SUBTREE (everything)."
  (let ([end (org-subtree-end line)] [children (org-children line)])
    (cond
      [(= end line) (message "empty entry")]
      [(list-find (lambda (f) (and (= (fold-first f) line) (= (fold-last f) end) (fold-closed? f))) (buffer-folds))
       (org-unfold! line end)
       (if (null? children)
           (begin (org-close-drawers! line end) (message "SUBTREE"))
           (begin
             (org-fold! line (- (car children) 1))
             (for-each (lambda (c) (org-fold! c (org-subtree-end c))) children)
             (message "CHILDREN")))]
      [(pair? (filter (lambda (f) (not (org-drawer-fold? f))) (org-folds-from line end)))
       (org-unfold! line end) (org-close-drawers! line end) (message "SUBTREE")]
      [else (org-unfold! line end) (org-fold! line end) (message "FOLDED")])
    (set-cursor! (line-start line))))

(define (org-global-cycle!)
  "Cycles the whole buffer: OVERVIEW (top headings), CONTENTS (every
   heading), SHOW ALL."
  (let ([state (or (buffer-local 'org-visibility) 'all)] [headings (org-headings)])
    (org-unfold! 0 (last-line))
    (cond
      [(null? headings) (message "no headings")]
      [(eq? state 'all)
       (let ([top (apply min (map org-level headings))])
         (for-each (lambda (h) (when (= (org-level h) top) (org-fold! h (org-subtree-end h)))) headings))
       (set-buffer-local! 'org-visibility 'overview)
       (message "OVERVIEW")]
      [(eq? state 'overview)
       (for-each (lambda (h) (org-fold! h (org-body-end h))) headings)
       (set-buffer-local! 'org-visibility 'contents)
       (message "CONTENTS")]
      [else (org-close-drawers! 0 (last-line)) (set-buffer-local! 'org-visibility 'all) (message "SHOW ALL")])
    (let ([line (current-line)]) (set-cursor! (line-start (shown-line line))))))

;;; Editing lines

(define (org-lines-text first last)
  "Text of lines first..last, each ending in a line break."
  (string-append (buffer-substring (line-start first) (line-end last)) "\n"))

(define (org-replace-lines! first last text)
  "Replaces lines first..last with `text` (lines ending in line breaks)."
  (let* ([end (line-end last)] [break? (< end (buffer-length))])
    (replace-range! (line-start first) (if break? (+ end 1) end)
                    (if break? text (substring text 0 (- (string-length text) 1))))))

(define (org-set-line! line text)
  "Replaces the text of `line`, leaving its line break."
  (replace-range! (line-start line) (line-end line) text))

(define (org-keywords)
  "The TODO keywords in `org-todo-keywords`, in order, without the \"|\"
   that separates the not-done ones from the done ones."
  (filter (lambda (k) (not (equal? k "|"))) (option 'org-todo-keywords)))

(define (org-done-keywords)
  "The keywords that mean done: those after \"|\" in
   `org-todo-keywords`, or with no \"|\" the last one, as in Org."
  (let* ([kws (option 'org-todo-keywords)] [after (member "|" kws)])
    (cond [after (filter (lambda (k) (not (equal? k "|"))) (cdr after))]
          [(null? kws) '()]
          [else (list (last kws))])))

(define (org-keyword-in rest)
  "The keyword the heading text after its stars starts with, or #f."
  (list-find (lambda (k) (or (equal? rest k) (starts-with? rest (string-append k " "))))
             (org-keywords)))

(define (org-remove-cookies text)
  "`text` without statistics cookies like [1/3], [50%] or []."
  (let ([n (string-length text)])
    (let loop ([i 0] [from 0] [acc '()])
      (if (>= i n)
          (apply string-append (reverse (cons (substring text from n) acc)))
          (let* ([digits-end (lambda (j) (let d ([j j]) (if (and (< j n) (char-numeric-ascii? (string-ref text j))) (d (+ j 1)) j)))]
                 [end (and (equal? (string-ref text i) #\[)
                           (let* ([j (digits-end (+ i 1))]
                                  [j (cond [(>= j n) #f]
                                           [(equal? (string-ref text j) #\%) (+ j 1)]
                                           [(equal? (string-ref text j) #\/) (digits-end (+ j 1))]
                                           [else j])])
                             (and j (< j n) (equal? (string-ref text j) #\]) (+ j 1))))])
            (if end
                (loop end end (cons (substring text from i) acc))
                (loop (+ i 1) from acc)))))))

(define (org-normalize-title text)
  "`text` as Org compares heading titles: statistics cookies removed and
   runs of whitespace made single spaces."
  (string-join (split-whitespace (org-remove-cookies text)) " "))

(define (org-tag-char? c)
  "Whether `c` may appear in an Org tag."
  (or (char-numeric-ascii? c) (not (equal? (char-upcase c) (char-downcase c))) (member c '(#\_ #\@ #\# #\% #\:))))

(define (org-heading-title text)
  "The title of heading text `text`: without its stars, TODO keyword,
   priority like [#A] or tags like :work:urgent:, normalized as
   `org-normalize-title` does."
  (let* ([level (or (org-level-of text) 0)]
         [rest (trim-start (substring text (min (+ level 1) (string-length text)) (string-length text)))]
         [kw (org-keyword-in rest)]
         [rest (if kw (trim-start (substring rest (string-length kw) (string-length rest))) rest)]
         [rest (if (and (>= (string-length rest) 4) (starts-with? rest "[#") (equal? (string-ref rest 3) #\]))
                   (trim-start (substring rest 4 (string-length rest)))
                   rest)]
         [rest (trim-end rest)]
         [words (split-whitespace rest)]
         [tags (and (pair? words) (last words))]
         [rest (if (and tags (> (string-length tags) 1) (starts-with? tags ":") (ends-with? tags ":")
                        (andmap org-tag-char? (string->list tags)))
                   (substring rest 0 (- (string-length rest) (string-length tags)))
                   rest)])
    (org-normalize-title rest)))

(define (org-todo-set! line next)
  "Gives the heading on `line` TODO keyword `next`, or none when it is
   #f. Done with a repeating date, the date moves on instead and the
   keyword goes back to the first."
  (let* ([text (line-text line)]
         [level (org-level line)]
         [rest (substring text (+ level 1) (string-length text))]
         [kws (org-keywords)]
         [current (org-keyword-in rest)]
         [title (if current (trim-start (substring rest (string-length current) (string-length rest))) rest)]
         [repeat? (and next (member next (org-done-keywords))
                       (pair? (org-repeating-stamps line (org-body-end line)))
                       (list next))]
         [next (if repeat? (car kws) next)])
    (with-undo-group
     (lambda ()
       (begin-change!)
       (org-set-line! line (string-append (make-string level #\*) " " (if next (string-append next " ") "") title))
       (org-log-change! line current (if repeat? (car repeat?) next) repeat?)
       (let ([moved (and repeat? (org-repeat-entry! line))])
         (set-cursor! (line-start line))
         (message (if moved (string-append "repeats: " moved) (or next "no keyword"))))))))

(define (org-todo-cycle! line)
  "Moves the heading on `line` to the next TODO keyword (none after the last)."
  (let* ([text (line-text line)]
         [rest (substring text (+ (org-level line) 1) (string-length text))]
         [kws (org-keywords)]
         [current (org-keyword-in rest)])
    (org-todo-set! line (cond [(not current) (car kws)]
                              [(member current kws)
                               (let ([after (cdr (member current kws))]) (if (null? after) #f (car after)))]
                              [else #f]))))

(define (org-priority-in text)
  "The priority letter `text` starts with, as in \"[#A] title\", or #f."
  (and (>= (string-length text) 4) (starts-with? text "[#") (equal? (string-ref text 3) #\])
       (string (string-ref text 2))))

(define (org-set-priority! line priority)
  "Gives the heading on `line` priority `priority` (\"A\", \"B\"...), or
   none when it is #f. The cookie goes after the TODO keyword."
  (let* ([text (line-text line)]
         [level (org-level line)]
         [rest (substring text (+ level 1) (string-length text))]
         [kw (org-keyword-in rest)]
         [title (if kw (trim-start (substring rest (string-length kw) (string-length rest))) rest)]
         [title (if (org-priority-in title) (trim-start (substring title 4 (string-length title))) title)])
    (begin-change!)
    (org-set-line! line (string-append (make-string level #\*) " " (if kw (string-append kw " ") "")
                                       (if priority (string-append "[#" priority "] ") "") title))
    (set-cursor! (line-start line))))

(define (org-priority-menu!)
  "C-c ,: asks for the priority of the heading the cursor is under."
  (let ([h (org-heading-line (current-line))])
    (if (not h)
        (message "not under a heading")
        (menu! "Priority"
               (append (map (lambda (p) (list (string-downcase p) p (lambda () (org-set-priority! h p))))
                            '("A" "B" "C"))
                       (list (list " " "remove" (lambda () (org-set-priority! h #f)))))))))

(define (org-priority-rank p)
  "Where priority `p` sorts: A first, a heading with none as B."
  (char->integer (string-ref (or p "B") 0)))

(define (org-list-item line)
  "A list item on `line`: (indent-width marker-end checkbox-offset-or-#f), or #f."
  (let* ([text (line-text line)] [n (string-length text)] [start (line-start line)])
    (let skip ([i 0])
      (cond
        [(and (< i n) (equal? (string-ref text i) #\space)) (skip (+ i 1))]
        [(>= i n) #f]
        [else
         (let* ([c (string-ref text i)]
                [after (cond [(and (member c '(#\- #\+)) (< (+ i 1) n) (equal? (string-ref text (+ i 1)) #\space)) (+ i 2)]
                             ;; "* item" is an item only when indented (else it's a heading).
                             [(and (equal? c #\*) (> i 0) (< (+ i 1) n) (equal? (string-ref text (+ i 1)) #\space)) (+ i 2)]
                             [(char-numeric-ascii? c)
                              (let digits ([j i])
                                (cond [(and (< j n) (char-numeric-ascii? (string-ref text j))) (digits (+ j 1))]
                                      [(and (< (+ j 1) n) (member (string-ref text j) '(#\. #\))) (equal? (string-ref text (+ j 1)) #\space)) (+ j 2)]
                                      [else #f]))]
                             [else #f])])
           (and after
                (list i after
                      (and (< (+ after 2) n) (equal? (string-ref text after) #\[)
                           (member (string-ref text (+ after 1)) '(#\space #\X #\x #\-))
                           (equal? (string-ref text (+ after 2)) #\])
                           (+ start after)))))]))))

(define (org-toggle-checkbox! line)
  "Toggles the checkbox on `line`, then updates the [n/m] or [n%] cookie of
   its heading."
  (let* ([item (org-list-item line)] [box (and item (caddr item))])
    (when box
      (begin-change!)
      (let ([checked? (member (buffer-char-at (+ box 1)) '(#\X #\x))])
        (replace-range! (+ box 1) (+ box 2) (if checked? " " "X")))
      (let ([h (org-heading-line line)]) (when h (org-update-cookie! h))))))

(define (org-count-boxes first last)
  "(checked total): the checkboxes on lines `first` to `last`."
  (foldl (lambda (l acc)
           (let* ([item (org-list-item l)] [box (and item (caddr item))])
             (if box
                 (list (+ (car acc) (if (member (buffer-char-at (+ box 1)) '(#\X #\x)) 1 0)) (+ (cadr acc) 1))
                 acc)))
         (list 0 0) (range first (+ last 1))))

(define (org-find-cookie text)
  "The [..] cookie in `text`: (start end percent?), or #f."
  (let ([n (string-length text)])
    (let loop ([i 0])
      (cond
        [(>= i n) #f]
        [(equal? (string-ref text i) #\[)
         (let scan ([j (+ i 1)] [slash? #f])
           (cond [(>= j n) #f]
                 [(char-numeric-ascii? (string-ref text j)) (scan (+ j 1) slash?)]
                 [(and (equal? (string-ref text j) #\/) (not slash?)) (scan (+ j 1) #t)]
                 [(and (equal? (string-ref text j) #\%) (< (+ j 1) n) (equal? (string-ref text (+ j 1)) #\]))
                  (list i (+ j 2) #t)]
                 [(and (equal? (string-ref text j) #\]) slash?) (list i (+ j 1) #f)]
                 [else (loop (+ i 1))]))]
        [else (loop (+ i 1))]))))

(define (org-update-cookie! heading)
  "Recounts the [n/m] or [n%] cookie on `heading` from its checkboxes.
   Counts the boxes in the heading's own text, not its subheadings',
   and does nothing when the heading has no cookie."
  (let* ([text (line-text heading)] [cookie (org-find-cookie text)])
    (when cookie
      (let* ([counts (org-count-boxes (+ heading 1) (org-body-end heading))]
             [done (car counts)] [total (cadr counts)]
             [new (if (caddr cookie)
                      (string-append "[" (number->string (if (= total 0) 0 (quotient (* 100 done) total))) "%]")
                      (string-append "[" (number->string done) "/" (number->string total) "]"))]
             [start (+ (line-start heading) (car cookie))])
        (replace-range! start (+ (line-start heading) (cadr cookie)) new)))))

(define (org-insert-heading!)
  "M-<ret>: a new item after a list item, or a heading after this subtree."
  (let* ([line (current-line)] [item (org-list-item line)] [h (org-heading-line line)])
    (begin-change!)
    (cond
      [item
       (let* ([text (line-text line)]
              [prefix (string-append (substring text 0 (cadr item)) (if (caddr item) "[ ] " ""))])
         (buffer-insert! (line-end line) (string-append "\n" prefix))
         (set-cursor! (line-end (+ line 1))))]
      [else
       (let* ([level (if h (org-level h) 1)]
              [end (if h (org-subtree-end h) line)]
              [stars (string-append (make-string level #\*) " ")])
         ;; Insert at the start of the next line, so a closed fold of this
         ;; subtree doesn't swallow the new heading.
         (if (< end (last-line))
             (begin (buffer-insert! (line-start (+ end 1)) (string-append stars "\n"))
                    (set-cursor! (line-end (+ end 1))))
             (let ([break? (and (> (buffer-length) 0) (equal? (buffer-char-at (- (buffer-length) 1)) #\newline))])
               (buffer-insert! (buffer-length) (string-append (if break? "" "\n") stars (if break? "\n" "")))
               (set-cursor! (line-end (last-line))))))])
    (set-mode! 'insert)
    (set! *insert-start* (cursor)))
  void)

(define (org-shift! line delta subtree?)
  "Promotes (-1) or demotes (+1) the heading or list item on `line`, or
   with `subtree?` every heading under it too."
  (let ([level (org-level line)] [item (org-list-item line)])
    (cond
      [level
       (if (and (< delta 0) (= level 1))
           (message "can't promote a top-level heading")
           (let ([lines (if subtree? (filter org-level (range line (+ (org-subtree-end line) 1))) (list line))])
             (begin-change!)
             (for-each (lambda (l)
                         (if (> delta 0)
                             (buffer-insert! (line-start l) "*")
                             (buffer-delete! (line-start l) (+ (line-start l) 1))))
                       lines)))]
      [item
       (begin-change!)
       (if (> delta 0)
           (buffer-insert! (line-start line) "  ")
           (buffer-delete! (line-start line) (+ (line-start line) (min 2 (car item)))))]
      [else (message "not on a heading or list item")])))

(define (org-move-subtree! down?)
  "Swaps the subtree under the heading at the cursor with the sibling
   after it (down?) or before it."
  (let* ([h (org-heading-line (current-line))] [level (and h (org-level h))])
    (if (not h)
        (message "not in a subtree")
        (let* ([end (org-subtree-end h)]
               [other (if down?
                          (and (< end (last-line)) (equal? (org-level (+ end 1)) level) (+ end 1))
                          (let loop ([l (- h 1)])
                            (cond [(< l 0) #f]
                                  [(org-level l) (and (= (org-level l) level) l)]
                                  [else (loop (- l 1))])))])
          (if (not other)
              (message (if down? "no subtree below to swap with" "no subtree above to swap with"))
              (let* ([first (if down? h other)] [second (if down? other h)]
                     [a (org-lines-text first (- second 1))]
                     [b (org-lines-text second (org-subtree-end second))])
                (begin-change!)
                (org-unfold! first (org-subtree-end second))
                (org-replace-lines! first (org-subtree-end second) (string-append b a))
                (set-cursor! (line-start (if down? (+ first (length (text-lines b))) first)))))))))

;;; Links

(define (org-link-at at)
  "The link at offset `at`: its target, or #f. [[target][text]],
   [[target]], or a bare http(s) URL."
  (let* ([line (offset->line at)] [text (line-text line)] [col (- at (line-start line))] [n (string-length text)])
    (or
     (let loop ([i 0])
       (cond
         [(>= (+ i 1) n) #f]
         [(and (equal? (string-ref text i) #\[) (equal? (string-ref text (+ i 1)) #\[))
          (let find-end ([j (+ i 2)])
            (cond [(>= (+ j 1) n) #f]
                  [(and (equal? (string-ref text j) #\]) (equal? (string-ref text (+ j 1)) #\]))
                   (if (and (<= i col) (<= col (+ j 1)))
                       (car (split-many (substring text (+ i 2) j) "]["))
                       (loop (+ j 2)))]
                  [else (find-end (+ j 1))]))]
         [else (loop (+ i 1))]))
     ;; A bare URL around the cursor.
     (let* ([start (let back ([i col]) (if (and (> i 0) (not (char-whitespace? (string-ref text (- i 1))))) (back (- i 1)) i))]
            [end (let fwd ([i col]) (if (and (< i n) (not (char-whitespace? (string-ref text i)))) (fwd (+ i 1)) i))]
            [word (if (< start end) (substring text start end) "")])
       (and (or (starts-with? word "http://") (starts-with? word "https://")) word)))))

(define (org-follow! target)
  "Follows link `target`, like Org's C-c C-o.
   A URL or mailto: opens with xdg-open; *Title jumps to the heading
   titled Title (its keyword, priority and tags aside); anything else is a file (file: optional, relative
   to this buffer's directory) with an optional ::LINE or ::TEXT to
   go to."
  (cond
    [(or (starts-with? target "http://") (starts-with? target "https://") (starts-with? target "mailto:"))
     (start-job! (string-append "xdg-open " (shell-quote target)) "" #f #f)
     (message (string-append "opening " target))]
    [(starts-with? target "*")
     ;; As in Org, the title must match exactly, keyword, priority and
     ;; tags aside.
     (let* ([title (substring target 1 (string-length target))]
            [want (org-normalize-title title)]
            [h (list-find (lambda (l) (equal? (org-heading-title (line-text l)) want)) (org-headings))])
       (if h (begin (record-jump!) (set-cursor! (line-start h))) (message (string-append "no heading " title))))]
    [else
     (let* ([target (if (starts-with? target "file:") (substring target 5 (string-length target)) target)]
            [parts (split-many target "::")]
            [path (car parts)]
            [full (if (or (starts-with? path "/") (starts-with? path "~") (not (buffer-path)))
                      path
                      (string-append (directory-of (buffer-path)) "/" path))])
       (when (open-file! full)
         (when (pair? (cdr parts))
           (let ([n (string->number (cadr parts))])
             (if n
                 (set-cursor! (line-first-nonblank (clamp (- n 1) 0 (last-line))))
                 (let ([hit (search-next (cadr parts) 0 #t)]) (when hit (set-cursor! (car hit)))))))))]))

;;; Tables

(define (org-table-line? line)
  "Whether buffer line `line` exists and is a table row (starts with |)."
  (and (<= 0 line) (<= line (last-line)) (starts-with? (trim-start (line-text line)) "|")))

(define (org-table-bounds line)
  "(first last): the lines of the table around `line`."
  (list (let up ([l line]) (if (org-table-line? (- l 1)) (up (- l 1)) l))
        (let down ([l line]) (if (org-table-line? (+ l 1)) (down (+ l 1)) l))))

(define (org-separator? text)
  "Whether table row `text` is a rule, |-..."
  (starts-with? (trim-start text) "|-"))

(define (org-row-cells text)
  "The cells of table row `text`, trimmed."
  (let* ([t (trim text)]
         [parts (split-many (substring t 1 (string-length t)) "|")]
         [parts (if (and (pair? parts) (equal? (trim (last parts)) "")) (reverse (cdr (reverse parts))) parts)])
    (map trim parts)))

(define (org-table-align! line . live)
  "Aligns the table around `line`, padding every column to its widest.
   Returns (first-line columns cell-index), the cell being the 1-based
   one the cursor was in. With `live`, a (cell text) pair, the cursor's
   line has that 0-based cell's text as typed, and the change joins the
   insert in progress instead of being an undo step of its own."
  (let* ([bounds (org-table-bounds line)] [first (car bounds)] [last (cadr bounds)]
         [texts (map line-text (range first (+ last 1)))]
         [indent (let ([t (car texts)]) (substring t 0 (- (string-length t) (string-length (trim-start t)))))]
         [keep (and (pair? live) (car live))]
         [rows (map (lambda (t l)
                      (cond [(org-separator? t) 'rule]
                            [(and keep (= l (current-line)))
                             (let ([cells (org-row-cells t)])
                               (map (lambda (c i) (if (= i (car keep)) (cadr keep) c))
                                    cells (range 0 (length cells))))]
                            [else (org-row-cells t)]))
                    texts (range first (+ last 1)))]
         [cols (apply max (cons 1 (map (lambda (r) (if (eq? r 'rule) 0 (length r))) rows)))]
         [width (lambda (i) (apply max (cons 1 (map (lambda (r) (if (and (pair? r) (< i (length r))) (string-length (list-ref r i)) 0)) rows))))]
         [widths (map width (range 0 cols))]
         [cell (lambda (r i) (if (< i (length r)) (list-ref r i) ""))]
         [render (lambda (r)
                   (if (eq? r 'rule)
                       (string-append indent "|" (string-join (map (lambda (w) (make-string (+ w 2) #\-)) widths) "+") "|")
                       (string-append indent "| "
                                      (string-join (map (lambda (i) (pad-right (cell r i) (list-ref widths i))) (range 0 cols)) " | ")
                                      " |")))]
         [cell-index (let ([col (current-col)] [t (line-text (current-line))])
                       (length (filter (lambda (i) (equal? (string-ref t i) #\|)) (range 0 (min col (string-length t))))))]
         [new (string-append (string-join (map render rows) "\n") "\n")])
    (unless (equal? new (org-lines-text first last))
      (unless keep (begin-change!))
      (org-replace-lines! first last new))
    (list first cols (max 1 cell-index))))

(define (org-table-live-align!)
  "Realigns the table at the cursor while typing in it, keeping the
   cursor where it was in its cell. The cell keeps what was typed up to
   the cursor, spaces included, so the space before the next word stays."
  (let* ([line (current-line)] [col (current-col)] [t (line-text line)]
         [bars (filter (lambda (i) (equal? (string-ref t i) #\|)) (range 0 (string-length t)))]
         [index (length (filter (lambda (b) (< b col)) bars))])
    (if (or (= index 0) (>= index (length bars)))
        (org-table-align! line (list -1 ""))
        (let* ([start (+ (list-ref bars (- index 1)) 1)]
               [raw (substring t start (list-ref bars index))]
               [body (trim-start raw)]
               [lead (- (string-length raw) (string-length body))]
               [offset (max 0 (min (- col start lead) (string-length body)))]
               [text (substring body 0 (max offset (string-length (trim-right body))))])
          (org-table-align! line (list (- index 1) text))
          (let* ([t (line-text line)]
                 [bars (filter (lambda (i) (equal? (string-ref t i) #\|)) (range 0 (string-length t)))])
            (when (< (- index 1) (length bars))
              (set-cursor! (+ (line-start line) (list-ref bars (- index 1)) 2 offset))))))))

;; Typing in a table keeps it aligned.
(add-hook! 'after-change
  (lambda ()
    (when (and (eq? (major-mode) 'org-mode) (eq? *mode* 'insert) (org-table-line? (current-line)))
      (org-table-live-align!))))

(define (org-go-to-cell! line index)
  "Moves to cell `index` (1-based) of row `line`."
  (let* ([t (line-text line)] [bars (filter (lambda (i) (equal? (string-ref t i) #\|)) (range 0 (string-length t)))])
    (set-cursor! (+ (line-start line) (min (+ (list-ref bars (min (- index 1) (- (length bars) 1))) 2) (string-length t))))))

(define (org-table-next-cell!)
  "<tab> in a table: align it and go to the next cell, past rules, adding
   a row at the end."
  (let* ([line (current-line)] [r (org-table-align! line)] [cols (cadr r)] [index (caddr r)])
    (if (< index cols)
        (org-go-to-cell! line (+ index 1))
        (let next-row ([l (+ line 1)])
          (cond
            [(not (org-table-line? l))
             (let ([indent (let ([t (line-text line)]) (substring t 0 (- (string-length t) (string-length (trim-start t)))))])
               (buffer-insert! (line-end line)
                               (string-append "\n" indent "|" (string-join (map (lambda (i) " ") (range 0 cols)) "|") "|"))
               (org-table-align! (+ line 1))
               (org-go-to-cell! (+ line 1) 1))]
            [(org-separator? (line-text l)) (next-row (+ l 1))]
            [else (org-go-to-cell! l 1)])))))

;;; Do what the line means

(define (org-dwim! count)
  "<ret> in Org: does what the line at the cursor means.
   Follows a link, toggles a checkbox, cycles a heading's TODO keyword
   or aligns a table; elsewhere it is the usual <ret> motion, `count`
   times."
  (let* ([line (current-line)] [link (org-link-at (cursor))] [item (org-list-item line)])
    (cond
      [link (org-follow! link)]
      [(and item (caddr item)) (org-toggle-checkbox! line)]
      [(org-level line) (org-todo-cycle! line)]
      [(org-table-line? line) (org-table-align! line)]
      [else (let ([target ((motion-proc (find-motion "<ret>")) (cursor) count)])
              (when target (set-cursor! target)))])))

(define (org-tab! count)
  "<tab> in Org: next table cell, cycle the heading's subtree, or open
   or close the drawer.
   Elsewhere it does whatever <tab> does in normal state."
  (let ([line (current-line)])
    (cond
      [(org-table-line? line) (org-table-next-cell!)]
      [(org-level line) (org-cycle! line)]
      [(org-drawer-start? (line-text line)) (org-toggle-drawer! line)]
      [else (let ([b (hash-try-get (keymap 'normal) "<tab>")])
              (when b ((if (symbol? b) (command-proc b) b) count)))])))

;;; Properties
;;;
;;; A heading's properties are the :NAME: value lines of the :PROPERTIES:
;;; drawer right under it (after its planning line, if any), as in Org.
;;; They are read from lines of text, a vector, so the agenda can read
;;; files that aren't open; (org-entry-property line name) reads the
;;; current buffer.

(define (org-property-line text)
  "The (NAME . value) a drawer line such as \":Effort: 2h\" holds, the
   name upper-cased, or #f."
  (let ([t (trim text)])
    (and (> (string-length t) 2) (starts-with? t ":")
         (let ([close (string-index-from t ":" 1)])
           (and close (> close 1)
                (cons (string-upcase (substring t 1 close))
                      (trim (substring t (+ close 1) (string-length t)))))))))

(define (org-drawer-at lines heading)
  "The (first last) lines of the property drawer of the heading at index
   `heading` of `lines`, from :PROPERTIES: to :END:, or #f."
  (let* ([n (vector-length lines)]
         [at (+ heading 1)]
         [at (if (and (< at n) (org-planning-line? (vector-ref lines at))) (+ at 1) at)])
    (and (< at n) (equal? (string-upcase (trim (vector-ref lines at))) ":PROPERTIES:")
         (let loop ([l (+ at 1)])
           (cond [(or (>= l n) (org-level-of (vector-ref lines l))) #f]
                 [(equal? (string-upcase (trim (vector-ref lines l))) ":END:") (list at l)]
                 [else (loop (+ l 1))])))))

(define (org-heading-properties lines heading)
  "The (NAME . value) properties of the heading at index `heading`."
  (let ([d (org-drawer-at lines heading)])
    (if d
        (filter (lambda (p) p) (map (lambda (l) (org-property-line (vector-ref lines l)))
                                    (range (+ (car d) 1) (cadr d))))
        '())))

(define (org-heading-above lines index)
  "The heading at or above index `index` of `lines`, or #f."
  (let loop ([l index]) (cond [(< l 0) #f] [(org-level-of (vector-ref lines l)) l] [else (loop (- l 1))])))

(define (org-parent-heading lines heading)
  "The heading the one at index `heading` is under, or #f."
  (let ([level (org-level-of (vector-ref lines heading))])
    (let loop ([l (- heading 1)])
      (cond [(< l 0) #f]
            [(let ([lv (org-level-of (vector-ref lines l))]) (and lv (< lv level))) l]
            [else (loop (- l 1))]))))

(define (org-file-setting lines key)
  "The value of the first `key` line in `lines`, as \"#+CATEGORY:\" (any
   case) gives \"work\" from \"#+category: work\", or #f."
  (let ([n (vector-length lines)] [k (string-upcase key)])
    (let loop ([l 0])
      (cond [(>= l n) #f]
            [(let ([t (vector-ref lines l)])
               (and (starts-with? (string-upcase t) k) (trim (substring t (string-length k) (string-length t)))))
             => (lambda (v) v)]
            [else (loop (+ l 1))]))))

(define (org-file-property lines name)
  "The value `#+PROPERTY: NAME value` lines give `name`, or #f."
  (let ([n (vector-length lines)] [name (string-upcase name)])
    (let loop ([l 0])
      (if (>= l n)
          #f
          (let ([t (vector-ref lines l)])
            (if (starts-with? (string-upcase t) "#+PROPERTY:")
                (let* ([rest (trim (substring t 11 (string-length t)))]
                       [parts (split-once rest " ")])
                  (if (and (pair? parts) (equal? (string-upcase (car parts)) name))
                      (if (pair? (cdr parts)) (trim (cadr parts)) "")
                      (loop (+ l 1))))
                (loop (+ l 1))))))))

(define (org-lines-property lines index name inherit?)
  "The value of property `name` for the entry at index `index` of
   `lines`, or #f. With `inherit?`, a heading without it takes its
   ancestors', then the file's #+PROPERTY:."
  (let ([name (string-upcase name)])
    (let loop ([h (org-heading-above lines index)])
      (let ([found (and h (assoc name (org-heading-properties lines h)))])
        (cond [found (cdr found)]
              [(not inherit?) #f]
              [h (loop (org-parent-heading lines h))]
              [else (org-file-property lines name)])))))

(define (org-buffer-lines)
  "The current buffer's lines, as a vector."
  (list->vector (map line-text (range 0 (buffer-line-count)))))

(define (org-entry-property line name . inherit)
  "The value of property `name` (any case) of the heading `line` is
   under, or #f. With a third argument #t, a heading without it takes
   its ancestors', then the file's #+PROPERTY: lines, as Org's
   inheritance does."
  (org-lines-property (org-buffer-lines) line name (and (pair? inherit) (car inherit))))

;;; Setting properties: C-c C-x p (SPC m P).

(define (org-property-name-in text)
  "The name of a drawer line such as \":Effort: 2h\", as written, or #f."
  (let ([t (trim text)])
    (and (starts-with? t ":")
         (let ([close (string-index-from t ":" 1)])
           (and close (> close 1) (substring t 1 close))))))

(define (org-property-names lines)
  "The names of the properties in any property drawer of `lines`, each
   once, as first written."
  (let loop ([hs (filter (lambda (l) (org-level-of (vector-ref lines l))) (range 0 (vector-length lines)))]
             [seen (hash)] [acc '()])
    (if (null? hs)
        (reverse acc)
        (let* ([d (org-drawer-at lines (car hs))]
               [names (if d
                          (filter (lambda (n) n) (map (lambda (l) (org-property-name-in (vector-ref lines l)))
                                                      (range (+ (car d) 1) (cadr d))))
                          '())]
               [new (filter (lambda (n) (not (hash-contains? seen (string-upcase n)))) names)])
          (loop (cdr hs)
                (foldl (lambda (n h) (hash-insert h (string-upcase n) #t)) seen new)
                (append (reverse new) acc))))))

(define (org-set-property! heading name value)
  "Sets property `name` of the heading on line `heading` to `value`, or
   removes it when `value` is \"\". The drawer is made, after the
   planning line, if the heading has none."
  (let* ([lines (org-buffer-lines)]
         [d (org-drawer-at lines heading)]
         [key (string-upcase name)]
         [at (and d (let loop ([l (+ (car d) 1)])
                      (cond [(>= l (cadr d)) #f]
                            [(let ([p (org-property-line (vector-ref lines l))]) (and p (equal? (car p) key))) l]
                            [else (loop (+ l 1))])))]
         [entry (lambda (n) (string-append ":" n ": " value))])
    (begin-change!)
    (cond
      [(equal? value "")
       (when at
         ;; The last property goes with its drawer.
         (if (= (- (cadr d) (car d)) 2)
             (replace-range! (line-start (car d)) (+ (line-end (cadr d)) (if (< (line-end (cadr d)) (buffer-length)) 1 0)) "")
             (replace-range! (line-start at) (+ (line-end at) 1) "")))]
      [at (org-set-line! at (entry (org-property-name-in (vector-ref lines at))))]
      [d (buffer-insert! (line-start (cadr d)) (string-append (entry name) "\n"))]
      [else
       (let ([after (if (and (<= (+ heading 1) (last-line)) (org-planning-line? (line-text (+ heading 1))))
                        (+ heading 1)
                        heading)])
         (buffer-insert! (line-end after) (string-append "\n:PROPERTIES:\n" (entry name) "\n:END:")))])
    (message (if (equal? value "") (string-append "removed " name) (string-append name ": " value)))))

(define (org-property-prompt!)
  "C-c C-x p: asks for a property name, completing from the buffer's,
   then its value for the heading the cursor is under. An empty value
   removes it."
  (let ([h (org-heading-line (current-line))])
    (if (not h)
        (message "not under a heading")
        (completing-read "Property: " (org-property-names (org-buffer-lines))
                         (lambda (name)
                           (if (or (string-index-from name ":" 0) (string-index-from name " " 0))
                               (message "a property name has no spaces or colons")
                               (open-cmdline! (string-append name ": ") (or (org-entry-property h name) "")
                                              (lambda (v) (org-set-property! h name (trim v))) #f #f)))))))

;;; Tags

(define (org-file-text file)
  "The text of `file`: its buffer's, unsaved changes included, when a
   buffer visits it, else what is on the disk."
  (let ([id (buffer-for-path (absolute-path file))])
    (if id
        (with-buffer id (lambda () (buffer-substring 0 (buffer-length))))
        (read-file file))))

(define (org-tags-of text)
  "The tags at the end of heading text `text`, as (\"work\" \"urgent\")
   from \"* TODO Write :work:urgent:\", or '()."
  (let* ([words (split-whitespace text)] [w (and (pair? words) (last words))])
    (if (and w (> (string-length w) 2) (starts-with? w ":") (ends-with? w ":")
             (andmap org-tag-char? (string->list w)))
        (filter (lambda (t) (not (equal? t ""))) (split-many (substring w 1 (- (string-length w) 1)) ":"))
        '())))

(define (org-without-tags text)
  "Heading text `text` without the tags at its end."
  (let ([t (trim-end text)])
    (if (null? (org-tags-of t))
        t
        (trim-end (substring t 0 (- (string-length t) (string-length (last (split-whitespace t)))))))))

(define (org-file-tags lines)
  "The tags `#+FILETAGS:` gives in `lines` (a vector), as (\"a\" \"b\")
   from \":a:b:\" (or \"a b\")."
  (let ([v (org-file-setting lines "#+FILETAGS:")])
    (if v
        (filter (lambda (t) (not (equal? t "")))
                (apply append (map (lambda (w) (split-many w ":")) (split-whitespace v))))
        '())))

;; Where a heading's tags go: a negative number right-aligns them to end
;; at that column, a positive one starts them there, as Org's
;; org-tags-column.
(define-option! 'org-tags-column -77 '())
;; Where archiving moves a heading: a file, %s for the file's name, then
;; :: and an optional heading to go under, as Org's.
(define-option! 'org-archive-location "%s_archive::" '())

(define (org-heading-tags line)
  "The tags of the heading on `line`, as (\"work\" \"urgent\")."
  (org-tags-of (line-text line)))

(define (org-with-tags text tags)
  "Heading text `text` with `tags` (a list) at its end in place of any it
   had, placed by org-tags-column."
  (let* ([base (org-without-tags text)]
         [tag-text (string-append ":" (string-join tags ":") ":")]
         [col (option 'org-tags-column)]
         [start (if (< col 0) (- (- col) (string-length tag-text)) col)]
         [pad (max 1 (- start (string-length base)))])
    (if (null? tags) base (string-append base (make-string pad #\space) tag-text))))

(define (org-set-heading-tags! line tags)
  "Gives the heading on `line` exactly `tags` (a list)."
  (begin-change!)
  (org-set-line! line (org-with-tags (line-text line) tags)))

(define (org-known-tags)
  "Every tag in the agenda files and the current buffer, each once."
  (let* ([texts (cons (buffer-substring 0 (buffer-length))
                      (map (lambda (f) (with-handler (lambda (e) "") (org-file-text f))) (org-agenda-file-list)))]
         [tags (apply append
                      (map (lambda (t)
                             (let ([lines (text-lines t)])
                               (append (org-file-tags (list->vector lines))
                                       (apply append (map (lambda (l) (if (org-level-of l) (org-tags-of l) '())) lines)))))
                           texts))])
    (let loop ([ts tags] [acc '()])
      (cond [(null? ts) (reverse acc)]
            [(member (car ts) acc) (loop (cdr ts) acc)]
            [else (loop (cdr ts) (cons (car ts) acc))]))))

(define (org-tags-prompt!)
  "C-c C-q: sets the tags of the heading the cursor is under. Each tag
   picked, completing from the agenda files' tags, or a new one typed, is
   added, or removed if the heading has it; it asks again until <esc>."
  (let ([h (org-heading-line (current-line))])
    (if (not h)
        (message "not under a heading")
        (let ask ()
          (let ([now (org-heading-tags h)])
            (completing-read (string-append "Tags " (if (null? now) "(none)" (string-append ":" (string-join now ":") ":"))
                                            " (<esc> when done): ")
                             (org-known-tags)
                             (lambda (tag)
                               (let ([tag (trim (org-trim-colons tag))])
                                 (cond [(equal? tag "") void]
                                       [(not (andmap org-tag-char? (string->list tag)))
                                        (message (string-append "not a tag: " tag))]
                                       [else
                                        (org-set-heading-tags! h (if (member tag now)
                                                                     (filter (lambda (t) (not (equal? t tag))) now)
                                                                     (append now (list tag))))
                                        (ask)])))
                             (lambda (tag) (and (member tag now) "on"))))))))

(define (org-trim-colons text)
  "`text` without colons at either end."
  (let loop ([t text])
    (cond [(starts-with? t ":") (loop (substring t 1 (string-length t)))]
          [(ends-with? t ":") (loop (substring t 0 (- (string-length t) 1)))]
          [else t])))

(define (org-effort-prompt!)
  "C-c C-x e: sets the Effort property of the heading the cursor is
   under, as 0:45 or 1:30; an empty answer removes it."
  (let ([h (org-heading-line (current-line))])
    (if (not h)
        (message "not under a heading")
        (open-cmdline! "Effort: " (or (org-entry-property h "Effort") "")
                       (lambda (v) (org-set-property! h "Effort" (trim v))) #f #f))))

;;; The agenda files, which capture and refile use too

(define (org-notes-file)
  "The full path of the default notes file, where captures go.
   That is org-default-notes-file, or inbox.org in org-directory when
   the option is empty."
  (expand-path (if (equal? (option 'org-default-notes-file) "")
                   (string-append (option 'org-directory) "/inbox.org")
                   (option 'org-default-notes-file))))

(define (org-agenda-file-list)
  "The full paths of the files the agenda reads.
   They are org-agenda-files, or when that is empty every .org file
   under org-directory (none if it doesn't exist) but the archives
   org-archive-location names."
  (let ([files (option 'org-agenda-files)])
    (if (pair? files)
        (map org-path files)
        (let ([dir (expand-path (option 'org-directory))])
          (if (file-exists? dir)
              (let* ([all (map (lambda (f) (string-append dir "/" f))
                               (filter (lambda (f) (ends-with? f ".org")) (list-files dir 10000)))]
                     ;; Not the files archiving moves headings to.
                     [archives (filter (lambda (t) t)
                                       (map (lambda (f) (let ([t (car (org-archive-target f))]) (and (not (equal? t f)) t))) all))])
                (filter (lambda (f) (not (member f archives))) all))
              '())))))

(define (org-date-after text key)
  "The date in \"<2026-10-18 Sun>\" after `key` on `text`, or #f."
  (let ([parts (split-once text key)])
    (and (pair? parts) (pair? (cdr parts))
         (let ([rest (trim-start (cadr parts))])
           (and (>= (string-length rest) 11) (member (substring rest 0 1) '("<" "["))
                (substring rest 1 11))))))

;;; Dates: scheduling, deadlines and timestamps
;;;
;;; C-c C-s and C-c C-d (SPC m s, SPC m d) set the heading's SCHEDULED or
;;; DEADLINE date, picked from a calendar (calendar.scm), on the line
;;; under it as Org keeps them. C-c . (SPC m .) puts a timestamp at the
;;; cursor, or changes the one there.

(define (org-planning-line? text)
  "Whether `text` is a heading's planning line: SCHEDULED:, DEADLINE: or
   CLOSED: dates."
  (let ([t (trim-start text)])
    (or (starts-with? t "SCHEDULED:") (starts-with? t "DEADLINE:") (starts-with? t "CLOSED:"))))

(define (org-stamp-bounds text from)
  "The (start end) of the timestamp starting at or after index `from` in
   `text`, past spaces only, or #f."
  (let ([n (string-length text)])
    (let loop ([i from])
      (cond [(>= i n) #f]
            [(equal? (string-ref text i) #\space) (loop (+ i 1))]
            [(member (string-ref text i) '(#\< #\[))
             (let ([close (string-index-from text (if (equal? (string-ref text i) #\<) ">" "]") i)])
               (and close (list i (+ close 1))))]
            [else #f]))))

(define (org-interval text prefixes)
  "The (prefix n unit) `text` is, a prefix from `prefixes` (longest
   first) then a count and one of d w m y, as \"+1w\" -> (\"+\" 1 \"w\").
   #f if it is something else."
  (let loop ([ps prefixes])
    (cond
      [(null? ps) #f]
      [(starts-with? text (car ps))
       (let* ([p (car ps)] [n (string-length text)]
              [count (and (> n (+ (string-length p) 1))
                          (string->number (substring text (string-length p) (- n 1))))]
              [unit (substring text (- n 1) n)])
         (and count (integer? count) (> count 0) (member unit '("d" "w" "m" "y"))
              (list p count unit)))]
      [else (loop (cdr ps))])))

(define (org-parse-stamp text)
  "The parts of the Org timestamp `text`, such as
   \"<2026-10-24 Sat 09:00 +1w -3d>\": (active? date time repeater
   warning). The date is a (year month day), the time a string or #f, the
   repeater a (kind n unit) such as (\"+\" 1 \"w\") or #f, and the warning
   one too, such as (\"-\" 3 \"d\"). #f if `text` isn't a timestamp."
  (let ([n (string-length text)])
    (and (>= n 12)
         (let ([open (string-ref text 0)] [close (string-ref text (- n 1))])
           (and (or (and (equal? open #\<) (equal? close #\>)) (and (equal? open #\[) (equal? close #\])))
                (let* ([words (split-whitespace (substring text 1 (- n 1)))]
                       [date (and (pair? words) (string->date (car words)))])
                  (and date
                       (let loop ([ws (cdr words)] [time #f] [repeater #f] [warning #f] [day? #t])
                         (if (null? ws)
                             (list (equal? open #\<) date time repeater warning)
                             (let* ([w (car ws)] [c (string-ref w 0)])
                               (cond
                                 [(and day? (not (char-digit? c)) (not (memv c (list #\+ #\- #\.))))
                                  (loop (cdr ws) time repeater warning #f)]
                                 [(and (not time) (char-digit? c) (string-index-from w ":" 0))
                                  (loop (cdr ws) w repeater warning #f)]
                                 [(and (not repeater) (org-repeater w))
                                  => (lambda (r) (loop (cdr ws) time r warning #f))]
                                 [(and (not warning) (org-interval w '("--" "-")))
                                  => (lambda (r) (loop (cdr ws) time repeater r #f))]
                                 [else #f])))))))))))

(define (org-repeater text)
  "The repeater `text` is, as org-interval gives it, \".+2d\" -> (\".+\" 2
   \"d\"); a habit's may give the most it may wait after a slash,
   \".+2d/4d\" -> (\".+\" 2 \"d\" (4 \"d\")). #f if it is something else."
  (let ([slash (string-index-from text "/" 0)])
    (if (not slash)
        (org-interval text '("++" ".+" "+"))
        (let ([r (org-interval (substring text 0 slash) '("++" ".+" "+"))]
              [most (org-interval (string-append "+" (substring text (+ slash 1) (string-length text))) '("+"))])
          (and r most (append r (list (cdr most))))))))

(define (org-interval->string interval)
  "`interval`, a (prefix n unit), written as Org does: \"+1w\"; a
   habit's repeater with its most after a slash, \".+2d/4d\"."
  (string-append (car interval) (number->string (cadr interval)) (caddr interval)
                 (if (= (length interval) 4)
                     (string-append "/" (number->string (car (cadddr interval))) (cadr (cadddr interval)))
                     "")))

(define (org-stamp->string stamp)
  "The timestamp `stamp`, parts as org-parse-stamp gives them, written
   out with the day name its date has."
  (let ([active? (car stamp)] [date (cadr stamp)] [time (caddr stamp)]
        [repeater (cadddr stamp)] [warning (list-ref stamp 4)])
    (string-append (if active? "<" "[") (date->string date) " "
                   (vector-ref *calendar-day-names* (date-weekday date))
                   (if time (string-append " " time) "")
                   (if repeater (string-append " " (org-interval->string repeater)) "")
                   (if warning (string-append " " (org-interval->string warning)) "")
                   (if active? ">" "]"))))

;;; Repeaters: marking a heading done moves on its entry's repeating
;;; timestamps instead, and its keyword goes back to the first.

(define (org-shift-date date interval k)
  "`date` moved on `k` times `interval`, a (prefix n unit)."
  (let ([n (* k (cadr interval))] [unit (caddr interval)])
    (cond [(equal? unit "d") (date-add-days date n)]
          [(equal? unit "w") (date-add-days date (* 7 n))]
          [(equal? unit "m") (date-add-months date n)]
          [else (date-add-months date (* 12 n))])))

(define (org-repeat-stamp stamp today)
  "`stamp` moved on by its repeater, as on marking its heading done: +
   one interval, ++ whole intervals until after `today`, .+ one interval
   from `today`."
  (let* ([date (cadr stamp)] [r (cadddr stamp)] [kind (car r)]
         [next (cond [(equal? kind "+") (org-shift-date date r 1)]
                     [(equal? kind ".+") (org-shift-date today r 1)]
                     [else (let loop ([k 1])
                             (let ([d (org-shift-date date r k)]) (if (date<? today d) d (loop (+ k 1)))))])])
    (list (car stamp) next (caddr stamp) r (list-ref stamp 4))))

(define (org-repeating-stamps first last)
  "The repeating active timestamps on lines `first` to `last`, as
   (start end stamp) with buffer offsets, the last one first."
  (let loop ([l first] [acc '()])
    (if (> l last)
        acc
        (let ([text (line-text l)])
          (let scan ([i 0] [acc acc])
            (let ([b (org-stamp-bounds-anywhere text i)])
              (if (not b)
                  (loop (+ l 1) acc)
                  (let ([stamp (org-parse-stamp (substring text (car b) (cadr b)))])
                    (scan (cadr b)
                          (if (and stamp (car stamp) (cadddr stamp))
                              (cons (list (+ (line-start l) (car b)) (+ (line-start l) (cadr b)) stamp) acc)
                              acc))))))))))

(define (org-repeat-entry! heading)
  "Moves on each repeating active timestamp in the entry of the heading
   on line `heading`. Returns the first, as it now reads, or #f if there
   were none."
  (let ([today (calendar-today)])
    (foldl (lambda (found first)
             (let ([text (org-stamp->string (org-repeat-stamp (caddr found) today))])
               (replace-range! (car found) (cadr found) text)
               text))
           #f
           (org-repeating-stamps heading (org-body-end heading)))))

;;; Logging: CLOSED: stamps, LAST_REPEAT and the :LOGBOOK: drawer, as
;;; Org writes them (org-log-into-drawer, as Doom sets it). The clock's
;;; CLOCK: lines go in the same drawer, newest first.

(define (org-now)
  "The time now, as \"11:42\"."
  (trim (cadr (run-shell "date +%H:%M" ""))))

(define (org-now-stamp)
  "An inactive timestamp for now: \"[2026-10-25 Sun 11:42]\"."
  (date-timestamp (calendar-today) (org-now) #f))

(define (org-logbook-line heading)
  "The :LOGBOOK: line in the text of the heading on line `heading`, or #f."
  (let ([end (org-body-end heading)])
    (let loop ([l (+ heading 1)])
      (cond [(> l end) #f]
            [(equal? (string-upcase (trim (line-text l))) ":LOGBOOK:") l]
            [else (loop (+ l 1))]))))

(define (org-logbook-insert! heading text)
  "Puts line `text` at the top of the :LOGBOOK: drawer of the heading on
   line `heading`, making the drawer after its planning line and
   properties if it has none. Returns the line `text` is on."
  (let ([at (org-logbook-line heading)])
    (if at
        (begin (buffer-insert! (line-end at) (string-append "\n" text)) (+ at 1))
        (let* ([lines (org-buffer-lines)]
               [d (org-drawer-at lines heading)]
               [after (cond [d (cadr d)]
                            [(and (<= (+ heading 1) (last-line)) (org-planning-line? (line-text (+ heading 1))))
                             (+ heading 1)]
                            [else heading])])
          (buffer-insert! (line-end after) (string-append "\n:LOGBOOK:\n" text "\n:END:"))
          (+ after 2)))))

(define (org-set-closed! heading stamp)
  "Sets the CLOSED: date of the heading on line `heading` to `stamp`, at
   the start of its planning line (made if there isn't one), or removes
   it when `stamp` is #f, with the line if nothing else is on it."
  (let* ([next (+ heading 1)]
         [planning? (and (<= next (last-line)) (org-planning-line? (line-text next)))]
         [text (if planning? (line-text next) "")]
         [at (and planning? (string-index-from text "CLOSED:" 0))]
         [bounds (and at (org-stamp-bounds text (+ at 7)))])
    (cond
      [(and bounds stamp)
       (replace-range! (+ (line-start next) (car bounds)) (+ (line-start next) (cadr bounds)) stamp)]
      [bounds
       (let* ([rest (trim (string-append (substring text 0 at) (substring text (cadr bounds) (string-length text))))])
         (if (equal? rest "")
             (replace-range! (line-end heading) (line-end next) "")
             (org-set-line! next rest)))]
      [(not stamp) void]
      [planning?
       (let ([indent (- (string-length text) (string-length (trim-start text)))])
         (buffer-insert! (+ (line-start next) indent) (string-append "CLOSED: " stamp " ")))]
      [else (buffer-insert! (line-end heading) (string-append "\nCLOSED: " stamp))])
    void))

(define (org-pad text width)
  "`text` with spaces after it to `width` columns."
  (if (< (string-length text) width) (string-append text (make-string (- width (string-length text)) #\space)) text))

(define (org-state-line new old stamp)
  "The logbook line for a change from keyword `old` (or #f) to `new`, as
   Org writes it: - State \"DONE\"       from \"TODO\"       [stamp]."
  (string-append "- State " (org-pad (string-append "\"" new "\"") 12)
                 " from " (org-pad (if old (string-append "\"" old "\"") "") 12) " " stamp))

(define (org-log-change! heading old new repeat?)
  "Logs the heading on line `heading` going from keyword `old` to `new`:
   a CLOSED: stamp on done, removed on leaving done (org-log-done); on a
   repeat, LAST_REPEAT and a state line instead (org-log-repeat)."
  (let ([done (org-done-keywords)])
    (cond
      [repeat?
       (when (option 'org-log-repeat)
         (let ([stamp (org-now-stamp)])
           (org-set-property! heading "LAST_REPEAT" stamp)
           (org-logbook-insert! heading (org-state-line new old stamp))))]
      [(and new (member new done))
       (when (option 'org-log-done) (org-set-closed! heading (org-now-stamp)))]
      [else (org-set-closed! heading #f)])
    void))

;;; Clocking: C-c C-x C-i (SPC m c i) clocks in on the heading, C-c C-x
;;; C-o (SPC m c o) clocks out, C-c C-x C-q (SPC m c c) cancels the
;;; clock, C-c C-x C-j (SPC m c g) goes to its heading. One clock runs at
;;; a time: an open CLOCK: line at the top of its heading's :LOGBOOK:.
;;; The clock remembers its file and finds the open line there again, so
;;; edits above it don't lose it; one left running in an agenda file is
;;; picked up shortly after imp starts. %{org-clock} in the status line
;;; shows it, as [0:23/1:00] Write report, the heading's effort after /.

;; The running clock, as (path title start effort), or #f.
(define *org-clock* #f)
;; The timer that redraws %{org-clock} each minute, or #f.
(define *org-clock-timer* #f)

(define (org-stamp-minutes stamp)
  "The minutes from day 0 inactive timestamp text `stamp` is at, as for
   \"[2026-10-25 Sun 11:42]\", or #f without a date and time."
  (let* ([n (string-length stamp)]
         [date (and (>= n 12) (string->date (substring stamp 1 11)))]
         [time (and date (>= n 18) (substring stamp (- n 6) (- n 1)))])
    (and time (equal? (string-ref time 2) #\:)
         (let ([h (string->number (substring time 0 2))] [m (string->number (substring time 3 5))])
           (and h m (+ (* 1440 (date->days date)) (* 60 h) m))))))

(define (org-duration minutes)
  "`minutes` as Org writes a duration: 75 as \"1:15\"."
  (string-append (number->string (quotient minutes 60)) ":" (two-digits (modulo minutes 60))))

(define (org-clock-open-start text)
  "The start stamp of line `text` when it is a running clock, \"CLOCK:
   [2026-10-25 Sun 11:42]\" with no end, else #f."
  (let ([t (trim text)])
    (and (starts-with? t "CLOCK: [") (not (string-index-from t "]--[" 0))
         (let ([close (string-index-from t "]" 0)])
           (and close (substring t 7 (+ close 1)))))))

(define (org-clock-line)
  "The line of the current buffer's running clock, or #f."
  (let loop ([l 0])
    (cond [(> l (last-line)) #f]
          [(org-clock-open-start (line-text l)) l]
          [else (loop (+ l 1))])))

(define (org-clock-buffer)
  "The id of the buffer visiting the clock's file, opening it in the
   background if none does, or #f after saying why."
  (let ([path (car *org-clock*)])
    (or (buffer-for-path path)
        (with-handler (lambda (e) (message (error-message e)) #f) (buffer-open! path)))))

(define (org-clock-elapsed)
  "The minutes the running clock has run."
  (max 0 (- (or (org-stamp-minutes (org-now-stamp)) 0) (or (org-stamp-minutes (caddr *org-clock*)) 0))))

(define (org-clock-show!)
  "Sets %{org-clock} in the status line to the running clock, or clears it."
  (set-status-value! "org-clock"
                     (if *org-clock*
                         (let ([effort (cadddr *org-clock*)])
                           (string-append "[" (org-duration (org-clock-elapsed))
                                          (if effort (string-append "/" effort) "") "] " (cadr *org-clock*) "  "))
                         "")
                     #t))

(define (org-clock-start! clock)
  "Makes `clock`, a (path title start effort), the running one."
  (set! *org-clock* clock)
  (unless *org-clock-timer* (set! *org-clock-timer* (run-every! 60000 org-clock-show!)))
  (org-clock-show!))

(define (org-clock-stop!)
  "Forgets the running clock."
  (set! *org-clock* #f)
  (when *org-clock-timer* (cancel-timer! *org-clock-timer*) (set! *org-clock-timer* #f))
  (org-clock-show!))

(define (org-clock-edit! proc)
  "Runs (proc line) on the running clock's line in its file's buffer, as
   one change, saving the buffer if it isn't the current one and had no
   unsaved changes. Returns whether the line was found."
  (let ([id (org-clock-buffer)])
    (and id
         (let ([clean? (not (buffer-modified-by-id? id))] [here? (= id (current-buffer))])
           (let ([found (with-buffer id
                                     (lambda ()
                                       (let ([l (org-clock-line)])
                                         (and l (with-undo-group (lambda () (begin-change!) (proc l) #t))))))])
             (when (and found clean? (not here?)) (with-buffer id (lambda () (save-buffer!))))
             found)))))

(define (org-clock-in! heading)
  "Clocks in on the heading on line `heading` of the current buffer,
   clocking out the running clock first."
  (cond
    [(not (buffer-path)) (message "the buffer has no file")]
    [else
     (when *org-clock* (org-clock-out!))
     (let ([stamp (org-now-stamp)]
           [title (org-heading-title (line-text heading))]
           [effort (org-entry-property heading "Effort")])
       (with-undo-group
        (lambda () (begin-change!) (org-logbook-insert! heading (string-append "CLOCK: " stamp))))
       (org-clock-start! (list (absolute-path (buffer-path)) title stamp effort))
       (message (string-append "clocked in: " title)))]))

(define (org-clock-out!)
  "Clocks out: ends the running clock's line with now and its length."
  (if (not *org-clock*)
      (message "no clock is running")
      (let* ([now (org-now-stamp)]
             [took (org-duration (org-clock-elapsed))]
             [title (cadr *org-clock*)])
        (org-clock-edit!
         (lambda (l)
           (let* ([text (line-text l)]
                  [indent (substring text 0 (- (string-length text) (string-length (trim-start text))))])
             (org-set-line! l (string-append indent "CLOCK: " (org-clock-open-start text) "--" now " => "
                                             (make-string (max 0 (- 5 (string-length took))) #\space) took)))))
        (org-clock-stop!)
        (message (string-append "clocked out: " title " (" took ")")))))

(define (org-clock-cancel!)
  "Cancels the running clock, removing its line, and its :LOGBOOK: when
   that leaves it empty."
  (if (not *org-clock*)
      (message "no clock is running")
      (begin
        (org-clock-edit!
         (lambda (l)
           (let ([empty? (and (> l 0) (< l (last-line))
                              (equal? (string-upcase (trim (line-text (- l 1)))) ":LOGBOOK:")
                              (equal? (string-upcase (trim (line-text (+ l 1)))) ":END:"))])
             (if empty?
                 (replace-range! (line-end (- l 2)) (line-end (+ l 1)) "")
                 (replace-range! (line-end (- l 1)) (line-end l) "")))))
        (org-clock-stop!)
        (message "clock canceled"))))

(define (org-clock-goto!)
  "Goes to the running clock's heading, opening its file."
  (if (not *org-clock*)
      (message "no clock is running")
      (let ([id (open-file! (car *org-clock*))])
        (when id
          (let ([l (org-clock-line)])
            (if l
                (begin (set-cursor! (line-start (or (org-heading-line l) l)))
                       (message (string-append "clocked: " (cadr *org-clock*))))
                (message "the clock's line is gone")))))))

(define (org-clock-resume!)
  "Picks up a clock left running in an agenda file: the first open
   CLOCK: line found."
  (unless *org-clock*
    (let loop ([files (org-agenda-file-list)])
      (when (pair? files)
        (let* ([file (car files)]
               [lines (if (file-exists? file) (list->vector (split-many (org-file-text file) "\n")) (vector))]
               [at (let find ([i 0])
                     (cond [(>= i (vector-length lines)) #f]
                           [(org-clock-open-start (vector-ref lines i)) i]
                           [else (find (+ i 1))]))]
               [h (and at (org-heading-above lines at))])
          (if h
              (org-clock-start! (list (absolute-path file) (org-heading-title (vector-ref lines h))
                                      (org-clock-open-start (vector-ref lines at))
                                      (org-lines-property lines h "Effort" #f)))
              (loop (cdr files))))))))

(add-hook! 'startup (lambda () (run-after! 1000 org-clock-resume!)))

(define (org-clock-at-heading proc)
  "Runs (proc heading) on the heading the cursor is under, or says it isn't."
  (let ([h (org-heading-line (current-line))]) (if h (proc h) (message "not under a heading"))))

(define (org-restamp old new)
  "Timestamp `new` with the repeater and warning of timestamp `old`, so
   picking a new date keeps them."
  (let ([o (org-parse-stamp old)] [n (org-parse-stamp new)])
    (if (and o n)
        (org-stamp->string (list (car n) (cadr n) (caddr n) (cadddr o) (list-ref o 4)))
        new)))

(define (org-set-planning! heading key stamp)
  "Sets `key` (\"SCHEDULED:\" or \"DEADLINE:\") of the heading on line
   `heading` to timestamp `stamp`, on its planning line (made if there
   isn't one)."
  (let* ([next (+ heading 1)]
         [planning? (and (<= next (last-line)) (org-planning-line? (line-text next)))])
    (begin-change!)
    (if planning?
        (let* ([text (line-text next)]
               [at (string-index-from text key 0)]
               [bounds (and at (org-stamp-bounds text (+ at (string-length key))))])
          (cond
            [bounds (replace-range! (+ (line-start next) (car bounds)) (+ (line-start next) (cadr bounds))
                                   (org-restamp (substring text (car bounds) (cadr bounds)) stamp))]
            [at (buffer-insert! (+ (line-start next) at (string-length key)) (string-append " " stamp))]
            [else (buffer-insert! (line-end next) (string-append " " key " " stamp))]))
        (buffer-insert! (line-end heading) (string-append "\n" key " " stamp)))))

(define (org-shift-stamp-at! line bounds days)
  "Moves the timestamp at `bounds` (start end) of `line`'s text `days`
   days on, keeping its time, repeater and warning."
  (let* ([text (line-text line)]
         [stamp (org-parse-stamp (substring text (car bounds) (cadr bounds)))])
    (when stamp
      (begin-change!)
      (replace-range! (+ (line-start line) (car bounds)) (+ (line-start line) (cadr bounds))
                      (org-stamp->string (list (car stamp) (date-add-days (cadr stamp) days)
                                               (caddr stamp) (cadddr stamp) (list-ref stamp 4)))))))

(define (org-shift-planning! heading key days)
  "Moves `key`'s date (\"SCHEDULED:\" or \"DEADLINE:\") of the heading
   on line `heading` `days` days on."
  (let ([next (+ heading 1)])
    (when (and (<= next (last-line)) (org-planning-line? (line-text next)))
      (let* ([text (line-text next)] [at (string-index-from text key 0)]
             [bounds (and at (org-stamp-bounds text (+ at (string-length key))))])
        (when bounds (org-shift-stamp-at! next bounds days))))))

(define (org-shift-appointment! heading date days)
  "Moves the first active timestamp dated `date` in the entry of the
   heading on line `heading`, other than its SCHEDULED: and DEADLINE:,
   `days` days on."
  (let loop ([line heading])
    (when (<= line (org-body-end heading))
      (let ([text (line-text line)])
        (let find ([from 0])
          (let ([b (org-stamp-bounds-anywhere text from)])
            (cond
              [(not b) (loop (+ line 1))]
              [(let ([st (org-parse-stamp (substring text (car b) (cadr b)))]
                     [before (trim-end (substring text 0 (car b)))])
                 (and st (car st) (equal? (cadr st) date)
                      (not (ends-with? before "SCHEDULED:")) (not (ends-with? before "DEADLINE:"))))
               (org-shift-stamp-at! line b days)]
              [else (find (cadr b))])))))))

(define (org-planning-date heading key)
  "The date `key` gives the heading on line `heading`, or #f."
  (let ([next (+ heading 1)])
    (and (<= next (last-line)) (org-planning-line? (line-text next))
         (let ([d (org-date-after (line-text next) key)]) (and d (string->date d))))))

(define (org-plan! key prompt)
  "Asks for a date with `prompt` and sets the heading's `key` to it."
  (let ([h (org-heading-line (current-line))])
    (if (not h)
        (message "not under a heading")
        (read-date prompt (org-planning-date h key)
                   (lambda (d)
                     (let ([stamp (date-timestamp (take d 3) (cadddr d) #t)])
                       (org-set-planning! h key stamp)
                       (message (string-append key " " stamp))))))))

(define (org-schedule!)
  "Sets the heading's SCHEDULED date, picked from a calendar."
  (org-plan! "SCHEDULED:" "Schedule: "))

(define (org-deadline!)
  "Sets the heading's DEADLINE date, picked from a calendar."
  (org-plan! "DEADLINE:" "Deadline: "))

(define (org-stamp-at pos)
  "The (start end) of the timestamp around buffer offset `pos`, or #f."
  (let* ([line (offset->line pos)] [text (line-text line)] [col (- pos (line-start line))])
    (let loop ([i 0])
      (let ([b (org-stamp-bounds-anywhere text i)])
        (cond [(not b) #f]
              [(and (<= (car b) col) (< col (cadr b)))
               (list (+ (line-start line) (car b)) (+ (line-start line) (cadr b)))]
              [else (loop (cadr b))])))))

(define (org-stamp-bounds-anywhere text from)
  "The (start end) of the next timestamp in `text` at or after `from`: a
   < or [ followed by a YYYY-MM-DD date. #f if there is none."
  (let ([n (string-length text)])
    (let loop ([i from])
      (cond [(>= (+ i 11) n) #f]
            [(and (member (string-ref text i) '(#\< #\[)) (string->date (substring text (+ i 1) (+ i 11))))
             (or (org-stamp-bounds text i) (loop (+ i 1)))]
            [else (loop (+ i 1))]))))

(define (org-time-stamp!)
  "Puts an active timestamp at the cursor, picked from a calendar. On a
   timestamp, changes it instead."
  (let* ([pos (cursor)] [old (org-stamp-at pos)]
         [initial (and old (string->date (buffer-substring (+ (car old) 1) (+ (car old) 11))))])
    (read-date "Date: " initial
               (lambda (d)
                 (let ([stamp (if old
                                  (org-restamp (buffer-substring (car old) (cadr old))
                                               (date-timestamp (take d 3) (cadddr d) #t))
                                  (date-timestamp (take d 3) (cadddr d) #t))])
                   (begin-change!)
                   (if old
                       (replace-range! (car old) (cadr old) stamp)
                       (buffer-insert! pos stamp))
                   (set-cursor! (+ (if old (car old) pos) (string-length stamp))))))))

;;; Capture
;;;
;;; SPC o c asks which template (one template skips the question), then
;;; opens a *capture* buffer, down the right, with the template filled in
;;; and the cursor where its %? was, in insert state. C-c C-c (or :w) files
;;; the entry and closes the window; C-c C-k throws it away; C-c C-w files
;;; it under a heading you pick instead. An entry left as the template
;;; made it, with nothing typed, isn't filed.
;;;
;;;   (define-capture-template! "t" "Todo" '(file+headline "inbox.org" "Tasks")
;;;     "* TODO %?\n/Entered on/ %U")
;;;
;;; Targets, with paths relative to org-directory ("" for
;;; org-default-notes-file, which is inbox.org unless set):
;;;   (file F)                at the end of F
;;;   (file+headline F H)     at the end of heading H's subtree (made if
;;;                           missing); the entry's headings go one level
;;;                           under H
;;;   (file+datetree F)       under year, month and day headings
;;; In the template: %? the cursor; %U and %u an inactive timestamp with
;;; and without the time, %T and %t active ones; %a a link to the line you
;;; were on; %i the text you had selected; %f that file's name; %^{Prompt}
;;; asks for a value first; %^t asks for a date from the calendar (%^u for
;;; an inactive one); %% a %. In the capture buffer, C-c C-s and C-c C-d
;;; schedule the entry or give it a deadline, as in any Org buffer.

(define *capture-templates* '())  ; (key description target template), in order

(define (define-capture-template! key description target template)
  "Adds capture template `key`, replacing one already bound to it.
   `description` is what the menu shows, `target` where the entry
   goes and `template` its text; see the Capture notes above."
  (remove-capture-template! key)
  (set! *capture-templates* (append *capture-templates* (list (list key description target template))))
  void)

(define (remove-capture-template! key)
  "Removes the capture template bound to `key`, if there is one."
  (set! *capture-templates* (filter (lambda (t) (not (equal? (car t) key))) *capture-templates*))
  void)

(define-capture-template! "t" "Todo" '(file+headline "" "Tasks") "* TODO %?\n/Entered on/ %U")
(define-capture-template! "n" "Note" '(file+headline "" "Notes") "* %? %a\n/Entered on/ %U")
(define-capture-template! "j" "Journal" '(file+datetree "journal.org") "* %<%H:%M> %?")

(define (org-path path)
  "`path` under org-directory unless it is absolute (or starts with ~);
   \"\" is the default notes file."
  (cond [(equal? path "") (org-notes-file)]
        [(or (starts-with? path "/") (starts-with? path "~")) (expand-path path)]
        [else (string-append (expand-path (option 'org-directory)) "/" path)]))

(define (capture-clock)
  "The time, as (date day time weekday month-name): (\"2026-10-19\" \"Mon\"
   \"14:02\" \"Monday\" \"October\")."
  (let ([parts (split-many (trim (cadr (run-shell "date '+%Y-%m-%d|%a|%H:%M|%A|%B'" ""))) "|")])
    (if (= (length parts) 5) parts (list "1970-01-01" "Thu" "00:00" "Thursday" "January"))))

;; The date a capture is for instead of today's, as the agenda's C sets
;; it, or #f.
(define *capture-date* #f)

(define (capture-day-clock clock date)
  "`clock` (as capture-clock gives it) on `date` instead, at its time."
  (list (date->string date) (vector-ref *calendar-day-names* (date-weekday date)) (caddr clock)
        (vector-ref (vector "Sunday" "Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday")
                    (date-weekday date))
        (vector-ref *calendar-month-names* (- (cadr date) 1))))

(define (capture-context)
  "What a template can refer to, gathered where capture starts: on
   *capture-date* when it is set."
  (list (cons 'clock (if *capture-date* (capture-day-clock (capture-clock) *capture-date*) (capture-clock)))
        (cons 'path (and (buffer-path) (absolute-path (buffer-path))))
        (cons 'line (+ (current-line) 1))
        (cons 'region (if (eq? *mode* 'visual)
                          (let ([r (visual-range)]) (buffer-substring (car r) (cadr r)))
                          ""))))

(define (context-ref ctx key)
  "The value under `key` in capture context `ctx`."
  (cdr (assq key ctx)))

(define (capture-prompts template)
  "The questions `template` asks, in order: a %^{Prompt} as its prompt
   text, a %^t %^T %^u or %^U (a date from the calendar) as the char."
  (let ([n (string-length template)])
    (let loop ([i 0] [acc '()])
      (let ([at (string-index-from template "%^" i)])
        (if (or (not at) (>= (+ at 2) n))
            (reverse acc)
            (let ([c (string-ref template (+ at 2))])
              (cond
                [(equal? c #\{)
                 (let ([close (string-index-from template "}" (+ at 3))])
                   (if close
                       (loop (+ close 1) (cons (substring template (+ at 3) close) acc))
                       (reverse acc)))]
                [(memv c '(#\t #\T #\u #\U)) (loop (+ at 3) (cons c acc))]
                [else (loop (+ at 2) acc)])))))))

(define (string-index-from text needle from)
  "The first index of `needle` in `text` at or after `from`, or #f."
  (let ([n (string-length text)] [m (string-length needle)])
    (let loop ([i from])
      (cond [(> (+ i m) n) #f]
            [(equal? (substring text i (+ i m)) needle) i]
            [else (loop (+ i 1))]))))

(define (capture-expand template ctx answers)
  "`template` filled in from `ctx`, with `answers` for its prompts in
   order: (text cursor), the cursor where %? was (else the end)."
  (let* ([clock (context-ref ctx 'clock)]
         [date (car clock)] [day (cadr clock)] [time (caddr clock)]
         [path (context-ref ctx 'path)]
         [n (string-length template)])
    (let loop ([i 0] [out ""] [cursor #f] [answers answers])
      (cond
        [(>= i n) (list out (or cursor (string-length out)))]
        [(and (equal? (string-ref template i) #\%) (< (+ i 1) n))
         (let* ([c (string-ref template (+ i 1))]
                [put (lambda (text) (loop (+ i 2) (string-append out text) cursor answers))])
           (cond
             [(equal? c #\?) (loop (+ i 2) out (string-length out) answers)]
             [(equal? c #\U) (put (string-append "[" date " " day " " time "]"))]
             [(equal? c #\u) (put (string-append "[" date " " day "]"))]
             [(equal? c #\T) (put (string-append "<" date " " day " " time ">"))]
             [(equal? c #\t) (put (string-append "<" date " " day ">"))]
             [(equal? c #\a) (put (if path
                                      (string-append "[[file:" (abbreviate-path path) "::"
                                                     (number->string (context-ref ctx 'line)) "]]")
                                      ""))]
             [(equal? c #\i) (put (context-ref ctx 'region))]
             [(equal? c #\f) (put (if path (file-name-of path) ""))]
             [(equal? c #\%) (put "%")]
             [(and (equal? c #\<) (string-index-from template ">" i))
              ;; %<%H:%M>: the time, in date's format.
              => (lambda (close)
                   (loop (+ close 1)
                         (string-append out (trim (cadr (run-shell (string-append "date " (shell-quote (string-append "+" (substring template (+ i 2) close)))) ""))))
                         cursor answers))]
             [(and (equal? c #\^) (< (+ i 2) n)
                   (let ([k (string-ref template (+ i 2))])
                     (cond [(memv k '(#\t #\T #\u #\U)) (+ i 3)]
                           [(equal? k #\{) (let ([close (string-index-from template "}" i)]) (and close (+ close 1)))]
                           [else #f])))
              ;; A prompt's answer, in order: %^{Prompt}, or a date for %^t.
              => (lambda (next)
                   (loop next (string-append out (if (pair? answers) (car answers) "")) cursor
                         (if (pair? answers) (cdr answers) '())))]
             [else (loop (+ i 1) (string-append out "%") cursor answers)]))]
        [else (loop (+ i 1) (string-append out (string (string-ref template i))) cursor answers)]))))

(define (ask-all prompts done)
  "Asks each of `prompts` in turn (see capture-prompts), then calls
   `done` with the answers. A date is asked with the calendar and answered
   as a timestamp: active for t and T, inactive for u and U, with a time
   if one was typed."
  (let loop ([prompts prompts] [acc '()])
    (cond
      [(null? prompts) (done (reverse acc))]
      [(char? (car prompts))
       (read-date "Date: " #f
                  (lambda (d)
                    (loop (cdr prompts)
                          (cons (date-timestamp (take d 3) (cadddr d) (memv (car prompts) '(#\t #\T))) acc))))]
      [else
       (ask (string-append (car prompts) ": ") ""
            (lambda (answer) (loop (cdr prompts) (cons answer acc))))])))

(define (capture-placement lines target entry clock)
  "Where an entry goes in a file's `lines`: (index text), the text going
   before line `index` (the line count for the end). It holds any
   headings the target needs that aren't there yet, then `entry` with its
   headings moved under the target's."
  (let* ([lines (list->vector lines)] [count (vector-length lines)]
         [level-at (lambda (i) (org-level-of (vector-ref lines i)))]
         ;; The end of the subtree under the heading at `h` (level `level`).
         [subtree-end (lambda (h level)
                        (let loop ([i (+ h 1)])
                          (cond [(>= i count) count]
                                [(let ([l (level-at i)]) (and l (<= l level))) i]
                                [else (loop (+ i 1))])))]
         ;; The heading titled `title` among the children of the region
         ;; [from, to) at `level`, or #f. Its keyword, priority and tags
         ;; don't count, as in Org.
         [find-child (lambda (from to level title)
                       (let loop ([i from])
                         (cond [(>= i to) #f]
                               [(and (eqv? (level-at i) level)
                                     (equal? (org-heading-title (vector-ref lines i)) (org-normalize-title title)))
                                i]
                               [else (loop (+ i 1))])))]
         ;; Where a new child titled `title` goes in [from, to): before the
         ;; first sibling that sorts after it.
         [sorted-slot (lambda (from to level title)
                        (let loop ([i from])
                          (cond [(>= i to) to]
                                [(and (eqv? (level-at i) level)
                                      (string<? title (trim (substring (vector-ref lines i) (+ level 1) (string-length (vector-ref lines i))))))
                                 i]
                                [else (loop (+ i 1))])))]
         [stars (lambda (n) (make-string n #\*))]
         [heading (lambda (level title) (string-append (stars level) " " title "\n"))])
    (cond
      [(eq? (car target) 'file+headline)
       (let ([h (find-child 0 count 1 (caddr target))])
         (if h
             (list (subtree-end h 1) (org-demote-entry entry 1))
             (list count (string-append (heading 1 (caddr target)) (org-demote-entry entry 1)))))]
      [(eq? (car target) 'heading)
       ;; Under the heading on line (caddr target), as refiling picks.
       (let* ([h (min (caddr target) (max 0 (- count 1)))] [level (or (and (< h count) (level-at h)) 0)])
         (list (if (> level 0) (subtree-end h level) count) (org-demote-entry entry level)))]
      [(eq? (car target) 'file+datetree)
       (let* ([date (car clock)]
              [titles (list (substring date 0 4)
                            (string-append (substring date 0 7) " " (list-ref clock 4))
                            (string-append date " " (list-ref clock 3)))])
         ;; Down the tree as far as it exists; the rest is made in place.
         (let loop ([level 1] [from 0] [to count] [titles titles])
           (if (null? titles)
               (list to (org-demote-entry entry 3))
               (let ([h (find-child from to level (car titles))])
                 (if h
                     (loop (+ level 1) (+ h 1) (subtree-end h level) (cdr titles))
                     (list (sorted-slot from to level (car titles))
                           (string-append
                            (apply string-append
                                   (let make ([level level] [titles titles])
                                     (if (null? titles) '()
                                         (cons (heading level (car titles)) (make (+ level 1) (cdr titles))))))
                            (org-demote-entry entry 3))))))))]
      [else (list count (org-demote-entry entry 0))])))

(define (org-demote-entry entry by)
  "`entry` with each heading `by` levels deeper, ending in a line break."
  (apply string-append
         (map (lambda (line)
                (string-append (if (org-level-of line) (string-append (make-string by #\*) line) line) "\n"))
              (text-lines entry))))

(define (capture-file! target entry clock)
  "Files `entry` (text ending in a line break) at `target`. A buffer that
   has the file gets it (and is saved, if it had no other changes);
   otherwise the file is written. Returns the path."
  (let* ([path (org-path (cadr target))] [id (buffer-for-path path)])
    (if id
        (with-buffer id
          (lambda ()
            (let* ([clean? (not (buffer-modified?))]
                   [lines (text-lines (buffer-substring 0 (buffer-length)))]
                   [place (capture-placement lines target entry clock)]
                   [at (car place)])
              (begin-change!)
              (if (< at (buffer-line-count))
                  (if (and (= at (last-line)) (= (line-start at) (buffer-length)))
                      (buffer-insert! (buffer-length) (cadr place))
                      (buffer-insert! (line-start at) (cadr place)))
                  (let ([end (buffer-length)])
                    (buffer-insert! end (string-append (if (or (= end 0) (ends-with? (buffer-substring 0 end) "\n")) "" "\n")
                                                       (cadr place)))))
              (when clean? (save-buffer!)))))
        (let* ([old (if (file-exists? path) (read-file path) "")]
               [lines (text-lines old)]
               [place (capture-placement lines target entry clock)]
               [before (take lines (car place))]
               [after (list-tail lines (car place))]
               [join (lambda (ls) (apply string-append (map (lambda (l) (string-append l "\n")) ls)))])
          (write-text-file! path (string-append (join before) (cadr place) (join after)))))
    path))

(define (capture-with! t)
  "Starts capturing with template `t`."
  (let ([ctx (capture-context)])
    (when (eq? *mode* 'visual) (leave-visual!))
    (ask-all (capture-prompts (cadddr t))
      (lambda (answers)
        (let* ([expanded (capture-expand (cadddr t) ctx answers)]
               [id (buffer-new! "*capture*")])
          (display-buffer! id)
          (set-buffer-local! 'mode-line-label "capture")
          (set-major-mode! 'org-mode)
          (minor-mode-on! 'org-capture-mode)
          (set-buffer-local! 'capture (list t ctx (car expanded)))
          (set-buffer-local! 'write-handler capture-finish!)
          (buffer-insert! 0 (car expanded))
          (set-cursor! (cadr expanded))
          ((enter-insert! 'here) 1)
          (capture-hint!))))))

(define (capture-hint!)
  "Where the capture goes and its keys, on the message line."
  (let ([t (car (buffer-local 'capture))])
    (message (string-append (cadr t) " → " (capture-target-label (caddr t))
                            ": C-c C-c file, C-c C-k cancel, C-c C-w refile, C-c C-s schedule, C-c C-d deadline"))))

(add-hook! 'buffer-enter (lambda () (when (buffer-local 'capture) (capture-hint!))))

(define (capture-target-label target)
  "A short name for where `target` files to: the file, › heading."
  (string-append (file-name-of (org-path (cadr target)))
                 (if (eq? (car target) 'file+headline) (string-append " › " (caddr target)) "")))

(define (org-capture! . date)
  "Starts a capture, asking which template when there is more than one.
   When a capture is already in progress, shows it instead. With a
   `date`, the capture is for that day rather than today."
  (set! *capture-date* (and (pair? date) (car date)))
  (cond
    [(list-find (lambda (id) (equal? (car (buffer-info id)) "*capture*")) (buffer-list))
     => (lambda (id) (display-buffer! id) (message "a capture is in progress: C-c C-c files it, C-c C-k cancels"))]
    [(null? *capture-templates*) (message "no capture templates (define-capture-template!)")]
    [(null? (cdr *capture-templates*)) (capture-with! (car *capture-templates*))]
    [else (menu! "Capture"
                 (map (lambda (t) (list (car t) (cadr t) (lambda () (capture-with! t))))
                      *capture-templates*))]))

(define (capture-close!)
  "Closes the capture buffer and its window."
  (let ([id (current-buffer)])
    (when (memq *mode* '(insert replace)) (leave-insert!))
    (set-buffer-unmodified!)
    (run-command 'quit-window)
    (when (memv id (buffer-list)) (kill-buffer! id))))

(define (capture-entry)
  "The entry as typed, or #f when nothing was added to the template."
  (let ([text (buffer-substring 0 (buffer-length))] [made (caddr (buffer-local 'capture))])
    (and (not (equal? (trim text) (trim made)))
         (not (equal? (trim text) ""))
         (trim-end text))))

(define (capture-finish-at! target)
  "Files the capture at `target` (its template's, unless refiling)."
  (let ([entry (capture-entry)] [clock (context-ref (cadr (buffer-local 'capture)) 'clock)])
    (capture-close!)
    (if entry
        (let ([path (capture-file! target entry clock)])
          (message (string-append "captured to " (abbreviate-path path)
                                  (cond [(eq? (car target) 'file+headline) (string-append " › " (caddr target))]
                                        [(eq? (car target) 'heading) (string-append " › " (cadddr target))]
                                        [else ""]))))
        (message "nothing captured"))))

(define (capture-finish!)
  "C-c C-c: files the capture at its template's target and closes it.
   It is also the capture buffer's :w. Nothing typed, nothing filed."
  (when (buffer-local 'capture) (capture-finish-at! (caddr (car (buffer-local 'capture))))))

(define (capture-abort!)
  "C-c C-k: throws the capture away and closes its window."
  (when (buffer-local 'capture) (capture-close!) (message "capture cancelled")))

(define (org-refile-targets)
  "Every heading in the agenda files, as (\"file › outline path\" path line)."
  (apply append
         (map (lambda (path)
                (let loop ([lines (if (or (buffer-for-path path) (file-exists? path)) (text-lines (org-file-text path)) '())]
                           [n 0] [stack '()] [acc '()])
                  (if (null? lines)
                      (reverse acc)
                      (let ([level (org-level-of (car lines))])
                        (if level
                            (let* ([title (trim (substring (car lines) (+ level 1) (string-length (car lines))))]
                                   [stack (cons (cons level title) (filter (lambda (s) (< (car s) level)) stack))])
                              (loop (cdr lines) (+ n 1) stack
                                    (cons (list (string-append (file-name-of path) " › "
                                                               (string-join (reverse (map cdr stack)) " › "))
                                                path n)
                                          acc)))
                            (loop (cdr lines) (+ n 1) stack acc))))))
              (org-agenda-file-list))))

(define (capture-refile!)
  "C-c C-w: asks for a heading in the agenda files and files under it."
  (let ([targets (org-refile-targets)])
    (if (null? targets)
        (message "no headings in the agenda files to refile under")
        (completing-read "Refile under: " (map car targets)
                         (lambda (choice)
                           (let ([hit (assoc choice targets)])
                             (when hit
                               (capture-finish-at! (list 'heading (cadr hit) (caddr hit) (last (split-many (car hit) " › ")))))))))))

(define (org-refile-to! h target)
  "Moves the heading on line `h` of the current buffer, with its subtree,
   under `target` (label path line), at the end of that heading's
   subtree and a level below it. Returns #f after saying why when the
   target is inside the subtree."
  (let* ([end (org-subtree-end h)]
         [level (org-level h)]
         [path (cadr target)]
         [same? (equal? (and (buffer-path) (absolute-path (buffer-path))) (absolute-path path))]
         [tline (caddr target)])
    (if (and same? (<= h tline end))
        (begin (message "can't refile a heading under itself") #f)
        (let* ([text (buffer-substring (line-start h) (min (buffer-length) (+ (line-end end) 1)))]
               [text (if (ends-with? text "\n") text (string-append text "\n"))]
               ;; As a level-1 subtree, which filing demotes to fit.
               [entry (apply string-append
                             (map (lambda (l) (string-append (if (org-level-of l) (substring l (- level 1) (string-length l)) l) "\n"))
                                  (text-lines text)))]
               [tline (if (and same? (> tline end)) (- tline (+ (- end h) 1)) tline)])
          (with-undo-group
           (lambda ()
             (begin-change!)
             (replace-range! (line-start h) (min (buffer-length) (+ (line-end end) 1)) "")
             (capture-file! (list 'heading path tline (last (split-many (car target) " › ")))
                            entry #f)))
          (message (string-append "refiled to " (car target)))
          #t))))

(define (org-refile-prompt! then)
  "C-c C-w: asks for a heading in the agenda files and moves the heading
   the cursor is under there, with its subtree. `then` runs after, with
   whether it moved."
  (let ([h (org-heading-line (current-line))] [targets (org-refile-targets)])
    (cond [(not h) (message "not under a heading")]
          [(null? targets) (message "no headings in the agenda files to refile under")]
          [else (completing-read "Refile under: " (map car targets)
                                 (lambda (choice)
                                   (let ([hit (assoc choice targets)])
                                     (then (and hit (org-refile-to! h hit))))))])))

(define (org-archive-target path)
  "Where org-archive-location sends a heading of file `path`: (file
   heading-or-#f). %s anywhere in the location is the file's name; an empty file
   part is the file itself; after :: an optional heading, as \"* Archive\"."
  (let* ([name (file-name-of path)]
         [loc (let loop ([t (option 'org-archive-location)])
                (let ([i (string-index-from t "%s" 0)])
                  (if i (loop (string-append (substring t 0 i) name (substring t (+ i 2) (string-length t)))) t)))]
         [parts (let ([i (string-index-from loc "::" 0)])
                  (if i (list (substring loc 0 i) (substring loc (+ i 2) (string-length loc))) (list loc "")))]
         [file (car parts)]
         [file (cond [(equal? file "") path]
                     [(or (starts-with? file "/") (starts-with? file "~")) (expand-path file)]
                     [else (string-append (directory-of path) "/" file)])]
         [heading (trim (cadr parts))]
         [heading (let ([lv (org-level-of heading)])
                    (if lv (trim (substring heading (min (string-length heading) (+ lv 1)) (string-length heading))) heading))])
    (list file (if (equal? heading "") #f heading))))

(define (org-archive! h)
  "Moves the heading on line `h`, with its subtree, to its archive
   (org-archive-location), with Org's ARCHIVE_TIME, ARCHIVE_FILE,
   ARCHIVE_OLPATH, ARCHIVE_CATEGORY and ARCHIVE_TODO properties. The
   archive file is made if needed. Returns the archive's path."
  (let* ([path (absolute-path (buffer-path))]
         [target (org-archive-target path)]
         [file (car target)]
         [lines (org-buffer-lines)]
         [clock (capture-clock)]
         [olpath (let loop ([p (org-parent-heading lines h)] [acc '()])
                   (if p (loop (org-parent-heading lines p) (cons (org-heading-title (vector-ref lines p)) acc)) acc))]
         [base (let ([b (file-name-of path)]) (if (ends-with? b ".org") (substring b 0 (- (string-length b) 4)) b))]
         [category (or (org-lines-property lines h "CATEGORY" #t) (org-file-setting lines "#+CATEGORY:") base)]
         [rest (substring (line-text h) (+ (org-level h) 1) (string-length (line-text h)))]
         [keyword (org-keyword-in rest)])
    (with-undo-group
     (lambda ()
       (org-set-property! h "ARCHIVE_TIME" (string-append (car clock) " " (cadr clock) " " (caddr clock)))
       (org-set-property! h "ARCHIVE_FILE" path)
       (when (pair? olpath) (org-set-property! h "ARCHIVE_OLPATH" (string-join olpath "/")))
       (org-set-property! h "ARCHIVE_CATEGORY" category)
       (when keyword (org-set-property! h "ARCHIVE_TODO" keyword))
       (let* ([end (org-subtree-end h)]
              [level (org-level h)]
              [text (buffer-substring (line-start h) (min (buffer-length) (+ (line-end end) 1)))]
              [entry (apply string-append
                            (map (lambda (l) (string-append (if (org-level-of l) (substring l (- level 1) (string-length l)) l) "\n"))
                                 (text-lines text)))])
         (begin-change!)
         (replace-range! (line-start h) (min (buffer-length) (+ (line-end end) 1)) "")
         (unless (or (buffer-for-path file) (file-exists? file))
           (write-text-file! file (string-append "#    -*- mode: org -*-\n\n\nArchived entries from file " path "\n\n\n")))
         (capture-file! (if (cadr target) (list 'file+headline file (cadr target)) (list 'file file)) entry #f))))
    file))

(define (org-archive-prompt!)
  "C-c C-x C-a: archives the heading the cursor is under, with its
   subtree (org-archive-location)."
  (let ([h (org-heading-line (current-line))])
    (if (not h)
        (message "not under a heading")
        (let ([file (org-archive! h)])
          (message (string-append "archived in " (file-name-of file)))))))

(define-minor-mode! 'org-capture-mode #f #f)
(for-each (lambda (state)
            (define-mode-key! 'org-capture-mode state "C-cC-c" (lambda args (capture-finish!)))
            (define-mode-key! 'org-capture-mode state "C-cC-k" (lambda args (capture-abort!)))
            (define-mode-key! 'org-capture-mode state "C-cC-w" (lambda args (capture-refile!))))
          '(normal insert))
(define-popup-rule! "*capture" 'side 'right 'size 0.33)

;;; Modes and keys

(define (org-keyword-pattern keywords)
  "A pattern matching any of `keywords` right after a heading's stars.
   Characters special in a pattern are escaped. It is all one group, as
   a buffer's highlight pattern paints only its groups."
  (let ([escape (lambda (k)
                  (apply string-append
                         (map (lambda (c) (if (member c '(#\\ #\. #\* #\[ #\] #\~ #\^ #\$ #\/)) (string #\\ c) (string c)))
                              (string->list k))))])
    (string-append "\\(^\\*\\+ \\(" (string-join (map escape keywords) "\\|") "\\)\\)\\>")))

(define-major-mode! 'org-mode 'text-mode '("org")
  (lambda ()
    (set-local-option! 'shiftwidth 2)
    ;; The outline is made of folds by hand, not by indent.
    (set-local-option! 'foldmethod "manual")
    (for-each (lambda (p) (buffer-highlight-pattern! (car p) (cadr p) (caddr p)))
              (list (list "org-1" "^\\* .*" "org.level1")
                    (list "org-2" "^\\*\\* .*" "org.level2")
                    (list "org-3" "^\\*\\*\\* .*" "org.level3")
                    (list "org-4" "^\\*\\*\\*\\*\\+ .*" "org.level4")
                    (list "org-h1" "^\\* .*" "org.height1")
                    (list "org-h2" "^\\*\\* .*" "org.height2")
                    (list "org-h3" "^\\*\\*\\* .*" "org.height3")
                    (list "org-h4" "^\\*\\*\\*\\*\\+ .*" "org.height4")
                    (list "org-todo" (org-keyword-pattern (filter (lambda (k) (not (member k (org-done-keywords))))
                                                                  (org-keywords)))
                          "org.todo")
                    (list "org-done" (org-keyword-pattern (org-done-keywords)) "org.done")
                    (list "org-tags" "\\s:[a-zA-Z0-9_@#%:]\\+:\\s*$" "org.tag")
                    (list "org-meta" "^\\s*#.*" "org.meta")
                    (list "org-table" "^\\s*|.*" "org.table")
                    (list "org-special" "SCHEDULED:\\|DEADLINE:\\|CLOSED:" "org.special")
                    (list "org-date" "[<[]\\d\\{4}-\\d\\d-\\d\\d[^]>]*[]>]" "org.date")
                    (list "org-box" "\\[[ X-]\\]" "org.checkbox")
                    (list "org-priority" "\\[#[A-Z]\\]" "org.priority")
                    (list "org-cookie" "\\(\\[\\d\\+\\(/\\d\\+\\)\\?%\\?\\]\\)" "org.checkbox")
                    (list "org-code" "=[^= ][^=]*=" "org.code")
                    (list "org-verbatim" "[~][^~ ][^~]*[~]" "org.code")
                    (list "org-link" "\\(\\[\\[[^\\]]*\\]\\(\\[[^\\]]*\\]\\)\\?\\]\\)" "org.link")))
    (org-show-links! (not (option 'org-link-descriptive)))
    (org-close-drawers! 0 (last-line))
    (org-set-indent! (option 'org-indent))))

(define (org-set-indent! on?)
  "Draws this buffer indented by outline level when `on?`, else as written."
  (set-buffer-local! 'org-indented on?)
  (set-outline-indent! (if on? (max 1 (option 'org-indent-per-level)) 0)))

(define-command! 'org-indent-mode
  (lambda (count)
    "Indent each section under its heading in this buffer, or stop."
    (org-set-indent! (not (buffer-local 'org-indented)))
    (message (if (buffer-local 'org-indented) "org-indent on" "org-indent off"))))

(define (org-set-heading-heights! heights)
  "Sets the faces that size headings, org.height1 to org.height4, from
   `heights` (see org-heading-heights)."
  (for-each (lambda (level)
              (let ([h (and (list? heights) (> (length heights) (- level 1)) (list-ref heights (- level 1)))])
                (set-face! (string-append "org.height" (number->string level))
                           (if (and (number? h) (not (= h 1))) (string-append "height=" (number->string h)) ""))))
            '(1 2 3 4)))

(watch-option! 'org-heading-heights org-set-heading-heights!)

;; What a link hides when it shows just its description: its brackets,
;; and the target when there is a description.
(define *org-link-conceal* "\\(\\[\\[\\([^\\]]*\\]\\[\\)\\?\\)[^\\]]*\\(\\]\\]\\)")

(define (org-show-links! whole?)
  "Shows the buffer's links as written when `whole?`, else just their
   descriptions (whole on the cursor's line)."
  (set-buffer-local! 'org-links-whole whole?)
  (buffer-conceal-pattern! "org-link-conceal" (if whole? "" *org-link-conceal*)))

(define-command! 'org-toggle-link-display
  (lambda (count)
    "Show links as written, or just their descriptions, in this buffer."
    (org-show-links! (not (buffer-local 'org-links-whole)))
    (message (if (buffer-local 'org-links-whole) "links shown whole" "links show their descriptions"))))

(define (org-key! states key proc . label)
  "Binds `key` to `proc` in Org buffers, in each of `states`. An optional
   last argument is the label which-key shows."
  (for-each (lambda (state) (apply define-mode-key! (append (list 'org-mode state key proc) label))) states))

(org-key! '(normal) "<tab>" org-tab!)
(org-key! '(normal) "<s-tab>" (lambda (count) (org-global-cycle!)))
(org-key! '(normal) "<ret>" org-dwim!)
(org-key! '(normal) "gx" (lambda (count) (let ([l (org-link-at (cursor))]) (if l (org-follow! l) (message "no link here"))))
  "follow link")
(org-key! '(normal insert) "M-<ret>" (lambda args (org-insert-heading!)))
(org-key! '(normal) "M-h" (lambda (count) (org-shift! (current-line) -1 #f)))
(org-key! '(normal) "M-l" (lambda (count) (org-shift! (current-line) 1 #f)))
(org-key! '(normal) "M-H" (lambda (count) (org-shift! (current-line) -1 #t)))
(org-key! '(normal) "M-L" (lambda (count) (org-shift! (current-line) 1 #t)))
(org-key! '(normal) "M-k" (lambda (count) (org-move-subtree! #f)))
(org-key! '(normal) "M-j" (lambda (count) (org-move-subtree! #t)))
;; In insert state <tab> moves between table cells, and is a tab elsewhere.
(org-key! '(insert) "<tab>"
  (lambda () (if (org-table-line? (current-line)) (org-table-next-cell!) (insert-tab!))))

(org-key! '(normal insert) "C-cC-s" (lambda args (org-schedule!)))
(org-key! '(normal insert) "C-cC-d" (lambda args (org-deadline!)))
(org-key! '(normal insert) "C-c." (lambda args (org-time-stamp!)))
(org-key! '(normal insert) "C-c," (lambda args (org-priority-menu!)))
(org-key! '(normal insert) "C-cC-xp" (lambda args (org-property-prompt!)))
(org-key! '(normal insert) "C-cC-q" (lambda args (org-tags-prompt!)))
(org-key! '(normal insert) "C-cC-xC-a" (lambda args (org-archive-prompt!)))
(org-key! '(normal insert) "C-cC-w" (lambda args (org-refile-prompt! (lambda (moved?) void))))
(org-key! '(normal insert) "C-cC-xe" (lambda args (org-effort-prompt!)))
(org-key! '(normal insert) "C-cC-xC-i" (lambda args (org-clock-at-heading org-clock-in!)))
(org-key! '(normal insert) "C-cC-xC-o" (lambda args (org-clock-out!)))
(org-key! '(normal insert) "C-cC-xC-q" (lambda args (org-clock-cancel!)))
(org-key! '(normal insert) "C-cC-xC-j" (lambda args (org-clock-goto!)))
(define-mode-leader! 'org-mode "i" (lambda (n) (run-command 'org-indent-mode)) "toggle indent")
(define-mode-leader! 'org-mode "l" (lambda (n) (run-command 'org-toggle-link-display)) "toggle link display")
(define-mode-leader! 'org-mode "s" (lambda (n) (org-schedule!)) "schedule")
(define-mode-leader! 'org-mode "d" (lambda (n) (org-deadline!)) "deadline")
(define-mode-leader! 'org-mode "." (lambda (n) (org-time-stamp!)) "timestamp")
(define-mode-leader! 'org-mode "t" (lambda (n) (let ([h (org-heading-line (current-line))]) (if h (org-todo-cycle! h) (message "not under a heading")))) "cycle TODO")
(define-mode-leader! 'org-mode "x" (lambda (n) (org-toggle-checkbox! (current-line))) "toggle checkbox")
(define-mode-leader! 'org-mode "p" (lambda (n) (org-priority-menu!)) "priority")
(define-mode-leader! 'org-mode "P" (lambda (n) (org-property-prompt!)) "set property")
(define-mode-leader! 'org-mode "q" (lambda (n) (org-tags-prompt!)) "set tags")
(define-mode-leader! 'org-mode "A" (lambda (n) (org-archive-prompt!)) "archive")
(define-mode-leader! 'org-mode "r" (lambda (n) (org-refile-prompt! (lambda (moved?) void))) "refile")
(define-mode-leader-group! 'org-mode "c" "clock")
(define-mode-leader! 'org-mode "cE" (lambda (n) (org-effort-prompt!)) "set effort")
(define-mode-leader! 'org-mode "ci" (lambda (n) (org-clock-at-heading org-clock-in!)) "clock in")
(define-mode-leader! 'org-mode "co" (lambda (n) (org-clock-out!)) "clock out")
(define-mode-leader! 'org-mode "cc" (lambda (n) (org-clock-cancel!)) "cancel clock")
(define-mode-leader! 'org-mode "cg" (lambda (n) (org-clock-goto!)) "go to clock")
(define-mode-leader! 'org-mode "o" (lambda (n) (let ([l (org-link-at (cursor))]) (if l (org-follow! l) (message "no link here")))) "open link")
(define-mode-leader! 'org-mode "b" (lambda (n) (when (org-table-line? (current-line)) (org-table-align! (current-line)))) "align table")

(define-command! 'org-capture
  (lambda (count)
    "Capture a TODO, note or journal entry from a template."
    (org-capture!)))
(define-leader-group! "o" "org")
(define-leader! "oc" 'org-capture "capture")
