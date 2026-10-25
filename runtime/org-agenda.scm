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
;; The day of the week a week's agenda starts on: 0 for Sunday to 6 for
;; Saturday, or #f for today. Unset, it is calendar-week-start's day.
(define-option! 'org-agenda-start-on-weekday 0 '())
;; The line today's header was drawn on, or #f, and each day's header's,
;; as (day . line).
(define *org-agenda-today-line* #f)
(define *org-agenda-day-lines* '())
;; The file buffers the agenda opened, which ZQ closes.
(define *org-agenda-opened* '())
;; Whether follow mode is on, and the line it last showed.
(define *org-agenda-follow* #f)
(define *org-agenda-followed* #f)
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

;; The first day the agenda shows, or #f for this week's.
(define *org-agenda-start* #f)

(define *org-day-names*
  (vector "Sunday" "Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday"))

(define (org-agenda-first-day)
  "The first day the agenda shows: the one f and b moved to, or else the
   first day of the span that shows today."
  (or *org-agenda-start* (org-agenda-span-start (calendar-today))))

(define (org-agenda-span-start day)
  "The first day of the span that shows `day`: with a span of 7 days and
   org-agenda-start-on-weekday a day, the last such day on or before it,
   else `day` itself."
  (let ([start (if (option-set? 'org-agenda-start-on-weekday)
                   (option 'org-agenda-start-on-weekday)
                   (option 'calendar-week-start))])
    (if (and start (= (option 'org-agenda-span) 7))
        (date-add-days day (- (modulo (- (date-weekday day) start) 7)))
        day)))

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
  (let loop ([t (cadddr e)])
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
;;   (title NAME COVERS)         the view's name, what it covers under
;;                               it, then a rule
;;   (header TEXT KIND [DAY])    a section or day, with a rule under it;
;;                               KIND is section, date, weekend or today
;;   (entry E TIME WHAT KIND)    entry E, TIME and WHAT strings (or ""),
;;                               KIND the what's kind (org-what-face)
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
    (for-each
     (lambda (r)
       (when (and (eq? (car r) 'header) (eq? (caddr r) 'today))
         (set! *org-agenda-today-line* (length *draw-lines*)))
       (when (and (eq? (car r) 'header) (pair? (cdddr r)))
         (set! *org-agenda-day-lines* (cons (cons (cadddr r) (length *draw-lines*)) *org-agenda-day-lines*)))
       (case (car r)
         [(title)
          (draw-line! (list (list " " #f) (list (cadr r) (list "org.agenda.title" (heights 1)))) #f)
          (draw-line! (list (list " " #f) (list (caddr r) "org.agenda.span")) #f)
          (draw-line! (list (list (rule (- width 1)) "org.agenda.rule")) #f)]
         [(header)
          (let* ([text (cadr r)] [kind (caddr r)]
                 [face (case kind [(today) "org.agenda.today"] [(weekend) "org.agenda.weekend"]
                                  [(date) "org.agenda.date"] [else "org.agenda.section"])])
            (draw-line! (list (list (if (eq? kind 'today) "▌ " "  ") "org.agenda.today")
                              (list text (list face (heights 2))))
                        #f)
            (draw-line! (list (list "  " #f) (list (rule (string-length text)) "org.agenda.rule")) #f))]
         [(entry)
          (let* ([e (cadr r)] [time (caddr r)] [what (cadddr r)] [kind (list-ref r 4)]
                 [kw (caddr e)]
                 [title (org-agenda-title-text e)]
                 [prio (and (>= (string-length title) 5) (starts-with? title "[#")
                            (equal? (substring title 3 5) "] ") (substring title 0 4))]
                 [fitted (org-fit title title-w)]
                 [cell (lambda (text w face) (if (> w 0) (list (list (org-fit text w) face) (list "  " #f)) '()))])
            (draw-line!
             (append (list (list "    " #f))
                     (cell time time-w "org.agenda.time")
                     (cell what what-w (org-what-face kind))
                     (cell (or kw "") kw-w (if (org-entry-done? e) "org.done" "org.todo"))
                     (if (and prio (> title-w 5))
                         (list (list prio "org.priority")
                               (list (substring fitted 4 (string-length fitted)) #f))
                         (list (list fitted #f)))
                     (if (> tags-w 0)
                         (list (list "  " #f) (list (org-pad-left (org-agenda-tags-text e) tags-w) "org.agenda.tag"))
                         '())
                     (list (list "  " #f) (list (pad-right (list-ref e 7) cat-w) "org.agenda.category")))
             (list 'org (car e) (cadr e))))]
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
    (if (or (not (option 'org-agenda-use-time-grid)) (and (not today?) (null? timed)))
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
               (org-entry-appointments e))))

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

(define (org-render-agenda!)
  "Redraws the agenda from the agenda files, as Org's week view: the
   undone entries scheduled or due before today, then org-agenda-span
   days with what falls on each (repeats and ranges included, timed
   entries first, and on today the deadlines coming), then what is dated
   after the span, then the TODOs with no date. Done entries are left
   out."
  (let* ([today (calendar-today)]
         [first (org-agenda-first-day)]
         [span (max 1 (option 'org-agenda-span))]
         [last (date-add-days first (- span 1))]
         [today-shown? (and (not (date<? today first)) (not (date<? last today)))]
         [entries (apply append (map org-file-entries (org-agenda-file-list)))]
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
         [overdue
          (map (lambda (x)
                 (let* ([o (car x)] [stamp (car o)] [n (days-since (cadr stamp))])
                   (list 'entry (cadr x) (time-of stamp)
                         (if (eq? (cadr o) 'scheduled)
                             (string-append "Sched. " (number->string n) "x")
                             (string-append (number->string n) " d. ago"))
                         'overdue)))
               (org-sort-entries
                (filter (lambda (x) (and (memq (cadr (car x)) '(scheduled deadline))
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
                                      (string-append "In " (number->string n) " d.") 'upcoming))))
                       occs))]
         [day-rows
          (lambda (day)
            (org-with-grid
             (append
              (by-time
              (apply append
                     (map (lambda (x)
                            (let ([o (car x)])
                              (map (lambda (d) (list 'entry (cadr x) (if (cadr d) "" (time-of (car o)))
                                                     (or (cadr d) (org-occurrence-label (cadr o))) (cadr o)))
                                   (filter (lambda (d) (equal? (car d) day)) (org-occurrence-days o day day)))))
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
                                            (list 'entry (cadr x)
                                                  (string-append (org-short-date next)
                                                                 (if (caddr (car o)) (string-append " " (caddr (car o))) ""))
                                                  (org-occurrence-label (cadr o)) (cadr o))))))
                             occs))
                car))]
         [todos (org-sort-entries (filter (lambda (e) (and (caddr e) (null? (org-entry-occurrences e)))) open) rank)]
         [section (lambda (name items)
                    (if (null? items) '() (append (list '(blank) (list 'header name 'section)) items)))])
    (org-agenda-draw!
     (append
      (list (list 'title "Agenda"
                  (string-append (if (= span 7) (string-append "Week " (number->string (org-iso-week (org-span-thursday first))) " · ") "")
                                 (org-span-text first last))))
      (section "Overdue" (if today-shown? overdue '()))
      (apply append
             (map (lambda (n)
                    (let ([day (date-add-days first n)])
                      (append (list '(blank) (org-day-header day today)) (day-rows day))))
                  (range 0 span)))
      (section "Later" later)
      (section "To do" (map (lambda (e) (list 'entry e "" "" #f)) todos))
      (if (null? entries)
          (list '(blank) (list 'note (string-append "no entries in " (option 'org-directory)
                                                    " (set org-directory or org-agenda-files)")))
          '()))
     (window-text-width))))

(define (org-agenda-cursor-home!)
  "Puts the cursor on today's header if the agenda shows today, else on
   its first line."
  (set-cursor! (line-start (or *org-agenda-today-line* 0))))

(define (org-agenda-move! days)
  "Moves the agenda `days` on, or back to this week when `days` is #f."
  (set! *org-agenda-start* (and days (date-add-days (org-agenda-first-day) days)))
  (org-render-agenda!)
  (org-agenda-cursor-home!))

(define (org-agenda!)
  "Shows the agenda in its own buffer, freshly read from the files, from
   this week."
  (go-to-buffer! (special-buffer "*org agenda*" 'org-agenda-mode))
  (set! *org-agenda-start* #f)
  (org-render-agenda!)
  (org-agenda-cursor-home!))

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
  (set! *org-agenda-start* (org-agenda-span-start date))
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

(define (org-agenda-visit!)
  "Opens the file of the agenda entry at the cursor, on its heading."
  (let ([item (line-item)])
    (when (and item (eq? (car item) 'org))
      (org-agenda-open-entry! item))))

(define-major-mode! 'org-agenda-mode 'special-mode '() #f)
(define (org-agenda-key! key proc label)
  "Binds `key` in the agenda, in normal state, labelled `label`."
  (define-mode-key! 'org-agenda-mode 'normal key proc label))

(define (org-agenda-span-days n)
  "How far `n` spans go, in days."
  (* (max 1 n) (max 1 (option 'org-agenda-span))))

(org-agenda-key! "<ret>" (lambda (n) (org-agenda-visit!)) "go to entry")
(org-agenda-key! "<tab>" (lambda (n) (org-agenda-show!)) "show entry")
(org-agenda-key! "gr" (lambda (n) (org-render-agenda!)) "refresh")
(org-agenda-key! "gR" (lambda (n) (org-agenda-redraw-all!)) "refresh all")
(org-agenda-key! "f" (lambda (n) (org-agenda-move! (org-agenda-span-days n))) "later")
(org-agenda-key! "b" (lambda (n) (org-agenda-move! (- (org-agenda-span-days n)))) "earlier")
(org-agenda-key! "]]" (lambda (n) (org-agenda-move! (org-agenda-span-days n))) "later")
(org-agenda-key! "[[" (lambda (n) (org-agenda-move! (- (org-agenda-span-days n)))) "earlier")
(org-agenda-key! "." (lambda (n) (org-agenda-move! #f)) "today")
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
(org-agenda-key! "ZZ" (lambda (n) (org-agenda-quit! #f)) "quit")
(org-agenda-key! "ZQ" (lambda (n) (org-agenda-quit! #t)) "quit, closing its files")

(define-command! 'org-agenda
  (lambda (count)
    "Show the agenda: TODOs and SCHEDULED and DEADLINE dates."
    (org-agenda!)))
(define-leader! "oa" 'org-agenda "agenda")
(define-ex! '("OrgAgenda") (lambda (ex) (org-agenda!)))
