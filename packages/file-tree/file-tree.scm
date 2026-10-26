;;; file-tree.scm -- the project's folders as a tree down the left.
;;;
;;; The *file-tree* buffer shows the current buffer's project root (or the
;;; working directory) as a tree, in a window file-tree-width columns wide
;;; on the left of the frame. Dired stays the way to edit a directory as
;;; text; this is for finding your way around.
;;;
;;;   (use-package! 'file-tree)
;;;
;;;   SPC t e, :FileTree   open or close the tree
;;;   <ret>, <tab>         open or shut a folder; <ret> opens a file
;;;   H, I                 show or hide dotfiles, files git ignores
;;;   a                    add a file, or a folder (a name ending in /)
;;;   r                    rename or move the entry at the cursor
;;;   D                    delete it, after asking
;;;   R                    read the folders again
;;;   q                    close it
;;;   ?                    show or hide these keys
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
        (list "R" "read the folders again" (lambda (n) (file-tree-refresh!)))
        (list "q" "close the tree" (lambda (n) (file-tree-close!)))
        (list "?" "show or hide these keys" (lambda (n) (file-tree-help!)))))

;; Whether ? is showing the tree's keys.
(define *file-tree-help* #f)

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
  "The entries of `dir` the tree shows, as (name directory?): directories
   first, then files, each alphabetical, without dotfiles and ignored
   files unless the options say to show them."
  (let ([entries (directory-entries dir)])
    (if (string? entries)
        (begin (message entries) '())
        (let* ([ignored (if (option 'file-tree-show-ignored) '() (directory-ignored dir))]
               [shown (filter (lambda (e)
                                (and (or (option 'file-tree-show-hidden) (not (starts-with? (car e) ".")))
                                     (not (member (car e) ignored))))
                              entries)]
               [by-name (lambda (es) (sort es (lambda (a b) (file-tree-name<? (car a) (car b)))))])
          (append (by-name (filter cadr shown)) (by-name (filter (lambda (e) (not (cadr e))) shown)))))))

(define (file-tree-expanded? path)
  "Whether folder `path` is shown open."
  (hash-contains? *file-tree-expanded* path))

(define (file-tree-rows dir depth)
  "The rows for the entries of `dir` and, under each open folder, its
   own, as (path directory? depth)."
  (apply append
         (map (lambda (e)
                (let* ([path (file-tree-join dir (car e))] [row (list path (cadr e) depth)])
                  (if (and (cadr e) (file-tree-expanded? path))
                      (cons row (file-tree-rows path (+ depth 1)))
                      (list row))))
              (file-tree-entries dir))))

(define (file-tree-row-text row)
  "The line that shows `row`: indented two columns a level, a directory's
   name ending in /."
  (string-append (make-string (* 2 (caddr row)) #\space)
                 (file-name-of (car row))
                 (if (cadr row) "/" "")))

(define (file-tree-cursor-to! line)
  "Puts the cursor on the name on `line` of the tree, past its indent."
  (let ([lines (buffer-local 'file-tree-lines)])
    (set-cursor! (+ (line-start line)
                    (if (and lines (< line (vector-length lines))) (* 2 (caddr (vector-ref lines line))) 0)))))

(define (file-tree-render!)
  "Reads the root's directories afresh and redraws the tree buffer (the
   current buffer), keeping the cursor on the line it was on."
  (let* ([root (buffer-local 'file-tree-root)]
         [rows (file-tree-rows root 1)]
         [line (current-line)])
    (set-buffer-local! 'file-tree-lines (list->vector (cons (list root #t 0) rows)))
    (set-buffer-contents!
     (apply string-append (file-name-of root) "\n"
            (map (lambda (r) (string-append (file-tree-row-text r) "\n")) rows)))
    (set-buffer-unmodified!)
    (file-tree-cursor-to! (min line (- (buffer-line-count) 1)))))

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
    (when focus (file-tree-reveal! root focus))
    (go-to-buffer! id)
    (unless (eq? (major-mode) 'file-tree-mode) (set-major-mode! 'file-tree-mode))
    (unless (equal? (buffer-local 'file-tree-root) root)
      (set-buffer-local! 'file-tree-root root)
      (set-cursor! 0))
    (file-tree-render!)
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
  "The row, (path directory? depth), at the cursor's line of the tree."
  (let ([lines (buffer-local 'file-tree-lines)] [line (current-line)])
    (and lines (< line (vector-length lines)) (vector-ref lines line))))

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
    (cond [(or (not row) (= (current-line) 0)) void]
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

(define (file-tree-root)
  "The root the tree buffer (the current buffer) shows."
  (buffer-local 'file-tree-root))

(define (file-tree-relative path)
  "`path` relative to the tree's root (\"\" for the root itself)."
  (let ([root (file-tree-root)])
    (if (starts-with? path (string-append root "/"))
        (substring path (+ (string-length root) 1) (string-length path))
        (if (equal? path root) "" path))))

(define (file-tree-strip-slash name)
  "`name` without a trailing /."
  (if (and (> (string-length name) 1) (ends-with? name "/")) (substring name 0 (- (string-length name) 1)) name))

(define (file-tree-target-dir)
  "The folder `a` adds to: the folder at the cursor, a file's folder, or
   the root on the first line."
  (let ([row (file-tree-row)])
    (cond [(or (not row) (= (current-line) 0)) (file-tree-root)]
          [(cadr row) (car row)]
          [else (directory-of (car row))])))

(define (file-tree-go-to! path)
  "Redraws the tree with the folders down to `path` open, and the cursor
   on it."
  (file-tree-reveal! (file-tree-root) path)
  (file-tree-render!)
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

(define (file-tree-follow! from to)
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
  "Renames or moves `from` to `text`, a path relative to the root,
   making the folders it needs."
  (let* ([to (file-tree-join (file-tree-root) (file-tree-strip-slash text))]
         [made (make-directory! (directory-of to))]
         [r (if (string? made) made (rename-file! from to))])
    (if (string? r)
        (message r)
        (begin (file-tree-follow! from to)
               (file-tree-go-to! to)
               (message (string-append "renamed to " (file-tree-relative to)))))))

(define (file-tree-rename-prompt!)
  "r: asks for a new path for the entry at the cursor."
  (let ([row (file-tree-row)])
    (if (or (not row) (= (current-line) 0))
        (message "the root can't be renamed here")
        (ask "Rename to: " (file-tree-relative (car row))
             (lambda (text) (file-tree-rename! (car row) text))))))

(define (file-tree-delete-prompt!)
  "D: deletes the entry at the cursor, a folder with everything in it,
   once you say y."
  (let ([row (file-tree-row)])
    (if (or (not row) (= (current-line) 0))
        (message "the root can't be deleted here")
        (let ([rel (file-tree-relative (car row))])
          (confirm! (string-append "Delete " rel (if (cadr row) "/ and everything in it?" "?"))
                    (lambda ()
                      (let ([r (delete-path! (car row))])
                        (if (string? r)
                            (message r)
                            (begin (file-tree-refresh!) (message (string-append "deleted " rel)))))))))))

(define (file-tree-tab!)
  "<tab>: opens or shuts the folder at the cursor."
  (let ([row (file-tree-row)])
    (when (and row (cadr row) (> (current-line) 0)) (file-tree-toggle-folder! (car row)))
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
    (buffer-highlight-pattern! "file-tree-hidden" "^ *\\.[^/]*/?$" "dired.hidden")))

(define-command! 'file-tree
  (lambda (count)
    "Open or close the file tree: the project's folders down the left."
    (file-tree-toggle!)))

(define-ex! "FileTree" (lambda (ex) (file-tree-toggle!)))
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
