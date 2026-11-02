;;; files.scm -- files on disk: formats, outside changes, backups, autosave.
;;;
;;; Saving is atomic (Rust writes a temporary file and renames it), so a
;;; crash never leaves half a file. Beyond that:
;;;
;;; - fileformat ("unix" or "dos") and fileencoding ("utf-8" or "latin1")
;;;   are the current buffer's, detected when it was read; :set ff=unix
;;;   converts on the next save.
;;; - autoread: a file changed outside imp reloads if its buffer has no
;;;   changes, and otherwise you are told; :w then refuses to overwrite it
;;;   until :w!. Checked every few seconds and on entering a buffer.
;;; - backup keeps the previous version as FILE~ on every save.
;;; - autosave: a few seconds after typing stops, changed buffers are
;;;   copied to the state directory, readable only by the user (a copy
;;;   may hold a secret the file never had); after a crash, :recover
;;;   brings a copy back (spec/crash-recovery).

;; Reload a file changed outside imp when its buffer has no changes.
(define-option! 'autoread #t '(ar))
;; Keep the previous version of a file as FILE~ on every save.
(define-option! 'backup #f '(bk))
;; The most seconds a change waits to be copied for crash recovery while
;; typing goes on; 0 turns autosave off.
(define-option! 'autosave-interval 30 '())
;; Seconds without a key or click from any client before changed buffers
;; are copied for crash recovery; 0 leaves only autosave-interval.
(define-option! 'autosave-idle 4 '())
;; Where autosaved copies go; empty means $XDG_STATE_HOME/imp.
(define-option! 'state-directory "" '())

