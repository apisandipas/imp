;;; project.scm -- projects: a root directory found from a marker, files
;;; and buffers within it, search across it, and a quickfix list.
;;;
;;; A file's project is the nearest directory above it holding one of
;;; project-markers (tried in order, so the git root wins over a nested
;;; package). Projects you open files in are remembered.
;;;
;;;   SPC p f   find a file in the project      SPC p p  switch project
;;;   SPC p b   switch to a project buffer      SPC s p  search the project
;;;   :grep PATTERN   search, and jump to the first match, as in Vim
;;;   :copen    the list of matches; <ret> jumps to one
;;;   :cn :cp :cfirst :clast, ]q [q    step through the list
;;;
;;; Search uses grepprg; empty means rg if it's installed, else grep -rnI.

(define-option! 'project-markers '(".git" ".hg" ".jj" ".project") '())
(define-option! 'grepprg "" '())

(define (project-root-of dir)
  "The project root of directory `dir`, or #f."
  (let try ([markers (option 'project-markers)])
    (if (null? markers)
        #f
        (let up ([d dir])
          (cond [(file-exists? (string-append d "/" (car markers))) d]
                [(or (equal? d "/") (equal? d ".") (equal? d "")) (try (cdr markers))]
                [else (up (directory-of d))])))))

(define (absolute path)
  "`path` expanded (~ too) and made absolute from the working directory."
  (let ([p (expand-path path)]) (if (starts-with? p "/") p (string-append (current-dir) "/" p))))

(define (project-root)
  "The current buffer's project root (a browser buffer's directory counts),
   or #f."
  (project-root-of (cond [(buffer-local 'dired-dir) (buffer-local 'dired-dir)]
                         [(buffer-local 'git-root) (buffer-local 'git-root)]
                         [(buffer-path) (directory-of (absolute (buffer-path)))]
                         [else (current-dir)])))

;;; Remembered projects

(define (projects-file)
  "The file listing the remembered projects, in imp's state directory."
  (string-append (imp-state-dir) "/projects"))

(define (known-projects)
  "The roots of the remembered projects, most recently added first."
  (if (file-exists? (projects-file)) (text-lines (read-file (projects-file))) '()))

(define (remember-project! root)
  "Adds `root` to the front of the remembered projects, if it's new.
   Remembering is a convenience: an unwritable state directory isn't an
   error worth showing, so failures are ignored."
  (with-handler
   (lambda (e) #f)
   (let ([known (known-projects)])
     (unless (member root known)
       (write-text-file! (projects-file) (string-append (string-join (cons root known) "\n") "\n"))))))

(add-hook! 'buffer-open (lambda () (let ([root (and (buffer-path) (project-root))]) (when root (remember-project! root)))))

;;; Files and buffers

(define (project-find-file-in root)
  "Asks for a file anywhere under `root`, then opens it."
  (set! *completion-category* 'file)
  (completing-read (string-append "Find file in " (file-name-of root) ": ")
                   (list-files root 50000)
                   (lambda (file)
                     (open-file! (if (or (starts-with? file "/") (starts-with? file "~"))
                                     file
                                     (string-append root "/" file))))))

(define (with-project proc)
  "Calls `proc` with the current project's root, or says there is none."
  (let ([root (project-root)])
    (if root (proc root) (message "not in a project (no marker from project-markers above it)"))))

(define (under? path root)
  "Whether `path` is inside directory `root` (not `root` itself)."
  (starts-with? path (string-append root "/")))

(define-command! 'project-find-file
  (lambda (count)
    "Find a file in the current project and open it."
    (with-project project-find-file-in)))

(define-command! 'project-switch
  (lambda (count)
    "Pick a remembered project, then a file in it to open."
    (let ([known (filter file-directory? (known-projects))])
      (if (null? known)
          (message "no projects yet: open a file in one")
          (begin
            (set! *completion-category* 'project)
            (completing-read "Switch to project: " known project-find-file-in))))))

(define-command! 'project-switch-buffer
  (lambda (count)
    "Switch to a buffer visiting a file in the current project."
    (with-project
     (lambda (root)
       (let* ([ids (filter (lambda (id) (let ([p (cadr (buffer-info id))]) (and p (under? (absolute p) root))))
                           (buffer-list))]
              [label (lambda (id) (substring (absolute (cadr (buffer-info id))) (+ (string-length root) 1)
                                             (string-length (absolute (cadr (buffer-info id))))))])
         (set! *completion-category* 'file)
         (completing-read "Project buffer: " (map label ids)
                          (lambda (name)
                            (let ([hit (list-find (lambda (id) (equal? (label id) name)) ids)])
                              (if hit (go-to-buffer! hit) (message (string-append "no buffer " name)))))))))))

;;; Search and the quickfix list

(define *quickfix* '())       ; (path line col text), lines and columns from 1
(define *quickfix-index* 0)
(define *quickfix-title* "")

(define (grep-command pattern)
  "The shell command that searches the current directory for `pattern`.
   It is grepprg with the pattern added when that is set, else rg if
   it is installed, else grep -rnI. Output is path:line[:col]:text."
  (cond [(not (equal? (option 'grepprg) "")) (string-append (option 'grepprg) " " (shell-quote pattern))]
        [(= (car (run-shell "command -v rg" "")) 0)
         ;; The explicit . matters: with stdin not a terminal, rg searches stdin.
         (string-append "rg --vimgrep --no-heading --color=never --smart-case --sort=path -- " (shell-quote pattern) " .")]
        [else (string-append "grep -rnI --exclude-dir=.git -- " (shell-quote pattern) " .")]))

(define (digits? s)
  "Whether `s` is one or more ASCII digits and nothing else, like a line
   number. \"1e5\", \"1.5\" and \"\" aren't."
  (and (> (string-length s) 0) (andmap char-numeric-ascii? (string->list s))))

(define (parse-grep-line root line)
  "One output line, \"path:line:col:text\" or \"path:line:text\", as a quickfix
   entry with the path made absolute, or #f."
  (let ([a (split-once line ":")])
    (and (pair? a) (pair? (cdr a))
         (let ([b (split-once (cadr a) ":")])
           (and (pair? b) (pair? (cdr b)) (digits? (car b))
                (let* ([c (split-once (cadr b) ":")]
                       [col? (and (pair? c) (pair? (cdr c)) (digits? (car c)))]
                       [path (let ([p (car a)]) (if (starts-with? p "./") (substring p 2 (string-length p)) p))])
                  (list (if (starts-with? path "/") path (string-append root "/" path))
                        (string->number (car b))
                        (if col? (string->number (car c)) 1)
                        (if col? (cadr c) (cadr b)))))))))

(define (project-grep! root pattern)
  "Searches the project for `pattern`, filling the quickfix list; returns
   how many matches."
  (let* ([r (run-shell (string-append "cd " (shell-quote root) " && " (grep-command pattern)) "")]
         [entries (filter (lambda (x) x) (map (lambda (l) (parse-grep-line root l)) (text-lines (cadr r))))])
    (set! *quickfix* entries)
    (set! *quickfix-index* 0)
    (set! *quickfix-title* (string-append "grep " pattern))
    (when (and (null? entries) (> (car r) 1))
      (message (string-append "grep failed: " (trim (cadr r)))))
    (length entries)))

(define (quickfix-label e root)
  "Quickfix entry `e` as path:line: text, the path relative to `root`.
   Paths outside `root`, or with `root` #f, stay absolute."
  (let ([p (car e)])
    (string-append (if (and root (under? p root)) (substring p (+ (string-length root) 1) (string-length p)) p)
                   ":" (number->string (cadr e)) ": " (trim (cadddr e)))))

(define (quickfix-go! i)
  "Jumps to entry `i` of the list."
  (if (null? *quickfix*)
      (message "E42: No Errors")
      (let ([i (clamp i 0 (- (length *quickfix*) 1))])
        (set! *quickfix-index* i)
        (let ([e (list-ref *quickfix* i)])
          (record-jump!)
          (when (open-file! (car e))
            (set-cursor! (min (line-col->offset (clamp (- (cadr e) 1) 0 (last-line)) (- (caddr e) 1))
                              (line-end (clamp (- (cadr e) 1) 0 (last-line)))))
            (message (string-append "(" (number->string (+ i 1)) " of " (number->string (length *quickfix*)) ") "
                                    (trim (cadddr e)))))))))

(define (quickfix-step! n)
  "Moves `n` entries along the quickfix list (back when negative).
   Like Vim's :cnext and :cprevious, says E553 instead of going past
   either end."
  (cond [(null? *quickfix*) (message "E42: No Errors")]
        [(and (> n 0) (>= (+ *quickfix-index* n) (length *quickfix*))) (message "E553: No more items")]
        [(and (< n 0) (< (+ *quickfix-index* n) 0)) (message "E553: No more items")]
        [else (quickfix-go! (+ *quickfix-index* n))]))

(define (quickfix-open!)
  "Shows the quickfix list in the *grep* buffer, like Vim's :copen.
   The cursor starts on the current entry; <ret> on a line jumps there."
  (let ([root (project-root)])
    (display-buffer! (special-buffer "*grep*" 'grep-mode))
    (draw-begin!)
    (draw-line! (list (list (string-append *quickfix-title* " (" (number->string (length *quickfix*)) " matches)")
                            "git.section"))
                #f)
    (let loop ([es *quickfix*] [i 0])
      (unless (null? es)
        (let* ([e (car es)] [label (quickfix-label e root)] [head (car (split-once label ": "))])
          (draw-line! (list (list head "grep.location") (list (substring label (string-length head) (string-length label)) #f))
                      (list 'quickfix i)))
        (loop (cdr es) (+ i 1))))
    (draw-finish!)
    (set-cursor! (line-start (min (+ *quickfix-index* 1) (last-line))))))

(define (search-project! pattern)
  "Searches the current project for `pattern` and lists the matches."
  (with-project
   (lambda (root)
     (let ([n (project-grep! root pattern)])
       (if (= n 0) (message (string-append "no matches for " pattern)) (quickfix-open!))))))

(define-major-mode! 'grep-mode 'special-mode '() #f)
(define-mode-key! 'grep-mode 'normal "<ret>"
  (lambda (n)
    (let ([item (line-item)])
      (when (and item (eq? (car item) 'quickfix)) (quickfix-go! (cadr item))))))

(define-command! 'search-project
  (lambda (count)
    "Search the project for a pattern (the word at the cursor to start)."
    (ask "Search project: " (word-at-cursor-or-empty) search-project!)))

(define (word-at-cursor-or-empty)
  "The word the cursor is on, or \"\" when it isn't on a word character."
  (let ([c (buffer-char-at (cursor))])
    (if (and c (= (char-class c) 1))
        (let ([start (run-start (cursor) char-class (line-start (current-line)))]
              [end (run-end (cursor) char-class (line-end (current-line)))])
          (buffer-substring start end))
        "")))

;; :grep PATTERN jumps to the first match (:grep! doesn't), as in Vim.
(define-ex! '("gr" "grep")
  (lambda (ex)
    (let ([pattern (trim (ex-args ex))])
      (if (equal? pattern "")
          (message "usage: :grep PATTERN")
          (with-project
           (lambda (root)
             (let ([n (project-grep! root pattern)])
               (cond [(= n 0) (message (string-append "no matches for " pattern))]
                     [(ex-bang? ex) (message (string-append (number->string n) " matches; :copen lists them"))]
                     [else (quickfix-go! 0)]))))))))
(define-ex! '("cope" "copen") (lambda (ex) (quickfix-open!)))
(define-ex! '("cn" "cnext") (lambda (ex) (quickfix-step! 1)))
(define-ex! '("cp" "cprevious" "cN" "cNext") (lambda (ex) (quickfix-step! -1)))
(define-ex! '("cfir" "cfirst" "cr" "crewind") (lambda (ex) (quickfix-go! 0)))
(define-ex! '("cla" "clast") (lambda (ex) (quickfix-go! (- (length *quickfix*) 1))))
(define-ex! '("cc") (lambda (ex) (quickfix-go! (if (equal? (trim (ex-args ex)) "") *quickfix-index*
                                                    (- (or (string->number (trim (ex-args ex))) 1) 1)))))
(define-key! 'normal "]q" (lambda (count) (quickfix-step! count)))
(define-key! 'normal "[q" (lambda (count) (quickfix-step! (- count))))

(define-leader-group! "p" "project")
(define-leader! "pf" 'project-find-file "find file")
(define-leader! "pp" 'project-switch "switch project")
(define-leader! "pb" 'project-switch-buffer "project buffer")
(define-leader! "sp" 'search-project "search project")
