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

(define-option! 'dired-show-hidden #f '())

;; Each listed entry has a sticky mark at the start of its line: text
;; typed at the start of the line (cw, cc, I) goes after it, so a renamed
;; line keeps its mark. Deleting a line moves its mark onto the next line,
;; or (for the last lines) to the end of the line before.
(define (dired-mark i) (string-append "dired:" (number->string i)))

(define (dired-dir) (buffer-local 'dired-dir))

(define (dired-join dir name) (if (equal? dir "/") (string-append "/" name) (string-append dir "/" name)))

(define (dired-strip-slash name)
  (if (and (> (string-length name) 1) (ends-with? name "/")) (substring name 0 (- (string-length name) 1)) name))

(define (dired-hidden? name) (starts-with? name "."))

;; The entries to show: (name directory?), directories first.
(define (dired-listing dir)
  (let ([entries (directory-entries dir)])
    (if (string? entries)
        (begin (message entries) '())
        (let ([shown (filter (lambda (e) (or (option 'dired-show-hidden) (not (dired-hidden? (car e))))) entries)])
          (append (filter cadr shown) (filter (lambda (e) (not (cadr e))) shown))))))

;; Lists the current buffer's directory afresh.
(define (dired-refresh!)
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
    (set-buffer-unmodified!)))

(define (dired-buffer-name dir) (if (equal? dir "/") "/" (string-append dir "/")))

;; Opens `dir` (an absolute path) in a browser buffer, the cursor on
;; `focus` (a name) if given.
(define (dired-open! dir . focus)
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

;; The original entry on each line, as a hash line -> entry; the rest were
;; deleted. A line that reads exactly as an entry did is that entry (so
;; moving lines, or opening one above, changes nothing). Otherwise an
;; entry's mark says which line it became, if it sits at the start of a
;; line nobody else has; when two marks meet there, the later entry's is
;; the line's own (deleting a line pushes its mark onto the next).
(define (dired-survivors)
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

;; The changes as a list of (rename FROM TO), (delete NAME DIR?),
;; (create NAME), names relative to the directory.
(define (dired-changes)
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

;; Makes the changes; returns the problems, if any.
(define (dired-apply! dir changes)
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
