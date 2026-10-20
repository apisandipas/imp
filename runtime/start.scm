;;; start.scm -- recent files and the start screen.
;;;
;;; Files you visit are remembered (newest first) in the state directory;
;;; SPC f r picks one. Started without a file, imp shows a start screen
;;; listing recent files and projects; a digit or letter opens one. i, I,
;;; A, o and O go to the unnamed buffer to type in, n to an empty one. :start shows it again; set
;;; 'start-screen to #f to begin in the empty buffer instead.

(define-option! 'start-screen #t '())
(define-option! 'recent-files-max 100 '())

;;; Recent files

(define (recent-files-file) (string-append (imp-state-dir) "/recent"))

(define (recent-files)
  (with-handler (lambda (e) '())
                (if (file-exists? (recent-files-file)) (text-lines (read-file (recent-files-file))) '())))

(define (take-at-most items n)
  (if (or (null? items) (<= n 0)) '() (cons (car items) (take-at-most (cdr items) (- n 1)))))

(define (remember-file! path)
  "Remembering is a convenience: an unwritable state directory isn't an
   error worth showing."
  (with-handler
   (lambda (e) #f)
   (let* ([known (recent-files)])
     (unless (and (pair? known) (equal? (car known) path))
       (write-text-file! (recent-files-file)
                         (string-append
                          (string-join (take-at-most (cons path (filter (lambda (p) (not (equal? p path))) known))
                                                     (option 'recent-files-max))
                                       "\n")
                          "\n"))))))

(add-hook! 'buffer-enter
  (lambda ()
    (when (and (buffer-path) (not (special-buffer?)))
      (remember-file! (absolute (buffer-path))))))

(define-command! 'recent-files
  (lambda (count)
    (let ([files (filter file-exists? (recent-files))])
      (if (null? files)
          (message "no recent files yet")
          (completing-read "Recent file: " (map abbreviate-path files) open-file!)))))

(define-leader! "fr" 'recent-files "recent files")

;;; The start screen

(define-major-mode! 'start-mode 'special-mode '() #f)

(define (start-entry key label face action) (list key label face action))

(define (start-entries)
  "What the screen offers, as (key label face action): recent files on
   digits, projects on letters, then commands."
  (let* ([files (take-at-most (filter file-exists? (recent-files)) 9)]
         [projects (take-at-most (filter file-directory? (known-projects)) 5)]
         [n 0])
    (append
     (map (lambda (path)
            (set! n (+ n 1))
            (start-entry (number->string n) (abbreviate-path path) "start.file"
                         (lambda () (open-file! path))))
          files)
     (let ([letters '("a" "s" "d" "g" "h")] [i -1])
       (map (lambda (root)
              (set! i (+ i 1))
              (start-entry (list-ref letters i) (abbreviate-path root) "start.project"
                           (lambda () (project-find-file-in root))))
            projects))
     (list (start-entry "f" "Find file" #f (lambda () (run-command 'find-file 1)))
           (start-entry "r" "Recent files" #f (lambda () (run-command 'recent-files 1)))
           (start-entry "p" "Switch project" #f (lambda () (run-command 'project-switch 1)))
           (start-entry "n" "New buffer" #f (lambda () (start-new-buffer! #f)))
           (start-entry "c" "Open config" #f
                        (lambda () (open-file! (string-append (config-dir) "/init.scm"))))
           (start-entry "?" "Help" #f (lambda () (run-ex! "help")))
           (start-entry "q" "Quit" #f (lambda () (run-ex! "qa")))))))

(define (start-section entries face) (filter (lambda (e) (equal? (caddr e) face)) entries))

(define (start-draw!)
  (let* ([entries (start-entries)]
         [files (start-section entries "start.file")]
         [projects (start-section entries "start.project")]
         [commands (start-section entries #f)]
         [width (apply max (cons 30 (map (lambda (e) (+ 4 (string-length (cadr e)))) entries)))]
         [left (max 2 (quotient (- (window-width) width) 2))]
         [pad (make-string left #\space)]
         [body (+ 3 (if (null? files) 0 (+ 2 (length files))) (if (null? projects) 0 (+ 2 (length projects)))
                  (length commands))]
         [top (max 1 (quotient (- (window-height) body) 3))]
         [entry-line (lambda (e)
                       (draw-line! (list (list pad #f) (list (car e) "start.key") (list "   " #f)
                                         (list (cadr e) (caddr e)))
                                   e))]
         [heading (lambda (text)
                    (draw-line! '() #f)
                    (draw-line! (list (list pad #f) (list text "start.heading")) #f))])
    (draw-begin!)
    (let loop ([i 0]) (when (< i top) (draw-line! '() #f) (loop (+ i 1))))
    (draw-line! (list (list pad #f) (list "imp" "start.title")
                      (list (string-append "  " (imp-version)) "start.dim"))
                #f)
    (draw-line! (list (list pad #f) (list "Vim keys, Scheme all the way down" "start.dim")) #f)
    (unless (null? files) (heading "Recent files") (for-each entry-line files))
    (unless (null? projects) (heading "Projects") (for-each entry-line projects))
    (draw-line! '() #f)
    (for-each entry-line commands)
    (draw-finish!)
    (set-buffer-local! 'start-entries entries)
    ;; The cursor rests on the first entry.
    (let loop ([i 0])
      (let ([items (buffer-local 'line-items)])
        (when (< i (vector-length items))
          (if (vector-ref items i)
              (set-cursor! (line-first-nonblank i))
              (loop (+ i 1))))))))

(define (start-run! entry) ((list-ref entry 3)))

(define (start-key! key)
  "The key typed on the start screen, if it names an entry."
  (let ([entry (list-find (lambda (e) (equal? (car e) key)) (or (buffer-local 'start-entries) '()))])
    (if entry (start-run! entry) (message (string-append (key-label key) " is undefined")))))

(define (start-new-buffer! changed?)
  "An unnamed buffer (with `changed?`, even one with text in it), or a
   new one."
  (let ([blank (list-find (lambda (id)
                            (let ([info (buffer-info id)])
                              (and (equal? (car info) "[No Name]") (or changed? (not (caddr info))))))
                          (buffer-list))])
    (if blank (go-to-buffer! blank) (run-ex! "enew"))))

(for-each (lambda (key) (define-mode-key! 'start-mode 'normal key (lambda (n) (start-key! key))))
          '("1" "2" "3" "4" "5" "6" "7" "8" "9" "a" "s" "d" "g" "h" "f" "r" "p" "n" "c" "?" "q"))
(for-each (lambda (key)
            (define-mode-key! 'start-mode 'normal key
              (lambda (n) (start-new-buffer! #t) ((lookup-key 'normal key) 1))))
          '("i" "I" "A" "o" "O"))
(define-mode-key! 'start-mode 'normal "<ret>"
  (lambda (n) (let ([e (line-item)]) (when e (start-run! e)))))

(define (show-start-screen!)
  (go-to-buffer! (special-buffer "*start*" 'start-mode))
  (start-draw!))

(define-ex! '("start") (lambda (ex) (show-start-screen!)))
(define-command! 'start-screen (lambda (count)
                                 "Show the start screen: recent files, projects and a few commands."
                                 (show-start-screen!)))

(define (imp-start-screen)
  "Called by the editor when it starts with no file."
  (when (option 'start-screen) (show-start-screen!)))
