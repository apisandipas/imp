;;; start.scm -- recent files and the start screen.
;;;
;;; Files you visit are remembered (newest first) in the state directory;
;;; SPC f r picks one. Started without a file, imp shows a start screen
;;; listing recent files and projects; a digit or letter opens one. i, I,
;;; A, o and O go to the unnamed buffer to type in, n to an empty one. M-x start-screen shows it again; set
;;; 'start-screen to #f to begin in the empty buffer instead.

(define-option! 'start-screen #t '())
(define-option! 'recent-files-max 100 '())

;;; Recent files

(define (recent-files-file)
  "The file the recent files list is kept in, in the state directory."
  (string-append (imp-state-dir) "/recent"))

(define (recent-files)
  "The recent files, newest first, or '() if none can be read."
  (with-handler (lambda (e) '())
                (if (file-exists? (recent-files-file)) (text-lines (read-file (recent-files-file))) '())))

(define (take-at-most items n)
  "The first `n` of `items`, or all of them if there are fewer."
  (if (or (null? items) (<= n 0)) '() (cons (car items) (take-at-most (cdr items) (- n 1)))))

(define (remember-file! path)
  "Puts `path` first in the recent files, keeping recent-files-max.
   Remembering is a convenience: an unwritable state directory isn't an
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
    "Pick a recently visited file and open it."
    (let ([files (filter file-exists? (recent-files))])
      (if (null? files)
          (message "no recent files yet")
          (begin
            (set! *completion-category* 'file)
            ;; Already in order of use.
            (set! *completion-ranked* #f)
            (completing-read "Recent file: " (map abbreviate-path files) open-file!))))))

(define-leader! "fr" 'recent-files "recent files")

;;; The start screen
;;;
;;; A dashboard in the style of Doom Emacs's: a banner over a column of
;;; actions, label on the left and key on the right, and a footer. It is
;;; made of sections, each a list of entries (key label action): the
;;; actions to begin with, and the recent files and projects when
;;; start-sections names them.

(define-major-mode! 'start-mode 'special-mode '() #f)

(define-option! 'start-sections '(actions) '())
(define-option! 'start-recent-files 9 '())
(define-option! 'start-projects 5 '())
(define-option! 'start-banner
  '("██ ███    ███ ██████ "
    "██ ████  ████ ██   ██"
    "██ ██ ████ ██ ██████ "
    "██ ██  ██  ██ ██     "
    "██ ██      ██ ██     ")
  '())

(define (start-entry key label action)
  "A start screen entry: `key` runs `action`, a command's name or a
   procedure of no arguments, shown as `label`."
  (list key label action))

(define *start-actions*
  (list (start-entry "r" "Recent files" 'recent-files)
        (start-entry "f" "Find file" 'find-file)
        (start-entry "p" "Switch project" 'project-switch)
        (start-entry "e" "File browser" 'file-browser)
        (start-entry "/" "Search project" 'search-project)
        (start-entry "c" "Open config" (lambda () (open-file! (string-append (config-dir) "/init.scm"))))
        (start-entry "n" "New buffer" (lambda () (start-new-buffer! #f)))
        (start-entry "q" "Quit" (lambda () (run-ex! "qa")))))

(define (define-start-action! key label action)
  "Adds an action to the start screen, after the others, replacing any
   with the same `key`. `action` is a command's name or a procedure of no
   arguments."
  (set! *start-actions*
        (append (filter (lambda (e) (not (equal? (car e) key))) *start-actions*)
                (list (start-entry key label action))))
  void)

(define (remove-start-action! key)
  "Takes the start screen's action on `key` away."
  (set! *start-actions* (filter (lambda (e) (not (equal? (car e) key))) *start-actions*))
  void)

;; Section name -> (heading proc): proc returns the section's entries.
(define *start-sections* (hash))

(define (define-start-section! name heading proc)
  "Makes section `name` of the start screen: `heading` over the entries
   `proc` returns, each made with start-entry. It shows once `name` is in
   the start-sections option."
  (set! *start-sections* (hash-insert *start-sections* name (list heading proc)))
  void)

(define-start-section! 'actions #f (lambda () *start-actions*))
(define-start-section! 'recent-files "Recent files"
  (lambda ()
    (let ([n 0])
      (map (lambda (path)
             (set! n (+ n 1))
             (start-entry (number->string n) (abbreviate-path path) (lambda () (open-file! path))))
           (take-at-most (filter file-exists? (recent-files)) (min 9 (option 'start-recent-files)))))))
(define-start-section! 'projects "Projects"
  (lambda ()
    (let ([letters '("a" "s" "d" "g" "h")] [i -1])
      (map (lambda (root)
             (set! i (+ i 1))
             (start-entry (list-ref letters i) (abbreviate-path root) (lambda () (project-find-file-in root))))
           (take-at-most (filter file-directory? (known-projects)) (min 5 (option 'start-projects)))))))

(define (start-sections)
  "The sections to show, as (heading entries), leaving out unknown and
   empty ones. A key already used by an earlier entry is dropped from a
   later one, which then shows without it."
  (let ([used '()])
    (filter (lambda (section) (pair? (cadr section)))
            (map (lambda (name)
                   (let ([section (hash-try-get *start-sections* name)])
                     (if section
                         (list (car section)
                               (map (lambda (e)
                                      (if (member (car e) used)
                                          (start-entry #f (cadr e) (caddr e))
                                          (begin (set! used (cons (car e) used)) e)))
                                    ((cadr section))))
                         (list #f '()))))
                 (option 'start-sections)))))

(define (start-footer)
  "The line under the actions: the version, and how many packages loaded."
  (let ([loaded (length (filter (lambda (p) (equal? (cadr p) "loaded")) *packages*))])
    (string-append "imp " (imp-version)
                   (if (> loaded 0)
                       (string-append " · " (number->string loaded) (if (= loaded 1) " package" " packages"))
                       ""))))

(define (start-layout sections banner spaced?)
  "How many lines the screen takes with `banner` (a list of lines, or #f
   for the one-line title) and a blank line between entries if `spaced?`:
   as start-draw! draws it, from the banner to the footer."
  (+ (if banner (length banner) 1) 1
     (apply + (map (lambda (s)
                     (+ 1 (if (car s) 2 0)
                        (* (length (cadr s)) (if spaced? 2 1))))
                   sections))
     2))

(define (start-draw!)
  "Draws the start screen into the current buffer, centred in the
   window, with the cursor on the first entry. The banner and the blank
   lines between entries go when the window hasn't room for them."
  (let* ([sections (start-sections)]
         [entries (apply append (map cadr sections))]
         [banner (option 'start-banner)]
         [banner (and (pair? banner)
                      (<= (+ (apply max (map string-length banner)) 4) (window-width))
                      banner)]
         [fits? (lambda (b spaced?) (<= (start-layout sections b spaced?) (window-height)))]
         [banner (and banner (fits? banner #t) banner)]
         [spaced? (fits? banner #t)]
         [width (apply max (cons 36 (map (lambda (e) (+ 8 (string-length (cadr e)))) entries)))]
         [centre (lambda (w) (make-string (max 2 (quotient (- (window-width) w) 2)) #\space))]
         [pad (centre width)]
         [top (max 1 (quotient (- (window-height) (start-layout sections banner spaced?)) 3))]
         [blank (lambda () (draw-line! '() #f))]
         [entry-line (lambda (e)
                       (draw-line! (list (list pad #f)
                                         (list (pad-right (cadr e) (- width 1)) "start.label")
                                         (list (or (car e) " ") "start.key"))
                                   e))])
    (draw-begin!)
    (let loop ([i 0]) (when (< i top) (blank) (loop (+ i 1))))
    (if banner
        (let ([bpad (centre (apply max (map string-length banner)))])
          (for-each (lambda (line) (draw-line! (list (list bpad #f) (list line "start.title")) #f)) banner))
        (draw-line! (list (list (centre 3) #f) (list "imp" "start.title")) #f))
    (blank)
    (for-each (lambda (section)
                (blank)
                (when (car section)
                  (draw-line! (list (list pad #f) (list (car section) "start.heading")) #f)
                  (blank))
                (for-each (lambda (e) (entry-line e) (when spaced? (blank))) (cadr section)))
              sections)
    (blank)
    (let ([footer (start-footer)])
      (draw-line! (list (list (centre (string-length footer)) #f) (list footer "start.dim")) #f))
    ;; Blank lines to the bottom of the window, so no ~ shows under it.
    (let loop ([i (+ top (start-layout sections banner spaced?))])
      (when (< i (window-height)) (blank) (loop (+ i 1))))
    (draw-finish!)
    (set-buffer-local! 'start-entries entries)
    (set-buffer-local! 'start-size (list (window-width) (window-height)))
    (for-each (lambda (e)
                (when (car e)
                  (define-mode-key! 'start-mode 'normal (car e) (lambda (n) (start-key! (car e))))))
              entries)
    ;; The cursor rests on the first entry.
    (let loop ([i 0])
      (let ([items (buffer-local 'line-items)])
        (when (< i (vector-length items))
          (if (vector-ref items i)
              (set-cursor! (line-first-nonblank i))
              (loop (+ i 1))))))))

(define (start-run! entry)
  "Runs start screen entry `entry`'s action: a command's name, or a
   procedure."
  (let ([action (caddr entry)])
    (if (symbol? action) (run-command action) (action))))

(define (start-key! key)
  "Runs the start screen entry for `key`, the key typed, if there is one."
  (let ([entry (and (eq? (major-mode) 'start-mode)
                     (list-find (lambda (e) (equal? (car e) key)) (or (buffer-local 'start-entries) '())))])
    (if entry (start-run! entry) (message (string-append (key-label key) " is undefined")))))

(define (start-new-buffer! changed?)
  "Goes to an unmodified unnamed buffer, or a new one if there is none.
   With `changed?`, an unnamed buffer with text in it will do too."
  (let ([blank (list-find (lambda (id)
                            (let ([info (buffer-info id)])
                              (and (equal? (car info) "[No Name]") (or changed? (not (caddr info))))))
                          (buffer-list))])
    (if blank (go-to-buffer! blank) (run-ex! "enew"))))

(for-each (lambda (key)
            (define-mode-key! 'start-mode 'normal key
              (lambda (n) (start-new-buffer! #t) ((lookup-key 'normal key) 1))))
          '("i" "I" "A" "o" "O"))
(define-mode-key! 'start-mode 'normal "<ret>"
  (lambda (n) (let ([e (line-item)]) (when e (start-run! e)))))

;; Redrawn to fit when the screen changes size.
(add-hook! 'resize (lambda () (when (eq? (major-mode) 'start-mode) (start-draw!))))

(define (show-start-screen!)
  "Goes to the *start* buffer and draws the start screen afresh."
  (go-to-buffer! (special-buffer "*start*" 'start-mode))
  (start-draw!))

(define-command! 'start-screen (lambda (count)
                                 "Show the start screen: recent files, projects and a few commands."
                                 (show-start-screen!)))

(define (imp-start-screen)
  "Shows the start screen unless 'start-screen is off.
   Called by the editor when it starts with no file."
  (when (option 'start-screen) (show-start-screen!)))
