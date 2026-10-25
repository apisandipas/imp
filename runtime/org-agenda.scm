;;; org-agenda.scm -- the Org agenda: what's scheduled, due, timed and to
;;; do in the agenda files (org-agenda-files, or every .org file under
;;; org-directory), as Org's week view, in aligned columns.
;;;
;;; SPC o a a shows it, a week (org-agenda-span days) with Overdue above
;;; and Later and To do below. Today has a time grid and a now line, and
;;; the deadlines coming soon. In it (normal state):
;;;
;;;   gj gk  C-j C-k   next, previous entry
;;;   gH gM gL         the window's top, middle, bottom
;;;   f b  ]] [[       next, previous span
;;;   .                back to today
;;;   gd               go to a date, from the calendar
;;;   <ret>            go to the entry
;;;   <tab>            show the entry in another window
;;;   F                follow mode: show each entry the cursor is on
;;;   gr gR            read the files again (gR: every agenda buffer)
;;;   q ZZ             leave; ZQ also closes the files the agenda opened
;;;
;;; It loads after org.scm and uses its readers: timestamps
;;; (org-parse-stamp), properties and categories, TODO keywords.

;; How many days the agenda shows.
(define-option! 'org-agenda-span 7 '())
;; The day of the week a week's agenda starts on: 0 for Sunday to 6 for
;; Saturday, or #f for today. Unset, it is calendar-week-start's day.
(define-option! 'org-agenda-start-on-weekday 0 '())
;; The view the agenda shows: (name blocks). A block is (kind settings
;; arg): kind agenda (the dated view), todo, tags, tags-todo or search,
;; its settings as org-agenda-setting reads them.
(define *org-agenda-view* (list "Agenda" (list (list 'agenda '() #f))))
;; What the next view shown is limited to, as the dispatcher's < sets it:
;; (file) or (file first-line last-line), or #f; and the view's own.
(define *org-agenda-pending-restriction* #f)
(define *org-agenda-restriction* #f)
;; The span gD chose: day, week, fortnight, month or year, or #f for
;; org-agenda-span days; and whether it turned the grid on or off
;; ('default for org-agenda-use-time-grid).
(define *org-agenda-span* #f)
(define *org-agenda-grid* 'default)
;; The line today's header was drawn on, or #f, and each day's header's,
;; as (day . line).
(define *org-agenda-today-line* #f)
(define *org-agenda-day-lines* '())
;; The file buffers the agenda opened, which ZQ closes.
(define *org-agenda-opened* '())
;; The last change made from the agenda: (buffer saved?), for u.
(define *org-agenda-last-change* #f)
;; Whether follow mode is on, and the line it last showed.
(define *org-agenda-follow* #f)
(define *org-agenda-followed* #f)
;; The agenda's filters, as sc, st, se, sr and s^ add them: (kind arg
;; label), kind category, tag, effort, regexp or top. They stay until S
;; or another view.
(define *org-agenda-filters* '())
;; The marked entries, as org-agenda-mark-key gives them, for the bulk
;; actions; and the entries the agenda last drew.
(define *org-agenda-marks* '())
(define *org-agenda-shown* '())
;; Draw a time grid on today, and on other days with something timed:
;; a line at each of org-agenda-time-grid's times, and on today a line
;; for now.
(define-option! 'org-agenda-use-time-grid #t '())
;; The grid's times, as Org writes them: 800 is 08:00.
(define-option! 'org-agenda-time-grid '(800 1000 1200 1400 1600 1800 2000) '())
;; How many days ahead a deadline shows on today, as "In 3 d.". A
;; deadline's own warning, as -3d in its timestamp, wins.
(define-option! 'org-deadline-warning-days 14 '())

(define (org-stamp-after text key)
  "The timestamp after `key` on `text`, parsed (org-parse-stamp), or #f."
  (let ([parts (split-once text key)])
    (and (pair? parts) (pair? (cdr parts))
         (let* ([rest (cadr parts)] [b (org-stamp-bounds rest 0)])
           (and b (org-parse-stamp (substring rest (car b) (cadr b))))))))

(define (org-line-appointments text)
  "The active timestamps on `text`, parsed, other than its SCHEDULED: and
   DEADLINE: ones, as (start end) where end is the range's last
   timestamp (<a>--<b>) or #f; then its diary dates, as (stamp #f)."
  (let ([n (string-length text)])
    (let loop ([from 0] [acc '()])
      (let ([b (org-stamp-bounds-anywhere text from)])
        (if (not b)
            (append (reverse acc) (map (lambda (d) (list d #f)) (org-diary-stamps text)))
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
;; priority category tags appointments level lines). The title is without
;; its keyword and tags; tags are (name . own?), own ones first;
;; appointments are (start end) as org-line-appointments gives them;
;; level is the heading's, lines the file's, a vector, for properties.
(define (org-entry-tags e)
  "Agenda entry `e`'s tags, as (name . own?) pairs, its own first."
  (list-ref e 8))

(define (org-entry-appointments e)
  "Agenda entry `e`'s appointments, as (start end) timestamps."
  (list-ref e 9))

(define (org-entry-level e)
  "Agenda entry `e`'s heading level."
  (list-ref e 10))

(define (org-entry-prop e name)
  "Agenda entry `e`'s property `name` (any case), not inherited, or #f."
  (org-lines-property (list-ref e 11) (cadr e) name #f))

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
                               tags (org-line-appointments title) level vec)
                         (cons (cons level own) above)))]
                [current
                 (let* ([s (org-stamp-after text "SCHEDULED:")] [d (org-stamp-after text "DEADLINE:")]
                        [current (list (car current) (cadr current) (caddr current) (cadddr current)
                                       (or (list-ref current 4) s) (or (list-ref current 5) d) (list-ref current 6)
                                       (list-ref current 7) (list-ref current 8)
                                       (append (list-ref current 9) (org-line-appointments text))
                                       (list-ref current 10) (list-ref current 11))])
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

;; The first day the agenda shows, or #f for this week's.
(define *org-agenda-start* #f)

(define *org-day-names*
  (vector "Sunday" "Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday"))

(define (org-agenda-first-day)
  "The first day the agenda shows: the one f and b moved to, or else the
   first day of the span that shows today."
  (or *org-agenda-start* (org-agenda-span-start (calendar-today))))

(define (org-agenda-span-start day)
  "The first day of the span that shows `day`: with a span of 7 or 14
   days and org-agenda-start-on-weekday a day, the last such day on or
   before it, else `day` itself."
  (let ([start (if (option-set? 'org-agenda-start-on-weekday)
                   (option 'org-agenda-start-on-weekday)
                   (option 'calendar-week-start))])
    (if (and start (memv (org-agenda-span) '(7 14)))
        (date-add-days day (- (modulo (- (date-weekday day) start) 7)))
        day)))

(define (org-stamp-days stamp first last)
  "The days from `first` to `last` that timestamp `stamp` falls on: its
   date, and with a repeater each interval after it; a diary date's
   days."
  (let ([date (cadr stamp)] [r (cadddr stamp)])
    (cond
      [(org-diary-stamp? stamp) (org-diary-days stamp first last)]
      [(not r)
       (if (and (not (date<? date first)) (not (date<? last date))) (list date) '())]
      [else
       (let loop ([k 0] [acc '()])
         (let ([d (org-shift-date date r k)])
           (cond [(date<? last d) (reverse acc)]
                 [(date<? d first) (loop (+ k 1) acc)]
                 [else (loop (+ k 1) (cons d acc))])))])))

(define (org-stamp-after-day stamp day)
  "The first day after `day` that timestamp `stamp` falls on, or #f: its
   date, or with a repeater the first repeat after `day`; a diary
   date's next day."
  (let ([date (cadr stamp)] [r (cadddr stamp)])
    (cond [(org-diary-stamp? stamp) (org-diary-after stamp day)]
          [(date<? day date) date]
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

(define (org-pad-left text width)
  "`text` padded with spaces on the left to `width` characters."
  (if (< (string-length text) width) (string-append (make-string (- width (string-length text)) #\space) text) text))

(define (org-fit text width)
  "`text` cut to `width` characters, ending in … when it was longer, and
   padded with spaces to `width`."
  (cond [(<= width 0) ""]
        [(> (string-length text) width) (string-append (substring text 0 (- width 1)) "…")]
        [else (pad-right text width)]))

(define (org-agenda-title-text e)
  "Agenda entry `e`'s title as the agenda shows it: without its active
   timestamps, which the agenda shows in their own column."
  (let loop ([t (org-diary-strip (cadddr e))])
    (let ([b (org-stamp-bounds-anywhere t 0)])
      (if (and b (equal? (substring t (car b) (+ (car b) 1)) "<"))
          (let* ([end (cadr b)]
                 [end (let ([r (and (<= (+ end 2) (string-length t)) (equal? (substring t end (+ end 2)) "--")
                                    (org-stamp-bounds t (+ end 2)))])
                        (if r (cadr r) end))])
            (loop (string-append (trim-end (substring t 0 (car b))) (substring t end (string-length t)))))
          (string-join (split-whitespace t) " ")))))

(define (org-agenda-tags-text e)
  "Agenda entry `e`'s tags as Org writes them, \":work:home:\", or \"\"."
  (let ([tags (map car (org-entry-tags e))])
    (if (null? tags) "" (string-append ":" (string-join tags ":") ":"))))

(define (org-short-date d)
  "Date `d` as \"Thu 5 Nov\", with its year when that isn't this year's."
  (string-append (vector-ref *calendar-day-names* (date-weekday d)) " "
                 (number->string (caddr d)) " "
                 (substring (vector-ref *calendar-month-names* (- (cadr d) 1)) 0 3)
                 (if (= (car d) (car (calendar-today))) "" (string-append " " (number->string (car d))))))

(define (org-iso-week d)
  "The ISO week number of date `d`: weeks start on Monday, and week 1 is
   the one with the year's first Thursday."
  (let* ([iso-day (+ (modulo (+ (date-weekday d) 6) 7) 1)]
         [thursday (date-add-days d (- 4 iso-day))])
    (+ 1 (quotient (- (date->days thursday) (date->days (list (car thursday) 1 1))) 7))))

(define (org-span-thursday first)
  "The Thursday of the 7 days from `first`: its ISO week is the week most
   of those days are in."
  (date-add-days first (modulo (- 4 (date-weekday first)) 7)))

(define (org-span-text first last)
  "The days `first` to `last` written short: \"19–25 Oct 2026\", or
   \"28 Oct – 3 Nov 2026\" across months, with both years across years."
  (let ([month (lambda (d) (substring (vector-ref *calendar-month-names* (- (cadr d) 1)) 0 3))]
        [day (lambda (d) (number->string (caddr d)))]
        [year (lambda (d) (number->string (car d)))])
    (cond [(equal? first last) (string-append (day first) " " (month first) " " (year first))]
          [(and (= (car first) (car last)) (= (cadr first) (cadr last)))
           (string-append (day first) "–" (day last) " " (month last) " " (year last))]
          [(= (car first) (car last))
           (string-append (day first) " " (month first) " – " (day last) " " (month last) " " (year last))]
          [else (string-append (day first) " " (month first) " " (year first) " – "
                               (day last) " " (month last) " " (year last))])))

(define (org-day-header day today)
  "The header row for `day`: its date, as \"Thursday 23 October\", and
   whether it is today or a weekend."
  (let ([text (string-append (vector-ref *org-day-names* (date-weekday day)) " "
                             (number->string (caddr day)) " "
                             (vector-ref *calendar-month-names* (- (cadr day) 1)))])
    (cond [(equal? day today) (list 'header (string-append text " · today") 'today day)]
          [(memv (date-weekday day) '(0 6)) (list 'header text 'weekend day)]
          [else (list 'header text 'date day)])))

;; What an agenda line says its date is, and the face it says it in.
(define (org-what-face what)
  "The face for the what column's `what`, a symbol such as 'scheduled."
  (case what
    [(scheduled) "org.agenda.scheduled"]
    [(deadline) "org.agenda.deadline"]
    [(overdue) "org.agenda.overdue"]
    [(upcoming) "org.agenda.upcoming"]
    [else "org.agenda.time"]))

;; The agenda is drawn in two steps: the sections make a list of rows,
;; then org-agenda-draw! lays them out, sizing each column of the entry
;; rows to what they hold and the window's width. A row is:
;;   (title NAME COVERS FILTER)  the view's name, what it covers under
;;                               it (FILTER at its right), then a rule
;;   (header TEXT KIND [DAY])    a section or day, with a rule under it;
;;                               KIND is section, date, weekend or today
;;   (entry E TIME WHAT KIND O [GRAPH])
;;                               entry E, TIME and WHAT strings (or ""),
;;                               KIND the what's kind (org-what-face), O
;;                               the occurrence shown (or #f), GRAPH a
;;                               habit's graph (org-habit-graph). The
;;                               line's item is (org file line kind date).
;;   (grid TIME), (now TIME)     a line of the time grid, and the now line
;;   (blank)
;;   (note TEXT)                 a line of its own, dim

(define (org-agenda-draw! rows width)
  "Draws `rows` (see above) into the current buffer, `width` columns wide."
  (let* ([entries (filter (lambda (r) (eq? (car r) 'entry)) rows)]
         [widest (lambda (f cap) (min cap (foldl (lambda (r m) (max m (string-length (f r)))) 0 entries)))]
         [col (lambda (w) (if (> w 0) (+ w 2) 0))]
         [time-w (widest caddr 17)]
         [what-w (widest cadddr 10)]
         [kw-w (widest (lambda (r) (or (caddr (cadr r)) "")) 12)]
         [tags? (>= width 60)]
         [tags-w (if tags? (widest (lambda (r) (org-agenda-tags-text (cadr r))) 30) 0)]
         [cat-w (widest (lambda (r) (list-ref (cadr r) 7)) 14)]
         ;; Indent, mark column, then the columns; what's left is the title's.
         [title-w (max 10 (- width 4 (col time-w) (col what-w) (col kw-w)
                             (if (> tags-w 0) (+ tags-w 2) 0) (+ cat-w 2) 1))]
         [rule (lambda (n) (make-string (max 0 n) #\─))]
         [heights (lambda (level) (string-append "org.height" (number->string level)))])
    (draw-begin!)
    (set! *org-agenda-today-line* #f)
    (set! *org-agenda-day-lines* '())
    (set! *org-agenda-shown* (map cadr entries))
    (for-each
     (lambda (r)
       (when (and (eq? (car r) 'header) (eq? (caddr r) 'today))
         (set! *org-agenda-today-line* (length *draw-lines*)))
       (when (and (eq? (car r) 'header) (pair? (cdddr r)))
         (set! *org-agenda-day-lines* (cons (cons (cadddr r) (length *draw-lines*)) *org-agenda-day-lines*)))
       (case (car r)
         [(title)
          (draw-line! (list (list " " #f) (list (cadr r) (list "org.agenda.title" (heights 1)))) #f)
          (let* ([covers (caddr r)] [filter-text (if (pair? (cdddr r)) (cadddr r) "")]
                 [gap (max 2 (- width 2 (string-length covers) (string-length filter-text)))])
            (draw-line! (append (list (list " " #f) (list covers "org.agenda.span"))
                                (if (equal? filter-text "")
                                    '()
                                    (list (list (make-string gap #\space) #f) (list filter-text "org.agenda.tag"))))
                        #f))
          (draw-line! (list (list (rule (- width 1)) "org.agenda.rule")) #f)]
         [(header)
          (let* ([text (cadr r)] [kind (caddr r)]
                 [face (case kind [(today) "org.agenda.today"] [(weekend) "org.agenda.weekend"]
                                  [(date) "org.agenda.date"] [(block) "org.agenda.title"]
                                  [else "org.agenda.section"])])
            (draw-line! (list (if (eq? kind 'today) (list "▌" "org.agenda.today") (list " " #f)) (list " " #f)
                              (list text (list face (heights 2))))
                        #f)
            ;; At the header's size, so the rule is as long as the header.
            (draw-line! (list (list "  " #f) (list (rule (string-length text)) (list "org.agenda.rule" (heights 2)))) #f))]
         [(entry)
          (let* ([e (cadr r)] [time (caddr r)] [what (cadddr r)] [kind (list-ref r 4)]
                 [kw (caddr e)]
                 [title (org-agenda-title-text e)]
                 [prio (and (>= (string-length title) 5) (starts-with? title "[#")
                            (equal? (substring title 3 5) "] ") (substring title 0 4))]
                 ;; A habit's graph goes after its title, when there's room.
                 [graph (and (> (length r) 6) (list-ref r 6))]
                 [graph (and graph (>= title-w (+ (length graph) 11)) graph)]
                 [fitted (org-fit title (if graph (- title-w (length graph) 1) title-w))]
                 [marked? (org-agenda-marked? e)]
                 [title-face (if marked? "org.agenda.marked" #f)]
                 [cell (lambda (text w face) (if (> w 0) (list (list (org-fit text w) face) (list "  " #f)) '()))])
            (draw-line!
             (append (list (list "  " #f) (if marked? (list "▸ " "org.agenda.marked") (list "  " #f)))
                     (cell time time-w "org.agenda.time")
                     (cell what what-w (org-what-face kind))
                     (cell (or kw "") kw-w (if (org-entry-done? e) "org.done" "org.todo"))
                     (if (and prio (> title-w 5))
                         (list (list prio "org.priority")
                               (list (substring fitted 4 (string-length fitted)) title-face))
                         (list (list fitted title-face)))
                     (if graph (cons (list " " #f) (org-habit-parts graph)) '())
                     (if (> tags-w 0)
                         (list (list "  " #f) (list (org-pad-left (org-agenda-tags-text e) tags-w) "org.agenda.tag"))
                         '())
                     (list (list "  " #f) (list (pad-right (list-ref e 7) cat-w) "org.agenda.category")))
             (let ([o (list-ref r 5)]) (list 'org (car e) (cadr e) (and o (cadr o)) (and o (cadr (car o)))))))]
         [(grid)
          (let ([time (pad-right (cadr r) (max 5 time-w))])
            (draw-line! (list (list "    " #f) (list time "org.agenda.time")
                              (list (string-append "  " (make-string (max 0 (- width 7 (string-length time))) #\┄))
                                    "org.agenda.grid"))
                        #f))]
         [(now)
          (let* ([time (pad-right (cadr r) (max 5 time-w))]
                 [n (max 0 (- width 7 (string-length time)))] [before (quotient (max 0 (- n 5)) 3)])
            (draw-line! (list (list "    " #f) (list time "org.agenda.now")
                              (list (string-append "  " (make-string before #\━) " now "
                                                   (make-string (max 0 (- n before 5)) #\━))
                                    "org.agenda.now"))
                        #f))]
         [(note) (draw-line! (list (list "  " #f) (list (cadr r) "org.agenda.span")) #f)]
         [else (draw-line! '() #f)]))
     rows)
    (draw-finish!)))

(define (org-time-minutes time)
  "The minutes after midnight time `time` starts at, as 600 for \"10:00\"
   or \"10:00-11:00\" (\"9:30\" too), or #f."
  (let ([colon (and time (string-index-from time ":" 0))])
    (and colon (<= (+ colon 3) (string-length time))
         (let ([h (string->number (substring time 0 colon))]
               [m (string->number (substring time (+ colon 1) (+ colon 3)))])
           (and h m (+ (* 60 h) m))))))

(define (org-agenda-now)
  "The time now, as \"11:42\"."
  (trim (cadr (run-shell "date +%H:%M" ""))))

(define (org-hhmm minutes)
  "`minutes` after midnight as \"08:00\"."
  (string-append (two-digits (quotient minutes 60)) ":" (two-digits (modulo minutes 60))))

(define (org-with-grid rows today?)
  "A day's entry `rows` with the time grid among the timed ones, when
   org-agenda-use-time-grid is on and it is today or something is timed:
   a (grid TIME) row at each grid time no entry has, and on today a (now
   TIME) row, all in time order before the untimed entries."
  (let* ([minutes (lambda (r) (org-time-minutes (caddr r)))]
         [timed (filter minutes rows)]
         [untimed (filter (lambda (r) (not (minutes r))) rows)])
    (if (or (not (org-agenda-grid?)) (and (not today?) (null? timed)))
        rows
        (let* ([taken (map minutes timed)]
               [grid (filter (lambda (m) (not (memv m taken)))
                             (map (lambda (t) (+ (* 60 (quotient t 100)) (modulo t 100)))
                                  (option 'org-agenda-time-grid)))]
               [now (and today? (org-time-minutes (org-agenda-now)))]
               ;; (minutes order row): at the same minute, entries come
               ;; first, then the now line.
               [all (append (map (lambda (r) (list (minutes r) 0 r)) timed)
                            (map (lambda (m) (list m 1 (list 'grid (org-hhmm m)))) grid)
                            (if now (list (list now 2 (list 'now (org-hhmm now)))) '()))])
          (append (map caddr (sort all (lambda (a b) (or (< (car a) (car b))
                                                          (and (= (car a) (car b)) (< (cadr a) (cadr b)))))))
                  untimed)))))

(define (org-warning-days stamp)
  "How many days ahead deadline `stamp` warns: its own warning, as -3d
   or -1w, else org-deadline-warning-days."
  (let ([w (list-ref stamp 4)])
    (if w
        (* (cadr w) (case (string->symbol (caddr w)) [(w) 7] [(m) 30] [(y) 365] [else 1]))
        (option 'org-deadline-warning-days))))

(define (org-entry-occurrences e)
  "Agenda entry `e`'s dates, as (stamp kind end): kind is scheduled,
   deadline or appointment, end a date range's last timestamp or #f."
  (append (if (list-ref e 4) (list (list (list-ref e 4) 'scheduled #f)) '())
          (if (list-ref e 5) (list (list (list-ref e 5) 'deadline #f)) '())
          (map (lambda (a) (list (car a) 'appointment
                                 (and (cadr a) (date<? (cadr (car a)) (cadr (cadr a))) (cadr a))))
               (filter (lambda (a) (not (org-diary-unknown? (car a)))) (org-entry-appointments e)))))

(define (org-occurrence-days o first last)
  "The days from `first` to `last` occurrence `o` falls on, as (day
   label): a range's with its place in it, \"(2/3)\", else its date and
   repeats with #f."
  (let ([stamp (car o)] [end (caddr o)])
    (if end
        (let* ([start (cadr stamp)] [n (+ 1 (- (date->days (cadr end)) (date->days start)))])
          (filter (lambda (d) d)
                  (map (lambda (k)
                         (let ([day (date-add-days start k)])
                           (and (not (date<? day first)) (not (date<? last day))
                                (list day (string-append "(" (number->string (+ k 1)) "/" (number->string n) ")")))))
                       (range 0 n))))
        (map (lambda (d) (list d #f)) (org-stamp-days stamp first last)))))

(define (org-occurrence-label kind)
  "What an occurrence of `kind` says it is on its day."
  (case kind [(scheduled) "Sched."] [(deadline) "Deadline"] [else ""]))

;;; Habits and diary dates
;;
;; A diary date is an active timestamp holding a diary sexp, such as
;; <%%(diary-float 11 4 4)>, read without running Lisp. Its stamp is
;; (#t #f TIME (diary FORM) #f): no date of its own, and in the
;; repeater's place the form saying which days it falls on, one of
;;   (anniversary DATE)       every year on DATE's day, after its year
;;   (float MONTH DAY N)      the Nth weekday DAY (0 Sunday) of MONTH,
;;                            #t for every month; N < 0 from the end
;;   (block FIRST LAST)       each day from FIRST to LAST
;;   (cyclic N DATE)          every N days from DATE
;;   (date (YEAR MONTH DAY))  the days matching, #t for any part
;;   (unknown TEXT)           a sexp the agenda doesn't read, skipped

;; The order a diary sexp's dates are in: 'american (month day year, as
;; Emacs), 'european (day month year) or 'iso (year month day).
(define-option! 'calendar-date-style 'american '())

(define (org-diary-stamp? stamp)
  "Whether timestamp `stamp` is a diary date."
  (let ([r (cadddr stamp)]) (and (pair? r) (eq? (car r) 'diary))))

(define (org-diary-form stamp)
  "Diary date `stamp`'s form (see above)."
  (cadr (cadddr stamp)))

(define (org-diary-unknown? stamp)
  "Whether `stamp` is a diary date whose sexp the agenda doesn't read."
  (and (org-diary-stamp? stamp) (eq? (car (org-diary-form stamp)) 'unknown)))

(define (org-diary-ymd args)
  "The (year month day) three of a diary sexp's arguments give, in
   calendar-date-style's order."
  (let ([a (car args)] [b (cadr args)] [c (caddr args)])
    (case (option 'calendar-date-style)
      [(european) (list c b a)]
      [(iso) (list a b c)]
      [else (list c a b)])))

(define (org-diary-args words)
  "A diary sexp's argument `words` read: whole numbers, and #t for t;
   #f if any is something else."
  (let loop ([ws words] [acc '()])
    (cond [(null? ws) (reverse acc)]
          [(equal? (car ws) "t") (loop (cdr ws) (cons #t acc))]
          [(let ([n (string->number (car ws))]) (and n (integer? n) n))
           => (lambda (n) (loop (cdr ws) (cons n acc)))]
          [else #f])))

(define (org-diary-parse inside)
  "The form (see above) of the diary sexp `inside` its parentheses, as
   \"diary-float 11 4 4\"; (unknown INSIDE) when it isn't one of the
   five the agenda reads, or its arguments don't fit."
  (let* ([words (split-whitespace inside)]
         [name (if (pair? words) (car words) "")]
         [args (and (pair? words) (org-diary-args (cdr words)))]
         [n (if args (length args) 0)]
         [numbers? (lambda (xs) (foldl (lambda (x ok) (and ok (number? x))) #t xs))])
    (or (and args
             (cond
               [(and (equal? name "diary-anniversary") (= n 3) (numbers? args))
                (list 'anniversary (org-diary-ymd args))]
               [(and (equal? name "diary-float") (= n 3)
                     (or (eq? (car args) #t) (and (number? (car args)) (<= 1 (car args) 12)))
                     (number? (cadr args)) (<= 0 (cadr args) 6)
                     (number? (caddr args)) (not (= (caddr args) 0)))
                (list 'float (car args) (cadr args) (caddr args))]
               [(and (equal? name "diary-block") (= n 6) (numbers? args))
                (list 'block (org-diary-ymd args) (org-diary-ymd (list-tail args 3)))]
               [(and (equal? name "diary-cyclic") (= n 4) (numbers? args) (> (car args) 0))
                (list 'cyclic (car args) (org-diary-ymd (cdr args)))]
               [(and (equal? name "diary-date") (= n 3))
                (list 'date (org-diary-ymd args))]
               [else #f]))
        (list 'unknown inside))))

(define (org-diary-bounds text from)
  "The (start open close end) of the next diary timestamp in `text` at
   or after `from`: where its <%%( starts, its sexp's parentheses, and
   just past its >. #f if there is none."
  (let ([start (string-index-from text "<%%(" from)] [n (string-length text)])
    (and start
         (let loop ([i (+ start 4)] [depth 1])
           (cond [(>= i n) #f]
                 [(equal? (string-ref text i) #\() (loop (+ i 1) (+ depth 1))]
                 [(and (equal? (string-ref text i) #\)) (= depth 1))
                  (let ([gt (string-index-from text ">" i)])
                    (and gt (list start (+ start 3) i (+ gt 1))))]
                 [(equal? (string-ref text i) #\)) (loop (+ i 1) (- depth 1))]
                 [else (loop (+ i 1) depth)])))))

(define (org-diary-stamps text)
  "The diary timestamps in `text`, as stamps (see above), with the time
   after the sexp if there is one, <%%(diary-float t 4 1) 19:00>."
  (let loop ([from 0] [acc '()])
    (let ([b (org-diary-bounds text from)])
      (if (not b)
          (reverse acc)
          (let* ([inside (substring text (+ (cadr b) 1) (caddr b))]
                 [after (trim (substring text (+ (caddr b) 1) (- (cadddr b) 1)))]
                 [time (and (org-time-minutes after) after)])
            (loop (cadddr b)
                  (cons (list #t #f time (list 'diary (org-diary-parse inside)) #f) acc)))))))

(define (org-diary-strip text)
  "`text` without its diary timestamps."
  (let ([b (org-diary-bounds text 0)])
    (if b
        (org-diary-strip (string-append (trim-end (substring text 0 (car b)))
                                        (substring text (cadddr b) (string-length text))))
        text)))

(define (org-diary-on? form day)
  "Whether diary `form` (see above) falls on `day`."
  (let ([y (car day)] [m (cadr day)] [d (caddr day)])
    (case (car form)
      [(anniversary)
       (let* ([date (cadr form)]
              ;; 29 February is 1 March in other years, as Emacs.
              [moved? (and (= (cadr date) 2) (= (caddr date) 29) (not (= (days-in-month y 2) 29)))])
         (and (> y (car date))
              (= m (if moved? 3 (cadr date)))
              (= d (if moved? 1 (caddr date)))))]
      [(float)
       (let ([month (cadr form)] [weekday (caddr form)] [k (cadddr form)])
         (and (or (eq? month #t) (= month m))
              (= (date-weekday day) weekday)
              (if (> k 0)
                  (= (quotient (- d 1) 7) (- k 1))
                  (= (quotient (- (days-in-month y m) d) 7) (- (- k) 1)))))]
      [(block) (and (not (date<? day (cadr form))) (not (date<? (caddr form) day)))]
      [(cyclic)
       (let ([k (- (date->days day) (date->days (caddr form)))])
         (and (>= k 0) (= (modulo k (cadr form)) 0)))]
      [(date)
       (let ([want (cadr form)])
         (and (or (eq? (car want) #t) (= (car want) y))
              (or (eq? (cadr want) #t) (= (cadr want) m))
              (or (eq? (caddr want) #t) (= (caddr want) d))))]
      [else #f])))

(define (org-diary-days stamp first last)
  "The days from `first` to `last` diary date `stamp` falls on."
  (let ([form (org-diary-form stamp)])
    (filter (lambda (day) (org-diary-on? form day))
            (map (lambda (k) (date-add-days first k))
                 (range 0 (+ 1 (- (date->days last) (date->days first))))))))

(define (org-diary-after stamp day)
  "The first day after `day` diary date `stamp` falls on, looking four
   years ahead, or #f."
  (let ([form (org-diary-form stamp)])
    (if (eq? (car form) 'block)
        (cond [(date<? day (cadr form)) (cadr form)]
              [(date<? day (caddr form)) (date-add-days day 1)]
              [else #f])
        (let loop ([k 1])
          (cond [(> k 1462) #f]
                [(org-diary-on? form (date-add-days day k)) (date-add-days day k)]
                [else (loop (+ k 1))])))))

(define (org-ordinal-suffix n)
  "The suffix of `n`'s ordinal: \"st\" for 1 and 21, \"th\" for 11."
  (cond [(memv (modulo n 100) '(11 12 13)) "th"]
        [(= (modulo n 10) 1) "st"]
        [(= (modulo n 10) 2) "nd"]
        [(= (modulo n 10) 3) "rd"]
        [else "th"]))

(define (org-replace-all text needle new)
  "`text` with each `needle` in it made `new`."
  (let ([i (string-index-from text needle 0)])
    (if i
        (string-append (substring text 0 i) new
                       (org-replace-all (substring text (+ i (string-length needle)) (string-length text)) needle new))
        text)))

(define (org-diary-entry e o day)
  "Agenda entry `e` as shown on `day` for occurrence `o`: an
   anniversary's title with %d made the count of years and %s its
   ordinal's suffix, as Emacs's diary does; else `e`."
  (let ([stamp (car o)])
    (if (and day (org-diary-stamp? stamp) (eq? (car (org-diary-form stamp)) 'anniversary))
        (let* ([years (- (car day) (car (cadr (org-diary-form stamp))))]
               [title (org-replace-all (org-replace-all (cadddr e) "%d" (number->string years))
                                     "%s" (org-ordinal-suffix years))])
          (append (take e 3) (list title) (list-tail e 4)))
        e)))

(define (org-diary-skipped entries)
  "How many diary timestamps in `entries` the agenda doesn't read."
  (length (filter (lambda (a) (org-diary-unknown? (car a)))
                  (apply append (map org-entry-appointments entries)))))

;; A habit is an entry whose STYLE property is habit, with a repeating
;; SCHEDULED: date. It shows on today only, with a graph of the days
;; around it, as Org's org-habit draws it.
(define-option! 'org-habit-preceding-days 21 '())
(define-option! 'org-habit-following-days 7 '())

(define (org-habit? e)
  "Whether agenda entry `e` is a habit."
  (let ([s (list-ref e 4)])
    (and s (cadddr s) (not (org-diary-stamp? s))
         (equal? (org-entry-prop e "STYLE") "habit"))))

(define (org-interval-days n unit)
  "How many days `n` of `unit` (\"d\" \"w\" \"m\" \"y\") are, as Org's
   habits count them: a month 30 days, a year 365."
  (* n (case (string->symbol unit) [(w) 7] [(m) 30] [(y) 365] [else 1])))

(define (org-habit-done-days e)
  "The days, as day numbers (date->days), habit `e` was done, oldest
   first: from the state changes to a done keyword logged in its text,
   and its LAST_REPEAT property."
  (let* ([lines (list-ref e 11)] [n (vector-length lines)]
         [stamp-day (lambda (text)
                      (let ([b (org-stamp-bounds-anywhere text 0)])
                        (and b (let ([s (org-parse-stamp (substring text (car b) (cadr b)))])
                                 (and s (date->days (cadr s)))))))]
         [logged
          (let loop ([i (+ (cadr e) 1)] [acc '()])
            (if (or (>= i n) (org-level-of (vector-ref lines i)))
                acc
                (let* ([t (trim (vector-ref lines i))]
                       [kw (and (starts-with? t "- State \"")
                                (let ([close (string-index-from t "\"" 9)]) (and close (substring t 9 close))))]
                       [day (and kw (member kw (org-done-keywords)) (stamp-day t))])
                  (loop (+ i 1) (if day (cons day acc) acc)))))]
         [last (let ([p (org-entry-prop e "LAST_REPEAT")]) (and p (stamp-day p)))]
         [all (sort (if last (cons last logged) logged) <)])
    (let loop ([ds all] [acc '()])
      (cond [(null? ds) (reverse acc)]
            [(and (pair? acc) (= (car acc) (car ds))) (loop (cdr ds) acc)]
            [else (loop (cdr ds) (cons (car ds) acc))]))))

(define (org-habit-faces day scheduled deadline donep)
  "The (past . future) faces of habit graph cell `day`, with the habit
   due from `scheduled` to `deadline` (day numbers), as Org's
   org-habit-get-faces: clear before it is due, ready while it may be
   done, alert on its last day, overdue after."
  (cond [(< day scheduled) (cons "clear" "clear-future")]
        [(< day deadline) (cons "ready" "ready-future")]
        [(= day deadline) (if donep (cons "ready" "ready-future") (cons "alert" "alert-future"))]
        [else (cons "overdue" "overdue-future")]))

(define (org-habit-graph e today)
  "Habit `e`'s graph on `today`: a (glyph face) cell for each of the
   org-habit-preceding-days before today, today, and the days after up
   to org-habit-following-days, as Org's org-habit-build-graph. A * is
   a day it was done, ! today."
  (let* ([stamp (list-ref e 4)] [r (cadddr stamp)] [type (car r)]
         [s-repeat (org-interval-days (cadr r) (caddr r))]
         [d-repeat (if (= (length r) 4) (org-interval-days (car (cadddr r)) (cadr (cadddr r))) s-repeat)]
         [scheduled (date->days (cadr stamp))]
         [deadline (+ scheduled (- d-repeat s-repeat))]
         [all (org-habit-done-days e)]
         [now (date->days today)]
         [start (- now (option 'org-habit-preceding-days))]
         [end (+ now (option 'org-habit-following-days))]
         ;; Where the habit was scheduled when `day` was today, `done`
         ;; the done days not yet passed and `last` the last one passed.
         [scheduled-then
          (lambda (done last)
            (cond [(null? done) scheduled]
                  [(equal? type ".+") (+ last s-repeat)]
                  [(equal? type "+") (- scheduled (* (length done) s-repeat))]
                  [else
                   ;; ++: from the first done day, each later one moves
                   ;; it on by as many whole repeats as get it past.
                   (let* ([first (car all)] [shift (modulo (- scheduled first) s-repeat)]
                          [s (+ first (if (= shift 0) s-repeat shift))])
                     (if (= first last)
                         s
                         (let loop ([ds (cdr all)] [s s])
                           (if (null? ds)
                               s
                               (let ([s (+ s (* (+ 1 (quotient (max (- (car ds) s) 0) s-repeat)) s-repeat))])
                                 (if (= (car ds) last) s (loop (cdr ds) s)))))))]))])
    (let skip ([done all] [last #f])
      (if (and (pair? done) (< (car done) start))
          (skip (cdr done) (car done))
          (let loop ([day start] [done done] [last last] [acc '()])
            (if (>= day end)
                (reverse acc)
                (let* ([past? (< day now)] [today? (= day now)]
                       [done? (and (pair? done) (= day (car done)))]
                       [faces (if (and past? (not last) (not (< scheduled now)))
                                  (if (and (pair? all) (= (car all) day))
                                      (cons "ready" "ready-future")
                                      (cons "clear" "clear-future"))
                                  (let ([s (if (and past? last) (scheduled-then done last) scheduled)])
                                    (org-habit-faces day s (+ s (- deadline scheduled)) done?)))]
                       [face (if (or past? today?) (car faces) (cdr faces))]
                       ;; A past day it wasn't done on, not overdue, is drawn lighter.
                       [face (if (and past? (not (equal? face "overdue")) (not done?)) (cdr faces) face)])
                  (loop (+ day 1)
                        (if done? (filter (lambda (d) (> d day)) done) done)
                        (if done? day last)
                        (cons (list (cond [done? "*"] [today? "!"] [else " "])
                                    (string-append "org.agenda.habit." face))
                              acc)))))))))

(define (org-habit-parts cells)
  "Graph `cells` as draw-line! parts, a run of one face as one part."
  (let loop ([cs cells] [acc '()])
    (cond [(null? cs) (reverse acc)]
          [(and (pair? acc) (equal? (cadr (car acc)) (cadr (car cs))))
           (loop (cdr cs) (cons (list (string-append (car (car acc)) (car (car cs))) (cadr (car cs))) (cdr acc)))]
          [else (loop (cdr cs) (cons (car cs) acc))])))

(define (org-habit-rows x day today)
  "The rows habit occurrence `x`, (occurrence entry), has on `day`: on
   today only, once it is due, with its graph; Sched. 3x when it was
   due 3 days ago."
  (let* ([o (car x)] [e (cadr x)] [date (cadr (car o))])
    (if (and (equal? day today) (not (date<? today date)))
        (let ([n (- (date->days today) (date->days date))])
          (list (list 'entry e (or (caddr (car o)) "")
                      (if (> n 0) (string-append "Sched. " (number->string n) "x") "Sched.")
                      'scheduled o (org-habit-graph e today))))
        '())))

(define (org-agenda-setting settings name default)
  "Block setting `name` from `settings`, ((span . 1) (header . \"Work\")),
   else `default`."
  (let ([hit (assq name settings)]) (if hit (cdr hit) default)))

(define (org-agenda-span)
  "How many days a dated block shows: the span gD chose (a month's or a
   year's from the first day shown), else the view's first dated
   block's span setting, else org-agenda-span."
  (let ([first (or *org-agenda-start* (calendar-today))])
    (case *org-agenda-span*
      [(day) 1] [(week) 7] [(fortnight) 14]
      [(month) (days-in-month (car first) (cadr first))]
      [(year) (if (= (days-in-month (car first) 2) 29) 366 365)]
      [else (let ([dated (filter (lambda (b) (eq? (car b) 'agenda)) (cadr *org-agenda-view*))])
              ;; A custom command's first dated block may give its span.
              (max 1 (if (pair? dated)
                         (org-agenda-setting (cadr (car dated)) 'span (option 'org-agenda-span))
                         (option 'org-agenda-span))))])))

(define (org-agenda-grid?)
  "Whether dated blocks draw the time grid: as gD set it, else
   org-agenda-use-time-grid."
  (if (eq? *org-agenda-grid* 'default) (option 'org-agenda-use-time-grid) *org-agenda-grid*))

(define (org-agenda-span-first day)
  "The first day of the span gD chose that holds `day`: the month's or
   year's first, else as org-agenda-span-start."
  (case *org-agenda-span*
    [(month) (list (car day) (cadr day) 1)]
    [(year) (list (car day) 1 1)]
    [(day) day]
    [else (org-agenda-span-start day)]))

(define (org-agenda-dated-block entries settings)
  "The dated block over `entries`, as Org's week view: (covers rows).
   The undone entries scheduled or due before today, then the span's
   days with what falls on each (repeats and ranges included, timed
   entries first, and on today the deadlines coming), then what is dated
   after the span, then the TODOs with no date. Done entries are left
   out. `settings` may give its span."
  (let* ([today (calendar-today)]
         [span (max 1 (org-agenda-setting settings 'span (org-agenda-span)))]
         [first (org-agenda-first-day)]
         [last (date-add-days first (- span 1))]
         [today-shown? (and (not (date<? today first)) (not (date<? last today)))]
         [open (filter (lambda (e) (not (org-entry-done? e))) entries)]
         [rank (lambda (e) (org-priority-rank (list-ref e 6)))]
         ;; (occurrence entry) for each date an open entry has, in priority order.
         [occs (org-sort-entries
                (apply append (map (lambda (e) (map (lambda (o) (list o e)) (org-entry-occurrences e))) open))
                (lambda (x) (rank (cadr x))))]
         [time-of (lambda (stamp) (or (caddr stamp) ""))]
         [by-time (lambda (rows)
                    (org-sort-entries rows (lambda (r) (let ([m (org-time-minutes (caddr r))])
                                                         (if m (+ (* m 100) (rank (cadr r))) (+ 200000 (rank (cadr r))))))))]
         [days-since (lambda (d) (- (date->days today) (date->days d)))]
         ;; A habit's SCHEDULED: shows on today only, with its graph.
         [habit? (lambda (x) (and (eq? (cadr (car x)) 'scheduled) (org-habit? (cadr x))))]
         [overdue
          (map (lambda (x)
                 (let* ([o (car x)] [stamp (car o)] [n (days-since (cadr stamp))])
                   (list 'entry (cadr x) (time-of stamp)
                         (if (eq? (cadr o) 'scheduled)
                             (string-append "Sched. " (number->string n) "x")
                             (string-append (number->string n) " d. ago"))
                         'overdue o)))
               (org-sort-entries
                (filter (lambda (x) (and (memq (cadr (car x)) '(scheduled deadline)) (not (habit? x))
                                         (date<? (cadr (car (car x))) today)))
                        occs)
                (lambda (x) (date->days (cadr (car (car x)))))))]
         [upcoming
          (filter (lambda (r) r)
                  (map (lambda (x)
                         (let* ([o (car x)] [next (and (eq? (cadr o) 'deadline) (org-stamp-after-day (car o) today))]
                                [n (and next (- (date->days next) (date->days today)))])
                           (and n (<= n (org-warning-days (car o)))
                                (list 'entry (cadr x) (time-of (car o))
                                      (string-append "In " (number->string n) " d.") 'upcoming o))))
                       occs))]
         [day-rows
          (lambda (day)
            (org-with-grid
             (append
              (by-time
              (apply append
                     (map (lambda (x)
                            (let ([o (car x)])
                              (if (habit? x)
                                  (org-habit-rows x day today)
                                  (map (lambda (d) (list 'entry (org-diary-entry (cadr x) o (car d)) (if (cadr d) "" (time-of (car o)))
                                                         (or (cadr d) (org-occurrence-label (cadr o))) (cadr o) o))
                                       (filter (lambda (d) (equal? (car d) day)) (org-occurrence-days o day day))))))
                          occs)))
              (if (equal? day today) upcoming '()))
             (equal? day today)))]
         [later
          (map cdr
               (org-sort-entries
                (filter (lambda (r) r)
                        (map (lambda (x)
                               (let* ([o (car x)] [next (if (caddr o)
                                                            (and (date<? last (cadr (car o))) (cadr (car o)))
                                                            (org-stamp-after-day (car o) last))])
                                 (and next
                                      (cons (date->days next)
                                            (list 'entry (org-diary-entry (cadr x) o next)
                                                  (string-append (org-short-date next)
                                                                 (if (caddr (car o)) (string-append " " (caddr (car o))) ""))
                                                  (org-occurrence-label (cadr o)) (cadr o) o)))))
                             (filter (lambda (x) (not (habit? x))) occs)))
                car))]
         [todos (org-sort-entries (filter (lambda (e) (and (caddr e) (null? (org-entry-occurrences e)))) open) rank)]
         [section (lambda (name items)
                    (if (null? items) '() (append (list '(blank) (list 'header name 'section)) items)))])
    (list
     (string-append (if (= span 7) (string-append "Week " (number->string (org-iso-week (org-span-thursday first))) " · ") "")
                    (org-span-text first last))
     (append
      (section "Overdue" (if today-shown? overdue '()))
      (apply append
             (map (lambda (n)
                    (let ([day (date-add-days first n)])
                      (append (list '(blank) (org-day-header day today)) (day-rows day))))
                  (range 0 span)))
      (section "Later" later)
      (section "To do" (map (lambda (e) (list 'entry e "" "" #f #f)) todos))))))


(define (org-agenda-todo-block entries keyword)
  "The TODO list over `entries`: (covers rows), every undone TODO entry
   (with `keyword` only, unless it is #f), by priority, then in file
   order."
  (let* ([todos (filter (lambda (e) (and (caddr e) (not (org-entry-done? e))
                                         (or (not keyword) (equal? (caddr e) keyword))))
                        entries)]
         [todos (org-sort-entries todos (lambda (e) (org-priority-rank (list-ref e 6))))]
         [n (length todos)])
    (list (string-append (if keyword keyword "Every keyword") " · " (number->string n) (if (= n 1) " entry" " entries"))
          (cons '(blank) (map (lambda (e) (list 'entry e "" "" #f #f)) todos)))))

;;; Tags matches, in Org's syntax: +work-urgent|home, LEVEL>1,
;;; TODO="NEXT", Effort<"1:00", PRIORITY="A", {regexp}.

(define (org-match-split text char)
  "`text` split at each `char` outside \"strings\" and {regexps}."
  (let loop ([chars (string->list text)] [quote? #f] [brace 0] [part '()] [acc '()])
    (let ([piece (lambda () (list->string (reverse part)))])
      (cond
        [(null? chars) (reverse (cons (piece) acc))]
        [(and (equal? (car chars) char) (not quote?) (= brace 0)) (loop (cdr chars) #f 0 '() (cons (piece) acc))]
        [else (let ([c (car chars)])
                (loop (cdr chars) (if (and (equal? c #\") (= brace 0)) (not quote?) quote?)
                      (cond [quote? brace] [(equal? c #\{) (+ brace 1)] [(equal? c #\}) (max 0 (- brace 1))] [else brace])
                      (cons c part) acc))]))))

(define (org-match-terms text)
  "The terms of one alternative of a match, as (must? term) where term
   is (tag NAME), (tag-re REGEXP) or (prop NAME OP VALUE)."
  (let loop ([chars (string->list text)] [must? #t] [quote? #f] [brace 0] [part '()] [acc '()])
    (let* ([word (list->string (reverse part))]
           [flush (lambda () (if (equal? word "") acc (cons (list must? (org-match-term word)) acc)))])
      (cond
        [(null? chars) (reverse (flush))]
        [(and (memv (car chars) '(#\+ #\- #\&)) (not quote?) (= brace 0)
              ;; A sign starts a term, unless it follows a comparison.
              (not (and (pair? part) (memv (car part) '(#\= #\< #\>)))))
         (loop (cdr chars) (not (equal? (car chars) #\-)) #f 0 '() (flush))]
        [else (let ([c (car chars)])
                (loop (cdr chars) must? (if (and (equal? c #\") (= brace 0)) (not quote?) quote?)
                      (cond [quote? brace] [(equal? c #\{) (+ brace 1)] [(equal? c #\}) (max 0 (- brace 1))] [else brace])
                      (cons c part) acc))]))))

(define (org-match-term word)
  "One term of a match: a comparison, a {regexp} over tags, or a tag."
  (let ([op-at (let loop ([i 0])
                 (cond [(>= i (string-length word)) #f]
                       [(memv (string-ref word i) '(#\= #\< #\>)) i]
                       [(memv (string-ref word i) '(#\" #\{)) #f]
                       [else (loop (+ i 1))]))])
    (cond
      [op-at
       (let* ([two (and (< (+ op-at 1) (string-length word)) (substring word op-at (+ op-at 2)))]
              [op (if (member two '("<>" "<=" ">=")) two (substring word op-at (+ op-at 1)))])
         (list 'prop (substring word 0 op-at) op (substring word (+ op-at (string-length op)) (string-length word))))]
      [(and (starts-with? word "{") (ends-with? word "}")) (list 'tag-re (substring word 1 (- (string-length word) 1)))]
      [else (list 'tag word)])))

(define (org-parse-match text)
  "Match `text` parsed: a list of alternatives, each a list of terms."
  (map org-match-terms (filter (lambda (a) (not (equal? (trim a) ""))) (org-match-split (trim text) #\|))))

(define (org-entry-match-value e name)
  "What property `name` of entry `e` is for a match: the special TODO,
   LEVEL, PRIORITY and CATEGORY, or a property of its drawer, or #f
   when it has none."
  (case (string->symbol (string-upcase name))
    [(TODO) (or (caddr e) "")]
    [(LEVEL) (number->string (org-entry-level e))]
    [(PRIORITY) (or (list-ref e 6) "B")]
    [(CATEGORY) (list-ref e 7)]
    [else (org-entry-prop e name)]))

(define (org-match-term? e term)
  "Whether entry `e` has `term`."
  (case (car term)
    [(tag) (and (member (cadr term) (map car (org-entry-tags e))) #t)]
    [(tag-re) (ormap (lambda (t) (regexp-match? (cadr term) t)) (map car (org-entry-tags e)))]
    [else
     (let* ([have (org-entry-match-value e (cadr term))] [op (caddr term)] [want (cadddr term)]
            [n (string-length want)])
       (cond
         ;; A property it hasn't matches only <>.
         [(not have) (equal? op "<>")]
         [(and (> n 1) (starts-with? want "{") (ends-with? want "}"))
          (let ([hit (regexp-match? (substring want 1 (- n 1)) have)]) (if (equal? op "<>") (not hit) hit))]
         [(and (> n 1) (starts-with? want "\"") (ends-with? want "\""))
          (let ([w (substring want 1 (- n 1))])
            (org-compare-with op (string<? have w) (equal? have w)))]
         [(and (string->number want) (string->number have))
          (let ([a (string->number have)] [b (string->number want)])
            (org-compare-with op (< a b) (= a b)))]
         [else (equal? op "<>")]))]))

(define (org-compare-with op less? same?)
  "Whether a comparison `op` holds, given whether the value is `less?`
   than the one asked for or the `same?`."
  (cond [(equal? op "=") same?]
        [(equal? op "<>") (not same?)]
        [(equal? op "<") less?]
        [(equal? op "<=") (or less? same?)]
        [(equal? op ">") (not (or less? same?))]
        [(equal? op ">=") (not less?)]
        [else #f]))

(define (org-entry-matches? e match)
  "Whether entry `e` matches `match`, as org-parse-match gives it."
  (ormap (lambda (terms) (andmap (lambda (t) (eq? (and (org-match-term? e (cadr t)) #t) (car t))) terms)) match))

(define (org-agenda-tags-block entries text todo-only?)
  "The headings among `entries` matching `text`: (covers rows). With
   `todo-only?`, only undone TODO entries; else done ones too."
  (let* ([match (org-parse-match text)]
         [hits (filter (lambda (e) (and (or (not todo-only?) (and (caddr e) (not (org-entry-done? e))))
                                        (org-entry-matches? e match)))
                       entries)]
         [n (length hits)])
    (list (string-append (if todo-only? "TODOs · " "") (number->string n) (if (= n 1) " entry" " entries"))
          (cons '(blank) (map (lambda (e) (list 'entry e "" "" #f #f)) hits)))))

;;; Search: words in a heading or its text.

(define (org-search-terms text)
  "The words of a search, as (must? kind value): kind word, phrase or
   regexp. +word and plain words must be there, -word mustn't;
   \"a phrase\" is as written, {regexp} a regexp."
  (let loop ([chars (string->list (trim text))] [acc '()])
    (cond
      [(null? chars) (reverse acc)]
      [(char-whitespace? (car chars)) (loop (cdr chars) acc)]
      [else
       (let* ([must? (not (equal? (car chars) #\-))]
              [chars (if (memv (car chars) '(#\+ #\-)) (cdr chars) chars)]
              [close (cond [(null? chars) #f] [(equal? (car chars) #\") #\"] [(equal? (car chars) #\{) #\}] [else #f])])
         (if close
             (let take ([cs (cdr chars)] [word '()])
               (if (or (null? cs) (equal? (car cs) close))
                   (loop (if (null? cs) cs (cdr cs))
                         (cons (list must? (if (equal? close #\") 'phrase 'regexp) (list->string (reverse word))) acc))
                   (take (cdr cs) (cons (car cs) word))))
             (let take ([cs chars] [word '()])
               (if (or (null? cs) (char-whitespace? (car cs)))
                   (loop cs (if (null? word) acc (cons (list must? 'word (list->string (reverse word))) acc)))
                   (take (cdr cs) (cons (car cs) word))))))])))

(define (org-entry-text e)
  "Agenda entry `e`'s heading and text, up to the next heading."
  (let* ([lines (list-ref e 11)] [n (vector-length lines)])
    (let loop ([l (+ (cadr e) 1)] [acc (list (vector-ref lines (cadr e)))])
      (if (or (>= l n) (org-level-of (vector-ref lines l)))
          (string-join (reverse acc) "\n")
          (loop (+ l 1) (cons (vector-ref lines l) acc))))))

(define (org-entry-found? e terms)
  "Whether entry `e`'s heading and text hold `terms`, ignoring case."
  (let ([text (string-downcase (org-entry-text e))])
    (andmap (lambda (t)
              (let ([hit (if (eq? (cadr t) 'regexp)
                             (regexp-match? (caddr t) text)
                             (string-contains? text (string-downcase (caddr t))))])
                (eq? (and hit #t) (car t))))
            terms)))

(define (org-agenda-search-block entries text)
  "The entries whose heading or text hold the words of `text`: (covers
   rows), in file order."
  (let* ([terms (org-search-terms text)]
         [hits (if (null? terms) '() (filter (lambda (e) (org-entry-found? e terms)) entries))]
         [n (length hits)])
    (list (string-append (number->string n) (if (= n 1) " entry" " entries"))
          (cons '(blank) (map (lambda (e) (list 'entry e "" "" #f #f)) hits)))))

(define (org-agenda-block entries block)
  "The (covers rows) of `block` over `entries`."
  (case (car block)
    [(agenda) (org-agenda-dated-block entries (cadr block))]
    [(todo) (org-agenda-todo-block entries (caddr block))]
    [(tags) (org-agenda-tags-block entries (caddr block) #f)]
    [(tags-todo) (org-agenda-tags-block entries (caddr block) #t)]
    [(search) (org-agenda-search-block entries (caddr block))]
    [else (list "" '())]))

(define (org-agenda-block-name block)
  "What a block of a block agenda is headed: its header setting, else
   its kind's name."
  (org-agenda-setting (cadr block) 'header
                      (case (car block)
                        [(agenda) "Agenda"] [(todo) "To do"]
                        [(tags tags-todo) (string-append "Tags: " (or (caddr block) ""))]
                        [(search) (string-append "Search: " (or (caddr block) ""))]
                        [else (symbol->string (car block))])))

(define (org-render-agenda!)
  "Redraws the agenda's view from the agenda files: its name and what it
   covers, then each block's sections, a block agenda's each under its
   own header."
  (let* ([r *org-agenda-restriction*]
         [all (if r
                      (filter (lambda (e) (or (null? (cdr r)) (<= (cadr r) (cadr e) (caddr r))))
                              (org-file-entries (car r)))
                      (apply append (map org-file-entries (org-agenda-file-list))))]
         [entries (org-agenda-filtered all)]
         [blocks (cadr *org-agenda-view*)]
         [drawn (map (lambda (b) (org-agenda-block entries b)) blocks)])
    (org-agenda-draw!
     (append
      (list (list 'title (car *org-agenda-view*) (car (car drawn)) (org-agenda-filter-text)))
      (if (null? (cdr blocks))
          (cadr (car drawn))
          (apply append
                 (let loop ([bs blocks] [ds drawn])
                   (if (null? bs)
                       '()
                       (cons (append (list '(blank) (list 'header (org-agenda-block-name (car bs)) 'block)) (cadr (car ds)))
                             (loop (cdr bs) (cdr ds)))))))
      (if (null? all)
          (list '(blank) (list 'note (string-append "no entries in " (option 'org-directory)
                                                    " (set org-directory or org-agenda-files)")))
          '())
      (let ([skipped (org-diary-skipped entries)])
        (if (and (> skipped 0) (pair? (filter (lambda (b) (eq? (car b) 'agenda)) blocks)))
            (list '(blank)
                  (list 'note (string-append (number->string skipped)
                                             (if (= skipped 1) " diary sexp" " diary sexps")
                                             " skipped: the agenda reads diary-anniversary, -float, -block, -cyclic and -date")))
            '())))
     (window-text-width))))

(define (org-agenda-cursor-home!)
  "Puts the cursor on today's header if the agenda shows today, else on
   its first line."
  (set-cursor! (line-start (or *org-agenda-today-line* 0))))

(define (org-agenda-move! n)
  "Moves the agenda `n` spans on (back when negative): months or years
   in a month's or year's view, else days. #f goes back to the span that
   has today."
  (let ([first (org-agenda-first-day)])
    (set! *org-agenda-start*
          (cond [(not n) (org-agenda-span-first (calendar-today))]
                [(eq? *org-agenda-span* 'month) (date-add-months first n)]
                [(eq? *org-agenda-span* 'year) (date-add-months first (* 12 n))]
                [else (date-add-days first (* n (org-agenda-span)))])))
  (org-render-agenda!)
  (org-agenda-cursor-home!))

(define (org-agenda-view-span! kind)
  "gD: shows the span `kind` (day, week, fortnight, month or year) that
   holds the day the cursor is on."
  (let ([day (org-agenda-line-date)])
    (set! *org-agenda-span* kind)
    (set! *org-agenda-start* (org-agenda-span-first day))
    (org-render-agenda!)
    (let ([line (assoc day *org-agenda-day-lines*)])
      (set-cursor! (line-start (if line (cdr line) 0))))))

(define (org-agenda-view-menu!)
  "gD: asks how the agenda's dated view shows."
  (menu! "View"
         (list (list "d" "day" (lambda () (org-agenda-view-span! 'day)))
               (list "w" "week" (lambda () (org-agenda-view-span! 'week)))
               (list "t" "fortnight" (lambda () (org-agenda-view-span! 'fortnight)))
               (list "m" "month" (lambda () (org-agenda-view-span! 'month)))
               (list "y" "year" (lambda () (org-agenda-view-span! 'year)))
               (list "g" "time grid" (lambda ()
                                       (set! *org-agenda-grid* (not (org-agenda-grid?)))
                                       (org-render-agenda!)
                                       (message (if *org-agenda-grid* "time grid on" "time grid off")))))))

(define (org-agenda-show-view! view)
  "Shows `view` (see *org-agenda-view*) in the agenda's buffer, freshly
   read from the files, from this week and at org-agenda-span."
  (go-to-buffer! (special-buffer "*org agenda*" 'org-agenda-mode))
  (set! *org-agenda-restriction* *org-agenda-pending-restriction*)
  (set! *org-agenda-pending-restriction* #f)
  (set! *org-agenda-view* (if *org-agenda-restriction*
                              (list (string-append (car view) " · " (file-name-of (car *org-agenda-restriction*))
                                                   (if (pair? (cdr *org-agenda-restriction*)) ", one subtree" ""))
                                    (cadr view))
                              view))
  (set! *org-agenda-start* #f)
  (set! *org-agenda-span* #f)
  (set! *org-agenda-grid* 'default)
  (set! *org-agenda-filters* '())
  (set! *org-agenda-marks* '())
  (org-render-agenda!)
  (org-agenda-cursor-home!))

(define (org-todo-list! keyword)
  "Shows the TODO list: every undone TODO entry, or those with
   `keyword` when it isn't #f."
  (org-agenda-show-view! (list (if keyword (string-append "To do: " keyword) "To do")
                               (list (list 'todo '() keyword)))))

(define (org-tags-view! text todo-only?)
  "Shows the headings matching tags match `text`; with `todo-only?`
   only the undone TODOs."
  (org-agenda-show-view! (list (string-append "Tags: " text)
                               (list (list (if todo-only? 'tags-todo 'tags) '() text)))))

(define (org-tags-view-prompt! todo-only?)
  "Asks for a tags match and shows what matches it."
  (open-cmdline! (if todo-only? "Match TODOs: " "Match: ") ""
                 (lambda (text) (unless (equal? (trim text) "") (org-tags-view! (trim text) todo-only?))) #f #f))

(define (org-search-view! text)
  "Shows the entries whose heading or text hold the words of `text`."
  (org-agenda-show-view! (list (string-append "Search: " text) (list (list 'search '() text)))))

(define (org-search-view-prompt!)
  "Asks for words and shows the entries that hold them."
  (open-cmdline! "Search: " ""
                 (lambda (text) (unless (equal? (trim text) "") (org-search-view! (trim text)))) #f #f))

(define (org-todo-list-prompt!)
  "Asks for a TODO keyword and shows the TODO list for it."
  (completing-read "Keyword: " (filter (lambda (k) (not (member k (org-done-keywords)))) (org-keywords))
                   (lambda (kw) (org-todo-list! kw))))

(define (org-agenda-dispatch! . restriction)
  "The dispatcher (Org's C-c a): a menu of views. < limits the next view
   to the current file, < < to the subtree the cursor is in."
  (let* ([r (if (pair? restriction) (car restriction) #f)]
         [show (lambda (thunk) (lambda () (set! *org-agenda-pending-restriction* r) (thunk)))]
         [title (cond [(not r) "Agenda"]
                      [(null? (cdr r)) (string-append "Agenda (" (file-name-of (car r)) ")")]
                      [else (string-append "Agenda (" (file-name-of (car r)) ", subtree)")])])
    (menu! title
           (append
            (list (list "a" "agenda for the week" (show org-agenda!))
                  (list "t" "TODO list" (show (lambda () (org-todo-list! #f))))
                  (list "T" "TODO list for a keyword" (show org-todo-list-prompt!))
                  (list "m" "match tags and properties" (show (lambda () (org-tags-view-prompt! #f))))
                  (list "M" "match, TODOs only" (show (lambda () (org-tags-view-prompt! #t))))
                  (list "s" "search" (show org-search-view-prompt!))
                  (list "n" "agenda and every TODO" (show (lambda () (org-agenda-show-view!
                                                                       (list "Agenda and TODOs"
                                                                             (list (list 'agenda '() #f) (list 'todo '() #f))))))))
            (org-agenda-custom-entries show)
            (list (list "<" (cond [(not r) "limit to this file"] [(null? (cdr r)) "limit to this subtree"] [else "no limit"])
                        (lambda () (org-agenda-dispatch! (org-agenda-next-restriction r)))))))))

(define (org-agenda-next-restriction r)
  "What < moves the dispatcher's limit to from `r`: the current file,
   then its subtree under the cursor, then none."
  (let ([path (and (buffer-path) (eq? (major-mode) 'org-mode) (absolute-path (buffer-path)))])
    (cond [(not path) (message "< limits to an Org file: open one first") #f]
          [(not r) (list path)]
          [(null? (cdr r))
           (let ([h (org-heading-line (current-line))])
             (if h (list path h (org-subtree-end h)) (begin (message "not under a heading") r)))]
          [else #f])))

;; Custom commands: (key description blocks), as define-agenda-command!
;; adds them.
(define *org-agenda-commands* '())

(define (org-agenda-command-block form)
  "A block of a custom command as written, (tags-todo \"+work\" (header
   \"Work\")), as a view's block: (kind settings arg)."
  (let* ([kind (car form)]
         [args (cdr form)]
         [arg (let ([strings (filter string? args)]) (if (pair? strings) (car strings) #f))]
         [settings (map (lambda (s) (cons (car s) (cadr s))) (filter pair? args))])
    (unless (memq kind '(agenda todo tags tags-todo search))
      (error (string-append "define-agenda-command!: no block kind " (symbol->string kind))))
    (list kind settings arg)))

(define (define-agenda-command! key description blocks)
  "Adds a view to the agenda dispatcher on `key`. `blocks` are shown
   one after another, each one of:

     (agenda)              the dated view; (agenda (span 1)) for a day
     (todo) (todo \"NEXT\")  the TODO list, or one keyword's
     (tags \"+work\")        a tags match; tags-todo for undone TODOs
     (search \"words\")      a search

   each with optional settings, (span N) and (header \"Name\"):

     (define-agenda-command! \"w\" \"Work\"
       '((agenda (span 1)) (tags-todo \"+work\" (header \"Work to do\"))))"
  (let ([parsed (map org-agenda-command-block blocks)])
    (set! *org-agenda-commands*
          (cons (list key description parsed)
                (filter (lambda (c) (not (equal? (car c) key))) *org-agenda-commands*))))
  void)

(define (org-agenda-custom-entries show)
  "The dispatcher's entries for the custom commands."
  (map (lambda (c) (list (car c) (cadr c)
                         (show (lambda () (org-agenda-show-view! (list (cadr c) (caddr c)))))))
       (reverse *org-agenda-commands*)))

(define (org-agenda!)
  "Shows the agenda: this week's dated view."
  (org-agenda-show-view! (list "Agenda" (list (list 'agenda '() #f)))))

(define (org-agenda-entry-line? line)
  "Whether agenda line `line` is an entry's."
  (let ([items (buffer-local 'line-items)])
    (and items (< line (vector-length items))
         (let ([item (vector-ref items line)]) (and (pair? item) (eq? (car item) 'org))))))

(define (org-agenda-next-entry! step count)
  "Moves the cursor `count` entries down (`step` 1) or up (-1), skipping
   headers, rules and the grid."
  (let loop ([line (current-line)] [left (max 1 count)])
    (let find ([l (+ line step)])
      (cond [(or (< l 0) (> l (last-line))) (set-cursor! (line-start line))]
            [(org-agenda-entry-line? l)
             (if (= left 1) (set-cursor! (line-start l)) (loop l (- left 1)))]
            [else (find (+ l step))]))))

(define (org-agenda-go-to-date! date)
  "Shows the span that has `date`, the cursor on its day."
  (set! *org-agenda-start* (org-agenda-span-first date))
  (org-render-agenda!)
  (let ([line (assoc date *org-agenda-day-lines*)])
    (set-cursor! (line-start (if line (cdr line) 0)))))

(define (org-agenda-other-window!)
  "Goes to a window other than the agenda's, splitting one off if there
   is none, and returns the agenda's window."
  (let* ([agenda (current-window)]
         [other (list-find (lambda (w) (not (= w agenda))) (window-list))])
    (leave-pending-states!)
    (if other
        (go-to-window! other)
        (begin (split-window! (if (>= (window-text-width) 140) "right" "below"))
               (after-window-change!)))
    agenda))

(define (org-agenda-open-entry! item)
  "Opens the file of agenda `item` (org file line) in the current window,
   on its heading, remembering the buffer if the agenda opened it."
  (let* ([path (cadr item)] [was (buffer-for-path (absolute-path path))] [id (open-file! path)])
    (when id
      (unless (or was (memv id *org-agenda-opened*))
        (set! *org-agenda-opened* (cons id *org-agenda-opened*)))
      (set-cursor! (line-start (min (caddr item) (last-line)))))))

(define (org-agenda-show!)
  "Shows the entry at the cursor in another window, keeping the cursor
   in the agenda."
  (let ([item (line-item)])
    (when (and item (eq? (car item) 'org))
      (let ([agenda (org-agenda-other-window!)])
        (org-agenda-open-entry! item)
        (go-to-window! agenda)))))

(define (org-agenda-follow!)
  "After a command in the agenda with follow mode on: shows the entry
   the cursor moved to."
  (when (and *org-agenda-follow* (eq? (major-mode) 'org-agenda-mode)
             (not (eqv? (current-line) *org-agenda-followed*)))
    (set! *org-agenda-followed* (current-line))
    (when (org-agenda-entry-line? (current-line)) (org-agenda-show!))))

(add-hook! 'post-command org-agenda-follow!)

(define (org-agenda-redraw-all!)
  "Reads the files again and redraws every agenda buffer."
  (for-each (lambda (id)
              (with-buffer id (lambda () (when (eq? (major-mode) 'org-agenda-mode) (org-render-agenda!)))))
            (buffer-list)))

(define (org-agenda-quit! close-opened?)
  "Leaves the agenda; with `close-opened?` also closes the file buffers
   it opened, except ones with unsaved changes."
  (let ([opened *org-agenda-opened*])
    (set! *org-agenda-follow* #f)
    (run-command 'quit-window)
    (when close-opened?
      (for-each (lambda (id) (when (and (memv id (buffer-list)) (not (buffer-modified-by-id? id)))
                               (buffer-kill! id)))
                opened)
      (set! *org-agenda-opened* '())))
  void)

;;; Acting on entries: each change goes through the entry's file buffer,
;;; as the same command does in an Org buffer.

(define (org-agenda-entry-buffer! path)
  "The id of the buffer visiting `path`, opening it in the background
   (remembered for ZQ) if none does, or #f after saying why."
  (or (buffer-for-path (absolute-path path))
      (let ([id (buffer-open! path)])
        (if (string? id)
            (begin (message id) #f)
            (begin (set! *org-agenda-opened* (cons id *org-agenda-opened*)) id)))))

(define (org-agenda-act! proc)
  "Runs (proc line) on the heading of the entry at the cursor, in its
   file's buffer, then saves the buffer unless it had unsaved changes
   before, and redraws the agenda. Returns whether there was an entry."
  (let ([item (line-item)])
    (if (not (and item (eq? (car item) 'org)))
        (begin (message "not on an agenda entry") #f)
        (let ([id (org-agenda-entry-buffer! (cadr item))])
          (when id
            (let ([clean? (not (buffer-modified-by-id? id))] [at (current-line)])
              (with-buffer id (lambda () (with-undo-group (lambda () (proc (caddr item))))))
              (when clean? (with-buffer id (lambda () (save-buffer!))))
              (set! *org-agenda-last-change* (list id clean?))
              (org-agenda-redraw-at! item at)))
          #t))))

(define (org-agenda-redraw-at! item at)
  "Redraws the agenda, the cursor on `item` if it is still there, or the
   same date of the same entry moved, else on line `at`."
  (org-render-agenda!)
  (if (not (and (pair? item) (eq? (car item) 'org)))
      (set-cursor! (line-start (min at (last-line))))
      (unless (equal? (line-item) item)
        (let* ([items (buffer-local 'line-items)]
               [find (lambda (n)
                       (let loop ([i 0])
                         (cond [(>= i (vector-length items)) #f]
                               [(let ([it (vector-ref items i)])
                                  (and (pair? it) (eq? (car it) 'org) (equal? (take it n) (take item n))))
                                i]
                               [else (loop (+ i 1))])))])
          ;; The same date of the entry, else the entry's first line.
          (set-cursor! (line-start (or (find 4) (find 3) (min at (last-line)))))))))

(define (org-agenda-set-todo!)
  "SPC m t: asks for a TODO keyword, or none, for the entry at the cursor."
  (when (org-agenda-entry-line? (current-line))
    (completing-read "Keyword: " (append (org-keywords) (list "(none)"))
                     (lambda (kw)
                       (org-agenda-act! (lambda (line) (org-todo-set! line (if (equal? kw "(none)") #f kw))))))))

(define (org-agenda-plan! key prompt)
  "Asks for a date with `prompt` (the calendar) and sets the entry's
   `key` (\"SCHEDULED:\" or \"DEADLINE:\") to it."
  (let ([item (line-item)])
    (when (org-agenda-entry-line? (current-line))
      (read-date prompt #f
                 (lambda (d)
                   (let ([stamp (date-timestamp (take d 3) (cadddr d) #t)])
                     (org-agenda-act! (lambda (line) (org-set-planning! line key stamp)))
                     (message (string-append key " " stamp))))))))

(define (org-agenda-shift-date! days)
  "Moves the date the line at the cursor shows `days` days on (back when
   negative)."
  (let ([item (line-item)])
    (cond
      [(not (and (pair? item) (eq? (car item) 'org) (list-ref item 3)))
       (message "no date on this line")]
      [(not (list-ref item 4)) (message "a diary date can't be moved")]
      [else
       (org-agenda-act!
         (lambda (line)
           (case (list-ref item 3)
             [(scheduled) (org-shift-planning! line "SCHEDULED:" days)]
             [(deadline) (org-shift-planning! line "DEADLINE:" days)]
             [else (org-shift-appointment! line (list-ref item 4) days)])))])))

(define (org-agenda-entry-at)
  "The agenda entry (as org-file-entries gives it) of the line at the
   cursor, read afresh from its file, or #f."
  (let ([item (line-item)])
    (and (pair? item) (eq? (car item) 'org)
         (let ([found (filter (lambda (e) (= (cadr e) (caddr item))) (org-file-entries (cadr item)))])
           (and (pair? found) (car found))))))

(define (org-agenda-priority-step! step)
  "Raises (`step` -1) or lowers (1) the entry's priority a letter, a
   heading without one counting as B; A and C are the ends."
  (let ([e (org-agenda-entry-at)])
    (when e
      (let* ([now (char->integer (string-ref (or (list-ref e 6) "B") 0))]
             [next (string (integer->char (max 65 (min 67 (+ now step)))))])
        (org-agenda-act! (lambda (line) (org-set-priority! line next)))
        (message (string-append "priority " next))))))

(define (org-agenda-priority-menu!)
  "SPC m p: asks for the entry's priority."
  (when (org-agenda-entry-line? (current-line))
    (menu! "Priority"
           (append (map (lambda (p) (list (string-downcase p) p
                                          (lambda () (org-agenda-act! (lambda (line) (org-set-priority! line p))))))
                        '("A" "B" "C"))
                   (list (list " " "remove" (lambda () (org-agenda-act! (lambda (line) (org-set-priority! line #f))))))))))

(define (org-agenda-tags!)
  "ct: sets the entry's tags as C-c C-q does: each tag picked is added,
   or removed if it has it, asking again until <esc>."
  (let ([e (org-agenda-entry-at)])
    (when e
      (let ([own (map car (filter cdr (org-entry-tags e)))])
        (completing-read (string-append "Tags " (if (null? own) "(none)" (string-append ":" (string-join own ":") ":"))
                                        " (<esc> when done): ")
                         (org-known-tags)
                         (lambda (tag)
                           (let ([tag (trim (org-trim-colons tag))])
                             (unless (equal? tag "")
                               (org-agenda-act!
                                (lambda (line)
                                  (let ([now (org-heading-tags line)])
                                    (org-set-heading-tags! line (if (member tag now)
                                                                    (filter (lambda (t) (not (equal? t tag))) now)
                                                                    (append now (list tag)))))))
                               (org-agenda-tags!))))
                         (lambda (tag) (and (member tag own) "on")))))))

(define (org-agenda-effort!)
  "ce: sets the entry's Effort property; empty removes it."
  (let ([item (line-item)])
    (when (org-agenda-entry-line? (current-line))
      (let* ([id (org-agenda-entry-buffer! (cadr item))]
             [now (and id (with-buffer id (lambda () (org-entry-property (caddr item) "Effort"))))])
        (when id
          (open-cmdline! "Effort: " (or now "")
                         (lambda (v) (org-agenda-act! (lambda (line) (org-set-property! line "Effort" (trim v)))))
                         #f #f))))))

(define (org-agenda-title-at)
  "The title of the entry at the cursor, for questions about it."
  (let ([e (org-agenda-entry-at)]) (if e (org-agenda-title-text e) "this entry")))

(define (org-agenda-refile!)
  "SPC m r: asks for a heading in the agenda files and moves the entry
   there, with its subtree."
  (when (org-agenda-entry-line? (current-line))
    (let ([targets (org-refile-targets)])
      (if (null? targets)
          (message "no headings in the agenda files to refile under")
          (completing-read "Refile under: " (map car targets)
                           (lambda (choice)
                             (let ([hit (assoc choice targets)])
                               (when hit
                                 (org-agenda-act! (lambda (line) (org-refile-to! line hit)))
                                 (org-agenda-forget-change-to-other-file! (cadr hit))))))))))

(define (org-agenda-forget-change-to-other-file! path)
  "After a change that also wrote `path`: when that is another file than
   the changed buffer's, u can't undo it (it would leave the entry in
   both), so it is forgotten."
  (let ([last *org-agenda-last-change*])
    (when (and last (not (equal? (buffer-for-path (absolute-path path)) (car last))))
      (set! *org-agenda-last-change* #f)))
  void)

(define (org-agenda-archive! ask?)
  "Archives the entry with its subtree (org-archive-location), asking
   first when `ask?`."
  (when (org-agenda-entry-line? (current-line))
    (let ([go (lambda ()
                (let ([file #f])
                  (org-agenda-act! (lambda (line) (set! file (org-archive! line))
                                     (message (string-append "archived in " (file-name-of file)))))
                  (when file (org-agenda-forget-change-to-other-file! file))))])
      (if ask?
          (confirm! (string-append "Archive \"" (org-agenda-title-at) "\"?") go)
          (go)))))

(define (org-agenda-delete!)
  "dd: deletes the entry and its subtree from its file, asking first."
  (when (org-agenda-entry-line? (current-line))
    (confirm! (string-append "Delete \"" (org-agenda-title-at) "\" and everything under it?")
              (lambda ()
                (org-agenda-act!
                 (lambda (line)
                   (let ([end (org-subtree-end line)])
                     (begin-change!)
                     (replace-range! (line-start line) (min (buffer-length) (+ (line-end end) 1)) "")
                     (message "deleted"))))))))

(define (org-agenda-line-date)
  "The day the line at the cursor is under, or today."
  (let* ([at (current-line)]
         [above (filter (lambda (d) (<= (cdr d) at)) *org-agenda-day-lines*)])
    (if (null? above)
        (calendar-today)
        (car (car (sort above (lambda (a b) (> (cdr a) (cdr b)))))))))

(define (org-agenda-undo!)
  "u: undoes the last change made from the agenda, in its file's buffer,
   saving it again if the change saved it."
  (let ([last *org-agenda-last-change*])
    (if (not (and last (memv (car last) (buffer-list))))
        (message "no change from the agenda to undo")
        (let ([at (current-line)] [item (line-item)])
          (set! *org-agenda-last-change* #f)
          (with-buffer (car last) (lambda () (undo!)))
          (when (cadr last) (with-buffer (car last) (lambda () (save-buffer!))))
          (org-agenda-redraw-at! item at)
          (message "undone")))))

(define (org-agenda-visit!)
  "Opens the file of the agenda entry at the cursor, on its heading."
  (let ([item (line-item)])
    (when (and item (eq? (car item) 'org))
      (org-agenda-open-entry! item))))

;;; Filters and bulk actions

(define (org-effort-minutes text)
  "Effort `text` (\"1:30\", \"0:45\" or \"45\") in minutes, or #f."
  (let* ([t (trim text)] [colon (string-index-from t ":" 0)])
    (if colon
        (let ([h (string->number (substring t 0 colon))]
              [m (string->number (substring t (+ colon 1) (string-length t)))])
          (and h m (+ (* h 60) m)))
        (string->number t))))

(define (org-agenda-top-heading e)
  "The first and last line of the top-level heading agenda entry `e` is
   under (its own if it is one), and its title: (first last title)."
  (let* ([lines (list-ref e 11)] [n (vector-length lines)]
         [first (let loop ([l (cadr e)])
                  (if (or (<= l 0) (eqv? (org-level-of (vector-ref lines l)) 1)) l (loop (- l 1))))]
         [last (let loop ([l (+ first 1)])
                 (if (or (>= l n) (eqv? (org-level-of (vector-ref lines l)) 1)) (- l 1) (loop (+ l 1))))]
         [text (vector-ref lines first)]
         [level (or (org-level-of text) 0)]
         [rest (substring text (min (string-length text) (+ level 1)) (string-length text))]
         [kw (org-keyword-in rest)]
         [title (org-without-tags (if kw (trim-start (substring rest (string-length kw) (string-length rest))) rest))])
    (list first last (trim title))))

(define (org-agenda-keeps? e filter)
  "Whether agenda entry `e` passes `filter` (see *org-agenda-filters*)."
  (let ([arg (cadr filter)])
    (case (car filter)
      [(category) (equal? (list-ref e 7) arg)]
      [(tag) (eq? (and (member (car arg) (map car (org-entry-tags e))) #t) (cdr arg))]
      [(effort)
       (let ([have (let ([v (org-entry-prop e "Effort")]) (and v (org-effort-minutes v)))])
         ;; Like a match, an entry without an effort passes only <>.
         (if have
             (org-compare-with (car arg) (< have (cadr arg)) (= have (cadr arg)))
             (equal? (car arg) "<>")))]
      [(regexp) (regexp-match? arg (org-agenda-title-text e))]
      [(top) (and (equal? (car e) (car arg)) (<= (cadr arg) (cadr e) (caddr arg)))]
      [else #t])))

(define (org-agenda-filtered entries)
  "`entries` that pass every filter."
  (filter (lambda (e) (andmap (lambda (f) (org-agenda-keeps? e f)) *org-agenda-filters*)) entries))

(define (org-agenda-filter-text)
  "The filters as the title line shows them, \"Filter: +work -home\", or
   \"\"."
  (if (null? *org-agenda-filters*)
      ""
      (string-append "Filter: " (string-join (map caddr *org-agenda-filters*) " "))))

(define (org-agenda-add-filter! kind arg label)
  "Adds a filter and redraws, keeping the cursor where it can."
  (let ([f (list kind arg label)] [item (line-item)] [at (current-line)])
    (unless (member f *org-agenda-filters*)
      (set! *org-agenda-filters* (append *org-agenda-filters* (list f))))
    (org-agenda-redraw-at! item at)
    (message (org-agenda-filter-text))))

(define (org-agenda-filter-category!)
  "sc: keeps the entries in the category of the entry at the cursor."
  (let ([e (org-agenda-entry-at)])
    (if e
        (org-agenda-add-filter! 'category (list-ref e 7) (string-append "cat:" (list-ref e 7)))
        (message "not on an agenda entry"))))

(define (org-agenda-filter-tag!)
  "st: asks for a tag and keeps the entries with it, or with -tag those
   without it."
  (let ([tags (org-known-tags)])
    (completing-read "Filter by tag (-tag leaves it out): "
                     (append tags (map (lambda (t) (string-append "-" t)) tags))
                     (lambda (text)
                       (let* ([text (trim text)]
                              [out? (starts-with? text "-")]
                              [tag (org-trim-colons (if (or out? (starts-with? text "+"))
                                                        (substring text 1 (string-length text))
                                                        text))])
                         (unless (equal? tag "")
                           (org-agenda-add-filter! 'tag (cons tag (not out?))
                                                   (string-append (if out? "-" "+") tag))))))))

(define (org-agenda-filter-effort!)
  "se: asks for a comparison and an effort, as <1:00, and keeps the
   entries whose effort fits; = when no comparison is given."
  (open-cmdline! "Filter by effort (as <1:00): " ""
                 (lambda (text)
                   (let* ([t (trim text)]
                          [op (list-find (lambda (o) (starts-with? t o)) '("<=" ">=" "<>" "<" ">" "="))]
                          [value (org-effort-minutes (if op (substring t (string-length op) (string-length t)) t))])
                     (if value
                         (org-agenda-add-filter! 'effort (list (or op "=") value)
                                                 (string-append "effort" (or op "=") (org-hhmm value)))
                         (message (string-append "not an effort: " t)))))
                 #f #f))

(define (org-agenda-filter-regexp!)
  "sr: asks for a regexp and keeps the entries whose title matches it."
  (open-cmdline! "Filter by regexp: " ""
                 (lambda (text)
                   (let ([re (trim text)])
                     (cond [(equal? re "") void]
                           [(not (with-handler (lambda (err) #f) (begin (regexp-match? re "") #t)))
                            (message (string-append "bad regexp: " re))]
                           [else (org-agenda-add-filter! 'regexp re (string-append "{" re "}"))])))
                 #f #f))

(define (org-agenda-filter-top!)
  "s^: keeps the entries under the top-level heading of the entry at the
   cursor."
  (let ([e (org-agenda-entry-at)])
    (if e
        (let ([top (org-agenda-top-heading e)])
          (org-agenda-add-filter! 'top (list (car e) (car top) (cadr top))
                                  (string-append "^" (org-fit (caddr top) (min 20 (string-length (caddr top)))))))
        (message "not on an agenda entry"))))

(define (org-agenda-filter-clear!)
  "S: removes every filter."
  (let ([item (line-item)] [at (current-line)])
    (set! *org-agenda-filters* '())
    (org-agenda-redraw-at! item at)
    (message "filters off")))

(define (org-agenda-mark-key e)
  "What marks agenda entry `e`: its file and its title without its
   priority, which stay put as other entries' changes move its line."
  (let ([t (org-agenda-title-text e)])
    (list (car e) (if (and (>= (string-length t) 5) (starts-with? t "[#") (equal? (substring t 3 5) "] "))
                      (substring t 5 (string-length t))
                      t))))

(define (org-agenda-marked? e)
  "Whether agenda entry `e` is marked."
  (and (member (org-agenda-mark-key e) *org-agenda-marks*) #t))

(define (org-agenda-item-entry item)
  "The shown agenda entry of line item `item`, or #f."
  (and (pair? item) (eq? (car item) 'org)
       (list-find (lambda (e) (and (equal? (car e) (cadr item)) (= (cadr e) (caddr item)))) *org-agenda-shown*)))

(define (org-agenda-shown-entries)
  "The entries the agenda shows, each once, in the order shown."
  (let loop ([es *org-agenda-shown*] [seen '()] [acc '()])
    (cond [(null? es) (reverse acc)]
          [(member (org-agenda-mark-key (car es)) seen) (loop (cdr es) seen acc)]
          [else (loop (cdr es) (cons (org-agenda-mark-key (car es)) seen) (cons (car es) acc))])))

(define (org-agenda-set-marks! keys)
  "Marks exactly `keys` and redraws, keeping the cursor."
  (let ([item (line-item)] [at (current-line)])
    (set! *org-agenda-marks* keys)
    (org-agenda-redraw-at! item at)
    (message (string-append (number->string (length keys)) " marked"))))

(define (org-agenda-mark!)
  "m: marks the entry at the cursor, or unmarks it, and moves down."
  (let ([e (org-agenda-item-entry (line-item))])
    (if (not e)
        (message "not on an agenda entry")
        (let ([key (org-agenda-mark-key e)])
          (org-agenda-set-marks! (if (member key *org-agenda-marks*)
                                     (filter (lambda (k) (not (equal? k key))) *org-agenda-marks*)
                                     (append *org-agenda-marks* (list key))))
          (org-agenda-next-entry! 1 1)))))

(define (org-agenda-mark-all! pred)
  "Marks every shown entry `pred` holds for, adding to the marks."
  (org-agenda-set-marks!
   (append *org-agenda-marks*
           (filter (lambda (k) (not (member k *org-agenda-marks*)))
                   (map org-agenda-mark-key (filter pred (org-agenda-shown-entries)))))))

(define (org-agenda-toggle-marks!)
  "~: marks every shown entry that isn't, and unmarks those that are."
  (org-agenda-set-marks! (map org-agenda-mark-key
                              (filter (lambda (e) (not (org-agenda-marked? e))) (org-agenda-shown-entries)))))

(define (org-agenda-mark-regexp!)
  "%: asks for a regexp and marks the shown entries whose title matches."
  (open-cmdline! "Mark by regexp: " ""
                 (lambda (text)
                   (let ([re (trim text)])
                     (cond [(equal? re "") void]
                           [(not (with-handler (lambda (err) #f) (begin (regexp-match? re "") #t)))
                            (message (string-append "bad regexp: " re))]
                           [else (org-agenda-mark-all! (lambda (e) (regexp-match? re (org-agenda-title-text e))))])))
                 #f #f))

(define-major-mode! 'org-agenda-mode 'special-mode '() #f)
(define (org-agenda-key! key proc label)
  "Binds `key` in the agenda, in normal state, labelled `label`."
  (define-mode-key! 'org-agenda-mode 'normal key proc label))

(org-agenda-key! "<ret>" (lambda (n) (org-agenda-visit!)) "go to entry")
(org-agenda-key! "<tab>" (lambda (n) (org-agenda-show!)) "show entry")
(org-agenda-key! "gr" (lambda (n) (org-render-agenda!)) "refresh")
(org-agenda-key! "gR" (lambda (n) (org-agenda-redraw-all!)) "refresh all")
(org-agenda-key! "f" (lambda (n) (org-agenda-move! (max 1 n))) "later")
(org-agenda-key! "b" (lambda (n) (org-agenda-move! (- (max 1 n)))) "earlier")
(org-agenda-key! "]]" (lambda (n) (org-agenda-move! (max 1 n))) "later")
(org-agenda-key! "[[" (lambda (n) (org-agenda-move! (- (max 1 n)))) "earlier")
(org-agenda-key! "." (lambda (n) (org-agenda-move! #f)) "today")
(org-agenda-key! "gD" (lambda (n) (org-agenda-view-menu!)) "view")
(org-agenda-key! "gd" (lambda (n) (read-date "Go to date: " #f (lambda (d) (org-agenda-go-to-date! (take d 3)))))
                 "go to date")
(org-agenda-key! "gj" (lambda (n) (org-agenda-next-entry! 1 n)) "next entry")
(org-agenda-key! "gk" (lambda (n) (org-agenda-next-entry! -1 n)) "previous entry")
(org-agenda-key! "C-j" (lambda (n) (org-agenda-next-entry! 1 n)) "next entry")
(org-agenda-key! "C-k" (lambda (n) (org-agenda-next-entry! -1 n)) "previous entry")
(org-agenda-key! "gH" (lambda (n) (set-cursor! (line-start (window-top)))) "window top")
(org-agenda-key! "gM" (lambda (n) (set-cursor! (line-start (+ (window-top) (quotient (- (window-bottom) (window-top)) 2)))))
                 "window middle")
(org-agenda-key! "gL" (lambda (n) (set-cursor! (line-start (window-bottom)))) "window bottom")
(org-agenda-key! "F" (lambda (n)
                       (set! *org-agenda-follow* (not *org-agenda-follow*))
                       (set! *org-agenda-followed* #f)
                       (message (if *org-agenda-follow* "follow mode on" "follow mode off")))
                 "follow mode")
(org-agenda-key! "t" (lambda (n) (org-agenda-act! org-todo-cycle!)) "cycle TODO")
(define-mode-leader! 'org-agenda-mode "t" (lambda (n) (org-agenda-set-todo!)) "set TODO")
(define-mode-leader-group! 'org-agenda-mode "d" "dates")
(define-mode-leader! 'org-agenda-mode "ds" (lambda (n) (org-agenda-plan! "SCHEDULED:" "Schedule: ")) "schedule")
(define-mode-leader! 'org-agenda-mode "dd" (lambda (n) (org-agenda-plan! "DEADLINE:" "Deadline: ")) "deadline")
(org-agenda-key! "H" (lambda (n) (org-agenda-shift-date! (- (max 1 n)))) "date earlier")
(org-agenda-key! "L" (lambda (n) (org-agenda-shift-date! (max 1 n))) "date later")
(org-agenda-key! "+" (lambda (n) (org-agenda-priority-step! -1)) "priority up")
(org-agenda-key! "-" (lambda (n) (org-agenda-priority-step! 1)) "priority down")
(define-mode-leader! 'org-agenda-mode "p" (lambda (n) (org-agenda-priority-menu!)) "priority")
(org-agenda-key! "ct" (lambda (n) (org-agenda-tags!)) "set tags")
(define-mode-leader! 'org-agenda-mode "q" (lambda (n) (org-agenda-tags!)) "set tags")
(org-agenda-key! "ce" (lambda (n) (org-agenda-effort!)) "set effort")
(define-mode-leader! 'org-agenda-mode "r" (lambda (n) (org-agenda-refile!)) "refile")
(org-agenda-key! "da" (lambda (n) (org-agenda-archive! #t)) "archive")
(org-agenda-key! "dA" (lambda (n) (org-agenda-archive! #f)) "archive now")
(org-agenda-key! "dd" (lambda (n) (org-agenda-delete!)) "delete")
(org-agenda-key! "C" (lambda (n) (org-capture! (org-agenda-line-date))) "capture")
(org-agenda-key! "u" (lambda (n) (org-agenda-undo!)) "undo")
(org-agenda-key! "ZZ" (lambda (n) (org-agenda-quit! #f)) "quit")
(org-agenda-key! "ZQ" (lambda (n) (org-agenda-quit! #t)) "quit, closing its files")

(define-command! 'org-agenda-list
  (lambda (count)
    "Show the agenda: this week's scheduled, due and timed entries."
    (org-agenda!)))
(define-command! 'org-agenda
  (lambda (count)
    "Show the agenda dispatcher: a menu of views."
    (org-agenda-dispatch!)))
(define-command! 'org-todo-list
  (lambda (count)
    "Show every undone TODO entry in the agenda files."
    (org-todo-list! #f)))
(define-leader-group! "oa" "agenda")
(define-leader! "oat" 'org-todo-list "TODO list")
(define-command! 'org-tags-view
  (lambda (count)
    "Show the headings matching a tags match, as +work-urgent|home."
    (org-tags-view-prompt! #f)))
(define-leader! "oam" 'org-tags-view "tags match")
(define-command! 'org-search-view
  (lambda (count)
    "Show the entries whose heading or text hold some words."
    (org-search-view-prompt!)))
(define-leader! "oas" 'org-search-view "search")
(define-leader! "oaa" 'org-agenda-list "agenda")
(define-ex! '("OrgAgenda") (lambda (ex) (org-agenda-dispatch!)))
(define-leader! "oA" 'org-agenda "agenda dispatcher")
(org-agenda-key! "sc" (lambda (n) (org-agenda-filter-category!)) "filter by category")
(org-agenda-key! "st" (lambda (n) (org-agenda-filter-tag!)) "filter by tag")
(org-agenda-key! "se" (lambda (n) (org-agenda-filter-effort!)) "filter by effort")
(org-agenda-key! "sr" (lambda (n) (org-agenda-filter-regexp!)) "filter by regexp")
(org-agenda-key! "s^" (lambda (n) (org-agenda-filter-top!)) "filter by top heading")
(org-agenda-key! "S" (lambda (n) (org-agenda-filter-clear!)) "remove filters")
(org-agenda-key! "m" (lambda (n) (org-agenda-mark!)) "mark")
(org-agenda-key! "~" (lambda (n) (org-agenda-toggle-marks!)) "toggle marks")
(org-agenda-key! "*" (lambda (n) (org-agenda-mark-all! (lambda (e) #t))) "mark all")
(org-agenda-key! "%" (lambda (n) (org-agenda-mark-regexp!)) "mark by regexp")
(org-agenda-key! "M" (lambda (n) (org-agenda-set-marks! '())) "unmark all")
