;;; history.scm -- what you pick in menus, so they put it first.
;;;
;;; Each kind of menu (M-x, find-file, project switching...) remembers
;;; what you pick in it: how many times, and when last. A candidate's score
;;; is the count weighed by that age ("frecency", as zoxide's), and
;;; completing-read puts the high scorers first (completion.scm). Kept in
;;; the state directory; (set-option! 'completion-history #f) turns it off.

(define-option! 'completion-history #t '())

(define completion-history-max 500)  ; candidates kept per menu
(define *history* #f)                ; menu -> (hash key -> (count time)), once read

(define (completion-history-file)
  "The file the history is kept in, in the state directory."
  (string-append (imp-state-dir) "/completion-history"))

(define (history-table)
  "The history, read from its file the first time. Each line is a menu,
   a count, a time and a key, between tabs."
  (unless *history*
    (set! *history* (hash))
    (with-handler
     (lambda (e) #f)
     (when (file-exists? (completion-history-file))
       (for-each (lambda (line)
                   (let ([fields (split-many line "\t")])
                     (when (= (length fields) 4)
                       (let ([count (string->number (cadr fields))] [time (string->number (caddr fields))])
                         (when (and count time)
                           (history-put! (car fields) (cadddr fields) (list count time)))))))
                 (text-lines (read-file (completion-history-file)))))))
  *history*)

(define (history-put! menu key entry)
  "Sets `menu`'s entry for `key` to `entry`, (count time)."
  (set! *history*
        (hash-insert *history* menu (hash-insert (or (hash-try-get *history* menu) (hash)) key entry)))
  void)

(define (history-score entry now)
  "The score of `entry`, (count time), at time `now`: its count, times 4
   if picked within the hour, 2 within the day, 1 within the week, else ½."
  (let ([age (- now (cadr entry))])
    (* (car entry)
       (cond [(< age 3600) 4] [(< age 86400) 2] [(< age 604800) 1] [else 0.5]))))

(define (history-save!)
  "Writes the history back, keeping each menu's highest scorers. Losing
   it isn't worth an error."
  (let ([now (unix-time)])
    (with-handler
     (lambda (e) #f)
     (write-text-file!
      (completion-history-file)
      (apply string-append
             (map (lambda (menu)
                    (let* ([table (hash-ref *history* menu)]
                           [keys (sort (hash-keys->list table)
                                       (lambda (a b) (> (history-score (hash-ref table a) now)
                                                        (history-score (hash-ref table b) now))))])
                      (apply string-append
                             (map (lambda (key)
                                    (let ([e (hash-ref table key)])
                                      (string-append menu "\t" (number->string (car e)) "\t"
                                                     (number->string (cadr e)) "\t" key "\n")))
                                  (take-at-most keys completion-history-max)))))
                  (hash-keys->list *history*)))))))

(set! *completion-scores*
      (lambda (menu keys)
        (if (option 'completion-history)
            (let ([table (hash-try-get (history-table) menu)] [now (unix-time)])
              (if table
                  (map (lambda (key) (let ([e (hash-try-get table key)]) (if e (history-score e now) 0))) keys)
                  '()))
            '())))

(set! *completion-picked*
      (lambda (menu key)
        (when (and (option 'completion-history) (not (string-contains? key "\t"))
                   (not (string-contains? key "\n")))
          (let* ([table (or (hash-try-get (history-table) menu) (hash))]
                 [old (hash-try-get table key)])
            (history-put! menu key (list (+ 1 (if old (car old) 0)) (unix-time)))
            (history-save!)))))

(define-command! 'clear-completion-history
  (lambda (count)
    "Forget what you've picked in menus, so they show their own order."
    (set! *history* (hash))
    (with-handler (lambda (e) #f) (write-text-file! (completion-history-file) ""))
    (message "completion history cleared")))
