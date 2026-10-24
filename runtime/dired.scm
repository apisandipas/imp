;;; dired.scm -- a file browser you edit like text (oil.nvim, Emacs's
;;; wdired).
;;;
;;; :Explore [DIR] (SPC f d, or :e on a directory) lists a directory, one
;;; name per line, directories ending in /. <ret> opens the entry under the
;;; cursor and - goes to the parent. g. shows or hides dotfiles, gr re-reads,
;;; q closes the browser. Going to another directory reuses the buffer
;;; (unless it has unsaved edits) rather than leaving one behind per
;;; directory, unless dired-reuse-buffer is off.
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
;; Going to another directory replaces the browser buffer, as Emacs's
;; dired-kill-when-opening-new-dired-buffer.
(define-option! 'dired-reuse-buffer #t '())

;; Each listed entry has a sticky mark at the start of its line: text
;; typed at the start of the line (cw, cc, I) goes after it, so a renamed
;; line keeps its mark. Deleting a line moves its mark onto the next line,
;; or (for the last lines) to the end of the line before.

(define (dired-mark i)
  "The name of the sticky mark that follows entry `i` of the listing."
  (string-append "dired:" (number->string i)))

(define (dired-dir)
  "The directory the current browser buffer lists."
  (buffer-local 'dired-dir))

(define (dired-join dir name)
  "The path of `name` in directory `dir`."
  (if (equal? dir "/") (string-append "/" name) (string-append dir "/" name)))

(define (dired-strip-slash name)
  "`name` without the trailing slash that marks a directory.
   A lone \"/\" stays as it is."
  (if (and (> (string-length name) 1) (ends-with? name "/")) (substring name 0 (- (string-length name) 1)) name))

(define (dired-hidden? name)
  "Whether entry `name` is a dotfile, hidden unless dired-show-hidden."
  (starts-with? name "."))

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

(define (two-digits n)
  "`n` as at least two digits, with a leading zero."
  (if (< n 10) (string-append "0" (number->string n)) (number->string n)))

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
  "Puts each entry's details beside the line it is on now, and an icon
   before each name if *dired-icon* gives one."
  (let* ([details (buffer-local 'dired-details)]
         [show? (and details (option 'dired-details))]
         [by-line (if show?
                      (foldl (lambda (pair h)
                               (let ([parts (hash-try-get details (car (cdr pair)))])
                                 (if parts (hash-insert h (car pair) parts) h)))
                             (hash)
                             (if (buffer-modified?)
                                 (hash->list (dired-survivors))
                                 (map (lambda (e) (cons (car e) e)) (buffer-local 'dired-entries))))
                      (hash))]
         ;; New lines have no details: a blank as wide keeps icons lined up.
         [blank (let ([some (hash-values->list by-line)])
                  (if (null? some)
                      '()
                      (list (list (make-string (apply + (map (lambda (p) (string-length (car p))) (car some))) #\space) ""))))])
    (set-buffer-local! 'dired-details-version (buffer-version))
    (set-margin!
     (filter (lambda (x) x)
             (map (lambda (line)
                    (let* ([parts (or (hash-try-get by-line line) blank)]
                           [name (trim (line-text line))]
                           [icon (and (not (equal? name "")) (*dired-icon* name))]
                           [parts (if icon
                                      (append parts (list (list (string-append (if (null? parts) "" " ") icon)
                                                                (if (ends-with? name "/") "dired.directory" ""))))
                                      (if (eq? parts blank) '() parts))])
                      (and (pair? parts) (list line parts))))
                  (range 0 (buffer-line-count)))))))

;; (lambda (name) ...) -> an icon (a short string) drawn before entry
;; `name` (ending in / for a directory), or #f. The nerd-icons package
;; sets it.
(define *dired-icon* (lambda (name) #f))

;; After an edit, in normal mode (not on every key typed in insert mode).
(add-hook! 'post-command
  (lambda ()
    (when (and (eq? (major-mode) 'dired-mode) (eq? *mode* 'normal)
               (not (equal? (buffer-local 'dired-details-version) (buffer-version))))
      (dired-show-details!))))

(define (dired-buffer-name dir)
  "The name of the browser buffer for `dir`: the path ending in /."
  (if (equal? dir "/") "/" (string-append dir "/")))

(define (dired-open! dir . focus)
  "Opens `dir` (an absolute path) in a browser buffer, the cursor on
   `focus` (a name) if given."
  (let* ([dir (if (and (> (string-length dir) 1) (ends-with? dir "/")) (substring dir 0 (- (string-length dir) 1)) dir)]
         [name (dired-buffer-name dir)]
         [existing (list-find (lambda (id) (equal? (car (buffer-info id)) name)) (buffer-list))]
         [id (or existing (buffer-new! name))]
         ;; The buffer that isn't a browser it came from, for q.
         [from (let ([cur (current-buffer)])
                 (if (eq? (major-mode) 'dired-mode) (buffer-local 'dired-return-to) cur))])
    (go-to-buffer! id)
    (unless (equal? from id) (set-buffer-local! 'dired-return-to from))
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
  "The full path that `line` of the listing names, or #f for a blank one."
  (let ([name (trim (line-text line))])
    (and (not (equal? name "")) (dired-join (dired-dir) (dired-strip-slash name)))))

(define (dired-visit!)
  "<ret>: opens the entry at the cursor, a directory in the browser.
   An entry typed but not saved yet only gets a message."
  (let ([path (dired-entry-path (current-line))])
    (cond [(not path) #f]
          [(file-directory? path) (dired-go! path)]
          [(file-exists? path) (open-file-buffer! path)]
          [else (message (string-append (trim (line-text (current-line))) " doesn't exist yet (:w makes it)"))])))

(define (dired-up!)
  "-: lists the parent directory, the cursor on the one just left."
  (let ([dir (dired-dir)])
    (unless (equal? dir "/") (dired-go! (directory-of dir) (file-name-of dir)))))

(define (dired-go! dir . focus)
  "Lists `dir` from a browser buffer, as dired-open! does, then closes
   the browser it left if dired-reuse-buffer is on and that has no
   unsaved edits or other window showing it."
  (let ([old (current-buffer)] [alt *alternate-buffer*])
    (apply dired-open! dir focus)
    (when (and (option 'dired-reuse-buffer) (not (= old (current-buffer)))
               (not (with-buffer old buffer-modified?))
               (not (list-find (lambda (w) (and (not (= w (current-window))) (= (window-buffer w) old)))
                               (window-list))))
      (kill-buffer! old)
      ;; C-^ goes back to where you were before the browser.
      (when (and alt (memv alt (buffer-list)) (not (= alt (current-buffer))))
        (set! *alternate-buffer* alt))))
  void)

(define (dired-quit!)
  "q: closes the browser for the buffer you came from, unless it has
   unsaved edits."
  (if (buffer-modified?)
      (message "unsaved changes: :w to make them or :e! to drop them")
      (let ([id (current-buffer)] [back (buffer-local 'dired-return-to)])
        (when (and back (memv back (buffer-list))) (go-to-buffer! back))
        (kill-buffer! id))))

;;; Saving: working out the changes, then making them

(define (dired-survivors)
  "The original entry on each line, as a hash line -> entry; the rest were
   deleted. Names swapped between entries come first: an entry whose mark
   is alone at the start of a line that now reads another entry's name
   is that line, if the other entry's line was renamed too. Then a line
   that reads exactly as an entry did is that entry (so moving lines, or
   opening one above, changes nothing). Otherwise an entry's mark says
   which line it became, if it sits at the start of a line nobody else
   has; when two marks meet there, the later entry's is the line's own
   (deleting a line pushes its mark onto the next)."
  (let* ([entries (buffer-local 'dired-entries)]
         [lines (range 0 (buffer-line-count))]
         [shown (lambda (e) (string-append (cadr e) (if (caddr e) "/" "")))]
         [mark-line (lambda (e)
                      (let ([at (mark-get (dired-mark (car e)))])
                        (and at (= at (line-start (offset->line at))) (offset->line at))))]
         [marks (map (lambda (e) (list e (mark-line e))) entries)]
         [marks-on (foldl (lambda (m h) (if (cadr m) (hash-insert h (cadr m) (+ 1 (or (hash-try-get h (cadr m)) 0))) h))
                          (hash) marks)]
         ;; The line an entry's mark has to itself, and what it reads now.
         [alone (foldl (lambda (m h)
                         (if (and (cadr m) (= (hash-ref marks-on (cadr m)) 1))
                             (hash-insert h (car (car m)) (list (cadr m) (trim (line-text (cadr m)))))
                             h))
                       (hash) marks)]
         [renamed? (lambda (e) (let ([a (hash-try-get alone (car e))]) (and a (not (equal? (cadr a) (shown e))))))]
         [by-name (foldl (lambda (e h) (hash-insert h (shown e) e)) (hash) entries)]
         ;; 0. Swapped names (and rotations): both lines were renamed.
         [swapped (foldl (lambda (e found)
                           (let* ([a (hash-try-get alone (car e))]
                                  [other (and a (renamed? e) (hash-try-get by-name (cadr a)))])
                             (if (and other (renamed? other)) (cons (list (car a) e) found) found)))
                         '() entries)]
         ;; 1. Exact text, preferring the line the entry's mark is on.
         [exact (foldl (lambda (e found)
                         (if (list-find (lambda (x) (equal? (cadr x) e)) found)
                             found
                             (let* ([want (shown e)]
                                    [free? (lambda (l) (and (equal? (trim (line-text l)) want)
                                                            (not (list-find (lambda (x) (equal? (car x) l)) found))))]
                                    [own (mark-line e)]
                                    [line (if (and own (free? own)) own (list-find free? lines))])
                               (if line (cons (list line e) found) found))))
                       swapped entries)]
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
  "Change `c` as one line for the list :w shows before asking."
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
    ;; An entry whose first step fails is left alone after that: its one
    ;; problem is the one reported.
    (let* ([temp (lambda (i) (path (string-append ".imp-rename-" (number->string i))))]
           [moved (let loop ([rs renames] [i 0] [acc '()])
                    (if (null? rs)
                        (reverse acc)
                        (let ([r (rename-file! (path (cadr (car rs))) (temp i))])
                          (try r)
                          (loop (cdr rs) (+ i 1) (if (string? r) acc (cons (list i (car rs)) acc))))))])
      (for-each (lambda (m)
                  (let* ([i (car m)] [c (cadr m)] [r (rename-file! (temp i) (path (caddr c)))])
                    ;; If the new name is taken, the file keeps its old one.
                    (when (string? r) (try r) (rename-file! (temp i) (path (cadr c))))))
                moved))
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
  ":w: shows what the edits would change, and makes the changes if
   confirmed. Then lists the directory afresh and reports any
   problems."
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
(define-mode-key! 'dired-mode 'normal "q" (lambda (n) (dired-quit!)))
(define-mode-key! 'dired-mode 'normal "g." (lambda (n)
                                             (set-option! 'dired-show-hidden (not (option 'dired-show-hidden)))
                                             (if (buffer-modified?) (message "save or :e! first") (dired-refresh!))))
(define-mode-key! 'dired-mode 'normal "("
  (lambda (n)
    (set-option! 'dired-details (not (option 'dired-details)))
    (dired-show-details!)))
(define-mode-key! 'dired-mode 'normal "gr" (lambda (n) (if (buffer-modified?) (message "save or :e! first") (dired-refresh!))))

(define (dired-explore! arg)
  "Lists directory `arg`, or for \"\" the current buffer's directory.
   That is the listed one in a browser, else the file's directory or
   the working directory. The cursor starts on the current file."
  (let ([dir (cond [(not (equal? arg "")) (expand-path arg)]
                   [(dired-dir) (dired-dir)]
                   [(buffer-path) (directory-of (expand-path (buffer-path)))]
                   [else (current-dir)])])
    (if (file-directory? dir)
        (dired-open! dir (if (buffer-path) (file-name-of (buffer-path)) ""))
        (message (string-append dir " is not a directory")))))

(define-ex! '("Ex" "Explore") (lambda (ex) (dired-explore! (trim (ex-args ex)))))
(define-command! 'file-browser
  (lambda (count)
    "Browse the current file's directory, editing it like text."
    (dired-explore! "")))
(define-leader! "fd" 'file-browser "browse directory")
(set! *open-directory* (lambda (dir) (dired-open! dir)))
