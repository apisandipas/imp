;;; git-gutter.scm -- a coloured bar beside each line that differs from
;;; git, as VSCode, gitsigns and diff-hl show them.
;;;
;;;   (use-package! 'git-gutter)
;;;
;;; git-gutter-mode turns on in every buffer visiting a file git tracks,
;;; and gives it a change column between the line numbers and the fold
;;; column (see lore:decision/0016). The buffer's text, unsaved edits
;;; included, is compared with the file in git's index: an added line
;;; gets a green bar, a changed one an orange bar, and the line above
;;; removed lines a red ▁ (▔ on the first line when they were at the
;;; top). The faces are git-gutter.added, git-gutter.changed and
;;; git-gutter.removed.
;;;
;;; The marks are worked out when the file opens, git-gutter-delay ms
;;; after the last change, after a save and when the buffer is shown
;;; again. ]h and [h move to the next and previous changed block;
;;; M-x git-gutter-mode turns the mode off and on.

;; How long after the last change the marks are worked out again, in ms.
(define-option! 'git-gutter-delay 300 '())

;; The timer waiting to refresh a buffer's marks, and that buffer.
(define *git-gutter-timer* #f)
(define *git-gutter-timer-buffer* #f)

(define (git-gutter-file)
  "The (root path) of the file the current buffer visits, its path
   relative to the repository, if git tracks it; else #f."
  (let* ([path (and (buffer-path) (expand-path (buffer-path)))]
         [root (and path (git-root-of (directory-of path)))])
    (and root (starts-with? path (string-append root "/"))
         (let ([rel (substring path (+ (string-length root) 1) (string-length path))])
           (and (= (car (run-shell (git-command root (string-append "ls-files --error-unmatch -- "
                                                                       (shell-quote rel) " >/dev/null 2>&1"))
                                   ""))
                   0)
                (list root rel))))))

(define-minor-mode! 'git-gutter-mode
  (lambda ()
    (unless (buffer-local 'git-gutter-file) (set-buffer-local! 'git-gutter-file (git-gutter-file)))
    (set-change-marks! '())
    (git-gutter-refresh!))
  (lambda () (set-change-marks! #f) (set-buffer-local! 'git-gutter-version #f)))

(define-command! 'git-gutter-mode
  (lambda (count)
    "Turn git-gutter-mode on or off: bars beside the lines that differ from git."
    (toggle-minor-mode! 'git-gutter-mode)))


(define (git-gutter-on?)
  "Whether the current buffer is in git-gutter-mode."
  (and (memq 'git-gutter-mode (minor-modes)) #t))

(define (git-gutter-start!)
  "Turns git-gutter-mode on in the current buffer if git tracks its file."
  (let ([file (git-gutter-file)])
    (when file
      (set-buffer-local! 'git-gutter-file file)
      (minor-mode-on! 'git-gutter-mode)))
  void)

(define (git-gutter-marks hunks)
  "The change marks, as set-change-marks! takes them, for `hunks` from
   line-diff. An added or changed line's mark wins over a removal's."
  (let* ([removed (filter (lambda (h) (= (cadddr h) 0)) hunks)]
         [others (filter (lambda (h) (> (cadddr h) 0)) hunks)]
         [marks (foldl (lambda (h acc)
                         (let ([at (caddr h)])
                           (hash-insert acc (max 0 (- at 1))
                                        (list (if (> at 0) "▁" "▔") "git-gutter.removed"))))
                       (hash) removed)]
         [marks (foldl (lambda (h acc)
                         (let ([face (if (= (cadr h) 0) "git-gutter.added" "git-gutter.changed")])
                           (foldl (lambda (line acc) (hash-insert acc line (list "┃" face)))
                                  acc (range (caddr h) (+ (caddr h) (cadddr h))))))
                       marks others)])
    (map (lambda (line) (cons line (hash-ref marks line))) (sort (hash-keys->list marks) <))))

(define (git-gutter-show! id old)
  "Marks buffer `id`'s lines that differ from `old`, git's copy, if it
   is still in git-gutter-mode."
  (when (member id (buffer-list))
    (with-buffer id
      (lambda ()
        (when (git-gutter-on?)
          (let ([hunks (line-diff old (buffer-substring 0 (buffer-length)))])
            (set-buffer-local! 'git-gutter-hunks hunks)
            (set-change-marks! (git-gutter-marks hunks)))))))
  void)

(define (git-gutter-refresh!)
  "Reads the current buffer's file from git's index in the background,
   then marks the lines that differ from it."
  (let ([file (buffer-local 'git-gutter-file)] [id (current-buffer)] [out ""])
    (when (and file (git-gutter-on?))
      (set-buffer-local! 'git-gutter-version (buffer-version))
      (start-job! (git-command (car file) (string-append "show " (shell-quote (string-append ":" (cadr file)))
                                                         " 2>/dev/null"))
                  ""
                  (lambda (text stream) (when (equal? stream "stdout") (set! out (string-append out text))))
                  (lambda (code) (when (= code 0) (git-gutter-show! id out))))))
  void)

(define (git-gutter-after-command!)
  "After each command: once the text has changed since the marks were
   asked for, waits git-gutter-delay ms for typing to stop, then
   refreshes them."
  (when (and (git-gutter-on?) (not (equal? (buffer-local 'git-gutter-version) (buffer-version))))
    (when *git-gutter-timer* (cancel-timer! *git-gutter-timer*))
    (set-buffer-local! 'git-gutter-version (buffer-version))
    (set! *git-gutter-timer-buffer* (current-buffer))
    (set! *git-gutter-timer*
          (run-after! (option 'git-gutter-delay)
                      (lambda ()
                        (set! *git-gutter-timer* #f)
                        (let ([id *git-gutter-timer-buffer*])
                          (when (member id (buffer-list)) (with-buffer id git-gutter-refresh!)))))))
  void)

(add-hook! 'post-command git-gutter-after-command!)
(add-hook! 'after-save git-gutter-refresh!)
;; Shown again: the index may have changed, by staging or a commit.
(add-hook! 'buffer-enter git-gutter-refresh!)

(define (git-gutter-hunk-lines)
  "The first line of each changed block in the current buffer, in order:
   a removal's is the line its mark is on."
  (let ([lines (map (lambda (h) (if (= (cadddr h) 0) (max 0 (- (caddr h) 1)) (caddr h)))
                    (if (git-gutter-on?) (or (buffer-local 'git-gutter-hunks) '()) '()))])
    (let loop ([ls (sort lines <)] [acc '()])
      (cond [(null? ls) (reverse acc)]
            [(and (pair? acc) (= (car acc) (car ls))) (loop (cdr ls) acc)]
            [else (loop (cdr ls) (cons (car ls) acc))]))))

(define (git-gutter-next-hunk! count forward?)
  "Moves `count` changed blocks on (or back), to the first line of the
   block; as far as there are, or nowhere when there are none."
  (let* ([line (current-line)]
         [ahead (if forward?
                    (filter (lambda (l) (> l line)) (git-gutter-hunk-lines))
                    (reverse (filter (lambda (l) (< l line)) (git-gutter-hunk-lines))))])
    (if (null? ahead)
        (message "no more hunks")
        (let ([to (list-ref ahead (- (min (max 1 count) (length ahead)) 1))])
          (set-cursor! (line-start to)))))
  void)

(define-command! 'git-gutter-next-hunk
  (lambda (count)
    "Go to the next block of lines that differ from git (]h)."
    (git-gutter-next-hunk! count #t)))
(define-command! 'git-gutter-previous-hunk
  (lambda (count)
    "Go to the previous block of lines that differ from git ([h)."
    (git-gutter-next-hunk! count #f)))
(define-key! 'normal "]h" 'git-gutter-next-hunk "next hunk")
(define-key! 'normal "[h" 'git-gutter-previous-hunk "previous hunk")

;; Files opened from now on, and those open as the package loads.
(add-hook! 'buffer-open git-gutter-start!)
(for-each (lambda (id) (with-buffer id git-gutter-start!)) (buffer-list))