(define (imp-state-dir)
  "The directory imp keeps state in: the state-directory option, or
   $XDG_STATE_HOME/imp when that is empty."
  (if (equal? (option 'state-directory) "") (state-dir) (option 'state-directory)))

;; The current buffer's line endings, "unix" or "dos"; setting it converts
;; the file on the next save.
(define-computed-option! 'fileformat '(ff)
  (lambda () (car (buffer-file-format)))
  (lambda (value)
    (let ([f (buffer-file-format)]) (set-buffer-file-format! value (cadr f) (caddr f)))))

;; The current buffer's encoding, "utf-8" or "latin1", as it was read;
;; setting it converts the file on the next save.
(define-computed-option! 'fileencoding '(fenc)
  (lambda () (cadr (buffer-file-format)))
  (lambda (value)
    (let ([f (buffer-file-format)]) (set-buffer-file-format! (car f) value (caddr f)))))

;; Whether the current buffer's file starts with a UTF-8 byte order mark,
;; which saving keeps.
(define-computed-option! 'bomb '()
  (lambda () (caddr (buffer-file-format)))
  (lambda (value)
    (let ([f (buffer-file-format)]) (set-buffer-file-format! (car f) (cadr f) value))))

;;; Changes made outside the editor

(define (check-disk-change!)
  "Checks the current buffer's file. Reloads it if nothing would be lost;
   otherwise says so once until it changes again."
  (when (and (buffer-path) (buffer-changed-on-disk?))
    (cond
      [(and (option 'autoread) (not (buffer-modified?)) (file-exists? (buffer-path)))
       (let ([p (cursor)])
         (buffer-reload!)
         (set-cursor! (min p (buffer-length)))
         (normal-clamp!)
         (message (string-append "reloaded " (buffer-name) " (changed on disk)")))]
      [(not (buffer-local 'disk-warned))
       (set-buffer-local! 'disk-warned #t)
       (message (string-append (buffer-name)
                               (if (file-exists? (buffer-path)) " changed on disk" " was deleted on disk")
                               "; :e! to reload, :w! to keep yours"))]
      [else #t])))

(define (check-all-buffers!)
  "Checks every buffer's file for changes made outside imp."
  (for-each (lambda (id) (with-buffer id check-disk-change!)) (buffer-list)))

(add-hook! 'buffer-enter check-disk-change!)
(add-hook! 'after-save (lambda () (set-buffer-local! 'disk-warned #f)))
;; One timer for both checks: tests pump events until none come for a
;; while, which a second timer out of step with this one would prevent.
(add-hook! 'startup (lambda () (run-every! 2000 (lambda () (check-all-buffers!) (autosave-check!)))))

;;; Autosave and recovery (spec/crash-recovery)
;;;
;;; A changed buffer is copied to STATE/autosave a few seconds after the
;;; typing stops, or at the latest autosave-interval seconds after its
;;; first change not yet copied. There is no write at exit or from a
;;; panic: a copy made ahead of time covers every way imp can die, a
;;; SIGKILL or a power cut too. A copy's name ends in #PID, the imp that
;;; wrote it: while that imp runs the copy is in use, and once it is gone
;;; the copy is orphaned and offered back when its file opens.

;; The copy this imp wrote of each buffer: buffer id -> its path.
(define *autosave-copies* (hash))

(define (autosave-dir)
  "The directory crash copies go in: autosave/ in the state directory."
  (string-append (imp-state-dir) "/autosave"))

(define (autosave-base path)
  "The start of the names of the copies of file `path`: its absolute
   path, slashes made %."
  (let ([full (if (starts-with? path "/") path (string-append (current-dir) "/" path))])
    (list->string (map (lambda (c) (if (equal? c #\/) #\% c)) (string->list full)))))

(define (autosave-buffer-base)
  "The start of the current buffer's copy names: its file's, or
   unnamed-N for buffer N with no file."
  (if (buffer-path)
      (autosave-base (buffer-path))
      (string-append "unnamed-" (number->string (current-buffer)))))

(define (autosave-name base)
  "This imp's copy name for `base`: it, # and this process's id."
  (string-append base "#" (number->string (process-id))))

(define (autosave-byte-length text)
  "How many bytes `text` takes as UTF-8."
  (foldl (lambda (c n)
           (let ([k (char->integer c)])
             (+ n (cond [(< k #x80) 1] [(< k #x800) 2] [(< k #x10000) 3] [else 4]))))
         0 (string->list text)))

(define (autosave-text-buffer?)
  "Whether the current buffer is ordinary text someone typed: not
   read-only, not a terminal, not a special-mode buffer, and not one
   whose name starts with * (*Messages*, the REPL)."
  (not (or (buffer-read-only?)
           (buffer-local 'term-id)
           (eq? (major-mode) 'term-mode)
           (memq 'special-mode (mode-lineage (major-mode)))
           (starts-with? (buffer-name) "*"))))

(define (autosave-wanted?)
  "Whether the current buffer's text should have a crash copy: a file's
   buffer with unsaved changes, or an unnamed text buffer with text."
  (if (buffer-path)
      (buffer-modified?)
      (and (> (buffer-length) 0) (autosave-text-buffer?))))

(define (autosave-say-once! text)
  "Says `text` on the message line, once for the current buffer."
  (unless (equal? (buffer-local 'autosave-said) text)
    (set-buffer-local! 'autosave-said text)
    (message text)))

(define (autosave-buffer!)
  "Copies the current buffer to its crash copy now, if its text changed
   since the last copy. A copy that can't be written is skipped, said
   once; editing goes on."
  (let ([version (buffer-version)])
    (unless (equal? version (buffer-local 'autosave-version))
      (let* ([name (autosave-name (autosave-buffer-base))]
             [path (string-append (autosave-dir) "/" name)])
        (set-buffer-local! 'autosave-version version)
        (set-buffer-local! 'autosave-since #f)
        (if (> (autosave-byte-length name) 255)
            (autosave-say-once! (string-append (buffer-name) "'s path is too long to autosave"))
            (let ([r (error-text (lambda () (write-private-file! path (buffer-substring 0 (buffer-length)))))])
              (if r
                  (autosave-say-once! (string-append "can't autosave " (buffer-name) ": " r))
                  (let ([old (hash-try-get *autosave-copies* (current-buffer))])
                    (when (and old (not (equal? old path))) (error-text (lambda () (delete-file! old))))
                    (set! *autosave-copies* (hash-insert *autosave-copies* (current-buffer) path)))))))))
  void)

(define (autosave-forget! id)
  "Deletes buffer `id`'s crash copy, its changes no longer at risk."
  (let ([path (hash-try-get *autosave-copies* id)])
    (when path
      (error-text (lambda () (delete-file! path)))
      (set! *autosave-copies* (hash-remove *autosave-copies* id))))
  void)

(define (autosave-check-buffer! now idle?)
  "The autosave check for the current buffer at `now` (seconds): copy
   it if it changed and typing has paused (`idle?`) or its first
   uncopied change is autosave-interval old; delete its copy if its
   changes are no longer at risk (saved, undone, reloaded, emptied)."
  (cond
    [(autosave-wanted?)
     (unless (equal? (buffer-version) (buffer-local 'autosave-version))
       (let ([since (or (buffer-local 'autosave-since)
                        (begin (set-buffer-local! 'autosave-since now) now))])
         (when (or idle? (>= (- now since) (option 'autosave-interval)))
           (autosave-buffer!))))]
    [(hash-contains? *autosave-copies* (current-buffer))
     (autosave-forget! (current-buffer))
     (set-buffer-local! 'autosave-version #f)])
  void)

(define (autosave-check!)
  "Copies every changed buffer that is due, and deletes the copies of
   buffers no longer at risk. Runs every two seconds; does nothing while
   autosave-interval is 0."
  (when (> (option 'autosave-interval) 0)
    (let ([now (unix-time)]
          [idle? (let ([idle (option 'autosave-idle)])
                   (and (> idle 0) (>= (input-idle-ms) (* 1000 idle))))])
      (for-each (lambda (id) (with-buffer id (lambda () (autosave-check-buffer! now idle?))))
                (buffer-list))))
  void)

(define (autosave-all!)
  "Copies every buffer that should have a crash copy now, whatever the
   timing."
  (for-each (lambda (id) (with-buffer id (lambda () (when (autosave-wanted?) (autosave-buffer!)))))
            (buffer-list))
  void)

;;; Orphaned copies

(define (copy-owner-alive? pid)
  "Whether the imp with process id `pid`, which wrote a crash copy, still
   runs, so its copy is in use rather than orphaned. #f, a copy named
   without a pid by an older imp, is never alive."
  (and pid (or (= pid (process-id)) (imp-running? pid))))

(define (autosave-copy-entry name)
  "Crash copy file `name` as (path pid mtime base): pid the number after
   its last #, or #f for an old name without one; mtime in milliseconds.
   #f for a temporary file still being written."
  (if (starts-with? name ".")
      #f
      (let* ([at (let loop ([i (- (string-length name) 1)])
                   (cond [(< i 0) #f]
                         [(equal? (string-ref name i) #\#) i]
                         [else (loop (- i 1))]))]
             [pid (and at (string->number (substring name (+ at 1) (string-length name))))]
             [pid (and (integer? pid) (> pid 0) pid)]
             [path (string-append (autosave-dir) "/" name)])
        (list path pid (or (file-mtime path) 0) (if pid (substring name 0 at) name)))))

(define (autosave-copies base)
  "The crash copies in the autosave directory, as (path pid mtime base),
   newest first; only those of `base` (a file's or unnamed-N) unless it
   is #f."
  (let ([names (with-handler (lambda (e) '()) (directory-entries (autosave-dir)))])
    (sort (filter (lambda (c) (and c (or (not base) (equal? (cadddr c) base))))
                  (map (lambda (e) (and (not (cadr e)) (autosave-copy-entry (car e)))) names))
          (lambda (a b) (> (caddr a) (caddr b))))))

(define (autosave-orphans base)
  "The orphaned crash copies of `base` (#f: of everything), newest first:
   those whose imp is gone."
  (filter (lambda (c) (not (copy-owner-alive? (cadr c)))) (autosave-copies base)))

(define (autosave-recover! copy)
  "Puts crash copy `copy`'s text in the current buffer as one change,
   which u undoes. Its file stays modified until :w."
  (let ([text (with-handler (lambda (e) (message (error-message e)) #f) (read-file (car copy)))])
    (when text
      (begin-change!)
      (replace-range! 0 (buffer-length) text)
      (set-cursor! 0)
      (message (string-append "recovered " (buffer-name) "; :w to keep it")))))

(add-hook! 'after-save
           (lambda ()
             (autosave-forget! (current-buffer))
             (set-buffer-local! 'autosave-version #f)))
(add-hook! 'buffer-open
           (lambda ()
             (when (and (buffer-path) (pair? (autosave-orphans (autosave-base (buffer-path)))))
               (message (string-append (buffer-name) " has unsaved changes from a crash: :recover to restore them")))))

(define-ex! '("rec" "recover")
  (lambda (ex)
    (let ([orphans (if (buffer-path) (autosave-orphans (autosave-base (buffer-path))) '())])
      (if (null? orphans)
          (message "no autosaved copy of this buffer")
          (autosave-recover! (car orphans))))))

;;; Deleting, renaming and copying files (M-x delete-file, rename-file,
;;; copy-file). Each asks for the file, offering the current buffer's, and
;;; a buffer visiting it follows: deleted with the file, or renamed.

(define (file-prompt-default)
  "What the file prompts start from: the current buffer's file, or the
   current directory."
  (abbreviate-path (if (buffer-path)
                       (absolute-path (buffer-path))
                       (string-append (current-dir) "/"))))

(define (ask-existing-file prompt done)
  "Asks for an existing file (not a directory), then calls `done` with
   its absolute path."
  (ask prompt (file-prompt-default)
       (lambda (name)
         (let ([path (absolute-path (expand-path name))])
           (cond [(not (file-exists? path)) (message (string-append name ": no such file"))]
                 [(file-directory? path) (message (string-append name " is a directory; use the file browser (:Ex)"))]
                 [else (done path)])))))

(define (destination-path from name)
  "Where `from` goes when the answer is `name`: into `name` if that is a
   directory, as mv and cp do."
  (let ([to (absolute-path (expand-path name))])
    (if (file-directory? to)
        (string-append (if (ends-with? to "/") to (string-append to "/")) (file-name-of from))
        to)))

(define-command! 'delete-file
  (lambda (count)
    "Delete a file, the current buffer's unless you name another, after asking."
    (ask-existing-file "Delete file: "
      (lambda (path)
        (confirm! (string-append "Delete " (abbreviate-path path) "?")
          (lambda ()
            (let ([r (error-text (lambda () (delete-path! path)))] [id (buffer-for-path path)])
              (cond [r (message r)]
                    [(and id (buffer-modified-by-id? id))
                     (message (string-append "deleted " (abbreviate-path path) "; its buffer has unsaved changes, so it stays"))]
                    [else (when id (kill-buffer! id))
                          (message (string-append "deleted " (abbreviate-path path)))]))))))))

(define-command! 'rename-file
  (lambda (count)
    "Rename or move a file, the current buffer's unless you name another."
    (ask-existing-file "Rename file: "
      (lambda (from)
        (ask (string-append "Rename " (abbreviate-path from) " to: ") (abbreviate-path from)
          (lambda (name)
            (let ([to (destination-path from name)])
              (if (equal? to from)
                  (message "same name; nothing to do")
                  (let ([r (error-text (lambda () (rename-file! from to)))])
                    (if r
                        (message r)
                        (let ([id (buffer-for-path from)])
                          (when id (with-buffer id (lambda () (buffer-renamed! from to))))
                          (message (string-append "renamed " (abbreviate-path from) " to " (abbreviate-path to))))))))))))))

(define (buffer-renamed! from to)
  "Points the current buffer at its file's new path `to`: its name, its
   major mode (the extension may have changed) and its language server."
  (set-buffer-path! to)
  (run-hooks 'buffer-renamed from)
  (pick-major-mode!))

(define-command! 'copy-file
  (lambda (count)
    "Copy a file, the current buffer's unless you name another."
    (ask-existing-file "Copy file: "
      (lambda (from)
        (ask (string-append "Copy " (abbreviate-path from) " to: ") (abbreviate-path from)
          (lambda (name)
            (let* ([to (destination-path from name)] [r (error-text (lambda () (copy-file! from to)))])
              (message (if r
                           r
                           (string-append "copied " (abbreviate-path from) " to " (abbreviate-path to)))))))))))

(define-leader! "fD" 'delete-file "delete file")
(define-leader! "fR" 'rename-file "rename file")
(define-leader! "fC" 'copy-file "copy file")
