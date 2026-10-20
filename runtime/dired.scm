;;; dired.scm -- a file browser you edit like text (oil.nvim, Emacs's
;;; wdired).
;;;
;;; :Explore [DIR] (SPC f d, or :e on a directory) lists a directory, one
;;; name per line, directories ending in /. <ret> opens the entry under the
;;; cursor and - goes to the parent. g. shows or hides dotfiles, gr re-reads.
;;;
;;; The listing is text: rename a line to rename the file, delete a line to
;;; delete it, add a line to make a file (a directory if it ends in /, and
;;; a/b.txt makes a/ too). :w shows what will change and asks first.
;;; Moving a line (dd then p) changes nothing. A line that reads exactly as
;;; an entry did is that entry, so swapping two names is no change: rename
;;; through a third name instead.
;;;
;;; Each entry's permissions, size and modification time show in the
;;; margin, which isn't text in the buffer, so they can't be edited by
;;; accident; they follow their entry as lines move. ( hides or shows them
;;; (the dired-details option).

(define-option! 'dired-show-hidden #f '())
(define-option! 'dired-details #t '())

(define (dired-mark i)
  "Each listed entry has a sticky mark at the start of its line: text
   typed at the start of the line (cw, cc, I) goes after it, so a renamed
   line keeps its mark. Deleting a line moves its mark onto the next line,
   or (for the last lines) to the end of the line before."
  (string-append "dired:" (number->string i)))

(define (dired-dir) (buffer-local 'dired-dir))

(define (dired-join dir name) (if (equal? dir "/") (string-append "/" name) (string-append dir "/" name)))

(define (dired-strip-slash name)
  (if (and (> (string-length name) 1) (ends-with? name "/")) (substring name 0 (- (string-length name) 1)) name))

(define (dired-hidden? name) (starts-with? name "."))

(define (dired-listing dir)
  "The entries to show: (name directory?), directories first."
  (let ([entries (directory-entries dir)])
    (if (string? entries)
        (begin (message entries) '())
        (let ([shown (filter (lambda (e) (or (option 'dired-show-hidden) (not (dired-hidden? (car e))))) entries)])
          (append (filter cadr shown) (filter (lambda (e) (not (cadr e))) shown))))))

(define (dired-refresh!)
  "Lists the current buffer's directory afresh."
  (let* ([dir (dired-dir)] [entries (dired-listing dir)] [old (buffer-local 'dired-entries)])
    (when old (for-each (lambda (e) (mark-delete! (dired-mark (car e)))) old))
    (set-buffer-contents!
     (apply string-append (map (lambda (e) (string-append (car e) (if (cadr e) "/" "") "\n")) entries)))
    (let loop ([es entries] [i 0] [acc '()])
      (if (null? es)
          (set-buffer-local! 'dired-entries (reverse acc))
          (begin
            (mark-set-sticky! (dired-mark i) (line-start i))
            (loop (cdr es) (+ i 1) (cons (list i (car (car es)) (cadr (car es))) acc)))))
    (set-buffer-unmodified!)
    (dired-read-details! dir)
    (dired-show-details!)))

;;; Details: permissions, size and modification time, in the margin

(define (civil-from-days days)
  "Days since 1970-01-01 as (year month day): Howard Hinnant's
   civil_from_days."
  (let* ([z (+ days 719468)]
         [era (quotient (if (>= z 0) z (- z 146096)) 146097)]
         [doe (- z (* era 146097))]
         [yoe (quotient (- (+ (- doe (quotient doe 1460)) (quotient doe 36524)) (quotient doe 146096)) 365)]
         [doy (- doe (- (+ (* 365 yoe) (quotient yoe 4)) (quotient yoe 100)))]
         [mp (quotient (+ (* 5 doy) 2) 153)]
         [day (+ (- doy (quotient (+ (* 153 mp) 2) 5)) 1)]
         [month (if (< mp 10) (+ mp 3) (- mp 9))])
    (list (+ yoe (* era 400) (if (<= month 2) 1 0)) month day)))

(define *month-names* (vector "Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))

(define (two-digits n) (if (< n 10) (string-append "0" (number->string n)) (number->string n)))

(define (format-file-time seconds now offset)
  "`seconds` (since the epoch, UTC) as ls shows it, 12 columns: \"Oct 19 14:02\"
   within half a year of `now`, else \"Oct 19  2024\". `offset` is the local
   time zone's, in seconds."
  (let* ([local (+ seconds offset)]
         [date (civil-from-days (quotient local 86400))]
         [in-day (modulo local 86400)]
         [day (number->string (caddr date))]
         [head (string-append (vector-ref *month-names* (- (cadr date) 1)) " "
                              (if (< (caddr date) 10) (string-append " " day) day))])
    (if (< (abs (- now seconds)) (* 180 86400))
        (string-append head " " (two-digits (quotient in-day 3600)) ":" (two-digits (quotient (modulo in-day 3600) 60)))
        (string-append head "  " (number->string (car date))))))

(define (format-file-size bytes)
  "A size as ls -h shows it: 512, 4.0K, 12K, 1.5M."
  (let loop ([n bytes] [units '("K" "M" "G" "T" "P")] [unit ""])
    (cond [(< n 1024)
           (cond [(equal? unit "") (number->string n)]
                 [(< n 10) (let ([tenths (exact (round (* n 10)))])
                             (if (>= tenths 100)
                                 (string-append "10" unit)
                                 (string-append (number->string (quotient tenths 10)) "."
                                                (number->string (modulo tenths 10)) unit)))]
                 [else (string-append (number->string (exact (ceiling n))) unit)])]
          [(null? units) (string-append (number->string (exact (round n))) unit)]
          [else (loop (/ n 1024.0) (cdr units) (car units))])))

(define (clock-now)
  "The current time and the local zone's offset from UTC, in seconds."
  (let ([words (split-whitespace (cadr (run-shell "date '+%s %z'" "")))])
    (if (= (length words) 2)
        (let* ([z (cadr words)]
               [sign (if (starts-with? z "-") -1 1)]
               [hours (or (string->number (substring z 1 3)) 0)]
               [minutes (or (string->number (substring z 3 5)) 0)])
          (list (or (string->number (car words)) 0) (* sign (+ (* hours 3600) (* minutes 60)))))
        (list 0 0))))

(define (dired-read-details! dir)
  "Reads every entry's details into the buffer-local dired-details, a hash
   of entry index -> margin parts."
  (let* ([clock (clock-now)] [now (car clock)] [offset (cadr clock)])
    (set-buffer-local! 'dired-details
      (foldl (lambda (e h)
               (let ([info (file-info (dired-join dir (cadr e)))])
                 (if info
                     (hash-insert h (car e)
                                  (list (list (string-append (car info) " ") "dired.permissions")
                                        (list (string-append (pad-left (format-file-size (cadr info)) 5) " ") "dired.size")
                                        (list (format-file-time (caddr info) now offset) "dired.date")))
                     h)))
             (hash) (buffer-local 'dired-entries)))))

(define (dired-show-details!)
  "Puts each entry's details beside the line it is on now."
  (let ([details (buffer-local 'dired-details)])
    (set-buffer-local! 'dired-details-version (buffer-version))
    (set-margin!
     (if (and details (option 'dired-details))
         (let ([lines (if (buffer-modified?)
                          (hash->list (dired-survivors))
                          (map (lambda (e) (cons (car e) e)) (buffer-local 'dired-entries)))])
           (filter (lambda (x) x)
                   (map (lambda (pair)
                          (let ([parts (hash-try-get details (car (cdr pair)))])
                            (and parts (list (car pair) parts))))
                        lines)))
         '()))))

;; After an edit, in normal mode (not on every key typed in insert mode).
(add-hook! 'post-command
  (lambda ()
    (when (and (eq? (major-mode) 'dired-mode) (eq? *mode* 'normal)
               (not (equal? (buffer-local 'dired-details-version) (buffer-version))))
      (dired-show-details!))))

(define (dired-buffer-name dir) (if (equal? dir "/") "/" (string-append dir "/")))

(define (dired-open! dir . focus)
  "Opens `dir` (an absolute path) in a browser buffer, the cursor on
   `focus` (a name) if given."
  (let* ([dir (if (and (> (string-length dir) 1) (ends-with? dir "/")) (substring dir 0 (- (string-length dir) 1)) dir)]
         [name (dired-buffer-name dir)]
         [existing (list-find (lambda (id) (equal? (car (buffer-info id)) name)) (buffer-list))]
         [id (or existing (buffer-new! name))])
    (go-to-buffer! id)
    (unless existing
      (set-major-mode! 'dired-mode)
      (set-buffer-local! 'dired-dir dir)
      (set-buffer-local! 'write-handler dired-save!)
      (set-buffer-local! 'revert-handler (lambda () (dired-refresh!) (normal-clamp!))))
    (unless (buffer-modified?) (dired-refresh!))
    (let ([line (and (pair? focus)
                     (list-find (lambda (l) (equal? (dired-strip-slash (line-text l)) (car focus)))
                                (range 0 (buffer-line-count))))])
      (set-cursor! (line-start (or line 0))))
    id))

(define (dired-entry-path line)
  (let ([name (trim (line-text line))])
    (and (not (equal? name "")) (dired-join (dired-dir) (dired-strip-slash name)))))

(define (dired-visit!)
  (let ([path (dired-entry-path (current-line))])
    (cond [(not path) #f]
          [(file-directory? path) (dired-open! path)]
          [(file-exists? path) (open-file-buffer! path)]
          [else (message (string-append (trim (line-text (current-line))) " doesn't exist yet (:w makes it)"))])))

(define (dired-up!)
  (let ([dir (dired-dir)])
    (unless (equal? dir "/") (dired-open! (directory-of dir) (file-name-of dir)))))

;;; Saving: working out the changes, then making them

(define (dired-survivors)
  "The original entry on each line, as a hash line -> entry; the rest were
   deleted. A line that reads exactly as an entry did is that entry (so
   moving lines, or opening one above, changes nothing). Otherwise an
   entry's mark says which line it became, if it sits at the start of a
   line nobody else has; when two marks meet there, the later entry's is
   the line's own (deleting a line pushes its mark onto the next)."
  (let* ([entries (buffer-local 'dired-entries)]
         [lines (range 0 (buffer-line-count))]
         [shown (lambda (e) (string-append (cadr e) (if (caddr e) "/" "")))]
         [mark-line (lambda (e)
                      (let ([at (mark-get (dired-mark (car e)))])
                        (and at (= at (line-start (offset->line at))) (offset->line at))))]
         ;; 1. Exact text, preferring the line the entry's mark is on.
         [exact (foldl (lambda (e found)
                         (let* ([want (shown e)]
                                [free? (lambda (l) (and (equal? (trim (line-text l)) want)
                                                        (not (list-find (lambda (x) (equal? (car x) l)) found))))]
                                [own (mark-line e)]
                                [line (if (and own (free? own)) own (list-find free? lines))])
                           (if line (cons (list line e) found) found)))
                       '() entries)]
         [claimed? (lambda (l) (list-find (lambda (x) (equal? (car x) l)) exact))]
         [matched? (lambda (e) (list-find (lambda (x) (equal? (cadr x) e)) exact))]
         ;; 2. Marks, for renamed lines: the latest entry wins a line.
         [renamed (foldl (lambda (e found)
                           (let ([line (and (not (matched? e)) (mark-line e))])
                             (if (and line (not (claimed? line)) (not (equal? (trim (line-text line)) "")))
                                 (hash-insert found line e)
                                 found)))
                         (hash) entries)])
    (foldl (lambda (x h) (hash-insert h (car x) (cadr x))) renamed exact)))

(define (dired-changes)
  "The changes as a list of (rename FROM TO), (delete NAME DIR?),
   (create NAME), names relative to the directory."
  (let* ([survivors (dired-survivors)]
         [kept (hash-values->list survivors)]
         [lines (range 0 (buffer-line-count))]
         [renames (filter (lambda (c) (not (equal? (cadr c) (caddr c))))
                          (map (lambda (l)
                                 (list 'rename (cadr (hash-ref survivors l)) (dired-strip-slash (trim (line-text l)))))
                               (filter (lambda (l) (hash-contains? survivors l)) lines)))]
         [deleted (filter (lambda (e) (not (member e kept))) (buffer-local 'dired-entries))]
         [created (filter (lambda (l) (and (not (hash-contains? survivors l)) (not (equal? (trim (line-text l)) ""))))
                          lines)])
    (append renames
            (map (lambda (e) (list 'delete (cadr e) (caddr e))) deleted)
            (map (lambda (l) (list 'create (trim (line-text l)))) created))))

(define (dired-describe c)
  (cond [(eq? (car c) 'rename) (string-append "rename  " (cadr c) " → " (caddr c))]
        [(eq? (car c) 'delete) (string-append "delete  " (cadr c) (if (caddr c) "/ and everything in it" ""))]
        [else (string-append "create  " (cadr c))]))

(define (dired-apply! dir changes)
  "Makes the changes; returns the problems, if any."
  (let* ([problems '()]
         [try (lambda (r) (when (string? r) (set! problems (cons r problems))))]
         [path (lambda (name) (dired-join dir (dired-strip-slash name)))]
         [renames (filter (lambda (c) (eq? (car c) 'rename)) changes)])
    ;; Renames go through temporary names, so swapping two names works.
    (let ([temp (lambda (i) (path (string-append ".imp-rename-" (number->string i))))])
      (let loop ([rs renames] [i 0])
        (unless (null? rs)
          (try (rename-file! (path (cadr (car rs))) (temp i)))
          (loop (cdr rs) (+ i 1))))
      (let loop ([rs renames] [i 0])
        (unless (null? rs)
          (let ([r (rename-file! (temp i) (path (caddr (car rs))))])
            ;; If the new name is taken, the file keeps its old one.
            (when (string? r) (try r) (rename-file! (temp i) (path (cadr (car rs))))))
          (loop (cdr rs) (+ i 1)))))
    (for-each (lambda (c)
                (cond
                  [(eq? (car c) 'delete) (try (delete-path! (path (cadr c))))]
                  [(eq? (car c) 'create)
                   (if (ends-with? (cadr c) "/")
                       (try (make-directory! (path (cadr c))))
                       (let ([p (path (cadr c))])
                         (if (file-exists? p)
                             (try (string-append (cadr c) " already exists"))
                             (try (with-handler (lambda (e) (error-message e)) (write-text-file! p "") #t)))))]
                  [else #f]))
              changes)
    (reverse problems)))

(define (dired-save!)
  (let ([changes (dired-changes)] [dir (dired-dir)])
    (if (null? changes)
        (begin (dired-refresh!) (message "no changes"))
        (begin
          (show-popup! (map dired-describe changes))
          (confirm! (string-append "Make these " (number->string (length changes)) " changes?")
                    (lambda ()
                      (set-popup! '())
                      (let ([problems (dired-apply! dir changes)] [line (current-line)])
                        (dired-refresh!)
                        (set-cursor! (line-start (min line (last-line))))
                        (message (if (null? problems)
                                     (string-append "made " (number->string (length changes)) " changes")
                                     (string-join problems "; "))))))))))

;;; Mode and keys

(define-major-mode! 'dired-mode #f '()
  (lambda ()
    (buffer-highlight-pattern! "dired-dir" ".*/$" "dired.directory")
    (buffer-highlight-pattern! "dired-hidden" "^\\..*" "dired.hidden")))

(define-mode-key! 'dired-mode 'normal "<ret>" (lambda (n) (dired-visit!)))
(define-mode-key! 'dired-mode 'normal "-" (lambda (n) (dired-up!)))
(define-mode-key! 'dired-mode 'normal "g." (lambda (n)
                                             (set-option! 'dired-show-hidden (not (option 'dired-show-hidden)))
                                             (if (buffer-modified?) (message "save or :e! first") (dired-refresh!))))
(define-mode-key! 'dired-mode 'normal "("
  (lambda (n)
    (set-option! 'dired-details (not (option 'dired-details)))
    (dired-show-details!)))
(define-mode-key! 'dired-mode 'normal "gr" (lambda (n) (if (buffer-modified?) (message "save or :e! first") (dired-refresh!))))

(define (dired-explore! arg)
  (let ([dir (cond [(not (equal? arg "")) (expand-path arg)]
                   [(dired-dir) (dired-dir)]
                   [(buffer-path) (directory-of (expand-path (buffer-path)))]
                   [else (current-dir)])])
    (if (file-directory? dir)
        (dired-open! dir (if (buffer-path) (file-name-of (buffer-path)) ""))
        (message (string-append dir " is not a directory")))))

(define-ex! '("Ex" "Explore") (lambda (ex) (dired-explore! (trim (ex-args ex)))))
(define-command! 'file-browser (lambda (count) (dired-explore! "")))
(define-leader! "fd" 'file-browser "browse directory")
(set! *open-directory* (lambda (dir) (dired-open! dir)))
