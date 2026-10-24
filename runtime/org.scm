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
;;; SPC o a shows the agenda: TODOs and SCHEDULED/DEADLINE dates from
;;; org-agenda-files (empty means every .org file under org-directory).
;;; SPC o c captures: a TODO, a note or a journal entry, from templates
;;; (see Capture below).
;;;
;;;   C-c C-s    schedule the heading (SCHEDULED:), from a calendar
;;;   C-c C-d    give it a deadline (DEADLINE:)
;;;   C-c .      put a timestamp at the cursor, or change the one there

(define-option! 'org-directory "~/org" '())
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
(define-option! 'org-indent-per-level 2 '())
;; How much bigger headings are drawn, from level 1 down: 1.4 is 1.4
;; times the font. Levels past the list are the font's size; '() makes
;; them all so. Window clients only: a terminal draws one size.
(define-option! 'org-heading-heights '(1.4 1.25 1.1) '())

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

(define (org-todo-cycle! line)
  "Moves the heading on `line` to the next TODO keyword (none after the last)."
  (let* ([text (line-text line)]
         [level (org-level line)]
         [rest (substring text (+ level 1) (string-length text))]
         [kws (org-keywords)]
         [current (org-keyword-in rest)]
         [title (if current (trim-start (substring rest (string-length current) (string-length rest))) rest)]
         [next (cond [(not current) (car kws)]
                     [(member current kws)
                      (let ([after (cdr (member current kws))]) (if (null? after) #f (car after)))]
                     [else #f])])
    (begin-change!)
    (org-set-line! line (string-append (make-string level #\*) " " (if next (string-append next " ") "") title))
    (set-cursor! (line-start line))
    (message (or next "no keyword"))))

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

;;; The agenda

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
   under org-directory (none if it doesn't exist)."
  (let ([files (option 'org-agenda-files)])
    (if (pair? files)
        (map org-path files)
        (let ([dir (expand-path (option 'org-directory))])
          (if (file-exists? dir)
              (map (lambda (f) (string-append dir "/" f))
                   (filter (lambda (f) (ends-with? f ".org")) (list-files dir 10000)))
              '())))))

(define (org-date-after text key)
  "The date in \"<2026-10-18 Sun>\" after `key` on `text`, or #f."
  (let ([parts (split-once text key)])
    (and (pair? parts) (pair? (cdr parts))
         (let ([rest (trim-start (cadr parts))])
           (and (>= (string-length rest) 11) (member (substring rest 0 1) '("<" "["))
                (substring rest 1 11))))))

(define (org-file-entries file)
  "Agenda entries in `file`: (file line keyword title scheduled deadline
   priority)."
  (let loop ([lines (text-lines (read-file file))] [n 0] [acc '()] [current #f])
    (let ([finish (lambda (acc) (if current (cons current acc) acc))])
      (if (null? lines)
          (reverse (finish acc))
          (let* ([text (car lines)] [level (org-level-of text)])
            (cond
              [level
               (let* ([rest (substring text (+ level 1) (string-length text))]
                      [kw (org-keyword-in rest)]
                      [title (if kw (trim-start (substring rest (string-length kw) (string-length rest))) rest)])
                 (loop (cdr lines) (+ n 1) (finish acc) (list file n kw title #f #f (org-priority-in title))))]
              [current
               (let* ([s (org-date-after text "SCHEDULED:")] [d (org-date-after text "DEADLINE:")]
                      [current (list (car current) (cadr current) (caddr current) (cadddr current)
                                     (or s (list-ref current 4)) (or d (list-ref current 5)) (list-ref current 6))])
                 (loop (cdr lines) (+ n 1) acc current))]
              [else (loop (cdr lines) (+ n 1) acc current)]))))))

(define (org-today)
  "Today's date as YYYY-MM-DD. Runs date."
  (trim (cadr (run-shell "date +%F" ""))))

(define (org-entry-done? e)
  "Whether agenda entry `e` has a done keyword (see `org-done-keywords`)."
  (and (caddr e) (member (caddr e) (org-done-keywords)) #t))

(define (org-agenda-line! e date what)
  "Draws agenda entry `e`, with its `date` and `what` (Scheduled:...).
   Either may be #f. The line remembers the entry's file and line, so
   <ret> on it goes there."
  (draw-line! (list (list "  " #f)
                   (list (if date (string-append date "  ") "") "org.date")
                   (list (if what (pad-right what 12) "") "org.special")
                   (list (if (caddr e) (string-append (caddr e) " ") "") (if (org-entry-done? e) "org.done" "org.todo"))
                   (list (cadddr e) #f)
                   (list (string-append "  " (file-name-of (car e))) "git.count"))
             (list 'org (car e) (cadr e))))

(define (org-render-agenda!)
  "Redraws the agenda from the agenda files, like Org's agenda.
   Undone entries scheduled or due today or earlier, then those
   upcoming, by date; then the TODOs with no date. Done entries are
   left out."
  (let* ([today (org-today)]
         [entries (apply append (map org-file-entries (org-agenda-file-list)))]
         [open (filter (lambda (e) (not (org-entry-done? e))) entries)]
         [dated (apply append (map (lambda (e)
                                     (append (if (list-ref e 4) (list (list (list-ref e 4) "Scheduled:" e)) '())
                                             (if (list-ref e 5) (list (list (list-ref e 5) "Deadline:" e)) '())))
                                   open))]
         ;; By date, then priority, then where they are in the files.
         [rank (lambda (e) (org-priority-rank (list-ref e 6)))]
         [dated (map cdr (sort (map cons (range 0 (length dated)) dated)
                               (lambda (a b)
                                 (let ([da (cadr a)] [db (cadr b)]
                                       [ra (rank (cadddr a))] [rb (rank (cadddr b))])
                                   (or (string<? da db)
                                       (and (equal? da db) (or (< ra rb) (and (= ra rb) (< (car a) (car b))))))))))]
         [todos (filter (lambda (e) (and (caddr e) (not (list-ref e 4)) (not (list-ref e 5)))) open)]
         [todos (map cdr (sort (map cons (range 0 (length todos)) todos)
                               (lambda (a b)
                                 (let ([ra (rank (cdr a))] [rb (rank (cdr b))])
                                   (or (< ra rb) (and (= ra rb) (< (car a) (car b))))))))])
    (draw-begin!)
    (draw-line! (list (list (string-append "Agenda for " today) "git.section")) #f)
    (draw-line! '() #f)
    (draw-line! (list (list "Overdue and today" "git.section")) #f)
    (for-each (lambda (d) (when (string<=? (car d) today) (org-agenda-line! (caddr d) (car d) (cadr d))))
              dated)
    (draw-line! '() #f)
    (draw-line! (list (list "Upcoming" "git.section")) #f)
    (for-each (lambda (d) (when (string<? today (car d)) (org-agenda-line! (caddr d) (car d) (cadr d))))
              dated)
    (draw-line! '() #f)
    (draw-line! (list (list "To do" "git.section")) #f)
    (for-each (lambda (e) (org-agenda-line! e #f #f)) todos)
    (when (null? entries)
      (draw-line! '() #f)
      (draw-line! (list (list (string-append "no entries in " (option 'org-directory)
                                            " (set org-directory or org-agenda-files)") "git.head"))
                 #f))
    (draw-finish!)))

(define (org-agenda!)
  "Shows the agenda in its own buffer, freshly read from the files."
  (go-to-buffer! (special-buffer "*org agenda*" 'org-agenda-mode))
  (org-render-agenda!)
  (set-cursor! 0))

(define (org-agenda-visit!)
  "Opens the file of the agenda entry at the cursor, on its heading."
  (let ([item (line-item)])
    (when (and item (eq? (car item) 'org))
      (when (open-file! (cadr item))
        (set-cursor! (line-start (min (caddr item) (last-line))))))))

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
            [bounds (replace-range! (+ (line-start next) (car bounds)) (+ (line-start next) (cadr bounds)) stamp)]
            [at (buffer-insert! (+ (line-start next) at (string-length key)) (string-append " " stamp))]
            [else (buffer-insert! (line-end next) (string-append " " key " " stamp))]))
        (buffer-insert! (line-end heading) (string-append "\n" key " " stamp)))))

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
                 (let ([stamp (date-timestamp (take d 3) (cadddr d) #t)])
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

(define (capture-context)
  "What a template can refer to, gathered where capture starts."
  (list (cons 'clock (capture-clock))
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

(define (org-capture!)
  "Starts a capture, asking which template when there is more than one.
   When a capture is already in progress, shows it instead."
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
                (let loop ([lines (if (file-exists? path) (text-lines (read-file path)) '())] [n 0] [stack '()] [acc '()])
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
   Characters special in a pattern are escaped."
  (let ([escape (lambda (k)
                  (apply string-append
                         (map (lambda (c) (if (member c '(#\\ #\. #\* #\[ #\] #\~ #\^ #\$ #\/)) (string #\\ c) (string c)))
                              (string->list k))))])
    (string-append "^\\*\\+ \\(" (string-join (map escape keywords) "\\|") "\\)\\>")))

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
                    (list "org-cookie" "\\[\\d\\+\\(/\\d\\+\\)\\?%\\?\\]" "org.checkbox")
                    (list "org-code" "=[^= ][^=]*=" "org.code")
                    (list "org-verbatim" "[~][^~ ][^~]*[~]" "org.code")
                    (list "org-link" "\\[\\[[^\\]]*\\]\\(\\[[^\\]]*\\]\\)\\?\\]" "org.link")))
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
(define-mode-leader! 'org-mode "i" (lambda (n) (run-command 'org-indent-mode)) "toggle indent")
(define-mode-leader! 'org-mode "l" (lambda (n) (run-command 'org-toggle-link-display)) "toggle link display")
(define-mode-leader! 'org-mode "s" (lambda (n) (org-schedule!)) "schedule")
(define-mode-leader! 'org-mode "d" (lambda (n) (org-deadline!)) "deadline")
(define-mode-leader! 'org-mode "." (lambda (n) (org-time-stamp!)) "timestamp")
(define-mode-leader! 'org-mode "t" (lambda (n) (let ([h (org-heading-line (current-line))]) (if h (org-todo-cycle! h) (message "not under a heading")))) "cycle TODO")
(define-mode-leader! 'org-mode "x" (lambda (n) (org-toggle-checkbox! (current-line))) "toggle checkbox")
(define-mode-leader! 'org-mode "p" (lambda (n) (org-priority-menu!)) "priority")
(define-mode-leader! 'org-mode "o" (lambda (n) (let ([l (org-link-at (cursor))]) (if l (org-follow! l) (message "no link here")))) "open link")
(define-mode-leader! 'org-mode "b" (lambda (n) (when (org-table-line? (current-line)) (org-table-align! (current-line)))) "align table")

(define-major-mode! 'org-agenda-mode 'special-mode '() #f)
(define-mode-key! 'org-agenda-mode 'normal "<ret>" (lambda (n) (org-agenda-visit!)))
(define-mode-key! 'org-agenda-mode 'normal "gr" (lambda (n) (org-render-agenda!)) "refresh")

(define-command! 'org-agenda
  (lambda (count)
    "Show the agenda: TODOs and SCHEDULED and DEADLINE dates."
    (org-agenda!)))
(define-command! 'org-capture
  (lambda (count)
    "Capture a TODO, note or journal entry from a template."
    (org-capture!)))
(define-leader-group! "o" "org")
(define-leader! "oa" 'org-agenda "agenda")
(define-leader! "oc" 'org-capture "capture")
(define-ex! '("OrgAgenda") (lambda (ex) (org-agenda!)))
(define-ex! '("OrgCapture") (lambda (ex) (org-capture!)))
