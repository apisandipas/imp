;;; calendar.scm -- dates, and a calendar to pick one from.
;;;
;;; (read-date prompt initial done) asks for a date on the command line
;;; with three months of calendar above it, like Org's date prompt. The
;;; chosen day is highlighted, today underlined. Move it with
;;;
;;;   <left> <right>        a day back, forward
;;;   <up> <down>           a week (C-p C-n too)
;;;   <pageup> <pagedown>   a month (< and > too)
;;;   .                     today
;;;
;;; or type it, which takes over from the keys:
;;;
;;;   2026-11-03  11-03  3      a date; a month and day, or a day of the
;;;                             month, is the next one from today
;;;   fri  monday               the next one, today included
;;;   tomorrow  tom  yesterday  today
;;;   +3  +3d  +2w  +1m  -1y    days, weeks, months, years from today
;;;   14:00  9:30  3pm  3:30pm  a time, after the date or by itself
;;;
;;; <ret> picks it: `done` gets (year month day time), the time a string
;;; like "14:00" or #f. <esc> picks nothing. A date is a list
;;; (year month day) of numbers throughout.

;; The day the calendar's weeks start on: 0 Sunday (as Emacs's calendar),
;; 1 Monday.
(define-option! 'calendar-week-start 0 '())

(define *calendar-month-names*
  (vector "January" "February" "March" "April" "May" "June" "July"
          "August" "September" "October" "November" "December"))
(define *calendar-day-names* (vector "Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat"))

(define (date->days date)
  "The number of days from 1970-01-01 to `date`, a (year month day)."
  ;; Howard Hinnant's days_from_civil.
  (let* ([y (car date)] [m (cadr date)] [d (caddr date)]
         [y (if (<= m 2) (- y 1) y)]
         [era (quotient (if (>= y 0) y (- y 399)) 400)]
         [yoe (- y (* era 400))]
         [doy (+ (quotient (+ (* 153 (+ m (if (> m 2) -3 9))) 2) 5) (- d 1))]
         [doe (+ (* yoe 365) (quotient yoe 4) (- (quotient yoe 100)) doy)])
    (+ (* era 146097) doe -719468)))

(define (days->date days)
  "The (year month day) `days` after 1970-01-01."
  (let* ([z (+ days 719468)]
         [era (quotient (if (>= z 0) z (- z 146096)) 146097)]
         [doe (- z (* era 146097))]
         [yoe (quotient (- doe (quotient doe 1460) (- (quotient doe 36524)) (quotient doe 146096)) 365)]
         [y (+ yoe (* era 400))]
         [doy (- doe (- (+ (* 365 yoe) (quotient yoe 4)) (quotient yoe 100)))]
         [mp (quotient (+ (* 5 doy) 2) 153)]
         [d (+ (- doy (quotient (+ (* 153 mp) 2) 5)) 1)]
         [m (+ mp (if (< mp 10) 3 -9))])
    (list (if (<= m 2) (+ y 1) y) m d)))

(define (date-add-days date n)
  "`date` moved `n` days, back for negative."
  (days->date (+ (date->days date) n)))

(define (days-in-month year month)
  "How many days `month` of `year` has."
  (- (date->days (if (= month 12) (list (+ year 1) 1 1) (list year (+ month 1) 1)))
     (date->days (list year month 1))))

(define (date-add-months date n)
  "`date` moved `n` months, its day kept within the month: January 31
   and a month is the last day of February."
  (let* ([total (+ (* (car date) 12) (- (cadr date) 1) n)]
         [y (quotient total 12)] [m (+ (- total (* y 12)) 1)])
    (list y m (min (caddr date) (days-in-month y m)))))

(define (date-weekday date)
  "The day of the week of `date`: 0 for Sunday to 6 for Saturday."
  (modulo (+ (date->days date) 4) 7))

(define (date<? a b)
  "Whether `a` is before `b`."
  (< (date->days a) (date->days b)))

(define (two-digits n)
  "`n` as at least two digits: 7 -> \"07\"."
  (if (< n 10) (string-append "0" (number->string n)) (number->string n)))

