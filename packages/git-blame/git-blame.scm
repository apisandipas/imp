;;; git-blame.scm -- the cursor's line's last commit after the line, as
;;; GitLens, gitsigns' current_line_blame and blamer.el show it.
;;;
;;;   (use-package! 'git-blame)
;;;
;;; git-blame-mode turns on in every buffer visiting a file in a git
;;; repository. SPC g b or M-x git-blame-mode turns it off and on in a buffer.
;;;
;;; Once the cursor rests git-blame-delay ms on a line in normal state,
;;; `git blame --contents -` runs in the background on the buffer's text
;;; as it is, and `git show` words the commit as git would; the line then
;;; ends with "Author, 3 days ago • Subject" in the git-blame face.
;;; Moving off the line, a change or insert state hides it.

;; How long the cursor rests on a line before its blame shows, in ms.
(define-option! 'git-blame-delay 500 '())

;; What is shown, as (buffer line version), and the timer waiting to.
(define *git-blame-shown* #f)
(define *git-blame-timer* #f)
;; Where a blame is wanted while waiting for the timer or git.
(define *git-blame-waiting* #f)
;; Commit hash -> its "Author, age • Subject".
(define *git-blame-commits* (hash))

;; Like comments, unless the user's config set it.
(unless (face-spec "git-blame") (set-face! "git-blame" (or (face-spec "syntax.comment") "")))

(define (git-blame-file?)
  "Whether the current buffer visits a file in a git repository."
  (and (buffer-path) (git-root-of (directory-of (expand-path (buffer-path)))) #t))

(define-minor-mode! 'git-blame-mode (lambda () (git-blame-update!)) (lambda () (git-blame-hide!)))

(define-command! 'git-blame-mode
  (lambda (count)
    "Turn git-blame-mode on or off: the cursor's line's last commit after it."
    (toggle-minor-mode! 'git-blame-mode)))

(define-leader! "gb" 'git-blame-mode "blame")

(define (git-blame-start!)
  "Turns git-blame-mode on in the current buffer if it visits a file in
   a git repository."
  (when (git-blame-file?) (minor-mode-on! 'git-blame-mode)))


(define (git-blame-here)
  "Where the cursor is, as (buffer line version)."
  (list (current-buffer) (current-line) (buffer-version)))

(define (git-blame-hide!)
  "Takes away the blame shown, if any, and stops waiting to show one."
  (when *git-blame-timer* (cancel-timer! *git-blame-timer*) (set! *git-blame-timer* #f))
  (when *git-blame-shown*
    (let ([shown *git-blame-shown*])
      (set! *git-blame-shown* #f)
      (when (member (car shown) (buffer-list))
        (with-buffer (car shown) (lambda () (set-line-end-text! (cadr shown) #f "git-blame"))))))
  void)

(define (git-blame-wanted?)
  "Whether the current buffer should show its cursor line's blame now."
  (and (memq 'git-blame-mode (minor-modes)) (eq? *mode* 'normal)))

(define (git-blame-update!)
  "After each command: keeps the blame while the cursor stays on its
   line and the text is unchanged, and otherwise hides it and waits
   git-blame-delay ms to show the new line's."
  (let ([here (git-blame-here)])
    (unless (and (equal? here (or *git-blame-shown* *git-blame-waiting*)) (git-blame-wanted?))
      (git-blame-hide!)
      (set! *git-blame-waiting* #f)
      (when (git-blame-wanted?)
        (set! *git-blame-waiting* here)
        (set! *git-blame-timer*
              (run-after! (option 'git-blame-delay)
                          (lambda () (set! *git-blame-timer* #f) (git-blame-run! here)))))))
  void)

(define (git-blame-show! here text)
  "Shows `text` after the line of `here`, if the cursor is still there."
  (when (and (equal? (git-blame-here) here) (git-blame-wanted?))
    (set-line-end-text! (cadr here) text "git-blame")
    (set! *git-blame-shown* here))
  void)

(define (git-blame-run! here)
  "Blames the line of `here` in the background, then shows the commit."
  (when (and (equal? (git-blame-here) here) (git-blame-wanted?))
    (let ([root (git-root-of (directory-of (expand-path (buffer-path))))]
          [out ""])
      (when root
        (start-job!
         (string-append (git-command root "blame --porcelain -L ")
                        (number->string (+ 1 (cadr here))) ",+1 --contents - -- "
                        (shell-quote (expand-path (buffer-path))) " 2>/dev/null")
         (buffer-substring 0 (buffer-length))
         (lambda (text stream) (when (equal? stream "stdout") (set! out (string-append out text))))
         (lambda (code)
           (let ([hash (and (= code 0) (> (string-length out) 40) (substring out 0 40))])
             (cond
               [(not hash) #f]
               [(equal? hash "0000000000000000000000000000000000000000") (git-blame-show! here "Not committed yet")]
               [(hash-try-get *git-blame-commits* hash) => (lambda (t) (git-blame-show! here t))]
               [else (git-blame-describe! root hash here)])))))))
  void)

(define (git-blame-describe! root hash here)
  "Words commit `hash` as \"Author, 3 days ago • Subject\", in git's
   relative date, remembers it and shows it at `here`."
  (let ([out ""])
    (start-job! (string-append (git-command root "show -s --format=%an%x09%ar%x09%s ") hash " 2>/dev/null") ""
                (lambda (text stream) (when (equal? stream "stdout") (set! out (string-append out text))))
                (lambda (code)
                  (let ([parts (split-many (trim out) "\t")])
                    (when (and (= code 0) (= (length parts) 3))
                      (let ([text (string-append (car parts) ", " (cadr parts) " • " (caddr parts))])
                        (set! *git-blame-commits* (hash-insert *git-blame-commits* hash text))
                        (git-blame-show! here text))))))))

(add-hook! 'post-command git-blame-update!)
;; A file on the command line, before any key.
(add-hook! 'startup git-blame-update!)

;; Files opened from now on, and those open as the package loads.
(add-hook! 'buffer-open git-blame-start!)
(for-each (lambda (id) (with-buffer id git-blame-start!)) (buffer-list))
