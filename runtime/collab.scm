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

(define (collab-peers buf)
  "The connections to the peers of shared buffer `buf`, or '()."
  (or (hash-try-get *collab-peers* buf) '()))

(define (collab-send! conn . words)
  "Sends `words`, joined by spaces, to `conn` as one message line."
  (socket-send! conn (string-append (string-join words " ") "\n")))

(define (collab-broadcast! buf update except)
  "Sends `update` to every peer of `buf` but `except` (#f for none)."
  (for-each (lambda (conn) (unless (equal? conn except) (collab-send! conn "update" update)))
            (collab-peers buf)))

(define (collab-sync!)
  "Sends each shared buffer's local changes to its peers."
  (for-each (lambda (buf)
              (let ([update (crdt-sync! buf)])
                (when update (collab-broadcast! buf update #f))))
            (hash-keys->list *collab-peers*)))

(define (collab-start! buf)
  "Starts keeping `buf` in sync: shares it with the CRDT and starts
   the sync timer if it isn't running."
  (unless (crdt-shared? buf) (crdt-share! buf))
  (unless (hash-contains? *collab-peers* buf)
    (set! *collab-peers* (hash-insert *collab-peers* buf '())))
  (unless *collab-timer*
    (set! *collab-timer* (run-every! collab-sync-ms collab-sync!)))
  void)

(define (collab-add-peer! buf conn)
  "Records `conn` as a peer of shared buffer `buf`."
  (set! *collab-buffers* (hash-insert *collab-buffers* conn buf))
  (set! *collab-peers* (hash-insert *collab-peers* buf (cons conn (collab-peers buf))))
  void)

(define (collab-drop-peer! conn)
  "Forgets connection `conn`; returns the buffer it was a peer of, or #f.
   The connection itself stays open."
  (let ([buf (hash-try-get *collab-buffers* conn)])
    (set! *collab-buffers* (hash-remove *collab-buffers* conn))
    (when buf
      (set! *collab-peers*
            (hash-insert *collab-peers* buf (filter (lambda (c) (not (equal? c conn))) (collab-peers buf)))))
    buf))

(define (collab-stop! buf)
  "Stops sharing (or leaves) buffer `buf`."
  (let ([listener (hash-try-get *collab-listeners* buf)])
    (when listener
      (socket-stop! (car listener))
      (set! *collab-listeners* (hash-remove *collab-listeners* buf))))
  (for-each (lambda (conn) (collab-drop-peer! conn) (socket-close! conn)) (collab-peers buf))
  (set! *collab-peers* (hash-remove *collab-peers* buf))
  (crdt-unshare! buf)
  (when (and *collab-timer* (= (hash-length *collab-peers*) 0))
    (cancel-timer! *collab-timer*)
    (set! *collab-timer* #f))
  void)

(define (collab-receive! buf conn line)
  "Handles `line`, a message from `conn`, a peer of shared buffer `buf`.
   hello gets the buffer's name and what the joiner lacks; update is
   applied and relayed to the other peers (a malformed one is reported
   and dropped); name names the joined buffer and picks its major mode,
   whichever buffer is current."
  (let ([words (split-whitespace line)])
    (cond [(null? words) #f]
          [(equal? (car words) "hello")
           (collab-send! conn "name" (car (buffer-info buf)))
           (collab-send! conn "update" (crdt-diff buf (if (null? (cdr words)) "" (cadr words))))]
          [(equal? (car words) "update")
           ;; One that is missing or can't be applied is reported, not relayed.
           (if (and (pair? (cdr words))
                    (with-handler (lambda (e) #f) (begin (crdt-apply! buf (cadr words)) #t)))
               (collab-broadcast! buf (cadr words) conn)
               (message "shared buffer: ignored a bad update from a peer"))]
          [(equal? (car words) "name")
           (when (memv buf (buffer-list))
             (with-buffer buf
               (lambda ()
                 (set-buffer-name! (string-append "[shared] " (string-join (cdr words) " ")))
                 (let ([mode (mode-for-path (string-join (cdr words) " "))])
                   (when mode (set-major-mode! mode))))))])))

(define (collab-socket-path name)
  "The socket for share `name`: `name` itself when it is a path (has a
   slash), else imp's socket called share-NAME."
  (if (string-contains? name "/") (expand-path name) (socket-path (string-append "share-" name))))

(define (share-buffer! name)
  "Serves the current buffer on the socket for `name`, for :share.
   Peers that join get a copy kept in sync; says where it is shared."
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
  "Opens the buffer shared as `name` in a new buffer, for :join.
   If the socket can't be reached the new buffer goes again; when the
   host goes away, the buffer stops being shared but stays."
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
  "The share name given to the ex command `ex`, \"imp\" by default."
  (let ([words (split-whitespace (ex-args ex))])
    (if (null? words) "imp" (car words))))

(define (collab-check)
  "Whether imp has the crdt feature; says so and returns #f if not."
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