(define (date->string date)
  "`date` as YYYY-MM-DD."
  (string-append (number->string (car date)) "-" (two-digits (cadr date)) "-" (two-digits (caddr date))))

(define (string->date text)
  "The date in `text` written as YYYY-MM-DD, or #f."
  (let ([parts (split-many text "-")])
    (and (= (length parts) 3)
         (let ([y (string->number (car parts))] [m (string->number (cadr parts))] [d (string->number (caddr parts))])
           (and y m d (integer? y) (integer? m) (integer? d) (<= 1 m 12) (<= 1 d (days-in-month y m))
                (list y m d))))))

(define (calendar-today)
  "Today's date, from date."
  (or (string->date (trim (cadr (run-shell "date +%F" "")))) (list 1970 1 1)))

(define (date-timestamp date time active?)
  "An Org timestamp for `date` and `time` (or #f): \"<2026-10-23 Fri>\",
   or in [] when not `active?`."
  (string-append (if active? "<" "[") (date->string date) " "
                 (vector-ref *calendar-day-names* (date-weekday date))
                 (if time (string-append " " time) "")
                 (if active? ">" "]")))

;;; Reading what's typed

(define (parse-time text)
  "The time in `text` as \"HH:MM\": 14:00, 9:30, 3pm, 3:30am. Else #f."
  (let* ([lower (string-downcase text)]
         [suffix (cond [(ends-with? lower "am") 'am] [(ends-with? lower "pm") 'pm] [else #f])]
         [body (if suffix (substring lower 0 (- (string-length lower) 2)) lower)]
         [parts (split-many body ":")]
         [h (and (pair? parts) (string->number (car parts)))]
         [m (cond [(null? (cdr parts)) (and suffix 0)]
                  [(null? (cddr parts)) (and (= (string-length (cadr parts)) 2) (string->number (cadr parts)))]
                  [else #f])])
    (and h m (integer? h) (integer? m) (<= 0 m 59)
         (if suffix (<= 1 h 12) (<= 0 h 23))
         (let ([h (cond [(not suffix) h]
                        [(eq? suffix 'am) (if (= h 12) 0 h)]
                        [else (if (= h 12) 12 (+ h 12))])])
           (string-append (two-digits h) ":" (two-digits m))))))

(define (parse-weekday text)
  "The day of the week `text` begins naming, 0 for Sunday, or #f. At
   least two letters: \"fr\", \"fri\", \"friday\"."
  (let ([lower (string-downcase text)]
        [names '("sunday" "monday" "tuesday" "wednesday" "thursday" "friday" "saturday")])
    (and (>= (string-length lower) 2)
         (let loop ([i 0] [names names])
           (cond [(null? names) #f]
                 [(starts-with? (car names) lower) i]
                 [else (loop (+ i 1) (cdr names))])))))

(define (parse-date-word text today)
  "The date `text` names, counting from `today`, or #f. See the notes at
   the top for what it reads."
  (let* ([lower (string-downcase text)]
         [n (string-length lower)]
         [number (lambda (s) (let ([v (string->number s)]) (and v (integer? v) (>= v 0) v)))]
         [future (lambda (date step)
                   ;; `date`, or moved by `step` until it isn't before today.
                   (let loop ([d date] [tries 0])
                     (cond [(not d) #f]
                           [(or (not (date<? d today)) (> tries 24)) d]
                           [else (loop (step d) (+ tries 1))])))])
    (cond
      [(member lower '("." "today")) today]
      [(member lower '("tom" "tomorrow")) (date-add-days today 1)]
      [(member lower '("yest" "yesterday")) (date-add-days today -1)]
      [(and (> n 1) (memv (string-ref lower 0) '(#\+ #\-)))
       (let* ([unit (string-ref lower (- n 1))]
              [has-unit (memv unit '(#\d #\w #\m #\y))]
              [count (number (substring lower 1 (if has-unit (- n 1) n)))]
              [count (and count (if (equal? (string-ref lower 0) #\-) (- count) count))])
         (and count
              (cond [(or (not has-unit) (equal? unit #\d)) (date-add-days today count)]
                    [(equal? unit #\w) (date-add-days today (* 7 count))]
                    [(equal? unit #\m) (date-add-months today count)]
                    [else (date-add-months today (* 12 count))])))]
      [(parse-weekday lower)
       => (lambda (wd) (date-add-days today (modulo (- wd (date-weekday today)) 7)))]
      [(string->date lower) => (lambda (d) d)]
      [else
       (let ([parts (split-many lower "-")])
         (cond
           [(and (= (length parts) 2) (number (car parts)) (number (cadr parts)))
            ;; MM-DD: this year's, or next year's once it has gone by.
            (let ([m (number (car parts))] [d (number (cadr parts))])
              (and (<= 1 m 12) (<= 1 d 31)
                   (future (string->date (string-append (number->string (car today)) "-" (two-digits m) "-" (two-digits d)))
                           (lambda (date) (string->date (string-append (number->string (+ (car date) 1)) "-" (two-digits m) "-" (two-digits d)))))))]
           [(and (= (length parts) 1) (number lower) (<= 1 (number lower) 31))
            ;; A day of the month: this month's, or the next month that has it.
            (let ([d (number lower)])
              (let loop ([y (car today)] [m (cadr today)] [tries 0])
                (cond [(> tries 12) #f]
                      [(and (<= d (days-in-month y m)) (not (date<? (list y m d) today))) (list y m d)]
                      [else (let ([next (date-add-months (list y m 1) 1)]) (loop (car next) (cadr next) (+ tries 1)))])))]
           [else #f]))])))

(define (parse-date-input text base today)
  "What the date prompt's `text` means: (date time), or #f if it can't be
   read. An empty date part keeps `base`; `today` is where relative ones
   count from."
  (let loop ([words (filter (lambda (w) (not (equal? w ""))) (split-many (trim text) " "))]
             [date #f] [time #f])
    (cond [(null? words) (list (or date base) time)]
          [(and (not time) (parse-time (car words))) => (lambda (t) (loop (cdr words) date t))]
          [(and (not date) (parse-date-word (car words) today)) => (lambda (d) (loop (cdr words) d time))]
          [else #f])))

;;; The calendar

(define (calendar-month-rows year month selected today)
  "The rows of `month` of `year` drawn as a calendar, 20 columns wide:
   its name, the days of the week, then up to six weeks. Each row is a
   list of (text face) spans."
  (let* ([start (option 'calendar-week-start)]
         [first (list year month 1)]
         [blank (modulo (- (date-weekday first) start) 7)]
         [count (days-in-month year month)]
         [title (string-append (vector-ref *calendar-month-names* (- month 1)) " " (number->string year))]
         [pad (quotient (- 20 (string-length title)) 2)]
         [cell (lambda (d)
                 (let* ([date (list year month d)]
                        [text (pad-left (number->string d) 2)]
                        [face (cond [(equal? date selected) "calendar.selected"]
                                    [(equal? date today) "calendar.today"]
                                    [(memv (date-weekday date) '(0 6)) "calendar.weekend"]
                                    [else #f])])
                   (list text face)))]
         [week-row (lambda (first-day)
                     ;; The week whose first cell is day `first-day` (< 1 for blanks).
                     (let loop ([i 0] [acc '()])
                       (if (= i 7)
                           (reverse acc)
                           (let* ([d (+ first-day i)]
                                  [span (if (and (>= d 1) (<= d count)) (cell d) (list "  " #f))])
                             (loop (+ i 1) (cons span (if (= i 0) acc (cons (list " " #f) acc))))))))])
    (append
     (list (list (list (string-append (make-string pad #\space) title) "popup-title"))
           (list (list (string-join (map (lambda (i) (substring (vector-ref *calendar-day-names* (modulo (+ i start) 7)) 0 2))
                                         (range 0 7))
                                    " ")
                       "popup.detail")))
     (let loop ([first-day (- 1 blank)] [acc '()])
       (if (> first-day count)
           (reverse acc)
           (loop (+ first-day 7) (cons (week-row first-day) acc)))))))

(define (calendar-rows selected today)
  "Three months of calendar side by side, the selected date's in the
   middle, as popup rows."
  (let* ([months (map (lambda (n) (date-add-months (list (car selected) (cadr selected) 1) n)) '(-1 0 1))]
         [blocks (map (lambda (m) (calendar-month-rows (car m) (cadr m) selected today)) months)]
         [height (apply max (map length blocks))]
         [width-of (lambda (spans) (apply + (map (lambda (s) (string-length (car s))) spans)))]
         [row-of (lambda (block i)
                   (let ([spans (if (< i (length block)) (list-ref block i) '())])
                     (append spans (list (list (make-string (- 20 (width-of spans)) #\space) #f)))))])
    (map (lambda (i)
           (append (list (list " " #f))
                   (row-of (car blocks) i) (list (list "   " #f))
                   (row-of (cadr blocks) i) (list (list "   " #f))
                   (row-of (caddr blocks) i)))
         (range 0 height))))

;;; The prompt

(define *date-base* (list 1970 1 1))  ; the date the keys move
(define *date-today* (list 1970 1 1))
(define *date-done* #f)               ; what gets the chosen date

(define (date-choice)
  "The prompt's choice, (date time), or #f when what's typed can't be read."
  (parse-date-input *cmdline* *date-base* *date-today*))

(define (date-redraw!)
  "Draws the calendar and the prompt with the date it would pick."
  (let* ([choice (date-choice)] [shown (if choice (car choice) *date-base*)])
    (set-popup! (append (calendar-rows shown *date-today*)
                        (list (list (list " ←→ day  ↑↓ week  PgUp PgDn month  . today   or type: fri  +3d  11-03  tom 3pm"
                                          "popup.detail")))))
    (set-popup-place! "bottom" 0 "")
    (set-popup-selected! -1)
    (set-cmdline! (string-append *cmdline-prompt* *cmdline* "   "
                                 (if choice (date-timestamp (car choice) (cadr choice) #t) "(not a date)"))
                  (+ (string-length *cmdline-prompt*) *cmdline-pos*))))

(define (date-move! f)
  "Moves the chosen date with `f` (a date -> date), dropping what's typed."
  (let ([choice (date-choice)])
    (set! *date-base* (f (if choice (car choice) *date-base*)))
    (cmdline-edit! "" 0)))

(define (date-key key)
  "Handles the date prompt's moving keys, returning #t; #f for others."
  (cond
    [(equal? key "<left>") (date-move! (lambda (d) (date-add-days d -1))) #t]
    [(equal? key "<right>") (date-move! (lambda (d) (date-add-days d 1))) #t]
    [(member key '("<up>" "C-p")) (date-move! (lambda (d) (date-add-days d -7))) #t]
    [(member key '("<down>" "C-n")) (date-move! (lambda (d) (date-add-days d 7))) #t]
    [(member key '("<pageup>" "<")) (date-move! (lambda (d) (date-add-months d -1))) #t]
    [(member key '("<pagedown>" ">")) (date-move! (lambda (d) (date-add-months d 1))) #t]
    [(and (equal? key ".") (equal? *cmdline* "")) (date-move! (lambda (d) *date-today*)) #t]
    [else #f]))

(define (date-close!)
  "Closes the calendar."
  (set-popup! '())
  (set-popup-selected! -1))

(define (read-date prompt initial done)
  "Asks for a date with `prompt` and a calendar, starting at `initial` (a
   date, or #f for today). `done` gets (year month day time), the time
   \"HH:MM\" or #f. See the notes at the top of calendar.scm.

     (read-date \"Due: \" #f (lambda (d) (message (date-timestamp d (cadddr d) #t))))"
  (set! *date-today* (calendar-today))
  (set! *date-base* (or initial *date-today*))
  (set! *date-done* done)
  (open-cmdline!
   prompt ""
   (lambda (text)
     (date-close!)
     (let ([choice (parse-date-input text *date-base* *date-today*)])
       (if choice
           (*date-done* (append (car choice) (list (cadr choice))))
           (message (string-append "not a date: " text)))))
   (lambda (text) (date-redraw!))
   date-close!)
  (set! *cmdline-key-handler* date-key)
  (date-redraw!))
