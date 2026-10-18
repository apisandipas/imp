;;; git.scm -- a Magit-style interface to git.
;;;
;;; SPC g g (or :Git) opens the status of the current file's repository:
;;; the branch, untracked, unstaged and staged files, stashes and recent
;;; commits. Act on whatever the cursor is on, a section, a file or a hunk:
;;;
;;;   <tab>   show or hide a file's diff (or a section)
;;;   s u     stage, unstage           x  discard (asks first)
;;;   S U     stage all, unstage all   <ret>  visit the file, commit or stash
;;;   c       commit menu: c commit, a amend, e extend
;;;   b       branch menu: b checkout, c create
;;;   l       log    d  diff menu      z  stash menu
;;;   f F P   fetch, pull, push (run in the background; $ shows output)
;;;   gr      refresh   q  leave   ?  these keys
;;;
;;; A commit message is edited in its own buffer: ZZ commits, ZQ cancels.
;;; :Git ARGS runs any git command and shows what it printed.

(define-option! 'git-recent-commits 10 '())

;;; Running git

(define (git-command root args)
  (string-append "git -C " (shell-quote root) " " args))

;; The output of a git command whose output is read; "" if it fails.
(define (git-output root args)
  (let ([r (run-shell (string-append (git-command root args) " 2>/dev/null") "")])
    (if (= (car r) 0) (cadr r) "")))

