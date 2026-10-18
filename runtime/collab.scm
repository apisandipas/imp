;;; collab.scm -- shared buffers: two or more editors editing one buffer.
;;;
;;; Built with the `crdt` feature (crdt.rs has how it works). One editor
;;; shares a buffer on a Unix socket; others join it and get a copy that
;;; stays in sync, edits from every side merged by the CRDT:
;;;
;;;   :share [NAME]   serve the current buffer (NAME defaults to "imp")
;;;   :join [NAME]    open the buffer someone shares as NAME (or a socket path)
;;;   :unshare        stop sharing or leave
;;;
;;; The sharing editor relays updates between the others. Each side sends
;;; its changes after every command and on a short timer. Undo is still
;;; local, and other cursors aren't shown.
;;;
;;; On the socket each line is a message: "hello STATE" from a joiner,
;;; "name NAME" and "update UPDATE" back, then "update UPDATE" both ways.

(define *collab-peers* (hash))     ; shared buffer -> connections to its peers
(define *collab-buffers* (hash))   ; connection -> buffer
(define *collab-listeners* (hash)) ; buffer -> (listener path)
(define *collab-timer* #f)
(define collab-sync-ms 200)

(define (collab-peers buf) (or (hash-try-get *collab-peers* buf) '()))

(define (collab-send! conn . words)
  (socket-send! conn (string-append (string-join words " ") "\n")))

(define (collab-broadcast! buf update except)
  (for-each (lambda (conn) (unless (equal? conn except) (collab-send! conn "update" update)))
            (collab-peers buf)))

;; Sends each shared buffer's local changes to its peers.
(define (collab-sync!)
  (for-each (lambda (buf)
              (let ([update (crdt-sync! buf)])
                (when update (collab-broadcast! buf update #f))))
            (hash-keys->list *collab-peers*)))

(define (collab-start! buf)
  (unless (crdt-shared? buf) (crdt-share! buf))
  (unless (hash-contains? *collab-peers* buf)
    (set! *collab-peers* (hash-insert *collab-peers* buf '())))
  (unless *collab-timer*
    (set! *collab-timer* (run-every! collab-sync-ms collab-sync!))))

(define (collab-add-peer! buf conn)
  (set! *collab-buffers* (hash-insert *collab-buffers* conn buf))
  (set! *collab-peers* (hash-insert *collab-peers* buf (cons conn (collab-peers buf)))))

(define (collab-drop-peer! conn)
  (let ([buf (hash-try-get *collab-buffers* conn)])
    (set! *collab-buffers* (hash-remove *collab-buffers* conn))
    (when buf
      (set! *collab-peers*
            (hash-insert *collab-peers* buf (filter (lambda (c) (not (equal? c conn))) (collab-peers buf)))))
    buf))

;; Stops sharing (or leaves) buffer `buf`.
(define (collab-stop! buf)
  (let ([listener (hash-try-get *collab-listeners* buf)])
    (when listener
      (socket-stop! (car listener))
      (set! *collab-listeners* (hash-remove *collab-listeners* buf))))
  (for-each (lambda (conn) (collab-drop-peer! conn) (socket-close! conn)) (collab-peers buf))
  (set! *collab-peers* (hash-remove *collab-peers* buf))
  (crdt-unshare! buf)
  (when (and *collab-timer* (= (hash-length *collab-peers*) 0))
    (cancel-timer! *collab-timer*)
    (set! *collab-timer* #f)))

;; A message from a peer of `buf`.
(define (collab-receive! buf conn line)
  (let ([words (split-whitespace line)])
    (cond [(null? words) #f]
          [(equal? (car words) "hello")
           (collab-send! conn "name" (car (buffer-info buf)))
           (collab-send! conn "update" (crdt-diff buf (if (null? (cdr words)) "" (cadr words))))]
          [(equal? (car words) "update")
           (crdt-apply! buf (cadr words))
           (collab-broadcast! buf (cadr words) conn)]
          [(equal? (car words) "name")
           (when (= buf (current-buffer))
             (set-buffer-name! (string-append "[shared] " (string-join (cdr words) " ")))
             (let ([mode (mode-for-path (string-join (cdr words) " "))])
               (when mode (set-major-mode! mode))))])))

(define (collab-socket-path name)
  (if (string-contains? name "/") (expand-path name) (socket-path (string-append "share-" name))))

(define (share-buffer! name)
  (let* ([buf (current-buffer)]
         [path (collab-socket-path name)]
         [listener (listen-socket! path
                                   (lambda (conn) (collab-add-peer! buf conn))
                                   (lambda (conn line) (collab-receive! buf conn line))
                                   (lambda (conn) (collab-drop-peer! conn)))])
    (when listener
      (collab-start! buf)
      (set! *collab-listeners* (hash-insert *collab-listeners* buf (list listener path)))
      (message (string-append "sharing on " path ": others :join " name)))))

(define (join-buffer! name)
  (let* ([buf (buffer-new! (string-append "[shared] " name))]
         [conn (connect-socket! (collab-socket-path name)
                                (lambda (conn line) (collab-receive! buf conn line))
                                (lambda (conn)
                                  (collab-drop-peer! conn)
                                  (when (null? (collab-peers buf))
                                    (collab-stop! buf)
                                    (message "the shared buffer's host went away"))))])
    (if conn
        (begin
          (go-to-buffer! buf)
          (collab-start! buf)
          (collab-add-peer! buf conn)
          (collab-send! conn "hello" (crdt-state buf)))
        (buffer-kill! buf))))

(define (collab-name ex)
  (let ([words (split-whitespace (ex-args ex))])
    (if (null? words) "imp" (car words))))

(define (collab-check)
  (or (crdt-available?)
      (begin (message "imp was built without the crdt feature") #f)))

(define-ex! "share" (lambda (ex) (when (collab-check) (share-buffer! (collab-name ex)))))
(define-ex! "join" (lambda (ex) (when (collab-check) (join-buffer! (collab-name ex)))))
(define-ex! "unshare"
  (lambda (ex)
    (if (hash-contains? *collab-peers* (current-buffer))
        (begin (collab-stop! (current-buffer)) (message "stopped sharing"))
        (message "this buffer isn't shared"))))

(add-hook! 'post-command (lambda () (unless (= (hash-length *collab-peers*) 0) (collab-sync!))))
(add-hook! 'buffer-kill (lambda (id) (when (hash-contains? *collab-peers* id) (collab-stop! id))))
