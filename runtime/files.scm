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
;;; - autosave-interval: every so many seconds, modified buffers are
;;;   copied to the state directory, readable only by the user (a copy
;;;   may hold a secret the file never had); on opening a file with a
;;;   newer copy there, :recover brings it back.

;; Reload a file changed outside imp when its buffer has no changes.
(define-option! 'autoread #t '(ar))
;; Keep the previous version of a file as FILE~ on every save.
(define-option! 'backup #f '(bk))
;; Seconds between copies of modified buffers into the state directory,
;; for :recover; 0 turns autosave off.
(define-option! 'autosave-interval 30 '())
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
(add-hook! 'startup (lambda () (run-every! 2000 check-all-buffers!)))

;;; Autosave and recovery

(define (autosave-path path)
  "Where the autosave copy of `path` goes: its full path, slashes made %."
  (let ([full (if (starts-with? path "/") path (string-append (current-dir) "/" path))])
    (string-append (imp-state-dir) "/autosave/"
                   (list->string (map (lambda (c) (if (equal? c #\/) #\% c)) (string->list full))))))

(define (autosave-buffer!)
  "Copies the current buffer to its autosave file if it is modified.
   A copy that can't be written is skipped quietly."
  (when (and (buffer-path) (buffer-modified?))
    (with-handler (lambda (e) #f)
                  (write-private-file! (autosave-path (buffer-path)) (buffer-substring 0 (buffer-length))))))

(define (autosave-all!)
  "Autosaves every modified buffer that has a file."
  (for-each (lambda (id) (with-buffer id autosave-buffer!)) (buffer-list)))

(define (remove-autosave!)
  "Deletes the current buffer's autosave copy, once it is saved."
  (when (buffer-path) (error-text (lambda () (delete-file! (autosave-path (buffer-path)))))))

(define (recoverable?)
  "Whether there is an autosave copy newer than the file itself."
  (and (buffer-path)
       (let ([copy (file-mtime (autosave-path (buffer-path)))]
             [file (file-mtime (buffer-path))])
         (and copy (or (not file) (> copy file))))))

(add-hook! 'after-save remove-autosave!)
(add-hook! 'buffer-open
           (lambda ()
             (when (recoverable?)
               (message (string-append "an autosaved copy of " (buffer-name)
                                       " is newer than the file: :recover to restore it")))))
(add-hook! 'startup
           (lambda ()
             (when (> (option 'autosave-interval) 0)
               (run-every! (* 1000 (option 'autosave-interval)) autosave-all!))))

(define-ex! '("rec" "recover")
  (lambda (ex)
    (let ([copy (and (buffer-path) (autosave-path (buffer-path)))])
      (if (not (and copy (file-exists? copy)))
          (message "no autosaved copy of this buffer")
          (let ([text (read-file copy)])
            (begin-change!)
            (replace-range! 0 (buffer-length) text)
            (set-cursor! 0)
            (message (string-append "recovered " (buffer-name) "; :w to keep it")))))))

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
