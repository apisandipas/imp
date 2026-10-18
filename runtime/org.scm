;;; org.scm -- Org mode: outlines, TODOs, checkboxes, links, tables, and an
;;; agenda over your .org files.
;;;
;;; In a .org buffer (normal state; SPC m has the same under the leader):
;;;
;;;   <tab>      on a heading, cycle its subtree: folded, children, all;
;;;              in a table, align it and go to the next cell
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
;;; SPC o c captures a TODO into org-default-notes-file.

(define-option! 'org-directory "~/org" '())
(define-option! 'org-agenda-files '() '())
;; Empty means inbox.org in org-directory.
(define-option! 'org-default-notes-file "" '())
(define-option! 'org-todo-keywords '("TODO" "DONE") '())

;;; Headings and subtrees

;; The level of the heading on `line` (how many stars), or #f.
(define (org-level-of text)
  (let ([n (string-length text)])
    (let loop ([i 0])
      (cond [(and (< i n) (equal? (string-ref text i) #\*)) (loop (+ i 1))]
            [(and (> i 0) (< i n) (equal? (string-ref text i) #\space)) i]
            [else #f]))))

(define (org-level line) (org-level-of (line-text line)))

;; The heading at or above `line`, or #f.
(define (org-heading-line line)
  (let loop ([l line]) (cond [(< l 0) #f] [(org-level l) l] [else (loop (- l 1))])))

;; The last line under the heading on `line`, before a heading of its
;; level or higher.
(define (org-subtree-end line)
  (let ([level (org-level line)])
    (let loop ([l (+ line 1)])
      (cond [(> l (last-line)) (last-line)]
            [(let ([lv (org-level l)]) (and lv (<= lv level))) (- l 1)]
            [else (loop (+ l 1))]))))

;; The last line of the heading's own text, before any heading.
(define (org-body-end line)
  (let loop ([l (+ line 1)])
    (cond [(> l (last-line)) (last-line)]
          [(org-level l) (- l 1)]
          [else (loop (+ l 1))])))

;; The headings directly under the one on `line`.
(define (org-children line)
  (let ([end (org-subtree-end line)])
    (let loop ([l (+ line 1)] [acc '()] [child-level #f])
      (if (> l end)
          (reverse acc)
          (let ([lv (org-level l)])
            (if (and lv (or (not child-level) (<= lv child-level)))
                (loop (+ l 1) (cons l acc) lv)
                (loop (+ l 1) acc child-level)))))))

(define (org-headings)
  (filter org-level (range 0 (buffer-line-count))))

;;; Visibility, with folds (fold.scm)

(define (org-folds-from first last)
  (filter (lambda (f) (and (>= (fold-first f) first) (<= (fold-first f) last))) (buffer-folds)))

(define (org-unfold! first last)
  (for-each (lambda (f) (fold-delete! (fold-id f))) (org-folds-from first last)))

(define (org-fold! first last) (when (> last first) (fold-create! first last #t)))

;; Cycles the subtree under the heading on `line`: FOLDED, CHILDREN (the
;; child headings, their text hidden), SUBTREE (everything).
(define (org-cycle! line)
  (let ([end (org-subtree-end line)] [children (org-children line)])
    (cond
      [(= end line) (message "empty entry")]
      [(list-find (lambda (f) (and (= (fold-first f) line) (= (fold-last f) end) (fold-closed? f))) (buffer-folds))
       (org-unfold! line end)
       (if (null? children)
           (message "SUBTREE")
           (begin
             (org-fold! line (- (car children) 1))
             (for-each (lambda (c) (org-fold! c (org-subtree-end c))) children)
             (message "CHILDREN")))]
      [(pair? (org-folds-from line end)) (org-unfold! line end) (message "SUBTREE")]
      [else (org-fold! line end) (message "FOLDED")])
    (set-cursor! (line-start line))))

;; Cycles the whole buffer: OVERVIEW (top headings), CONTENTS (every
;; heading), SHOW ALL.
(define (org-global-cycle!)
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
      [else (set-buffer-local! 'org-visibility 'all) (message "SHOW ALL")])
    (let ([line (current-line)]) (set-cursor! (line-start (shown-line line))))))

;;; Editing lines

;; Text of lines first..last, each ending in a line break.
(define (org-lines-text first last)
  (string-append (buffer-substring (line-start first) (line-end last)) "\n"))

;; Replaces lines first..last with `text` (lines ending in line breaks).
(define (org-replace-lines! first last text)
  (let* ([end (line-end last)] [break? (< end (buffer-length))])
    (replace-range! (line-start first) (if break? (+ end 1) end)
                    (if break? text (substring text 0 (- (string-length text) 1))))))

(define (org-set-line! line text)
  (replace-range! (line-start line) (line-end line) text))

;; The keyword the heading text after its stars starts with, or #f.
(define (org-keyword-in rest)
  (list-find (lambda (k) (or (equal? rest k) (starts-with? rest (string-append k " "))))
             (option 'org-todo-keywords)))

;; Moves the heading on `line` to the next TODO keyword (none after the last).
(define (org-todo-cycle! line)
  (let* ([text (line-text line)]
         [level (org-level line)]
         [rest (substring text (+ level 1) (string-length text))]
         [kws (option 'org-todo-keywords)]
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

;; A list item on `line`: (indent-width marker-end checkbox-offset-or-#f), or #f.
(define (org-list-item line)
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

;; Toggles the checkbox on `line`, then updates the [n/m] or [n%] cookie of
;; its heading.
(define (org-toggle-checkbox! line)
  (let* ([item (org-list-item line)] [box (and item (caddr item))])
    (when box
      (begin-change!)
      (let ([checked? (member (buffer-char-at (+ box 1)) '(#\X #\x))])
        (replace-range! (+ box 1) (+ box 2) (if checked? " " "X")))
      (let ([h (org-heading-line line)]) (when h (org-update-cookie! h))))))

(define (org-count-boxes first last)
  (foldl (lambda (l acc)
           (let* ([item (org-list-item l)] [box (and item (caddr item))])
             (if box
                 (list (+ (car acc) (if (member (buffer-char-at (+ box 1)) '(#\X #\x)) 1 0)) (+ (cadr acc) 1))
                 acc)))
         (list 0 0) (range first (+ last 1))))

;; The [..] cookie in `text`: (start end percent?), or #f.
(define (org-find-cookie text)
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
  (let* ([text (line-text heading)] [cookie (org-find-cookie text)])
    (when cookie
      (let* ([counts (org-count-boxes (+ heading 1) (org-body-end heading))]
             [done (car counts)] [total (cadr counts)]
             [new (if (caddr cookie)
                      (string-append "[" (number->string (if (= total 0) 0 (quotient (* 100 done) total))) "%]")
                      (string-append "[" (number->string done) "/" (number->string total) "]"))]
             [start (+ (line-start heading) (car cookie))])
        (replace-range! start (+ (line-start heading) (cadr cookie)) new)))))

;; M-<ret>: a new item after a list item, or a heading after this subtree.
(define (org-insert-heading!)
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
    (set! *insert-start* (cursor))))

;; Promotes (-1) or demotes (+1) the heading or list item on `line`, or
;; with `subtree?` every heading under it too.
(define (org-shift! line delta subtree?)
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

;; Swaps the subtree under the heading at the cursor with the sibling
;; after it (down?) or before it.
(define (org-move-subtree! down?)
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

;; The link at offset `at`: its target, or #f. [[target][text]],
;; [[target]], or a bare http(s) URL.
(define (org-link-at at)
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
  (cond
    [(or (starts-with? target "http://") (starts-with? target "https://") (starts-with? target "mailto:"))
     (start-job! (string-append "xdg-open " (shell-quote target)) "" #f #f)
     (message (string-append "opening " target))]
    [(starts-with? target "*")
     (let* ([title (substring target 1 (string-length target))]
            [h (list-find (lambda (l) (let ([t (line-text l)]) (ends-with? t title))) (org-headings))])
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
  (and (<= 0 line) (<= line (last-line)) (starts-with? (trim-start (line-text line)) "|")))

(define (org-table-bounds line)
  (list (let up ([l line]) (if (org-table-line? (- l 1)) (up (- l 1)) l))
        (let down ([l line]) (if (org-table-line? (+ l 1)) (down (+ l 1)) l))))

(define (org-separator? text) (starts-with? (trim-start text) "|-"))

(define (org-row-cells text)
  (let* ([t (trim text)]
         [parts (split-many (substring t 1 (string-length t)) "|")]
         [parts (if (and (pair? parts) (equal? (trim (last parts)) "")) (reverse (cdr (reverse parts))) parts)])
    (map trim parts)))

;; Aligns the table around `line`, keeping the cursor in its cell. Returns
;; (first-line cell-index) of where the cursor was.
(define (org-table-align! line)
  (let* ([bounds (org-table-bounds line)] [first (car bounds)] [last (cadr bounds)]
         [texts (map line-text (range first (+ last 1)))]
         [indent (let ([t (car texts)]) (substring t 0 (- (string-length t) (string-length (trim-start t)))))]
         [rows (map (lambda (t) (if (org-separator? t) 'rule (org-row-cells t))) texts)]
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
      (begin-change!)
      (org-replace-lines! first last new))
    (list first cols (max 1 cell-index))))

;; Moves to cell `index` (1-based) of row `line`.
(define (org-go-to-cell! line index)
  (let* ([t (line-text line)] [bars (filter (lambda (i) (equal? (string-ref t i) #\|)) (range 0 (string-length t)))])
    (set-cursor! (+ (line-start line) (min (+ (list-ref bars (min (- index 1) (- (length bars) 1))) 2) (string-length t))))))

;; <tab> in a table: align it and go to the next cell, past rules, adding
;; a row at the end.
(define (org-table-next-cell!)
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
  (let* ([line (current-line)] [link (org-link-at (cursor))] [item (org-list-item line)])
    (cond
      [link (org-follow! link)]
      [(and item (caddr item)) (org-toggle-checkbox! line)]
      [(org-level line) (org-todo-cycle! line)]
      [(org-table-line? line) (org-table-align! line)]
      [else (let ([target ((motion-proc (find-motion "<ret>")) (cursor) count)])
              (when target (set-cursor! target)))])))

(define (org-tab! count)
  (let ([line (current-line)])
    (cond
      [(org-table-line? line) (org-table-next-cell!)]
      [(org-level line) (org-cycle! line)]
      [else (let ([b (hash-try-get (keymap 'normal) "<tab>")])
              (when b ((if (symbol? b) (command-proc b) b) count)))])))

;;; The agenda

(define (org-notes-file)
  (expand-path (if (equal? (option 'org-default-notes-file) "")
                   (string-append (option 'org-directory) "/inbox.org")
                   (option 'org-default-notes-file))))

(define (org-agenda-file-list)
  (let ([files (option 'org-agenda-files)])
    (if (pair? files)
        (map expand-path files)
        (let ([dir (expand-path (option 'org-directory))])
          (if (file-exists? dir)
              (map (lambda (f) (string-append dir "/" f))
                   (filter (lambda (f) (ends-with? f ".org")) (list-files dir 10000)))
              '())))))

;; The date in "<2026-10-18 Sun>" after `key` on `text`, or #f.
(define (org-date-after text key)
  (let ([parts (split-once text key)])
    (and (pair? parts) (pair? (cdr parts))
         (let ([rest (trim-start (cadr parts))])
           (and (>= (string-length rest) 11) (member (substring rest 0 1) '("<" "["))
                (substring rest 1 11))))))

;; Agenda entries in `file`: (file line keyword title scheduled deadline).
(define (org-file-entries file)
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
                 (loop (cdr lines) (+ n 1) (finish acc) (list file n kw title #f #f)))]
              [current
               (let* ([s (org-date-after text "SCHEDULED:")] [d (org-date-after text "DEADLINE:")]
                      [current (list (car current) (cadr current) (caddr current) (cadddr current)
                                     (or s (list-ref current 4)) (or d (list-ref current 5)))])
                 (loop (cdr lines) (+ n 1) acc current))]
              [else (loop (cdr lines) (+ n 1) acc current)]))))))

(define (org-today) (trim (cadr (run-shell "date +%F" ""))))

(define (org-entry-done? e) (equal? (caddr e) (last (option 'org-todo-keywords))))

(define (org-agenda-line! e date what)
  (draw-line! (list (list "  " #f)
                   (list (if date (string-append date "  ") "") "org.date")
                   (list (if what (pad-right what 12) "") "org.special")
                   (list (if (caddr e) (string-append (caddr e) " ") "") (if (org-entry-done? e) "org.done" "org.todo"))
                   (list (cadddr e) #f)
                   (list (string-append "  " (file-name-of (car e))) "git.count"))
             (list 'org (car e) (cadr e))))

(define (org-render-agenda!)
  (let* ([today (org-today)]
         [entries (apply append (map org-file-entries (org-agenda-file-list)))]
         [open (filter (lambda (e) (not (org-entry-done? e))) entries)]
         [dated (apply append (map (lambda (e)
                                     (append (if (list-ref e 4) (list (list (list-ref e 4) "Scheduled:" e)) '())
                                             (if (list-ref e 5) (list (list (list-ref e 5) "Deadline:" e)) '())))
                                   open))]
         [dated (sort dated (lambda (a b) (string<? (car a) (car b))))]
         [todos (filter (lambda (e) (and (caddr e) (not (list-ref e 4)) (not (list-ref e 5)))) open)])
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
  (go-to-buffer! (special-buffer "*org agenda*" 'org-agenda-mode))
  (org-render-agenda!)
  (set-cursor! 0))

(define (org-agenda-visit!)
  (let ([item (line-item)])
    (when (and item (eq? (car item) 'org))
      (when (open-file! (cadr item))
        (set-cursor! (line-start (min (caddr item) (last-line))))))))

(define (org-capture!)
  (ask "Capture TODO: " ""
       (lambda (text)
         (let* ([file (org-notes-file)] [old (if (file-exists? file) (read-file file) "")])
           (write-text-file! file (string-append old (if (or (equal? old "") (ends-with? old "\n")) "" "\n")
                                                 "* TODO " text "\n"))
           (message (string-append "captured to " file))))))

;;; Modes and keys

(define-major-mode! 'org-mode 'text-mode '("org")
  (lambda ()
    (set-local-option! 'shiftwidth 2)
    (for-each (lambda (p) (buffer-highlight-pattern! (car p) (cadr p) (caddr p)))
              (list (list "org-1" "^\\* .*" "org.level1")
                    (list "org-2" "^\\*\\* .*" "org.level2")
                    (list "org-3" "^\\*\\*\\* .*" "org.level3")
                    (list "org-4" "^\\*\\*\\*\\*\\+ .*" "org.level4")
                    (list "org-todo" "^\\*\\+ TODO\\>" "org.todo")
                    (list "org-done" "^\\*\\+ DONE\\>" "org.done")
                    (list "org-tags" "\\s:[a-zA-Z0-9_@#%:]\\+:\\s*$" "org.tag")
                    (list "org-meta" "^\\s*#.*" "org.meta")
                    (list "org-table" "^\\s*|.*" "org.table")
                    (list "org-special" "SCHEDULED:\\|DEADLINE:\\|CLOSED:" "org.special")
                    (list "org-date" "[<[]\\d\\{4}-\\d\\d-\\d\\d[^]>]*[]>]" "org.date")
                    (list "org-box" "\\[[ X-]\\]" "org.checkbox")
                    (list "org-cookie" "\\[\\d\\+\\(/\\d\\+\\)\\?%\\?\\]" "org.checkbox")
                    (list "org-code" "=[^= ][^=]*=" "org.code")
                    (list "org-verbatim" "[~][^~ ][^~]*[~]" "org.code")
                    (list "org-link" "\\[\\[[^\\]]*\\]\\(\\[[^\\]]*\\]\\)\\?\\]" "org.link")))))

(define (org-key! states key proc)
  (for-each (lambda (state) (define-mode-key! 'org-mode state key proc)) states))

(org-key! '(normal) "<tab>" org-tab!)
(org-key! '(normal) "<s-tab>" (lambda (count) (org-global-cycle!)))
(org-key! '(normal) "<ret>" org-dwim!)
(org-key! '(normal) "gx" (lambda (count) (let ([l (org-link-at (cursor))]) (if l (org-follow! l) (message "no link here")))))
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

(define-mode-leader! 'org-mode "t" (lambda (n) (let ([h (org-heading-line (current-line))]) (if h (org-todo-cycle! h) (message "not under a heading")))) "cycle TODO")
(define-mode-leader! 'org-mode "x" (lambda (n) (org-toggle-checkbox! (current-line))) "toggle checkbox")
(define-mode-leader! 'org-mode "o" (lambda (n) (let ([l (org-link-at (cursor))]) (if l (org-follow! l) (message "no link here")))) "open link")
(define-mode-leader! 'org-mode "b" (lambda (n) (when (org-table-line? (current-line)) (org-table-align! (current-line)))) "align table")

(define-major-mode! 'org-agenda-mode 'special-mode '() #f)
(define-mode-key! 'org-agenda-mode 'normal "<ret>" (lambda (n) (org-agenda-visit!)))
(define-mode-key! 'org-agenda-mode 'normal "gr" (lambda (n) (org-render-agenda!)))

(define-command! 'org-agenda (lambda (count) (org-agenda!)))
(define-command! 'org-capture (lambda (count) (org-capture!)))
(define-leader-group! "o" "org")
(define-leader! "oa" 'org-agenda "agenda")
(define-leader! "oc" 'org-capture "capture")
(define-ex! '("OrgAgenda") (lambda (ex) (org-agenda!)))
(define-ex! '("OrgCapture") (lambda (ex) (org-capture!)))
