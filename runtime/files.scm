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
;;;   copied to the state directory; on opening a file with a newer copy
;;;   there, :recover brings it back.

(define-option! 'autoread #t '(ar))
(define-option! 'backup #f '(bk))
(define-option! 'autosave-interval 30 '())
;; Where autosaved copies go; empty means $XDG_STATE_HOME/imp.
(define-option! 'state-directory "" '())

(define (imp-state-dir)
  (if (equal? (option 'state-directory) "") (state-dir) (option 'state-directory)))

(define-computed-option! 'fileformat '(ff)
  (lambda () (car (buffer-file-format)))
  (lambda (value)
    (let ([f (buffer-file-format)]) (set-buffer-file-format! value (cadr f) (caddr f)))))

(define-computed-option! 'fileencoding '(fenc)
  (lambda () (cadr (buffer-file-format)))
  (lambda (value)
    (let ([f (buffer-file-format)]) (set-buffer-file-format! (car f) value (caddr f)))))

(define-computed-option! 'bomb '()
  (lambda () (caddr (buffer-file-format)))
  (lambda (value)
    (let ([f (buffer-file-format)]) (set-buffer-file-format! (car f) (cadr f) value))))

;;; Changes made outside the editor

;; Checks the current buffer's file. Reloads it if nothing would be lost;
;; otherwise says so once until it changes again.
(define (check-disk-change!)
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
  (for-each (lambda (id) (with-buffer id check-disk-change!)) (buffer-list)))

(add-hook! 'buffer-enter check-disk-change!)
(add-hook! 'after-save (lambda () (set-buffer-local! 'disk-warned #f)))
(add-hook! 'startup (lambda () (run-every! 2000 check-all-buffers!)))

;;; Autosave and recovery

;; Where the autosave copy of `path` goes: its full path, slashes made %.
(define (autosave-path path)
  (let ([full (if (starts-with? path "/") path (string-append (current-dir) "/" path))])
    (string-append (imp-state-dir) "/autosave/"
                   (list->string (map (lambda (c) (if (equal? c #\/) #\% c)) (string->list full))))))

(define (autosave-buffer!)
  (when (and (buffer-path) (buffer-modified?))
    (with-handler (lambda (e) #f)
                  (write-text-file! (autosave-path (buffer-path)) (buffer-substring 0 (buffer-length))))))

(define (autosave-all!)
  (for-each (lambda (id) (with-buffer id autosave-buffer!)) (buffer-list)))

(define (remove-autosave!)
  (when (buffer-path) (delete-file! (autosave-path (buffer-path)))))

;; Whether there is an autosave copy newer than the file itself.
(define (recoverable?)
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
