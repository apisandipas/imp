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
;;;   q                    close it
;;;
;;; Each frame has at most one tree window. It isn't a popup (special.scm):
;;; a popup shares its side with the others and closes through popup
;;; handling, while the tree stays put beside them.

(define-option! 'file-tree-width 30 '())
(define-option! 'file-tree-show-hidden #f '())   ; dotfiles
(define-option! 'file-tree-show-ignored #f '())  ; files git ignores

(define *file-tree-buffer-name* "*file-tree*")

;; (tree-window . origin): the window each open tree was opened from.
(define *file-tree-origins* '())

;; The folders shown open, path -> #t, kept while imp runs.
(define *file-tree-expanded* (hash))

(define (file-tree-buffer)
  "The *file-tree* buffer's id, or #f if there is none."
  (list-find (lambda (id) (equal? (car (buffer-info id)) *file-tree-buffer-name*)) (buffer-list)))

(define (file-tree-window)
  "The window showing the tree in this frame, or #f."
  (let ([id (file-tree-buffer)])
    (and id (list-find (lambda (w) (eqv? (window-buffer w) id)) (window-list)))))

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
    (set-cursor! (line-start (min line (- (buffer-line-count) 1))))))

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

(define (file-tree-show! root focus)
  "Shows the tree of `root` in the current window, making the buffer if
   there isn't one yet, with the cursor on `focus` (a path) if the tree
   shows it."
  (let ([id (or (file-tree-buffer) (buffer-new! *file-tree-buffer-name*))])
    (when focus (file-tree-reveal! root focus))
    (go-to-buffer! id)
    (unless (eq? (major-mode) 'file-tree-mode) (set-major-mode! 'file-tree-mode))
    (unless (equal? (buffer-local 'file-tree-root) root)
      (set-buffer-local! 'file-tree-root root)
      (set-cursor! 0))
    (file-tree-render!)
    (let ([line (and focus (file-tree-line-of focus))])
      (when line (set-cursor! (line-start line))))))

(define (file-tree-open!)
  "Opens the tree down the left of the frame, file-tree-width columns
   wide, and moves the cursor into it."
  (let ([origin (current-window)]
        [root (file-tree-root-for)]
        [file (and (buffer-path) (absolute (buffer-path)))])
    (leave-pending-states!)
    (split-frame! "left" 0.2)
    (set! *file-tree-origins*
          (cons (cons (current-window) origin)
                (filter (lambda (o) (memv (car o) (window-list))) *file-tree-origins*)))
    (after-window-change!)
    (file-tree-show! root file)
    ;; Sized once its buffer's options (no line numbers) are in place.
    (resize-window! "width" (- (option 'file-tree-width) (window-text-width)))
    void))

(define (file-tree-close!)
  "Closes this frame's tree, and puts the cursor back in the window it
   was opened from."
  (let* ([w (file-tree-window)] [entry (assv w *file-tree-origins*)] [origin (and entry (cdr entry))])
    (when w
      (leave-pending-states!)
      (close-window! w)
      (set! *file-tree-origins* (filter (lambda (o) (not (eqv? (car o) w))) *file-tree-origins*))
      (when (and origin (memv origin (window-list))) (focus-window! origin))
      (after-window-change!))))

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
    (if (and entry (memv (cdr entry) (window-list)))
        (cdr entry)
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
(define-mode-key! 'file-tree-mode 'normal "<ret>" (lambda (n) (file-tree-visit!)) "open")
(define-mode-key! 'file-tree-mode 'normal "<tab>"
  (lambda (n) (let ([row (file-tree-row)]) (when (and row (cadr row) (> (current-line) 0)) (file-tree-toggle-folder! (car row)))))
  "open or shut a folder")
(define-mode-key! 'file-tree-mode 'normal "q" (lambda (n) (file-tree-close!)) "close the tree")
