;;; file-tree.scm -- the project's folders as a tree down the left.
;;;
;;; The *file-tree* buffer shows the current buffer's project root (or the
;;; working directory) as a tree, and after it any roots added with P, in
;;; a window file-tree-width columns wide on the left of the frame. Dired
;;; stays the way to edit a directory as text; this is for finding your
;;; way around.
;;;
;;;   (use-package! 'file-tree)
;;;
;;;   SPC t e, M-x file-tree   open or close the tree
;;;   <ret>, <tab>         open or shut a folder; <ret> opens a file
;;;   H, I                 show or hide dotfiles, files git ignores
;;;   a                    add a file, or a folder (a name ending in /)
;;;   r                    rename or move the entry at the cursor
;;;   D                    delete it, after asking
;;;   P, X                 add a project as another root; remove one
;;;   R                    read the folders again
;;;   q                    close it
;;;   ?                    show or hide these keys
;;;
;;; In a git repository, changed entries show a letter after the name and
;;; a face on it: M changed, A added, U untracked, ! a conflict; a folder
;;; takes the face of the most serious change inside it. git status runs
;;; in the background, on opening, R, a, r, D, and saving a file.
;;;
;;; With file-tree-follow on (the default), switching to a buffer whose
;;; file is under a root moves the tree's cursor to it, opening the
;;; folders on the way; focus stays where it is.
;;;
;;; With file-tree-open-at-start set, the tree opens beside the first
;;; window when imp starts, the cursor left in that window.
;;;
;;; Each frame has at most one tree window, with a buffer of its own, so
;;; each daemon client has its own tree; the buffer goes when the tree
;;; closes. It isn't a popup (special.scm): a popup shares its side with
;;; the others and closes through popup handling, while the tree stays put
;;; beside them.

(define-option! 'file-tree-width 30 '())
(define-option! 'file-tree-show-hidden #f '())   ; dotfiles
(define-option! 'file-tree-show-ignored #f '())  ; files git ignores
(define-option! 'file-tree-open-at-start #f '())
(define-option! 'file-tree-follow #t '())  ; reveal the current buffer's file

(define *file-tree-buffer-name* "*file-tree*")

;; (tree-window origin buffer) for each open tree, every client's: the
;; window it was opened from, and its own buffer. Window ids aren't
;; reused, so another client's entries are never mistaken for ours.
(define *file-tree-origins* '())

;; The tree's keys, (key label procedure), bound at the end and shown by ?.
(define *file-tree-keys*
  (list (list "<ret>" "open a file, open or shut a folder" (lambda (n) (file-tree-visit!)))
        (list "<tab>" "open or shut a folder" (lambda (n) (file-tree-tab!)))
        (list "a" "add a file, or a folder/" (lambda (n) (file-tree-add-prompt!)))
        (list "r" "rename or move" (lambda (n) (file-tree-rename-prompt!)))
        (list "D" "delete" (lambda (n) (file-tree-delete-prompt!)))
        (list "H" "show or hide dotfiles" (lambda (n) (file-tree-flip! 'file-tree-show-hidden)))
        (list "I" "show or hide ignored files" (lambda (n) (file-tree-flip! 'file-tree-show-ignored)))
        (list "P" "add a project as a root" (lambda (n) (file-tree-add-root-prompt!)))
        (list "X" "remove this root" (lambda (n) (file-tree-remove-root!)))
        (list "R" "read the folders again" (lambda (n) (file-tree-refresh!)))
        (list "q" "close the tree" (lambda (n) (file-tree-close!)))
        (list "?" "show or hide these keys" (lambda (n) (file-tree-help!)))))

;; Whether ? is showing the tree's keys.
(define *file-tree-help* #f)

;; Git status by root: root -> (letters . folders), where letters maps a
;; changed file's path to "M", "A", "U" or "!", and folders maps a folder
;; holding changes to the most serious one's letter.
(define *file-tree-status* (hash))

;; The top of the git repository of each root, or #f outside one.
(define *file-tree-git-tops* (hash))

;; The folders shown open, path -> #t, kept while imp runs.
(define *file-tree-expanded* (hash))

(define (file-tree-entry)
  "This frame's open tree, as (tree-window origin buffer), or #f."
  (list-find (lambda (o) (and (memv (car o) (window-list)) (eqv? (window-buffer (car o)) (caddr o))))
             *file-tree-origins*))

(define (file-tree-window)
  "The window showing the tree in this frame, or #f."
  (let ([entry (file-tree-entry)]) (and entry (car entry))))

(define (file-tree-buffer)
  "The buffer of this frame's tree, or #f."
  (let ([entry (file-tree-entry)]) (and entry (caddr entry))))

(define (file-tree-new-buffer!)
  "A new tree buffer: *file-tree*, or *file-tree 2* and so on while
   another client's tree has that name. Tree buffers no open tree uses
   (left by a tree window closed with C-w c) go first."
  (set! *file-tree-origins* (filter (lambda (o) (memv (caddr o) (buffer-list))) *file-tree-origins*))
  (for-each (lambda (id)
              (when (and (eq? (with-buffer id major-mode) 'file-tree-mode)
                         (not (list-find (lambda (o) (eqv? (caddr o) id)) *file-tree-origins*)))
                (kill-buffer! id)))
            (buffer-list))
  (let loop ([n 1])
    (let ([name (if (= n 1) *file-tree-buffer-name* (string-append "*file-tree " (number->string n) "*"))])
      (if (list-find (lambda (id) (equal? (car (buffer-info id)) name)) (buffer-list))
          (loop (+ n 1))
          (buffer-new! name)))))

(define (file-tree-join dir name)
  "The path of `name` in directory `dir`."
  (if (equal? dir "/") (string-append "/" name) (string-append dir "/" name)))

(define (file-tree-root-for)
  "The root a tree opened now shows: the current buffer's project root,
   else the working directory."
  (or (project-root) (current-dir)))

(define (file-tree-name<? a b)
  "Whether entry name `a` sorts before `b`: alphabetical, case aside."
  (let ([la (string-downcase a)] [lb (string-downcase b)])
    (if (equal? la lb) (string<? a b) (string<? la lb))))

(define (file-tree-entries dir)
  "The entries of `dir` the tree shows, as (name directory? ignored?):
   directories first, then files, each alphabetical, without dotfiles
   and ignored files unless the options say to show them."
  (let ([entries (directory-entries dir)])
    (if (string? entries)
        (begin (message entries) '())
        (let* ([ignored (directory-ignored dir)]
               [shown (filter (lambda (e)
                                (and (or (option 'file-tree-show-hidden) (not (starts-with? (car e) ".")))
                                     (or (option 'file-tree-show-ignored) (not (member (car e) ignored)))))
                              (map (lambda (e) (list (car e) (cadr e) (and (member (car e) ignored) #t))) entries))]
               [by-name (lambda (es) (sort es (lambda (a b) (file-tree-name<? (car a) (car b)))))])
          (append (by-name (filter cadr shown)) (by-name (filter (lambda (e) (not (cadr e))) shown)))))))

(define (file-tree-expanded? path)
  "Whether folder `path` is shown open."
  (hash-contains? *file-tree-expanded* path))

(define (file-tree-rows dir depth root ignored)
  "The rows for the entries of `dir` (under `root`) and, under each open
   folder, its own, as (path directory? depth root ignored?). Everything
   in an `ignored` folder is ignored too."
  (apply append
         (map (lambda (e)
                (let* ([path (file-tree-join dir (car e))]
                       [gone (or ignored (caddr e))]
                       [row (list path (cadr e) depth root gone)])
                  (if (and (cadr e) (file-tree-expanded? path))
                      (cons row (file-tree-rows path (+ depth 1) root gone))
                      (list row))))
              (file-tree-entries dir))))

(define (file-tree-roots-file)
  "The file listing the roots added with P, in imp's state directory."
  (string-append (imp-state-dir) "/file-tree-roots"))

(define (file-tree-added-roots)
  "The roots added with P, in the order they were added."
  (with-handler (lambda (e) '())
                (if (file-exists? (file-tree-roots-file))
                    (filter (lambda (r) (not (equal? r ""))) (text-lines (read-file (file-tree-roots-file))))
                    '())))

(define (file-tree-save-roots! roots)
  "Saves `roots` as the added roots. An unwritable state directory only
   gets a message."
  (with-handler (lambda (e) (message (error-message e)))
                (write-text-file! (file-tree-roots-file) (apply string-append (map (lambda (r) (string-append r "\n")) roots))))
  void)

(define (file-tree-roots)
  "The tree buffer's roots: its first, then the added ones that are
   still directories, each once."
  (let ([first (buffer-local 'file-tree-root)])
    (cons first (let loop ([rs (file-tree-added-roots)] [seen (list first)])
                  (cond [(null? rs) '()]
                        [(or (member (car rs) seen) (not (file-directory? (car rs)))) (loop (cdr rs) seen)]
                        [else (cons (car rs) (loop (cdr rs) (cons (car rs) seen)))])))))

(define (file-tree-root-of path)
  "The root `path` is under (the deepest, if roots nest), or #f."
  (foldl (lambda (r best)
           (if (and (or (equal? path r) (starts-with? path (string-append r "/")))
                    (or (not best) (> (string-length r) (string-length best))))
               r
               best))
         #f
         (file-tree-roots)))

(define (file-tree-row-icon row)
  "The icon before `row`'s name, from the runtime's icon hooks (the
   nerd-icons package sets them), or #f: an open folder's, else what
   *dired-icon* gives the name (ending in / for a folder)."
  (let ([name (string-append (file-name-of (car row)) (if (cadr row) "/" ""))])
    (or (and (cadr row) (file-tree-expanded? (car row)) *open-folder-icon*)
        (*dired-icon* name))))

(define (file-tree-row-prefix row)
  "What comes before `row`'s name on its line: two columns a level, then
   its icon and a space if it has one. A root's line has none."
  (if (= (caddr row) 0)
      ""
      (let ([icon (file-tree-row-icon row)])
        (string-append (make-string (* 2 (caddr row)) #\space) (if icon (string-append icon " ") "")))))

(define (file-tree-row-text row)
  "The line that shows `row`: a root's name, or an entry's prefix and
   name, a directory's ending in /."
  (if (= (caddr row) 0)
      (file-name-of (car row))
      (string-append (file-tree-row-prefix row) (file-name-of (car row)) (if (cadr row) "/" ""))))

(define (file-tree-name-col line)
  "The column where the name on `line` of the tree starts."
  (let ([cols (buffer-local 'file-tree-name-cols)])
    (if (and cols (< line (vector-length cols))) (vector-ref cols line) 0)))

(define (file-tree-cursor-to! line)
  "Puts the cursor on the name on `line` of the tree, past its indent and
   icon."
  (set-cursor! (+ (line-start line) (file-tree-name-col line))))

(define (file-tree-render!)
  "Reads the roots' directories afresh and redraws the tree buffer (the
   current buffer), keeping the cursor on the line it was on."
  (let* ([rows (apply append (map (lambda (root) (cons (list root #t 0 root #f) (file-tree-rows root 1 root #f)))
                                  (file-tree-roots)))]
         [line (current-line)])
    (set-buffer-local! 'file-tree-lines (list->vector rows))
    (set-buffer-local! 'file-tree-name-cols (list->vector (map (lambda (r) (string-length (file-tree-row-prefix r))) rows)))
    (set-buffer-contents!
     (apply string-append (map (lambda (r) (string-append (file-tree-row-text r) "\n")) rows)))
    (set-buffer-unmodified!)
    (file-tree-decorate!)
    (file-tree-cursor-to! (min line (- (buffer-line-count) 1)))))

;;; Git status

(define (file-tree-severity letter)
  "How serious a status letter is: a conflict, then a change, then a new
   file."
  (cond [(equal? letter "!") 3] [(equal? letter "M") 2] [letter 1] [else 0]))

(define (file-tree-status-letter xy)
  "The tree's letter for git's two-letter porcelain status `xy`, or #f."
  (cond [(member xy '("DD" "AU" "UD" "UA" "DU" "AA" "UU")) "!"]
        [(equal? xy "??") "U"]
        [(equal? xy "!!") #f]
        [(memv (string-ref xy 0) '(#\A #\R #\C)) "A"]
        [else "M"]))

(define (file-tree-unquote path)
  "`path` as git prints it, without the quotes it puts round odd names."
  (if (and (> (string-length path) 1) (starts-with? path "\"") (ends-with? path "\""))
      (substring path 1 (- (string-length path) 1))
      path))

(define (file-tree-parse-status top root text)
  "The (letters . folders) of `git status --porcelain` output `text`, run
   at the repository's top `top`, for the paths under `root`."
  (let loop ([lines (text-lines text)] [letters (hash)] [folders (hash)])
    (if (null? lines)
        (cons letters folders)
        (let* ([line (car lines)]
               [letter (and (> (string-length line) 3) (file-tree-status-letter (substring line 0 2)))]
               [name (and letter (substring line 3 (string-length line)))]
               ;; A rename reads "old -> new": the new name is the one shown.
               [name (and name (let ([parts (split-many name " -> ")]) (if (> (length parts) 1) (last parts) name)))]
               [path (and name (file-tree-strip-slash (file-tree-join top (file-tree-unquote name))))])
          (if (and path (starts-with? path (string-append root "/")))
              (loop (cdr lines)
                    (hash-insert letters path letter)
                    (let up ([dir (directory-of path)] [fs folders])
                      (if (or (< (string-length dir) (string-length root)) (not (starts-with? dir root)))
                          fs
                          (let ([had (hash-try-get fs dir)])
                            (up (directory-of dir)
                                (if (> (file-tree-severity letter) (file-tree-severity had))
                                    (hash-insert fs dir letter)
                                    fs))))))
              (loop (cdr lines) letters folders))))))

(define (file-tree-git-top root)
  "The top of the git repository holding `root`, or #f, asked once."
  (if (hash-contains? *file-tree-git-tops* root)
      (hash-ref *file-tree-git-tops* root)
      (let ([top (git-root-of root)])
        (set! *file-tree-git-tops* (hash-insert *file-tree-git-tops* root top))
        top)))

(define (file-tree-git-refresh!)
  "Runs git status in the background for each of the tree buffer's (the
   current buffer's) roots, then redraws the statuses of every open tree."
  (for-each
   (lambda (root)
     (let ([top (file-tree-git-top root)] [out ""])
       (if (not top)
           (set! *file-tree-status* (hash-remove *file-tree-status* root))
           (start-job! (string-append (git-command top "status --porcelain --untracked-files=all") " 2>/dev/null") ""
                       (lambda (text stream) (when (equal? stream "stdout") (set! out (string-append out text))))
                       (lambda (code)
                         (when (= code 0)
                           (set! *file-tree-status*
                                 (hash-insert *file-tree-status* root (file-tree-parse-status top root out)))
                           (file-tree-decorate-all!)))))))
   (file-tree-roots))
  void)

(define (file-tree-row-status row)
  "The status letter of `row`: its own for a file, its folder's most
   serious for a folder, or #f."
  (let ([st (hash-try-get *file-tree-status* (list-ref row 3))])
    (and st (if (cadr row) (hash-try-get (cdr st) (car row)) (hash-try-get (car st) (car row))))))

(define (file-tree-row-face row)
  "The face of `row`'s name for its git status, or #f."
  (let ([letter (file-tree-row-status row)])
    (cond [(list-ref row 4) "file-tree.ignored"]
          [(equal? letter "!") "file-tree.conflict"]
          [(equal? letter "M") "file-tree.modified"]
          [(equal? letter "A") "file-tree.added"]
          [(equal? letter "U") "file-tree.untracked"]
          [else #f])))

(define (file-tree-face-of path)
  "The face the tree gives `path`'s name now, or #f: for tests and
   describe."
  (let ([line (file-tree-line-of path)])
    (and line (file-tree-row-face (vector-ref (buffer-local 'file-tree-lines) line)))))

(define (file-tree-decorate!)
  "Puts the git status faces and letters on the tree buffer's (the
   current buffer's) lines."
  (let ([lines (buffer-local 'file-tree-lines)])
    (for-each (lambda (l) (set-line-end-text! l #f "")) (or (buffer-local 'file-tree-lettered) '()))
    (buffer-highlight-clear! "file-tree-status")
    (let loop ([i 0] [lettered '()])
      (if (>= i (vector-length lines))
          (set-buffer-local! 'file-tree-lettered lettered)
          (let* ([row (vector-ref lines i)]
                 [face (and (> (caddr row) 0) (file-tree-row-face row))]
                 [letter (and (> (caddr row) 0) (not (cadr row)) (not (list-ref row 4)) (file-tree-row-status row))]
                 [start (+ (line-start i) (file-tree-name-col i))])
            (when face
              (buffer-highlight-add! "file-tree-status" start (+ (line-start i) (string-length (line-text i))) face))
            (when letter (set-line-end-text! i letter face))
            (loop (+ i 1) (if letter (cons i lettered) lettered))))))
  void)

(define (file-tree-decorate-all!)
  "Redraws the git statuses of every open tree, every client's."
  (for-each (lambda (o) (when (memv (caddr o) (buffer-list)) (with-buffer (caddr o) file-tree-decorate!)))
            *file-tree-origins*)
  void)

(define (file-tree-line-of path)
  "The tree buffer's line showing `path`, or #f."
  (let ([lines (buffer-local 'file-tree-lines)])
    (let loop ([i 0])
      (cond [(>= i (vector-length lines)) #f]
            [(equal? (car (vector-ref lines i)) path) i]
            [else (loop (+ i 1))]))))

(define (file-tree-reveal! root file)
  "Opens the folders between `root` and `file` (an absolute path), so
   the tree shows it. Does nothing for a file outside `root`."
  (when (starts-with? file (string-append root "/"))
    (let loop ([dir (directory-of file)])
      (when (and (> (string-length dir) (string-length root)) (starts-with? dir root))
        (set! *file-tree-expanded* (hash-insert *file-tree-expanded* dir #t))
        (loop (directory-of dir)))))
  void)

(define (file-tree-show! id root focus)
  "Shows the tree of `root` in tree buffer `id`, in the current window,
   with the cursor on `focus` (a path) if the tree shows it."
  (begin
    (go-to-buffer! id)
    (unless (eq? (major-mode) 'file-tree-mode) (set-major-mode! 'file-tree-mode))
    (unless (equal? (buffer-local 'file-tree-root) root)
      (set-buffer-local! 'file-tree-root root)
      (set-cursor! 0))
    (let ([under (and focus (file-tree-root-of focus))])
      (when under (file-tree-reveal! under focus)))
    (file-tree-render!)
    (file-tree-git-refresh!)
    (let ([line (and focus (file-tree-line-of focus))])
      (when line (file-tree-cursor-to! line)))))

(define (file-tree-open!)
  "Opens the tree down the left of the frame, file-tree-width columns
   wide, and moves the cursor into it."
  (let ([origin (current-window)]
        [root (file-tree-root-for)]
        [file (and (buffer-path) (absolute (buffer-path)))])
    (leave-pending-states!)
    (split-frame! "left" 0.2)
    (let ([id (file-tree-new-buffer!)])
      (set! *file-tree-origins* (cons (list (current-window) origin id) *file-tree-origins*))
      (after-window-change!)
      (file-tree-show! id root file))
    ;; Sized once its buffer's options (no line numbers) are in place.
    (resize-window! "width" (- (option 'file-tree-width) (window-text-width)))
    void))

(define (file-tree-close!)
  "Closes this frame's tree, and puts the cursor back in the window it
   was opened from."
  (let ([entry (file-tree-entry)])
    (when entry
      (let ([w (car entry)] [origin (cadr entry)] [id (caddr entry)])
        (file-tree-hide-help!)
        (leave-pending-states!)
        (close-window! w)
        (set! *file-tree-origins* (filter (lambda (o) (not (eqv? (car o) w))) *file-tree-origins*))
        (when (memv origin (window-list)) (focus-window! origin))
        (after-window-change!)
        (when (memv id (buffer-list)) (kill-buffer! id))))
    void))

(define (file-tree-row)
  "The row, (path directory? depth root), at the cursor's line of the
   tree."
  (let ([lines (buffer-local 'file-tree-lines)] [line (current-line)])
    (and lines (< line (vector-length lines)) (vector-ref lines line))))

(define (file-tree-root-row? row)
  "Whether `row` is a root's line."
  (= (caddr row) 0))

(define (file-tree-toggle-folder! path)
  "Opens folder `path` in the tree if it is shut, or shuts it."
  (set! *file-tree-expanded*
        (if (file-tree-expanded? path)
            (hash-remove *file-tree-expanded* path)
            (hash-insert *file-tree-expanded* path #t)))
  (file-tree-render!))

(define (file-tree-other-window)
  "The window a file opened from the tree goes to: the one the tree came
   from, else another window of the frame, else #f."
  (let* ([w (current-window)] [entry (assv w *file-tree-origins*)])
    (if (and entry (memv (cadr entry) (window-list)))
        (cadr entry)
        (list-find (lambda (o) (not (= o w))) (window-list)))))

(define (file-tree-visit!)
  "<ret>: opens or shuts the folder at the cursor, or opens the file in
   the window the tree came from, moving the cursor there."
  (let ([row (file-tree-row)])
    (cond [(or (not row) (file-tree-root-row? row)) void]
          [(cadr row) (file-tree-toggle-folder! (car row))]
          [else
           (let ([target (file-tree-other-window)])
             (if target
                 (begin (go-to-window! target) (open-file-buffer! (car row)) void)
                 (message "no window to open it in")))])))

(define (file-tree-refresh!)
  "Reads the folders again and redraws the tree, the cursor staying on
   the entry it was on if that is still shown."
  (let* ([row (file-tree-row)] [path (and row (car row))])
    (file-tree-render!)
    (file-tree-git-refresh!)
    (let ([line (and path (file-tree-line-of path))])
      (when line (file-tree-cursor-to! line)))
    void))

(define (file-tree-flip! name)
  "Turns option `name` (file-tree-show-hidden or -ignored) over, and
   redraws the tree."
  (set-option! name (not (option name)))
  (file-tree-refresh!)
  (message (string-append (if (eq? name 'file-tree-show-hidden) "dotfiles " "ignored files ")
                          (if (option name) "shown" "hidden"))))

(define (file-tree-relative path)
  "`path` relative to the root it is under (\"\" for a root itself)."
  (let ([root (or (file-tree-root-of path) "")])
    (if (starts-with? path (string-append root "/"))
        (substring path (+ (string-length root) 1) (string-length path))
        (if (equal? path root) "" path))))

(define (file-tree-strip-slash name)
  "`name` without a trailing /."
  (if (and (> (string-length name) 1) (ends-with? name "/")) (substring name 0 (- (string-length name) 1)) name))

(define (file-tree-target-dir)
  "The folder `a` adds to: the folder or root at the cursor, or a file's
   folder."
  (let ([row (file-tree-row)])
    (cond [(not row) (buffer-local 'file-tree-root)]
          [(cadr row) (car row)]
          [else (directory-of (car row))])))

(define (file-tree-go-to! path)
  "Redraws the tree with the folders down to `path` open, and the cursor
   on it."
  (let ([root (file-tree-root-of path)]) (when root (file-tree-reveal! root path)))
  (file-tree-render!)
  (file-tree-git-refresh!)
  (let ([line (file-tree-line-of path)])
    (when line (file-tree-cursor-to! line)))
  void)

(define (file-tree-add! dir name)
  "Makes `name` in folder `dir`: a folder if it ends in /, else an empty
   file, with any folders it needs on the way."
  (let* ([path (file-tree-join dir (file-tree-strip-slash name))]
         [folder? (ends-with? name "/")]
         [r (cond [(file-exists? path) (string-append (file-tree-relative path) " already exists")]
                  [folder? (make-directory! path)]
                  [else (let ([made (make-directory! (directory-of path))])
                          (if (string? made)
                              made
                              (with-handler (lambda (e) (error-message e)) (write-text-file! path "") #t)))])])
    (if (string? r)
        (message r)
        (begin (file-tree-go-to! path)
               (message (string-append "added " (file-tree-relative path) (if folder? "/" "")))))))

(define (file-tree-add-prompt!)
  "a: asks for a name to add in the folder at the cursor."
  (let* ([dir (file-tree-target-dir)] [rel (file-tree-relative dir)])
    (ask (string-append "Add in " (if (equal? rel "") (file-name-of dir) rel) "/: ") ""
         (lambda (name) (file-tree-add! dir name)))))

(define (file-tree-move-paths! from to)
  "Points buffers visiting `from`, or a file under it, at the same file
   under `to`, and moves the open folders under `from` the same way."
  (let ([moved (lambda (p)
                 (cond [(equal? p from) to]
                       [(starts-with? p (string-append from "/"))
                        (string-append to (substring p (string-length from) (string-length p)))]
                       [else #f]))])
    (for-each (lambda (id)
                (with-buffer id
                  (lambda ()
                    (let* ([p (buffer-path)] [new (and p (moved (absolute p)))])
                      (when new (set-buffer-path! new))))))
              (buffer-list))
    (set! *file-tree-expanded*
          (let loop ([keys (hash-keys->list *file-tree-expanded*)] [h *file-tree-expanded*])
            (if (null? keys)
                h
                (let ([new (moved (car keys))])
                  (loop (cdr keys) (if new (hash-insert (hash-remove h (car keys)) new #t) h))))))
    void))

(define (file-tree-rename! from text)
  "Renames or moves `from` to `text`, a path relative to its root,
   making the folders it needs."
  (let* ([to (file-tree-join (file-tree-root-of from) (file-tree-strip-slash text))]
         [made (make-directory! (directory-of to))]
         [r (if (string? made) made (rename-file! from to))])
    (if (string? r)
        (message r)
        (begin (file-tree-move-paths! from to)
               (file-tree-go-to! to)
               (message (string-append "renamed to " (file-tree-relative to)))))))

(define (file-tree-rename-prompt!)
  "r: asks for a new path for the entry at the cursor."
  (let ([row (file-tree-row)])
    (if (or (not row) (file-tree-root-row? row))
        (message "a root can't be renamed here")
        (ask "Rename to: " (file-tree-relative (car row))
             (lambda (text) (file-tree-rename! (car row) text))))))

(define (file-tree-delete-prompt!)
  "D: deletes the entry at the cursor, a folder with everything in it,
   once you say y."
  (let ([row (file-tree-row)])
    (if (or (not row) (file-tree-root-row? row))
        (message "a root can't be deleted here (X takes it out of the tree)")
        (let ([rel (file-tree-relative (car row))])
          (confirm! (string-append "Delete " rel (if (cadr row) "/ and everything in it?" "?"))
                    (lambda ()
                      (let ([r (delete-path! (car row))])
                        (if (string? r)
                            (message r)
                            (begin (file-tree-refresh!) (message (string-append "deleted " rel)))))))))))

(define (file-tree-add-root! dir)
  "Adds directory `dir` as a root after the others, remembered between
   sessions, and puts the cursor on it."
  (let ([root (file-tree-strip-slash (absolute dir))])
    (cond [(not (file-directory? root)) (message (string-append dir " is not a directory"))]
          [(member root (file-tree-roots)) (file-tree-go-to! root) (message (string-append (file-name-of root) " is already a root"))]
          [else (file-tree-save-roots! (append (filter (lambda (r) (not (equal? r root))) (file-tree-added-roots))
                                               (list root)))
                (file-tree-go-to! root)
                (message (string-append "added root " root))])))

(define (file-tree-add-root-prompt!)
  "P: asks for a root to add, from the remembered projects or typed."
  (let ([roots (file-tree-roots)])
    (completing-read "Add root: " (filter (lambda (p) (not (member p roots))) (known-projects))
                     file-tree-add-root!)))

(define (file-tree-remove-root!)
  "X: takes the added root at the cursor out of the tree; the directory
   stays. The first root stays too."
  (let ([row (file-tree-row)])
    (cond [(or (not row) (not (file-tree-root-row? row))) (message "X works on a root's line")]
          [(equal? (car row) (buffer-local 'file-tree-root)) (message "the first root stays")]
          [else (file-tree-save-roots! (filter (lambda (r) (not (equal? r (car row)))) (file-tree-added-roots)))
                (file-tree-refresh!)
                (message (string-append "removed root " (car row)))])))

(define (file-tree-tab!)
  "<tab>: opens or shuts the folder at the cursor."
  (let ([row (file-tree-row)])
    (when (and row (cadr row) (not (file-tree-root-row? row))) (file-tree-toggle-folder! (car row)))
    void))

(define (file-tree-hide-help!)
  "Takes down the popup of the tree's keys, if ? put it up."
  (when *file-tree-help*
    (set! *file-tree-help* #f)
    (set-popup! '()))
  void)

(define (file-tree-help!)
  "?: shows the tree's keys in a which-key popup, or hides it."
  (if *file-tree-help*
      (file-tree-hide-help!)
      (begin
        (set! *file-tree-help* #t)
        (show-which-key-popup! (which-key-table (map (lambda (k) (cons (key-label (car k)) (cadr k))) *file-tree-keys*))
                               "file tree")
        void)))

(define (file-tree-follow-current!)
  "Moves this frame's tree to the current buffer's file, if it is under
   one of the tree's roots: the folders down to it open, and the tree
   window's cursor on it, scrolled into view. Focus moves to the tree and
   back with focus-window!, which runs no hooks."
  (let ([entry (file-tree-entry)] [path (and (buffer-path) (absolute (buffer-path)))])
    (when (and entry path (option 'file-tree-follow) (not (eq? (major-mode) 'file-tree-mode)))
      (let ([here (current-window)])
        (focus-window! (car entry))
        (let ([root (file-tree-root-of path)])
          (when root
            (unless (file-tree-line-of path)
              (file-tree-reveal! root path)
              (file-tree-render!))
            (let ([line (file-tree-line-of path)] [top (window-top)] [rows (window-height)])
              (when line
                (file-tree-cursor-to! line)
                (when (or (< line top) (>= line (+ top rows)))
                  (set-window-top! (max 0 (- line (quotient rows 2)))))))))
        (focus-window! here))))
  void)

(define (file-tree-toggle!)
  "Opens the tree, or closes it if this frame shows one."
  (if (file-tree-window) (file-tree-close!) (file-tree-open!)))

(define-major-mode! 'file-tree-mode #f '()
  (lambda ()
    (set-buffer-read-only! #t)
    (set-local-option! 'number #f)
    (set-local-option! 'relativenumber #f)
    (set-local-option! 'signcolumn "no")
    (set-local-option! 'wrap #f)
    (buffer-highlight-pattern! "file-tree-dir" "^ *[^ ].*/$" "dired.directory")
    (buffer-highlight-pattern! "file-tree-hidden" "(^| )\\.[^ /]*/?$" "dired.hidden")))

(define-command! 'file-tree
  (lambda (count)
    "Open or close the file tree: the project's folders down the left."
    (file-tree-toggle!)))

(define-leader! "te" 'file-tree "file tree")

(for-each (lambda (k) (define-mode-key! 'file-tree-mode 'normal (car k) (caddr k) (cadr k)))
          *file-tree-keys*)

;; After init.scm, so the option set there counts.
(add-hook! 'startup
  (lambda ()
    (when (option 'file-tree-open-at-start)
      (let ([w (current-window)])
        (file-tree-open!)
        (go-to-window! w)))))

;; A click opens what it lands on, as <ret> does; one below the last
;; entry, kept on it by normal mode, doesn't.
(add-hook! 'mouse-click
  (lambda (offset)
    (when (and (eq? (major-mode) 'file-tree-mode) (= (offset->line offset) (current-line)))
      (file-tree-visit!))
    void))

(add-hook! 'buffer-enter file-tree-follow-current!)

;; A saved file under a tree's root changes its status.
(add-hook! 'after-save
  (lambda ()
    (let ([path (and (buffer-path) (absolute (buffer-path)))])
      (when path
        (for-each (lambda (o)
                    (when (memv (caddr o) (buffer-list))
                      (with-buffer (caddr o)
                        (lambda () (when (file-tree-root-of path) (file-tree-git-refresh!))))))
                  *file-tree-origins*)))))