;; Runs a git command that changes something, with `input` on its stdin.
;; Shows git's complaint and returns #f if it fails.
(define (git-do! root args . input)
  (let ([r (run-shell (git-command root args) (if (null? input) "" (car input)))])
    (or (= (car r) 0)
        (begin (message (string-append "git " args ": " (trim (cadr r)))) #f))))

(define (git-root-of dir)
  (let ([r (run-shell (string-append "git -C " (shell-quote dir) " rev-parse --show-toplevel 2>/dev/null") "")])
    (and (= (car r) 0) (trim (cadr r)))))

;; The repository of the current buffer: a git buffer's own, its file's,
;; or the working directory's.
(define (git-current-root)
  (or (buffer-local 'git-root)
      (git-root-of (if (buffer-path) (directory-of (expand-path (buffer-path))) (current-dir)))))

;;; Reading the status

(define (git-status-name letter)
  (cond [(equal? letter "M") "modified"] [(equal? letter "A") "new file"]
        [(equal? letter "D") "deleted"] [(equal? letter "R") "renamed"]
        [(equal? letter "C") "copied"] [(equal? letter "T") "typechange"]
        [else "changed"]))

(define (git-unquote path)
  (if (and (> (string-length path) 1) (starts-with? path "\""))
      (substring path 1 (- (string-length path) 1))
      path))

;; The first `n` space-separated fields of `line`, then the rest as one.
(define (git-fields line n)
  (let loop ([i 0] [rest line] [acc '()])
    (let ([parts (split-once rest " ")])
      (if (or (= i n) (not (pair? parts)) (null? (cdr parts)))
          (reverse (cons rest acc))
          (loop (+ i 1) (cadr parts) (cons (car parts) acc))))))

(define (git-push st key entry) (hash-insert st key (cons entry (hash-ref st key))))

;; Adds one line of `git status --porcelain=v2 --branch` to `st`.
(define (git-status-line st line)
  (let ([kind (if (> (string-length line) 0) (substring line 0 1) "")])
    (cond
      [(starts-with? line "# branch.oid ") (hash-insert st 'oid (substring line 13))]
      [(starts-with? line "# branch.head ") (hash-insert st 'branch (substring line 14))]
      [(starts-with? line "# branch.upstream ") (hash-insert st 'upstream (substring line 18))]
      [(starts-with? line "# branch.ab ")
       (let ([ab (split-whitespace (substring line 12))])
         (hash-insert (hash-insert st 'ahead (string->number (substring (car ab) 1)))
                      'behind (string->number (substring (cadr ab) 1))))]
      [(equal? kind "?") (git-push st 'untracked (list "untracked" (git-unquote (substring line 2))))]
      [(member kind '("1" "2"))
       (let* ([fields (git-fields line (if (equal? kind "1") 8 9))]
              [xy (cadr fields)]
              [path (git-unquote (car (split-many (last fields) "\t")))]
              [x (substring xy 0 1)]
              [y (substring xy 1 2)]
              [st (if (equal? x ".") st (git-push st 'staged (list (git-status-name x) path)))])
         (if (equal? y ".") st (git-push st 'unstaged (list (git-status-name y) path))))]
      [(equal? kind "u") (git-push st 'unstaged (list "unmerged" (git-unquote (last (git-fields line 10)))))]
      [else st])))

;; A hash: 'branch 'oid 'upstream 'ahead 'behind, and 'untracked
;; 'unstaged 'staged lists of (status path).
(define (git-status root)
  (let ([st (foldl (lambda (line st) (git-status-line st line))
                   (hash 'branch "" 'oid "" 'upstream #f 'ahead 0 'behind 0 'untracked '() 'unstaged '() 'staged '())
                   (text-lines (git-output root "status --porcelain=v2 --branch --untracked-files=all")))])
    (foldl (lambda (key st) (hash-insert st key (reverse (hash-ref st key)))) st '(untracked unstaged staged))))

;; A file's diff as (header hunks): the lines before the first hunk, and
;; each hunk as its lines, the @@ line first.
(define (git-parse-diff text)
  (let loop ([lines (text-lines text)] [header '()] [hunks '()] [hunk #f])
    (cond
      [(null? lines)
       (list (reverse header) (reverse (if hunk (cons (reverse hunk) hunks) hunks)))]
      [(starts-with? (car lines) "@@")
       (loop (cdr lines) header (if hunk (cons (reverse hunk) hunks) hunks) (list (car lines)))]
      [hunk (loop (cdr lines) header hunks (cons (car lines) hunk))]
      [else (loop (cdr lines) (cons (car lines) header) hunks hunk)])))

(define (git-file-diff root section path)
  (git-parse-diff
   (git-output root (string-append "diff --no-color --no-ext-diff" (if (eq? section 'staged) " --cached" "")
                                   " -- " (shell-quote path)))))

(define (git-diff-face line)
  (cond [(starts-with? line "+") "diff.added"] [(starts-with? line "-") "diff.removed"] [else #f]))

;;; The status buffer

(define (git-key section path) (string-append (symbol->string section) ":" path))
(define (git-open? key) (hash-contains? (or (buffer-local 'git-expanded) (hash)) key))

(define (git-toggle-key! key)
  (let ([open (or (buffer-local 'git-expanded) (hash))])
    (set-buffer-local! 'git-expanded (if (hash-contains? open key) (hash-remove open key) (hash-insert open key #t)))))

(define (git-hunk-lines! root section path)
  (let loop ([hunks (cadr (git-file-diff root section path))] [i 0])
    (unless (null? hunks)
      (draw-line! (list (list (car (car hunks)) "diff.hunk")) (list 'hunk section path i))
      (let inner ([lines (cdr (car hunks))] [j 1])
        (unless (null? lines)
          (draw-line! (list (list (car lines) (git-diff-face (car lines)))) (list 'hunk-line section path i j))
          (inner (cdr lines) (+ j 1))))
      (loop (cdr hunks) (+ i 1)))))

(define (git-section! title section count)
  (draw-line! (list (list title "git.section") (list (string-append " (" (number->string count) ")") "git.count"))
             (list 'section section)))

(define (git-files-section! root title section files)
  (unless (null? files)
    (git-section! title section (length files))
    (unless (git-open? (git-key 'section (symbol->string section)))
      (for-each (lambda (f)
                  (draw-line! (list (list (pad-right (car f) 11) "git.status") (list (cadr f) #f))
                             (list 'file section (cadr f)))
                  (when (git-open? (git-key section (cadr f)))
                    (git-hunk-lines! root section (cadr f))))
                files))
    (draw-line! '() #f)))

(define (git-tab-separated root args)
  (map (lambda (line) (let ([p (split-once line "\t")]) (if (and (pair? p) (pair? (cdr p))) p (list line ""))))
       (text-lines (git-output root args))))

(define (git-render-status! root)
  (let* ([st (git-status root)]
         [branch (hash-ref st 'branch)]
         [subject (trim (git-output root "log -1 --format=%s"))]
         [stashes (git-tab-separated root "stash list --format=%gd%x09%s")]
         [commits (git-tab-separated root (string-append "log -n " (number->string (option 'git-recent-commits))
                                                         " --format=%h%x09%s"))])
    (draw-begin!)
    (draw-line! (list (list "Head:     " "git.head")
                     (list (if (equal? branch "(detached)") (substring (hash-ref st 'oid) 0 7) branch) "git.branch")
                     (list (if (equal? subject "") "  (no commits yet)" (string-append "  " subject)) #f))
               '(head))
    (when (hash-ref st 'upstream)
      (draw-line! (list (list "Upstream: " "git.head")
                       (list (hash-ref st 'upstream) "git.remote")
                       (list (cond [(and (= (hash-ref st 'ahead) 0) (= (hash-ref st 'behind) 0)) "  up to date"]
                                   [else (string-append "  ahead " (number->string (hash-ref st 'ahead))
                                                        ", behind " (number->string (hash-ref st 'behind)))])
                             "git.count"))
                 '(head)))
    (draw-line! '() #f)
    (git-files-section! root "Untracked files" 'untracked (hash-ref st 'untracked))
    (git-files-section! root "Unstaged changes" 'unstaged (hash-ref st 'unstaged))
    (git-files-section! root "Staged changes" 'staged (hash-ref st 'staged))
    (when (and (null? (hash-ref st 'untracked)) (null? (hash-ref st 'unstaged)) (null? (hash-ref st 'staged)))
      (draw-line! (list (list "Nothing to commit, working tree clean" "git.head")) #f)
      (draw-line! '() #f))
    (unless (null? stashes)
      (git-section! "Stashes" 'stashes (length stashes))
      (for-each (lambda (s) (draw-line! (list (list (car s) "git.hash") (list (string-append "  " (cadr s)) #f))
                                       (list 'stash (car s))))
                stashes)
      (draw-line! '() #f))
    (unless (null? commits)
      (draw-line! (list (list "Recent commits" "git.section")) (list 'section 'commits))
      (for-each (lambda (c) (draw-line! (list (list (car c) "git.hash") (list (string-append "  " (cadr c)) #f))
                                       (list 'commit (car c))))
                commits))
    (draw-finish!)))

(define (git-refresh!)
  (let ([root (buffer-local 'git-root)])
    (cond [(not root) #f]
          [(eq? (major-mode) 'git-status-mode) (git-render-status! root)]
          [(eq? (major-mode) 'git-log-mode) (git-render-log! root)])))

;; A git buffer called `name` for `root`, in `mode`.
(define (git-buffer name mode root)
  (let ([id (special-buffer name mode)] [here (current-buffer)])
    (switch-to-buffer! id)
    (unless (buffer-local 'git-root) (set-buffer-local! 'git-root root))
    (switch-to-buffer! here)
    id))

(define (git-status-buffer-name root) (string-append "*git " (file-name-of root) "*"))

(define (git-status!)
  (let ([root (git-current-root)])
    (if (not root)
        (message "not in a git repository")
        (let ([id (git-buffer (git-status-buffer-name root) 'git-status-mode root)])
          (if (= id (current-buffer)) (git-refresh!) (go-to-buffer! id))))))

;; Back to the status buffer of `root`, refreshed, if there is one.
(define (git-back-to-status! root)
  (let ([id (list-find (lambda (id) (equal? (car (buffer-info id)) (git-status-buffer-name root))) (buffer-list))])
    (if id (if (= id (current-buffer)) (git-refresh!) (go-to-buffer! id)) (git-status!))))

;;; Acting on the item at the cursor

(define (git-root) (buffer-local 'git-root))

;; The patch for hunk `i` of `path`'s diff in `section`.
(define (git-hunk-patch root section path i)
  (let ([diff (git-file-diff root section path)])
    (string-append (string-join (append (car diff) (list-ref (cadr diff) i)) "\n") "\n")))

(define (git-files-in section)
  (let ([items (buffer-local 'line-items)])
    (let loop ([i 0] [acc '()])
      (if (>= i (vector-length items))
          (reverse acc)
          (let ([item (vector-ref items i)])
            (loop (+ i 1) (if (and item (eq? (car item) 'file) (eq? (cadr item) section))
                              (cons (caddr item) acc) acc)))))))

(define (git-paths paths) (string-join (map shell-quote paths) " "))

(define (git-stage!)
  (let ([item (line-item)] [root (git-root)])
    (cond
      [(not item) (message "nothing to stage here")]
      [(equal? item '(section untracked)) (git-do! root (string-append "add -- " (git-paths (git-files-in 'untracked))))]
      [(equal? item '(section unstaged)) (git-do! root "add -u")]
      [(and (eq? (car item) 'file) (memq (cadr item) '(untracked unstaged)))
       (git-do! root (string-append "add -- " (shell-quote (caddr item))))]
      [(and (memq (car item) '(hunk hunk-line)) (eq? (cadr item) 'unstaged))
       (git-do! root "apply --cached --recount -" (git-hunk-patch root 'unstaged (caddr item) (cadddr item)))]
      [else (message "already staged")])
    (git-refresh!)))

(define (git-unstage-paths! root paths)
  (or (git-do! root (string-append "restore --staged -- " (git-paths paths)))
      ;; Before the first commit there is nothing to restore from.
      (git-do! root (string-append "rm --cached -q -- " (git-paths paths)))))

(define (git-unstage!)
  (let ([item (line-item)] [root (git-root)])
    (cond
      [(not item) (message "nothing to unstage here")]
      [(equal? item '(section staged)) (git-unstage-paths! root (git-files-in 'staged))]
      [(and (eq? (car item) 'file) (eq? (cadr item) 'staged)) (git-unstage-paths! root (list (caddr item)))]
      [(and (memq (car item) '(hunk hunk-line)) (eq? (cadr item) 'staged))
       (git-do! root "apply --cached -R --recount -" (git-hunk-patch root 'staged (caddr item) (cadddr item)))]
      [else (message "not staged")])
    (git-refresh!)))

(define (git-stage-all!) (git-do! (git-root) "add -A") (git-refresh!))
(define (git-unstage-all!)
  (let ([staged (git-files-in 'staged)])
    (unless (null? staged) (git-unstage-paths! (git-root) staged))
    (git-refresh!)))

(define (git-discard!)
  (let ([item (line-item)] [root (git-root)])
    (cond
      [(not item) (message "nothing to discard here")]
      [(and (eq? (car item) 'file) (eq? (cadr item) 'untracked))
       (confirm! (string-append "Delete " (caddr item) "?")
                 (lambda () (delete-file! (string-append root "/" (caddr item))) (git-refresh!)))]
      [(and (eq? (car item) 'file) (eq? (cadr item) 'unstaged))
       (confirm! (string-append "Discard changes to " (caddr item) "?")
                 (lambda () (git-do! root (string-append "restore -- " (shell-quote (caddr item)))) (git-refresh!)))]
      [(and (eq? (car item) 'file) (eq? (cadr item) 'staged))
       (confirm! (string-append "Discard staged and unstaged changes to " (caddr item) "?")
                 (lambda () (git-do! root (string-append "restore --staged --worktree -- " (shell-quote (caddr item))))
                         (git-refresh!)))]
      [(and (memq (car item) '(hunk hunk-line)) (eq? (cadr item) 'unstaged))
       (confirm! "Discard this hunk?"
                 (lambda () (git-do! root "apply -R --recount -" (git-hunk-patch root 'unstaged (caddr item) (cadddr item)))
                         (git-refresh!)))]
      [(stash-item? item)
       (confirm! (string-append "Drop " (cadr item) "?")
                 (lambda () (git-do! root (string-append "stash drop " (cadr item))) (git-refresh!)))]
      [else (message "can't discard that; unstage it first")])))

(define (stash-item? item) (and item (eq? (car item) 'stash)))

(define (git-toggle!)
  (let ([item (line-item)])
    (cond
      [(not item) #f]
      [(eq? (car item) 'section) (git-toggle-key! (git-key 'section (symbol->string (cadr item)))) (git-refresh!)]
      [(and (eq? (car item) 'file) (not (eq? (cadr item) 'untracked)))
       (git-toggle-key! (git-key (cadr item) (caddr item)))
       (git-refresh!)]
      [(memq (car item) '(hunk hunk-line))
       ;; Folds the file the hunk belongs to, landing on it.
       (git-toggle-key! (git-key (cadr item) (caddr item)))
       (let ([file (list 'file (cadr item) (caddr item))])
         (set-buffer-local! 'line-items (vector-map-file file))
         (git-refresh!))])))

;; The items with every line of a file's diff replaced by the file, so
;; refreshing keeps the cursor on the file once its diff is folded.
(define (vector-map-file file)
  (list->vector (map (lambda (item) (if (and item (memq (car item) '(hunk hunk-line))
                                             (equal? (cadr item) (cadr file)) (equal? (caddr item) (caddr file)))
                                        file item))
                     (vector->list (buffer-local 'line-items)))))

;; The line in the new file that line `j` of hunk `i` shows.
(define (git-hunk-target root section path i j)
  (let* ([hunk (list-ref (cadr (git-file-diff root section path)) i)]
         [plus (cadr (split-whitespace (car hunk)))]                      ; +START,COUNT
         [start (string->number (car (split-many (substring plus 1) ",")))])
    (let loop ([lines (cdr hunk)] [k 1] [line start])
      (if (or (null? lines) (>= k j))
          line
          (loop (cdr lines) (+ k 1) (if (starts-with? (car lines) "-") line (+ line 1)))))))

(define (git-visit!)
  (let ([item (line-item)] [root (git-root)])
    (cond
      [(not item) #f]
      [(eq? (car item) 'file) (open-file! (string-append root "/" (caddr item)))]
      [(memq (car item) '(hunk hunk-line))
       (let ([line (git-hunk-target root (cadr item) (caddr item) (cadddr item)
                                    (if (eq? (car item) 'hunk) 1 (list-ref item 4)))])
         (when (open-file! (string-append root "/" (caddr item)))
           (set-cursor! (line-first-nonblank (min (- line 1) (- (buffer-line-count) 1))))))]
      [(eq? (car item) 'commit) (git-show! root (cadr item))]
      [(stash-item? item) (git-show-text! root (string-append "*git " (cadr item) "*")
                                          (git-output root (string-append "stash show -p --no-color " (cadr item))))]
      [else #f])))

;;; Commits

(define (git-commit! amend?)
  (let* ([root (git-root)]
         [stat (git-output root "diff --cached --stat")])
    (if (and (not amend?) (equal? (trim stat) ""))
        (message "nothing staged to commit")
        (let* ([path (string-append (trim (git-output root "rev-parse --absolute-git-dir")) "/COMMIT_EDITMSG")]
               [previous (if amend? (trim (git-output root "log -1 --format=%B")) "")]
               [comment (lambda (line) (string-append "# " line))])
          (write-text-file! path
                            (string-append previous "\n\n"
                                           "# Write the message above. ZZ commits, ZQ cancels.\n"
                                           "# Lines starting with # are left out.\n#\n"
                                           (string-join (map comment (text-lines (if amend? (git-output root "show --stat --format= HEAD") stat))) "\n")
                                           "\n"))
          (when (open-file! path)
            (buffer-reload!)
            (set-major-mode! 'git-commit-mode)
            (set-buffer-local! 'git-root root)
            (set-buffer-local! 'git-amend amend?)
            (set-cursor! 0))))))

(define (git-commit-finish!)
  (let ([root (buffer-local 'git-root)] [path (buffer-path)] [id (current-buffer)])
    (run-ex! "w")
    (let ([r (run-shell (git-command root (string-append "commit --cleanup=strip"
                                                         (if (buffer-local 'git-amend) " --amend" "")
                                                         " -F " (shell-quote path)))
                        "")])
      (if (= (car r) 0)
          (begin
            (git-back-to-status! root)
            (buffer-kill! id)
            (message (car (text-lines (cadr r)))))
          (message (string-append "git commit: " (trim (cadr r))))))))

(define (git-commit-cancel!)
  (let ([root (buffer-local 'git-root)] [id (current-buffer)])
    (git-back-to-status! root)
    (buffer-kill! id)
    (message "commit cancelled")))

;;; Log, diffs and commits shown

(define (git-render-log! root)
  (draw-begin!)
  (for-each (lambda (line)
              (let ([f (split-many line "\t")])
                (when (= (length f) 4)
                  (draw-line! (list (list (car f) "git.hash") (list (string-append "  " (pad-right (cadr f) 14)) "git.count")
                                   (list (pad-right (caddr f) 18) "git.remote") (list (cadddr f) #f))
                             (list 'commit (car f))))))
            (text-lines (git-output root "log -n 300 --format=%h%x09%ar%x09%an%x09%s")))
  (when (null? *draw-lines*) (draw-line! (list (list "no commits yet" "git.head")) #f))
  (draw-finish!))

(define (git-log! root)
  (go-to-buffer! (git-buffer (string-append "*git log " (file-name-of root) "*") 'git-log-mode root))
  (git-render-log! root)
  (set-cursor! 0))

;; Shows `text` (a diff or a commit) in buffer `name`.
(define (git-show-text! root name text)
  (go-to-buffer! (git-buffer name 'git-diff-mode root))
  (set-buffer-contents! (if (equal? text "") "no changes\n" text))
  (set-cursor! 0))

(define (git-show! root hash)
  (git-show-text! root (string-append "*git show " hash "*")
                  (git-output root (string-append "show --stat -p --no-color --no-ext-diff " hash))))

(define (git-diff! staged?)
  (let ([root (git-root)])
    (git-show-text! root (if staged? "*git diff --cached*" "*git diff*")
                    (git-output root (string-append "diff --no-color --no-ext-diff" (if staged? " --cached" ""))))))

;;; Branches, stashes, remotes

(define (git-checkout!)
  (let* ([root (git-root)]
         [branches (text-lines (git-output root "branch -a --format=%(refname:short)"))])
    (completing-read "Checkout: " branches
                     (lambda (name)
                       ;; origin/x checks out a local x tracking it.
                       (let ([local (if (member name (text-lines (git-output root "branch --format=%(refname:short)")))
                                        name
                                        (let ([p (split-once name "/")]) (if (and (pair? p) (pair? (cdr p))) (cadr p) name)))])
                         (when (git-do! root (string-append "checkout " (shell-quote local)))
                           (message (string-append "on " local)))
                         (git-refresh!))))))

(define (git-create-branch!)
  (let ([root (git-root)])
    (ask "New branch: " ""
         (lambda (name)
           (when (git-do! root (string-append "checkout -b " (shell-quote name)))
             (message (string-append "on new branch " name)))
           (git-refresh!)))))

(define (git-stash-ref)
  (let ([item (line-item)]) (if (stash-item? item) (cadr item) "stash@{0}")))

(define *git-process-log* '())  ; newest first

;; Runs a git command that may take a while (it talks to a remote) in the
;; background, refreshing the status when it is done.
(define (git-job! root args)
  (message (string-append "git " args "..."))
  (set! *git-process-log* (cons (string-append "$ git " args) *git-process-log*))
  (start-job! (string-append "GIT_TERMINAL_PROMPT=0 " (git-command root args) " 2>&1") ""
              (lambda (text stream)
                (set! *git-process-log* (append (reverse (text-lines text)) *git-process-log*)))
              (lambda (code)
                (message (string-append "git " args (if (= code 0) ": done" (string-append ": failed (" (number->string code) "), $ shows why"))))
                (when (and (eq? (major-mode) 'git-status-mode) (equal? (buffer-local 'git-root) root))
                  (git-refresh!)))))

(define (git-show-process!)
  (show-popup! (if (null? *git-process-log*) (list "no git commands run yet")
                   (reverse (take *git-process-log* (min 200 (length *git-process-log*)))))))

;;; Menus and keys

(define-major-mode! 'git-status-mode 'special-mode '() #f)
(define-major-mode! 'git-log-mode 'special-mode '() #f)
(define-major-mode! 'git-diff-mode 'special-mode '()
  (lambda ()
    (buffer-highlight-pattern! "diff-added" "^+.*" "diff.added")
    (buffer-highlight-pattern! "diff-removed" "^-.*" "diff.removed")
    (buffer-highlight-pattern! "diff-hunk" "^@@.*" "diff.hunk")
    (buffer-highlight-pattern! "diff-header" "^diff --git.*" "diff.header")
    (buffer-highlight-pattern! "diff-commit" "^commit .*" "git.hash")))
(define-major-mode! 'git-commit-mode #f '()
  (lambda ()
    (buffer-highlight-pattern! "git-comment" "^#.*" "syntax.comment")))

(define (git-keys! mode keys)
  (for-each (lambda (k) (define-mode-key! mode 'normal (car k) (cadr k))) keys))

(define git-common-keys
  (list (list "gr" (lambda (n) (git-refresh!)))
        (list "$" (lambda (n) (git-show-process!)))
        (list "<ret>" (lambda (n) (git-visit!)))))

(git-keys! 'git-status-mode
  (append git-common-keys
   (list
    (list "<tab>" (lambda (n) (git-toggle!)))
    (list "s" (lambda (n) (git-stage!)))
    (list "u" (lambda (n) (git-unstage!)))
    (list "S" (lambda (n) (git-stage-all!)))
    (list "U" (lambda (n) (git-unstage-all!)))
    (list "x" (lambda (n) (git-discard!)))
    (list "c" (lambda (n) (menu! "Commit" (list (list "c" "commit" (lambda () (git-commit! #f)))
                                                     (list "a" "amend" (lambda () (git-commit! #t)))
                                                     (list "e" "extend (amend, same message)"
                                                           (lambda () (git-do! (git-root) "commit --amend --no-edit") (git-refresh!)))))))
    (list "b" (lambda (n) (menu! "Branch" (list (list "b" "checkout" git-checkout!)
                                                     (list "c" "create and checkout" git-create-branch!)))))
    (list "l" (lambda (n) (git-log! (git-root))))
    (list "d" (lambda (n) (menu! "Diff" (list (list "d" "unstaged" (lambda () (git-diff! #f)))
                                                   (list "s" "staged" (lambda () (git-diff! #t)))))))
    (list "z" (lambda (n) (menu! "Stash" (list (list "z" "stash changes" (lambda () (git-do! (git-root) "stash push") (git-refresh!)))
                                                    (list "p" "pop" (lambda () (git-do! (git-root) (string-append "stash pop " (git-stash-ref))) (git-refresh!)))
                                                    (list "a" "apply" (lambda () (git-do! (git-root) (string-append "stash apply " (git-stash-ref))) (git-refresh!)))))))
    (list "f" (lambda (n) (menu! "Fetch" (list (list "f" "fetch" (lambda () (git-job! (git-root) "fetch")))
                                                    (list "a" "fetch all remotes" (lambda () (git-job! (git-root) "fetch --all")))))))
    (list "F" (lambda (n) (menu! "Pull" (list (list "F" "pull" (lambda () (git-job! (git-root) "pull")))
                                                   (list "r" "pull --rebase" (lambda () (git-job! (git-root) "pull --rebase")))))))
    (list "P" (lambda (n) (menu! "Push" (list (list "P" "push" (lambda () (git-job! (git-root) "push")))
                                                   (list "u" "push, setting upstream" (lambda () (git-job! (git-root) "push -u origin HEAD")))))))
    (list "?" (lambda (n) (show-popup! (git-help-lines)))))))

(git-keys! 'git-log-mode git-common-keys)
(git-keys! 'git-diff-mode git-common-keys)
(git-keys! 'git-commit-mode
  (list (list "ZZ" (lambda (n) (git-commit-finish!)))
        (list "ZQ" (lambda (n) (git-commit-cancel!)))))
(define-mode-leader! 'git-commit-mode "c" (lambda (n) (git-commit-finish!)) "commit")
(define-mode-leader! 'git-commit-mode "k" (lambda (n) (git-commit-cancel!)) "cancel")

(define (git-help-lines)
  (list "<tab> show/hide diff   s stage   u unstage   x discard   S/U all"
        "<ret> visit            c commit  b branch    l log       d diff"
        "z stash   f fetch   F pull   P push   $ git output   gr refresh   q leave"))

(define-command! 'git-status (lambda (count) (git-status!)))
(define-command! 'git-log
  (lambda (count)
    (let ([root (git-current-root)])
      (if root (git-log! root) (message "not in a git repository")))))

(define-leader-group! "g" "git")
(define-leader! "gg" 'git-status "status")
(define-leader! "gl" 'git-log "log")

(define-ex! '("Git" "G")
  (lambda (ex)
    (let ([args (trim (ex-args ex))])
      (if (equal? args "")
          (git-status!)
          (let ([root (git-current-root)])
            (if (not root)
                (message "not in a git repository")
                (let ([r (run-shell (git-command root args) "")])
                  (show-popup! (let ([lines (text-lines (cadr r))]) (if (null? lines) (list "(no output)") lines)))
                  (git-refresh!))))))))

;; The status refreshes whenever you come back to it.
(add-hook! 'buffer-enter (lambda () (when (eq? (major-mode) 'git-status-mode) (git-refresh!))))
