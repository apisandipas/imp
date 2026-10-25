;;; org-agenda.scm -- the Org agenda: what's scheduled, due and to do in
;;; the agenda files (org-agenda-files, or every .org file under
;;; org-directory), as Org's week view.
;;;
;;; SPC o a shows it, as a week (org-agenda-span days): f and b move a
;;; week on and back, . returns to this one, gr reads the files again,
;;; <ret> goes to an entry.
;;;
;;; It loads after org.scm and uses its readers: timestamps
;;; (org-parse-stamp), properties and categories, TODO keywords.

;; How many days the agenda shows.
(define-option! 'org-agenda-span 7 '())

(define (org-stamp-after text key)
  "The timestamp after `key` on `text`, parsed (org-parse-stamp), or #f."
  (let ([parts (split-once text key)])
    (and (pair? parts) (pair? (cdr parts))
         (let* ([rest (cadr parts)] [b (org-stamp-bounds rest 0)])
           (and b (org-parse-stamp (substring rest (car b) (cadr b))))))))

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

(define (org-line-appointments text)
  "The active timestamps on `text`, parsed, other than its SCHEDULED: and
   DEADLINE: ones, as (start end) where end is the range's last
   timestamp (<a>--<b>) or #f."
  (let ([n (string-length text)])
    (let loop ([from 0] [acc '()])
      (let ([b (org-stamp-bounds-anywhere text from)])
        (if (not b)
            (reverse acc)
            (let* ([before (trim-end (substring text 0 (car b)))]
                   [planned? (or (ends-with? before "SCHEDULED:") (ends-with? before "DEADLINE:"))]
                   [stamp (org-parse-stamp (substring text (car b) (cadr b)))]
                   [end-b (and (<= (+ (cadr b) 2) n) (equal? (substring text (cadr b) (+ (cadr b) 2)) "--")
                               (org-stamp-bounds text (+ (cadr b) 2)))]
                   [end (and end-b (org-parse-stamp (substring text (car end-b) (cadr end-b))))]
                   [next (if end-b (cadr end-b) (cadr b))])
              (loop next (if (and stamp (car stamp) (not planned?))
                             (cons (list stamp (and end (car end) end)) acc)
                             acc))))))))

;; An agenda entry is a list: (file line keyword title scheduled deadline
;; priority category tags appointments). The title is without its keyword
;; and tags; tags are (name . own?), own ones first; appointments are
;; (start end) as org-line-appointments gives them.
(define (org-entry-tags e)
  "Agenda entry `e`'s tags, as (name . own?) pairs, its own first."
  (list-ref e 8))

(define (org-entry-appointments e)
  "Agenda entry `e`'s appointments, as (start end) timestamps."
  (list-ref e 9))

(define (org-file-entries file)
  "Agenda entries in `file`, from its buffer when one visits it: one per
   heading, with its SCHEDULED: and DEADLINE: dates, appointments in the
   heading or its text, and tags, its own and those it inherits from the
   headings above it and #+FILETAGS:."
  (let* ([all (text-lines (org-file-text file))]
         [vec (list->vector all)]
         [base (file-name-of file)]
         [base (if (ends-with? base ".org") (substring base 0 (- (string-length base) 4)) base)]
         [file-category (or (org-file-setting vec "#+CATEGORY:") base)]
         [file-tags (org-file-tags vec)])
    ;; `above` is ((level . tags) ...) for the headings the current one is
    ;; under, nearest first.
    (let loop ([lines all] [n 0] [acc '()] [current #f] [above '()])
      (let ([finish (lambda (acc) (if current (cons current acc) acc))])
        (if (null? lines)
            (reverse (finish acc))
            (let* ([text (car lines)] [level (org-level-of text)])
              (cond
                [level
                 (let* ([rest (substring text (+ level 1) (string-length text))]
                        [kw (org-keyword-in rest)]
                        [title (if kw (trim-start (substring rest (string-length kw) (string-length rest))) rest)]
                        [own (org-tags-of title)]
                        [above (filter (lambda (a) (< (car a) level)) above)]
                        [inherited (append (apply append (map cdr above)) file-tags)]
                        [tags (org-dedupe-tags (append (map (lambda (t) (cons t #t)) own)
                                                       (map (lambda (t) (cons t #f)) inherited)))])
                   (loop (cdr lines) (+ n 1) (finish acc)
                         (list file n kw (org-without-tags title) #f #f (org-priority-in title)
                               (or (org-lines-property vec n "CATEGORY" #t) file-category)
                               tags (org-line-appointments title))
                         (cons (cons level own) above)))]
                [current
                 (let* ([s (org-stamp-after text "SCHEDULED:")] [d (org-stamp-after text "DEADLINE:")]
                        [current (list (car current) (cadr current) (caddr current) (cadddr current)
                                       (or (list-ref current 4) s) (or (list-ref current 5) d) (list-ref current 6)
                                       (list-ref current 7) (list-ref current 8)
                                       (append (list-ref current 9) (org-line-appointments text)))])
                   (loop (cdr lines) (+ n 1) acc current above))]
                [else (loop (cdr lines) (+ n 1) acc current above)])))))))

(define (org-dedupe-tags tags)
  "`tags`, (name . own?) pairs, with each name once: its first."
  (let loop ([ts tags] [seen '()] [acc '()])
    (cond [(null? ts) (reverse acc)]
          [(member (car (car ts)) seen) (loop (cdr ts) seen acc)]
          [else (loop (cdr ts) (cons (car (car ts)) seen) (cons (car ts) acc))])))

(define (org-entry-done? e)
  "Whether agenda entry `e` has a done keyword (see `org-done-keywords`)."
  (and (caddr e) (member (caddr e) (org-done-keywords)) #t))

(define (org-agenda-line! e date what)
  "Draws agenda entry `e`, with its `date` and `what` (Scheduled:...),
   and its category.
   Either may be #f. The line remembers the entry's file and line, so
   <ret> on it goes there."
  (draw-line! (list (list "  " #f)
                   (list (if date (string-append date "  ") "") "org.date")
                   (list (if what (pad-right what 12) "") "org.special")
                   (list (if (caddr e) (string-append (caddr e) " ") "") (if (org-entry-done? e) "org.done" "org.todo"))
                   (list (cadddr e) #f)
                   (list (string-append "  " (list-ref e 7)) "git.count"))
             (list 'org (car e) (cadr e))))

;; The first day the agenda shows, or #f for this week's.
(define *org-agenda-start* #f)

(define *org-day-names*
  (vector "Sunday" "Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday"))

(define (org-agenda-first-day)
  "The first day the agenda shows: the one f and b moved to, or the first
   day of this week (calendar-week-start)."
  (or *org-agenda-start*
      (let ([today (calendar-today)])
        (date-add-days today (- (modulo (- (date-weekday today) (option 'calendar-week-start)) 7))))))

(define (org-stamp-days stamp first last)
  "The days from `first` to `last` that timestamp `stamp` falls on: its
   date, and with a repeater each interval after it."
  (let ([date (cadr stamp)] [r (cadddr stamp)])
    (if (not r)
        (if (and (not (date<? date first)) (not (date<? last date))) (list date) '())
        (let loop ([k 0] [acc '()])
          (let ([d (org-shift-date date r k)])
            (cond [(date<? last d) (reverse acc)]
                  [(date<? d first) (loop (+ k 1) acc)]
                  [else (loop (+ k 1) (cons d acc))]))))))

(define (org-stamp-after-day stamp day)
  "The first day after `day` that timestamp `stamp` falls on, or #f: its
   date, or with a repeater the first repeat after `day`."
  (let ([date (cadr stamp)] [r (cadddr stamp)])
    (cond [(date<? day date) date]
          [(not r) #f]
          [else (let loop ([k 1])
                  (let ([d (org-shift-date date r k)]) (if (date<? day d) d (loop (+ k 1)))))])))

(define (org-sort-entries items rank)
  "`items` sorted by `rank` (a number, lowest first), keeping their order
   where ranks are equal."
  (map cdr (sort (map cons (range 0 (length items)) items)
                 (lambda (a b)
                   (let ([ra (rank (cdr a))] [rb (rank (cdr b))])
                     (or (< ra rb) (and (= ra rb) (< (car a) (car b)))))))))

(define (org-render-agenda!)
  "Redraws the agenda from the agenda files, as Org's week view: the
   undone entries dated before today, then org-agenda-span days with what
   is scheduled or due on each (repeats included), then those dated
   after the span, then the TODOs with no date. Done entries are left out; entries on the same day sort by
   priority."
  (let* ([today (calendar-today)]
         [first (org-agenda-first-day)]
         [span (max 1 (option 'org-agenda-span))]
         [last (date-add-days first (- span 1))]
         [entries (apply append (map org-file-entries (org-agenda-file-list)))]
         [open (filter (lambda (e) (not (org-entry-done? e))) entries)]
         [rank (lambda (e) (org-priority-rank (list-ref e 6)))]
         ;; (stamp what entry) for each date an entry has.
         [dated (apply append (map (lambda (e)
                                     (append (if (list-ref e 4) (list (list (list-ref e 4) "Scheduled:" e)) '())
                                             (if (list-ref e 5) (list (list (list-ref e 5) "Deadline:" e)) '())))
                                   open))]
         [overdue (org-sort-entries (filter (lambda (d) (date<? (cadr (car d)) today)) dated)
                                    (lambda (d) (+ (* 100 (date->days (cadr (car d)))) (rank (caddr d)))))]
         [dated (org-sort-entries dated (lambda (d) (rank (caddr d))))]
         ;; (day what entry) for each day in the span an entry falls on.
         [shown (apply append (map (lambda (d) (map (lambda (day) (list day (cadr d) (caddr d)))
                                                    (org-stamp-days (car d) first last)))
                                   dated))]
         ;; (day what entry) for each date an entry next has after the span.
         [later (org-sort-entries
                 (filter (lambda (d) (car d))
                         (map (lambda (d) (list (org-stamp-after-day (car d) last) (cadr d) (caddr d))) dated))
                 (lambda (d) (+ (* 100 (date->days (car d))) (rank (caddr d)))))]
         [todos (org-sort-entries (filter (lambda (e) (and (caddr e) (not (list-ref e 4)) (not (list-ref e 5)))) open)
                                  rank)])
    (draw-begin!)
    (draw-line! (list (list (string-append "Agenda: " (date->string first) " to " (date->string last)) "git.section")) #f)
    (when (pair? overdue)
      (draw-line! '() #f)
      (draw-line! (list (list "Overdue" "git.section")) #f)
      (for-each (lambda (d) (org-agenda-line! (caddr d) (date->string (cadr (car d))) (cadr d))) overdue))
    (draw-line! '() #f)
    (for-each (lambda (n)
                (let ([day (date-add-days first n)])
                  (draw-line! (list (list (string-append (pad-right (vector-ref *org-day-names* (date-weekday day)) 10)
                                                         (number->string (caddr day)) " "
                                                         (vector-ref *calendar-month-names* (- (cadr day) 1)) " "
                                                         (number->string (car day))
                                                         (if (equal? day today) "  today" ""))
                                          (if (equal? day today) "git.head" "org.date")))
                              #f)
                  (for-each (lambda (d) (when (equal? (car d) day) (org-agenda-line! (caddr d) #f (cadr d))))
                            shown)))
              (range 0 span))
    (when (pair? later)
      (draw-line! '() #f)
      (draw-line! (list (list "Later" "git.section")) #f)
      (for-each (lambda (d) (org-agenda-line! (caddr d) (date->string (car d)) (cadr d))) later))
    (draw-line! '() #f)
    (draw-line! (list (list "To do" "git.section")) #f)
    (for-each (lambda (e) (org-agenda-line! e #f #f)) todos)
    (when (null? entries)
      (draw-line! '() #f)
      (draw-line! (list (list (string-append "no entries in " (option 'org-directory)
                                            " (set org-directory or org-agenda-files)") "git.head"))
                 #f))
    (draw-finish!)))

(define (org-agenda-move! days)
  "Moves the agenda `days` on, or back to this week when `days` is #f."
  (set! *org-agenda-start* (and days (date-add-days (org-agenda-first-day) days)))
  (org-render-agenda!)
  (set-cursor! 0))

(define (org-agenda!)
  "Shows the agenda in its own buffer, freshly read from the files, from
   this week."
  (go-to-buffer! (special-buffer "*org agenda*" 'org-agenda-mode))
  (set! *org-agenda-start* #f)
  (org-render-agenda!)
  (set-cursor! 0))

(define (org-agenda-visit!)
  "Opens the file of the agenda entry at the cursor, on its heading."
  (let ([item (line-item)])
    (when (and item (eq? (car item) 'org))
      (when (open-file! (cadr item))
        (set-cursor! (line-start (min (caddr item) (last-line))))))))

(define-major-mode! 'org-agenda-mode 'special-mode '() #f)
(define-mode-key! 'org-agenda-mode 'normal "<ret>" (lambda (n) (org-agenda-visit!)))
(define-mode-key! 'org-agenda-mode 'normal "gr" (lambda (n) (org-render-agenda!)) "refresh")
(define-mode-key! 'org-agenda-mode 'normal "f" (lambda (n) (org-agenda-move! (* (max 1 n) (max 1 (option 'org-agenda-span))))) "later")
(define-mode-key! 'org-agenda-mode 'normal "b" (lambda (n) (org-agenda-move! (- (* (max 1 n) (max 1 (option 'org-agenda-span)))))) "earlier")
(define-mode-key! 'org-agenda-mode 'normal "." (lambda (n) (org-agenda-move! #f)) "this week")

(define-command! 'org-agenda
  (lambda (count)
    "Show the agenda: TODOs and SCHEDULED and DEADLINE dates."
    (org-agenda!)))
(define-leader! "oa" 'org-agenda "agenda")
(define-ex! '("OrgAgenda") (lambda (ex) (org-agenda!)))
