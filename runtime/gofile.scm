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

(define (included-names name)
  "The names the buffer's includeexpr gives for `name`, or '()."
  (let ([expr (option 'includeexpr)])
    (if (procedure? expr)
        (let ([names (expr name)]) (if (list? names) (filter string? names) '()))
        '())))

(define (file-bases name)
  "The paths to look for `name` at, in order: as it is when absolute;
   only from the buffer's directory for ./ and ../; else from the
   buffer's directory, then the names includeexpr gives, then the
   project root and the working directory."
  (let ([dir (buffer-directory)])
    (cond
      [(starts-with? name "/") (list (clean-path name))]
      [(or (starts-with? name "./") (starts-with? name "../") (equal? name ".") (equal? name ".."))
       (list (join-path dir name))]
      [else
       (let loop ([paths (append (list (join-path dir name))
                                 (map (lambda (n) (if (starts-with? n "/") (clean-path n) (join-path dir n)))
                                      (included-names name))
                                 (map (lambda (d) (join-path d name))
                                      (filter (lambda (d) d) (list (project-root) (current-dir)))))]
                  [out '()])
         (cond [(null? paths) (reverse out)]
               [(member (car paths) out) (loop (cdr paths) out)]
               [else (loop (cdr paths) (cons (car paths) out))]))])))

(define (find-file-named name)
  "The path gf opens for `name` (with ~/ and $NAME expanded), or #f."
  (let ([name (expand-path (expand-env name))])
    (let loop ([bases (file-bases name)])
      (cond [(null? bases) #f]
            [(found-at (car bases)) => (lambda (p) p)]
            [else (loop (cdr bases))]))))

(define (digits-at text i)
  "The number of the digits in `text` from `i`, and where they end, as
   (n . end); #f if there are none there."
  (let loop ([j i])
    (if (and (< j (string-length text)) (char-digit? (string-ref text j)))
        (loop (+ j 1))
        (and (> j i) (cons (string->number (substring text i j)) j)))))

(define (line-after-name text)
  "The line and column `text`, what follows a name, gives as (line col)
   from 1, col #f without one: :42, :42:7, (42) or \" line 42\"; #f for
   none."
  (define (after prefix)
    (and (starts-with? text prefix) (digits-at text (string-length prefix))))
  (cond
    [(after ":")
     => (lambda (l)
          (let ([c (and (< (cdr l) (string-length text)) (equal? (string-ref text (cdr l)) #\:)
                        (digits-at text (+ (cdr l) 1)))])
            (list (car l) (and c (car c)))))]
    [(after "(") => (lambda (l) (and (< (cdr l) (string-length text)) (equal? (string-ref text (cdr l)) #\))
                                     (list (car l) #f)))]
    [(after " line ") => (lambda (l) (list (car l) #f))]
    [else #f]))

(define (go-to-line-col! line col)
  "Puts the cursor on `line` (from 1, kept in the buffer) at column
   `col` (from 1), or its first non-blank without one."
  (let ([l (clamp (- line 1) 0 (last-line))])
    (set-cursor! (if col (line-col->offset l (- col 1)) (line-first-nonblank l)))
    (normal-clamp!)
    (set! *goal-col* (current-col))
    void))

;;; TypeScript and JavaScript: compilerOptions.paths from the nearest
;;; tsconfig.json or jsconfig.json, as includeexpr.

(define (without-json-comments text)
  "`text` without // and /* */ comments outside strings, as tsconfig
   allows."
  (let ([n (string-length text)])
    (let loop ([i 0] [out '()] [in-string? #f])
      (if (>= i n)
          (list->string (reverse out))
          (let ([c (string-ref text i)] [next (and (< (+ i 1) n) (string-ref text (+ i 1)))])
            (cond
              [in-string?
               (cond [(and (equal? c #\\) next) (loop (+ i 2) (cons next (cons c out)) #t)]
                     [(equal? c #\") (loop (+ i 1) (cons c out) #f)]
                     [else (loop (+ i 1) (cons c out) #t)])]
              [(equal? c #\") (loop (+ i 1) (cons c out) #t)]
              [(and (equal? c #\/) (equal? next #\/))
               (let skip ([j i]) (if (or (>= j n) (equal? (string-ref text j) #\newline)) (loop j out #f) (skip (+ j 1))))]
              [(and (equal? c #\/) (equal? next #\*))
               (let skip ([j (+ i 2)])
                 (cond [(>= (+ j 1) n) (loop n out #f)]
                       [(and (equal? (string-ref text j) #\*) (equal? (string-ref text (+ j 1)) #\/)) (loop (+ j 2) out #f)]
                       [else (skip (+ j 1))]))]
              [else (loop (+ i 1) (cons c out) #f)]))))))

(define (without-trailing-commas text)
  "`text` without the commas before a } or ], outside strings."
  (let ([n (string-length text)])
    (define (closes-next? j)
      (cond [(>= j n) #f]
            [(char-whitespace? (string-ref text j)) (closes-next? (+ j 1))]
            [else (memv (string-ref text j) '(#\} #\]))]))
    (let loop ([i 0] [out '()] [in-string? #f])
      (if (>= i n)
          (list->string (reverse out))
          (let ([c (string-ref text i)])
            (cond
              [in-string?
               (cond [(and (equal? c #\\) (< (+ i 1) n)) (loop (+ i 2) (cons (string-ref text (+ i 1)) (cons c out)) #t)]
                     [(equal? c #\") (loop (+ i 1) (cons c out) #f)]
                     [else (loop (+ i 1) (cons c out) #t)])]
              [(equal? c #\") (loop (+ i 1) (cons c out) #t)]
              [(and (equal? c #\,) (closes-next? (+ i 1))) (loop (+ i 1) out #f)]
              [else (loop (+ i 1) (cons c out) #f)]))))))

(define (read-json-config path)
  "The JSON in config file `path`, comments and trailing commas allowed,
   or #f if it can't be read."
  (with-handler (lambda (e) #f)
                (json-decode (without-trailing-commas (without-json-comments (read-file path))))))

(define (nearest-script-config dir)
  "The nearest tsconfig.json, or jsconfig.json, in `dir` or above it, or #f."
  (let up ([d dir])
    (cond [(file-exists? (join-path d "tsconfig.json")) (join-path d "tsconfig.json")]
          [(file-exists? (join-path d "jsconfig.json")) (join-path d "jsconfig.json")]
          [(or (equal? d "/") (equal? d "")) #f]
          [else (up (directory-of d))])))

(define (config-paths path depth)
  "The path aliases config `path` sets, or those of the configs it
   extends (relative ones only), as (paths . base): `paths` the hash of
   compilerOptions.paths, `base` the directory they're relative to (its
   baseUrl, else the config's own directory). #f with none."
  (let ([json (and (< depth 5) (file-exists? path) (read-json-config path))])
    (and (hash? json)
         (let ([dir (directory-of path)] [paths (jget json "compilerOptions" "paths")])
           (if (hash? paths)
               (cons paths (let ([base (jget json "compilerOptions" "baseUrl")])
                             (if (string? base) (join-path dir base) dir)))
               (let* ([ext (jget json "extends")]
                      [exts (cond [(string? ext) (list ext)] [(list? ext) (reverse ext)] [else '()])])
                 ;; The last of several extends wins, as in TypeScript.
                 (let loop ([exts exts])
                   (cond [(null? exts) #f]
                         [(and (string? (car exts))
                               (or (starts-with? (car exts) "./") (starts-with? (car exts) "../")))
                          (let* ([p (join-path dir (car exts))]
                                 [p (if (ends-with? p ".json") p (string-append p ".json"))])
                            (or (config-paths p (+ depth 1)) (loop (cdr exts))))]
                         [else (loop (cdr exts))]))))))))

(define (alias-match pattern name)
  "What `name` gives in alias `pattern`, as (prefix-length . star): star
   the part matching its *, \"\" for an exact pattern; #f if no match."
  (let ([star (let find ([i 0]) (cond [(>= i (string-length pattern)) #f]
                                      [(equal? (string-ref pattern i) #\*) i]
                                      [else (find (+ i 1))]))])
    (if star
        (let ([prefix (substring pattern 0 star)]
              [suffix (substring pattern (+ star 1) (string-length pattern))])
          (and (starts-with? name prefix) (ends-with? name suffix)
               (>= (string-length name) (+ (string-length prefix) (string-length suffix)))
               (cons (string-length prefix)
                     (substring name (string-length prefix) (- (string-length name) (string-length suffix))))))
        (and (equal? pattern name) (cons (+ (string-length name) 1) "")))))

(define (script-aliases name)
  "includeexpr for TypeScript and JavaScript: the paths `name` gives
   through the nearest config's compilerOptions.paths, from the pattern
   with the longest prefix (an exact one first)."
  (let ([found (let ([config (nearest-script-config (buffer-directory))])
                 (and config (config-paths config 0)))])
    (if (not found)
        '()
        (let* ([paths (car found)] [base (cdr found)]
               [best (let loop ([patterns (hash-keys->list paths)] [best #f])
                       (if (null? patterns)
                           best
                           (let ([m (alias-match (car patterns) name)])
                             (loop (cdr patterns)
                                   (if (and m (or (not best) (> (car m) (car (cadr best)))))
                                       (list (car patterns) m)
                                       best)))))])
          (if (not best)
              '()
              (let ([targets (hash-ref paths (car best))] [star (cdr (cadr best))])
                (map (lambda (t)
                       (let ([i (let find ([i 0]) (cond [(>= i (string-length t)) #f]
                                                        [(equal? (string-ref t i) #\*) i]
                                                        [else (find (+ i 1))]))])
                         (join-path base (if i
                                             (string-append (substring t 0 i) star (substring t (+ i 1) (string-length t)))
                                             t))))
                     (if (list? targets) (filter string? targets) '()))))))))

(set! *script-includeexpr* script-aliases)

(define (go-to-file-named! name split? at)
  "Opens the file `name` names, after splitting the window if `split?`,
   then goes to `at`, (line col) or #f; says so when there is no file,
   leaving the window as it was. Returns whether it opened something."
  (let ([path (find-file-named name)])
    (if path
        (begin
          (when split? (split! #f))
          (let ([opened (open-file! path)])
            (when (and opened at) (go-to-line-col! (car at) (cadr at)))
            (and opened #t)))
        (begin (message (string-append "Can't find file \"" name "\" in path")) #f))))

(define (go-to-file-under-cursor! split? line? count)
  "gf, or with `line?` gF: opens the file named under the cursor, or in
   visual mode the selection, in a new split if `split?`. gF goes to the
   line after the name, or to `count` when one was given."
  (let* ([visual? (eq? *mode* 'visual)]
         [at (and (not visual?) (file-name-under-cursor))]
         [name (if visual?
                   (let ([n (selected-file-name)]) (leave-visual!) (and (not (equal? n "")) n))
                   (and at (car at)))]
         [line (and line?
                    (if *count-given*
                        (list count #f)
                        (and at (line-after-name (buffer-substring (cdr at) (line-end (current-line)))))))])
    (if name
        (go-to-file-named! name split? line)
        (begin (message "No file name under cursor") #f))))

(define-key! 'normal "gf" (lambda (count) (go-to-file-under-cursor! #f #f count)) "go to file")
(define-key! 'visual "gf" (lambda (count) (go-to-file-under-cursor! #f #f count)) "go to file")
(define-key! 'normal "gF" (lambda (count) (go-to-file-under-cursor! #f #t count)) "go to file and line")
(window-command! '("f" "C-f") (lambda (count) (go-to-file-under-cursor! #t #f count)))
(window-command! '("F") (lambda (count) (go-to-file-under-cursor! #t #t count)))
(for-each (lambda (state)
            (set-binding-label! state "C-wf" "file under cursor in a split")
            (set-binding-label! state "C-wC-f" "file under cursor in a split")
            (set-binding-label! state "C-wF" "file and line in a split"))
          '(normal visual))
