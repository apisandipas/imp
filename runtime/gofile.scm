;;; gofile.scm -- gf: open the file named under the cursor
;;; (docs/specs/go-to-file.md).
;;;
;;; A name is looked for in a list of places, each giving the paths to
;;; try in order: the name as written, with each of the buffer's
;;; suffixesadd endings, then index with each ending inside it if it is
;;; a directory. The first file wins; a place with only the directory
;;; opens it in the file browser.

(define (file-name-at-char? c)
  "Whether `c` can be part of a file name gf reads: letters, digits and
   / . - _ ~ + @ % $ # =."
  (or (char-word? c) (memv c '(#\/ #\. #\- #\_ #\~ #\+ #\@ #\% #\$ #\# #\=))))

(define (file-name-under-cursor)
  "The file name under the cursor, or the next one after it on the line,
   with its end offset as (name . end); #f with none."
  (let* ([line (current-line)] [lo (line-start line)] [hi (line-end line)]
         [at (let loop ([p (cursor)])
               (cond [(>= p hi) #f]
                     [(file-name-at-char? (buffer-char-at p)) p]
                     [else (loop (+ p 1))]))])
    (and at
         (let ([start (let back ([p at])
                        (if (and (> p lo) (file-name-at-char? (buffer-char-at (- p 1)))) (back (- p 1)) p))]
               [end (let fwd ([p at])
                      (if (and (< p hi) (file-name-at-char? (buffer-char-at p))) (fwd (+ p 1)) p))])
           (cons (buffer-substring start end) end)))))

(define (selected-file-name)
  "The visual selection as a file name: its first line, trimmed."
  (let* ([r (visual-range)]
         [text (buffer-substring (car r) (cadr r))]
         [first (car (split-many text "\n"))])
    (trim first)))

(define (expand-env name)
  "`name` with each $NAME or ${NAME} replaced by that environment
   variable (empty when it isn't set)."
  (let ([n (string-length name)])
    (let loop ([i 0] [out ""])
      (cond
        [(>= i n) out]
        [(and (equal? (string-ref name i) #\$) (< (+ i 1) n))
         (let* ([braced? (equal? (string-ref name (+ i 1)) #\{)]
                [from (if braced? (+ i 2) (+ i 1))]
                [to (let scan ([j from])
                      (if (and (< j n) (char-word? (string-ref name j)))
                          (scan (+ j 1))
                          j))])
           (if (= to from)
               (loop (+ i 1) (string-append out "$"))
               (loop (if (and braced? (< to n) (equal? (string-ref name to) #\})) (+ to 1) to)
                     (string-append out (or (getenv (substring name from to)) "")))))]
        [else (loop (+ i 1) (string-append out (string (string-ref name i))))]))))

(define (file-endings)
  "The buffer's suffixesadd endings, as a list."
  (filter (lambda (s) (not (equal? s ""))) (map trim (split-many (option 'suffixesadd) ","))))

(define (clean-path path)
  "Absolute `path` without its . and .. parts or doubled slashes."
  (let loop ([parts (split-many path "/")] [out '()])
    (cond [(null? parts) (string-append "/" (string-join (reverse out) "/"))]
          [(member (car parts) '("" ".")) (loop (cdr parts) out)]
          [(equal? (car parts) "..") (loop (cdr parts) (if (null? out) out (cdr out)))]
          [else (loop (cdr parts) (cons (car parts) out))])))

(define (join-path dir name)
  "`name` under directory `dir`, cleaned."
  (clean-path (string-append dir "/" name)))

(define (found-at base)
  "What gf opens for path `base`: the first file of base, base with each
   ending, then index with each ending in it; failing those base itself
   if it is a directory; else #f."
  (let* ([endings (file-endings)]
         [files (append (list base)
                        (map (lambda (e) (string-append base e)) endings)
                        (map (lambda (e) (join-path base (string-append "index" e))) endings))])
    (or (list-find (lambda (p) (and (file-exists? p) (not (file-directory? p)))) files)
        (and (file-directory? base) base))))

(define (file-bases name)
  "The paths to look for `name` at, in order: as it is when absolute;
   only from the buffer's directory for ./ and ../; else from the
   buffer's directory, the project root and the working directory."
  (let ([dir (buffer-directory)])
    (cond
      [(starts-with? name "/") (list (clean-path name))]
      [(or (starts-with? name "./") (starts-with? name "../") (equal? name ".") (equal? name ".."))
       (list (join-path dir name))]
      [else
       (let loop ([dirs (list dir (project-root) (current-dir))] [out '()])
         (cond [(null? dirs) (reverse out)]
               [(not (car dirs)) (loop (cdr dirs) out)]
               [else (let ([p (join-path (car dirs) name)])
                       (loop (cdr dirs) (if (member p out) out (cons p out))))]))])))

(define (find-file-named name)
  "The path gf opens for `name` (with ~/ and $NAME expanded), or #f."
  (let ([name (expand-path (expand-env name))])
    (let loop ([bases (file-bases name)])
      (cond [(null? bases) #f]
            [(found-at (car bases)) => (lambda (p) p)]
            [else (loop (cdr bases))]))))

(define (go-to-file-named! name)
  "Opens the file `name` names, saying so when there is none. Returns
   whether it opened something."
  (let ([path (find-file-named name)])
    (if path
        (and (open-file! path) #t)
        (begin (message (string-append "Can't find file \"" name "\" in path")) #f))))

(define (go-to-file-under-cursor!)
  "gf: opens the file named under the cursor, or in visual mode the
   selection."
  (let ([name (if (eq? *mode* 'visual)
                  (let ([n (selected-file-name)]) (leave-visual!) (and (not (equal? n "")) n))
                  (let ([at (file-name-under-cursor)]) (and at (car at))))])
    (if name
        (go-to-file-named! name)
        (begin (message "No file name under cursor") #f))))

(define-key! 'normal "gf" (lambda (count) (go-to-file-under-cursor!)) "go to file")
(define-key! 'visual "gf" (lambda (count) (go-to-file-under-cursor!)) "go to file")
