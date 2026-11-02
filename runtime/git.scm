;;; git.scm -- a Magit-style interface to git.
;;;
;;; SPC g g (or M-x git-status) opens the status of the current file's repository:
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
;;; A commit message is edited in its own buffer: ZZ or C-c C-c commits,
;;; ZQ or C-c C-k cancels.
;;; :git ARGS runs any git command and shows what it printed.

;; How many recent commits the status buffer lists.
(define-option! 'git-recent-commits 10 '())
;; Whether the status buffer shows its main keys at the bottom of its window.
(define-option! 'git-status-hints #t '())

;;; Running git

(define (git-command root args)
  "The shell command that runs git with `args` in repository `root`."
  (string-append "git -C " (shell-quote root) " " args))

(define (git-output root args)
  "The output of a git command whose output is read; \"\" if it fails."
  (let ([r (run-shell (string-append (git-command root args) " 2>/dev/null") "")])
    (if (= (car r) 0) (cadr r) "")))

(define (git-do! root args . input)
  "Runs a git command that changes something, with `input` on its stdin.
   Shows git's complaint and returns #f if it fails."
  (let ([r (run-shell (git-command root args) (if (null? input) "" (car input)))])
    (or (= (car r) 0)
        (begin (message (string-append "git " args ": " (trim (cadr r)))) #f))))

(define (git-root-of dir)
  "The top of the git repository holding `dir`, or #f outside one."
  (let ([r (run-shell (string-append "git -C " (shell-quote dir) " rev-parse --show-toplevel 2>/dev/null") "")])
    (and (= (car r) 0) (trim (cadr r)))))

(define (git-current-root)
  "The repository of the current buffer: a git buffer's own, its file's,
   or the working directory's."
  (or (buffer-local 'git-root)
      (git-root-of (if (buffer-path) (directory-of (expand-path (buffer-path))) (current-dir)))))

;;; Reading the status

(define (git-status-name letter)
  "The word git status uses for the porcelain status `letter`.
   M is \"modified\", A \"new file\" and so on; anything unknown is
   \"changed\"."
  (cond [(equal? letter "M") "modified"] [(equal? letter "A") "new file"]
        [(equal? letter "D") "deleted"] [(equal? letter "R") "renamed"]
        [(equal? letter "C") "copied"] [(equal? letter "T") "typechange"]
        [else "changed"]))

(define (git-unquote path)
  "`path` as git means it, without the quoting git puts on unusual names.
   A quoted name loses its double quotes and has its C-style escapes
   decoded (see `git-unescape`). A name git didn't quote is returned as
   it is."
  (if (and (> (string-length path) 1) (starts-with? path "\"") (ends-with? path "\""))
      (let ([inner (substring path 1 (- (string-length path) 1))])
        (with-handler (lambda (e) inner) (git-unescape inner)))
      path))

(define (git-unescape text)
  "`text` with git's C-style backslash escapes decoded.
   These are \\t, \\n, \\\", \\\\ and the like, and octal escapes such as
   \\303\\251, which are bytes: a run of them spells a UTF-8 character.
   Raises an error when the bytes aren't valid UTF-8."
  (let* ([bytes (string->bytes text)]
         [n (bytes-length bytes)]
         [octal? (lambda (i) (and (< i n) (<= 48 (bytes-ref bytes i) 55)))]
         [digit (lambda (i) (- (bytes-ref bytes i) 48))]
         [named (lambda (b) (cond [(= b 110) 10] [(= b 116) 9] [(= b 114) 13] [(= b 97) 7]
                                  [(= b 98) 8] [(= b 102) 12] [(= b 118) 11] [else b]))])
    (let loop ([i 0] [acc '()])
      (cond
        [(>= i n) (bytes->string/utf8 (list->bytes (reverse acc)))]
        [(and (= (bytes-ref bytes i) 92) (octal? (+ i 1)) (octal? (+ i 2)) (octal? (+ i 3)))
         (loop (+ i 4) (cons (+ (* 64 (digit (+ i 1))) (* 8 (digit (+ i 2))) (digit (+ i 3))) acc))]
        [(and (= (bytes-ref bytes i) 92) (< (+ i 1) n))
         (loop (+ i 2) (cons (named (bytes-ref bytes (+ i 1))) acc))]
        [else (loop (+ i 1) (cons (bytes-ref bytes i) acc))]))))

(define (git-fields line n)
  "The first `n` space-separated fields of `line`, then the rest as one."
  (let loop ([i 0] [rest line] [acc '()])
    (let ([parts (split-once rest " ")])
      (if (or (= i n) (not (pair? parts)) (null? (cdr parts)))
          (reverse (cons rest acc))
          (loop (+ i 1) (cadr parts) (cons (car parts) acc))))))

(define (git-push st key entry)
  "`st` with `entry` added to the front of the list under `key`."
  (hash-insert st key (cons entry (hash-ref st key))))

(define (git-status-line st line)
  "Adds one line of `git status --porcelain=v2 --branch` to `st`."
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

(define (git-status root)
  "A hash: 'branch 'oid 'upstream 'ahead 'behind, and 'untracked
   'unstaged 'staged lists of (status path)."
  (let ([st (foldl (lambda (line st) (git-status-line st line))
                   (hash 'branch "" 'oid "" 'upstream #f 'ahead 0 'behind 0 'untracked '() 'unstaged '() 'staged '())
                   (text-lines (git-output root "status --porcelain=v2 --branch --untracked-files=all")))])
    (foldl (lambda (key st) (hash-insert st key (reverse (hash-ref st key)))) st '(untracked unstaged staged))))

(define (git-parse-diff text)
  "A file's diff as (header hunks): the lines before the first hunk, and
   each hunk as its lines, the @@ line first."
  (let loop ([lines (text-lines text)] [header '()] [hunks '()] [hunk #f])
    (cond
      [(null? lines)
       (list (reverse header) (reverse (if hunk (cons (reverse hunk) hunks) hunks)))]
      [(starts-with? (car lines) "@@")
       (loop (cdr lines) header (if hunk (cons (reverse hunk) hunks) hunks) (list (car lines)))]
      [hunk (loop (cdr lines) header hunks (cons (car lines) hunk))]
      [else (loop (cdr lines) (cons (car lines) header) hunks hunk)])))

(define (git-file-diff root section path)
  "The diff of `path` in `section`, parsed as (header hunks).
   The staged section diffs the index against HEAD, any other the
   working tree against the index. Runs git."
  (git-parse-diff
   (git-output root (string-append "diff --no-color --no-ext-diff" (if (eq? section 'staged) " --cached" "")
                                   " -- " (shell-quote path)))))

(define (git-diff-face line)
  "The face for diff `line`: added, removed, or #f for context."
  (cond [(starts-with? line "+") "diff.added"] [(starts-with? line "-") "diff.removed"] [else #f]))

;;; The status buffer

(define (git-key section path)
  "The key under which `section`'s `path` is remembered as expanded."
  (string-append (symbol->string section) ":" path))
(define (git-open? key)
  "Whether the file or section under `key` is expanded in this buffer."
  (hash-contains? (or (buffer-local 'git-expanded) (hash)) key))

(define (git-toggle-key! key)
  "Expands what `key` names if it is folded, and folds it if expanded."
  (let ([open (or (buffer-local 'git-expanded) (hash))])
    (set-buffer-local! 'git-expanded (if (hash-contains? open key) (hash-remove open key) (hash-insert open key #t)))))

(define (git-hunk-lines! root section path)
  "Draws each hunk of `path`'s diff in `section`, under its file.
   Every line remembers its hunk and position, so staging, discarding
   and visiting can act on it."
  (let loop ([hunks (cadr (git-file-diff root section path))] [i 0])
    (unless (null? hunks)
      (draw-line! (list (list (car (car hunks)) "diff.hunk")) (list 'hunk section path i))
      (let inner ([lines (cdr (car hunks))] [j 1])
        (unless (null? lines)
          (draw-line! (list (list (car lines) (git-diff-face (car lines)))) (list 'hunk-line section path i j))
          (inner (cdr lines) (+ j 1))))
      (loop (cdr hunks) (+ i 1)))))

(define (git-section! title section count)
  "Draws a section heading, `title` with its `count`, for `section`."
  (draw-line! (list (list title "git.section") (list (string-append " (" (number->string count) ")") "git.count"))
             (list 'section section)))

(define (git-files-section! root title section files)
  "Draws `section` of the status: its heading, then its files.
   Draws nothing when `files` is empty. The files are left out when
   the section is folded; an expanded file is followed by its hunks."
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
  "Each line git prints for `args`, split at its first tab into a pair.
   A line with no tab comes back as (line \"\")."
  (map (lambda (line) (let ([p (split-once line "\t")]) (if (and (pair? p) (pair? (cdr p))) p (list line ""))))
       (text-lines (git-output root args))))

(define (git-render-status! root)
  "Redraws the status buffer for `root`, like Magit's status.
   The head and upstream, the untracked, unstaged and staged files,
   the stashes and the `git-recent-commits` latest commits. Runs git."
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
    (draw-finish!)
    (set-footer! (git-status-footer))))

(define (git-refresh!)
  "Redraws the current git status or log buffer from the repository.
   Does nothing (#f) in a buffer that isn't one of them."
  (let ([root (buffer-local 'git-root)])
    (cond [(not root) #f]
          [(eq? (major-mode) 'git-status-mode) (git-render-status! root)]
          [(eq? (major-mode) 'git-log-mode) (git-render-log! root)])))

(define (git-buffer name mode root)
  "A git buffer called `name` for `root`, in `mode`."
  (let ([id (special-buffer name mode)] [here (current-buffer)])
    (switch-to-buffer! id)
    (unless (buffer-local 'git-root) (set-buffer-local! 'git-root root))
    (switch-to-buffer! here)
    id))

(define (git-status-buffer-name root)
  "The name of the status buffer for the repository at `root`."
  (string-append "*git " (file-name-of root) "*"))

(define (git-status!)
  "Shows the git status of the current buffer's repository.
   Reuses the repository's status buffer, refreshing it if it is
   already the current one; says so outside a repository."
  (let ([root (git-current-root)])
    (if (not root)
        (message "not in a git repository")
        (let ([id (git-buffer (git-status-buffer-name root) 'git-status-mode root)])
          (if (= id (current-buffer)) (git-refresh!) (display-buffer! id))))))

(define (git-back-to-status! root)
  "Back to the status buffer of `root`, refreshed, if there is one."
  (let ([id (list-find (lambda (id) (equal? (car (buffer-info id)) (git-status-buffer-name root))) (buffer-list))])
    (if id (if (= id (current-buffer)) (git-refresh!) (display-buffer! id)) (git-status!))))

;;; Acting on the item at the cursor

(define (git-root)
  "The repository the current git buffer belongs to."
  (buffer-local 'git-root))

(define (git-hunk-patch root section path i)
  "The patch for hunk `i` of `path`'s diff in `section`."
  (let ([diff (git-file-diff root section path)])
    (string-append (string-join (append (car diff) (list-ref (cadr diff) i)) "\n") "\n")))

(define (git-files-in section)
  "The paths of the files drawn in `section` of the status buffer."
  (let ([items (buffer-local 'line-items)])
    (let loop ([i 0] [acc '()])
      (if (>= i (vector-length items))
          (reverse acc)
          (let ([item (vector-ref items i)])
            (loop (+ i 1) (if (and item (eq? (car item) 'file) (eq? (cadr item) section))
                              (cons (caddr item) acc) acc)))))))

(define (git-paths paths)
  "`paths`, each shell-quoted, joined by spaces for a git command line."
  (string-join (map shell-quote paths) " "))

(define (git-stage!)
  "Stages what the cursor is on: a section, a file or one hunk.
   The untracked section adds its files, the unstaged one updates
   every tracked file. Refreshes the status."
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
  "Takes `paths` out of the index, back to how HEAD has them.
   Before the first commit, removes them from the index instead.
   Returns #f if git fails."
  (or (git-do! root (string-append "restore --staged -- " (git-paths paths)))
      ;; Before the first commit there is nothing to restore from.
      (git-do! root (string-append "rm --cached -q -- " (git-paths paths)))))

(define (git-unstage!)
  "Unstages what the cursor is on: the staged section, a file or a hunk.
   Refreshes the status."
  (let ([item (line-item)] [root (git-root)])
    (cond
      [(not item) (message "nothing to unstage here")]
      [(equal? item '(section staged)) (git-unstage-paths! root (git-files-in 'staged))]
      [(and (eq? (car item) 'file) (eq? (cadr item) 'staged)) (git-unstage-paths! root (list (caddr item)))]
      [(and (memq (car item) '(hunk hunk-line)) (eq? (cadr item) 'staged))
       (git-do! root "apply --cached -R --recount -" (git-hunk-patch root 'staged (caddr item) (cadddr item)))]
      [else (message "not staged")])
    (git-refresh!)))

(define (git-stage-all!)
  "Stages every change, untracked files included, and refreshes."
  (git-do! (git-root) "add -A") (git-refresh!))
(define (git-unstage-all!)
  "Unstages every staged file and refreshes the status."
  (let ([staged (git-files-in 'staged)])
    (unless (null? staged) (git-unstage-paths! (git-root) staged))
    (git-refresh!)))

(define (git-discard!)
  "Throws away what the cursor is on, after asking.
   Deletes an untracked file, restores a changed file (a staged one
   from HEAD, both index and working tree, which deletes a staged new
   file), reverses an unstaged hunk,
   or drops a stash. A staged hunk can't be discarded; unstage it
   first."
  (let ([item (line-item)] [root (git-root)])
    (cond
      [(not item) (message "nothing to discard here")]
      [(and (eq? (car item) 'file) (eq? (cadr item) 'untracked))
       (confirm! (string-append "Delete " (caddr item) "?")
                 (lambda ()
                   (let ([r (error-text (lambda () (delete-file! (string-append root "/" (caddr item)))))])
                     (git-refresh!)
                     (when r (message r)))))]
      [(and (eq? (car item) 'file) (eq? (cadr item) 'unstaged))
       (confirm! (string-append "Discard changes to " (caddr item) "?")
                 (lambda () (git-do! root (string-append "restore -- " (shell-quote (caddr item)))) (git-refresh!)))]
      ;; A new file isn't in HEAD, so restoring it removes it from the
      ;; index and the disk, as Magit's discard does.
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

(define (stash-item? item)
  "Whether line `item` is a stash in the status buffer."
  (and item (eq? (car item) 'stash)))

(define (git-toggle!)
  "Shows or hides the diff of the file at the cursor, or a section.
   On a hunk, folds its file's diff and leaves the cursor on the file.
   Untracked files have no diff to show."
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

(define (vector-map-file file)
  "The items with every line of a file's diff replaced by the file, so
   refreshing keeps the cursor on the file once its diff is folded."
  (list->vector (map (lambda (item) (if (and item (memq (car item) '(hunk hunk-line))
                                             (equal? (cadr item) (cadr file)) (equal? (caddr item) (caddr file)))
                                        file item))
                     (vector->list (buffer-local 'line-items)))))

(define (git-hunk-target root section path i j)
  "The line in the new file that line `j` of hunk `i` shows."
  (let* ([hunk (list-ref (cadr (git-file-diff root section path)) i)]
         [plus (cadr (split-whitespace (car hunk)))]                      ; +START,COUNT
         [start (string->number (car (split-many (substring plus 1) ",")))])
    (let loop ([lines (cdr hunk)] [k 1] [line start])
      (if (or (null? lines) (>= k j))
          line
          (loop (cdr lines) (+ k 1) (if (starts-with? (car lines) "-") line (+ line 1)))))))

(define (git-visit!)
  "Opens what the cursor is on: a file, a commit or a stash.
   On a hunk, opens the file at the line the hunk shows there."
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
  "Opens a buffer to write the commit message in; `amend?` amends HEAD.
   The message goes in COMMIT_EDITMSG, below which the staged changes
   (or HEAD's, when amending) are listed as # comments. Amending
   starts from HEAD's message. Without `amend?` and with nothing
   staged, only says so."
  (let* ([root (git-root)]
         [stat (git-output root "diff --cached --stat")])
    (if (and (not amend?) (equal? (trim stat) ""))
        (message "nothing staged to commit")
        (let* ([path (string-append (trim (git-output root "rev-parse --absolute-git-dir")) "/COMMIT_EDITMSG")]
               [previous (if amend? (trim (git-output root "log -1 --format=%B")) "")]
               [comment (lambda (line) (string-append "# " line))])
          (write-text-file! path
                            (string-append previous "\n\n"
                                           "# Write the message above. ZZ or C-c C-c commits, ZQ or C-c C-k cancels.\n"
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
  "Saves the commit message and commits, back to the status buffer.
   Comment lines are stripped. Shows git's summary line on success;
   on failure shows git's complaint and stays in the message."
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
  "Abandons the commit message and goes back to the status buffer."
  (let ([root (buffer-local 'git-root)] [id (current-buffer)])
    (git-back-to-status! root)
    (buffer-kill! id)
    (message "commit cancelled")))

;;; Log, diffs and commits shown

(define (git-render-log! root)
  "Redraws the log buffer: the last 300 commits of `root`, one a line.
   Each shows its short hash, age, author and subject; <ret> on one
   shows it."
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
  "Shows the log of the repository at `root` in its own buffer."
  (display-buffer! (git-buffer (string-append "*git log " (file-name-of root) "*") 'git-log-mode root))
  (git-render-log! root)
  (set-cursor! 0))

(define (git-show-text! root name text)
  "Shows `text` (a diff or a commit) in buffer `name`."
  (display-buffer! (git-buffer name 'git-diff-mode root))
  (set-buffer-contents! (if (equal? text "") "no changes\n" text))
  (set-cursor! 0))

(define (git-show! root hash)
  "Shows commit `hash` of `root`: its message, stat and patch."
  (git-show-text! root (string-append "*git show " hash "*")
                  (git-output root (string-append "show --stat -p --no-color --no-ext-diff " hash))))

(define (git-diff! staged?)
  "Shows the whole diff of the repository: staged if `staged?`, else
   unstaged."
  (let ([root (git-root)])
    (git-show-text! root (if staged? "*git diff --cached*" "*git diff*")
                    (git-output root (string-append "diff --no-color --no-ext-diff" (if staged? " --cached" ""))))))

;;; Branches, stashes, remotes

(define (git-branch-names root)
  "The branches of repository `root` to check out: local ones like main,
   then remote ones like origin/main. A remote's HEAD (which git
   shortens to a bare \"origin\") isn't a branch and is left out."
  (map (lambda (ref) (substring ref (if (starts-with? ref "refs/heads/") 11 13) (string-length ref)))
       (filter (lambda (ref) (or (starts-with? ref "refs/heads/")
                                 (and (starts-with? ref "refs/remotes/") (not (ends-with? ref "/HEAD")))))
               (text-lines (git-output root "for-each-ref '--format=%(refname)' refs/heads refs/remotes")))))

(define (git-checkout!)
  "Asks for a branch, local or remote, and checks it out.
   A remote branch like origin/x checks out x, which git sets up to
   track it."
  (let* ([root (git-root)]
         [branches (git-branch-names root)])
    (completing-read "Checkout: " branches
                     (lambda (name)
                       ;; origin/x checks out a local x tracking it.
                       (let ([local (if (member name (text-lines (git-output root "branch '--format=%(refname:short)'")))
                                        name
                                        (let ([p (split-once name "/")]) (if (and (pair? p) (pair? (cdr p))) (cadr p) name)))])
                         (when (git-do! root (string-append "checkout " (shell-quote local)))
                           (message (string-append "on " local)))
                         (git-refresh!))))))

(define (git-create-branch!)
  "Asks for a name, then creates that branch and checks it out."
  (let ([root (git-root)])
    (ask "New branch: " ""
         (lambda (name)
           (when (git-do! root (string-append "checkout -b " (shell-quote name)))
             (message (string-append "on new branch " name)))
           (git-refresh!)))))

(define (git-stash-ref)
  "The stash at the cursor, or stash@{0} when the cursor isn't on one."
  (let ([item (line-item)]) (if (stash-item? item) (cadr item) "stash@{0}")))

(define *git-process-log* '())  ; newest first

(define (git-job! root args)
  "Runs a git command that may take a while (it talks to a remote) in the
   background, refreshing the status when it is done."
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
  "Shows what the background git commands printed, the last 200 lines."
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
  "Binds each (key action) of `keys` in normal state in `mode`; a third
   element is the key's which-key label."
  (for-each (lambda (k) (apply define-mode-key! (cons mode (cons 'normal k)))) keys))

(define git-common-keys
  (list (list "gr" (lambda (n) (git-refresh!)) "refresh")
        (list "$" (lambda (n) (git-show-process!)))
        (list "<ret>" (lambda (n) (git-visit!)))))

;; The status buffer's keys as (key label action): bound from here, and
;; listed by ? and the footer from here, so they can't drift apart.
(define git-status-keys
  (list
    (list "<tab>" "diff" (lambda (n) (git-toggle!)))
    (list "<ret>" "visit" (lambda (n) (git-visit!)))
    (list "s" "stage" (lambda (n) (git-stage!)))
    (list "u" "unstage" (lambda (n) (git-unstage!)))
    (list "S" "stage all" (lambda (n) (git-stage-all!)))
    (list "U" "unstage all" (lambda (n) (git-unstage-all!)))
    (list "x" "discard" (lambda (n) (git-discard!)))
    (list "c" "commit" (lambda (n) (menu! "Commit" (list (list "c" "commit" (lambda () (git-commit! #f)))
                                                     (list "a" "amend" (lambda () (git-commit! #t)))
                                                     (list "e" "extend (amend, same message)"
                                                           (lambda () (git-do! (git-root) "commit --amend --no-edit") (git-refresh!)))))))
    (list "b" "branch" (lambda (n) (menu! "Branch" (list (list "b" "checkout" git-checkout!)
                                                     (list "c" "create and checkout" git-create-branch!)))))
    (list "l" "log" (lambda (n) (git-log! (git-root))))
    (list "d" "diff menu" (lambda (n) (menu! "Diff" (list (list "d" "unstaged" (lambda () (git-diff! #f)))
                                                   (list "s" "staged" (lambda () (git-diff! #t)))))))
    (list "z" "stash" (lambda (n) (menu! "Stash" (list (list "z" "stash changes" (lambda () (git-do! (git-root) "stash push") (git-refresh!)))
                                                    (list "p" "pop" (lambda () (git-do! (git-root) (string-append "stash pop " (git-stash-ref))) (git-refresh!)))
                                                    (list "a" "apply" (lambda () (git-do! (git-root) (string-append "stash apply " (git-stash-ref))) (git-refresh!)))))))
    (list "f" "fetch" (lambda (n) (menu! "Fetch" (list (list "f" "fetch" (lambda () (git-job! (git-root) "fetch")))
                                                    (list "a" "fetch all remotes" (lambda () (git-job! (git-root) "fetch --all")))))))
    (list "F" "pull" (lambda (n) (menu! "Pull" (list (list "F" "pull" (lambda () (git-job! (git-root) "pull")))
                                                   (list "r" "pull --rebase" (lambda () (git-job! (git-root) "pull --rebase")))))))
    (list "P" "push" (lambda (n) (menu! "Push" (list (list "P" "push" (lambda () (git-job! (git-root) "push")))
                                                   (list "u" "push, setting upstream" (lambda () (git-job! (git-root) "push -u origin HEAD")))))))
    (list "$" "git output" (lambda (n) (git-show-process!)))
    (list "gr" "refresh" (lambda (n) (git-refresh!)))
    (list "?" "keys" (lambda (n) (git-status-menu!)))))

;; The keys the status buffer's footer shows: a column each, a related
;; pair in it, the first on the top line.
(define git-status-hint-columns '(("s" "<tab>") ("u" "x") ("c" "b") ("F" "P") ("l" "?")))

(define (git-status-footer)
  "The status buffer's footer: two lines of keys and their labels, from
   git-status-keys, in the columns of git-status-hint-columns. In each
   column the keys are right-aligned and the labels left-aligned. The
   lines are on a band of git.footer, with a blank line of it above and
   below, padded past any window's width (the window cuts them); none
   with git-status-hints off."
  (define (label key) (cadr (list-find (lambda (k) (equal? (car k) key)) git-status-keys)))
  (define (widest strings) (apply max (map string-length strings)))
  (define (cell column row)
    (let ([key (list-ref column row)])
      (list (list (pad-left key (widest column)) "git.footer.key")
            (list (string-append " " (pad-right (label key) (widest (map label column)))) "git.footer"))))
  (define blank (list (list (make-string 300 #\space) "git.footer")))
  (define (line row)
    (append (list (list " " "git.footer"))
            (cdr (apply append (map (lambda (column) (cons (list "  " "git.footer") (cell column row)))
                                    git-status-hint-columns)))
            (list (list (make-string 300 #\space) "git.footer"))))
  (if (option 'git-status-hints) (list blank (line 0) (line 1) blank) '()))

(define (git-status-menu!)
  "Opens a menu of every status key, as Magit's ? does; the key pressed
   runs on the item at the cursor."
  (menu! "Git" (map (lambda (k) (list (car k) (cadr k) (lambda () ((caddr k) 1))))
                    (filter (lambda (k) (not (equal? (car k) "?"))) git-status-keys))))

(git-keys! 'git-status-mode (map (lambda (k) (list (car k) (caddr k) (cadr k))) git-status-keys))

(git-keys! 'git-log-mode git-common-keys)
(git-keys! 'git-diff-mode git-common-keys)
(git-keys! 'git-commit-mode
  (list (list "ZZ" (lambda (n) (git-commit-finish!)) "commit")
        (list "ZQ" (lambda (n) (git-commit-cancel!)) "cancel commit")))
;; And Magit's keys, in insert state too.
(for-each (lambda (state)
            (define-mode-key! 'git-commit-mode state "C-cC-c" (lambda args (git-commit-finish!)))
            (define-mode-key! 'git-commit-mode state "C-cC-k" (lambda args (git-commit-cancel!))))
          '(normal insert))
(define-mode-leader! 'git-commit-mode "c" (lambda (n) (git-commit-finish!)) "commit")
(define-mode-leader! 'git-commit-mode "k" (lambda (n) (git-commit-cancel!)) "cancel")

(define-command! 'git-status (lambda (count)
                               "Show the Magit-style status of the current file's repository."
                               (git-status!)))
(define-command! 'git-log
  (lambda (count)
    "Show the commit log of the current file's repository."
    (let ([root (git-current-root)])
      (if root (git-log! root) (message "not in a git repository")))))

(define-leader-group! "g" "git")
(define-leader! "gg" 'git-status "status")
(define-leader! "gl" 'git-log "log")

(define (git-run! args)
  "Runs git with `args` in the current file's repository and shows what
   it printed; with no arguments, shows the status."
  (let ([args (trim args)])
    (if (equal? args "")
        (git-status!)
        (let ([root (git-current-root)])
          (if (not root)
              (message "not in a git repository")
              (let ([r (run-shell (git-command root args) "")])
                (show-popup! (let ([lines (text-lines (cadr r))]) (if (null? lines) (list "(no output)") lines)))
                (git-refresh!)))))))

(define-command! 'git
  (lambda (count)
    "Run git with the arguments asked for, in the current file's repository.
     With none, show the status. :git log --oneline runs git log --oneline."
    (open-cmdline! "git " "" git-run! #f #f)))

;; The status refreshes whenever you come back to it.
(add-hook! 'buffer-enter (lambda () (when (eq? (major-mode) 'git-status-mode) (git-refresh!))))
