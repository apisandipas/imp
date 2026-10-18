;;; syntax.scm -- tree-sitter: highlighting, structural text objects.
;;;
;;; Rust parses each buffer that has a language and keeps the tree up to
;;; date as you type. Highlighting draws faces named after the grammar's
;;; captures (syntax.keyword, syntax.function.method...), most specific
;;; first, so a theme is a set of set-face! calls. Text objects are defined
;;; here from node kinds, using two primitives: syntax-ancestors (the nodes
;;; around a position) and syntax-children (a node's children).

;;; The theme (One Dark colors)

(for-each
 (lambda (f) (set-face! (car f) (cadr f)))
 (list (list "syntax.keyword" "fg=#c678dd")
       (list "syntax.string" "fg=#98c379")
       (list "syntax.string.special" "fg=#56b6c2")
       (list "syntax.escape" "fg=#56b6c2")
       (list "syntax.comment" "fg=#7f848e italic")
       (list "syntax.function" "fg=#61afef")
       (list "syntax.function.macro" "fg=#56b6c2")
       (list "syntax.type" "fg=#e5c07b")
       (list "syntax.constructor" "fg=#e5c07b")
       (list "syntax.module" "fg=#e5c07b")
       (list "syntax.constant" "fg=#d19a66")
       (list "syntax.number" "fg=#d19a66")
       (list "syntax.boolean" "fg=#d19a66")
       (list "syntax.variable.builtin" "fg=#e06c75")
       (list "syntax.variable.parameter" "fg=#e06c75")
       (list "syntax.property" "fg=#e06c75")
       (list "syntax.label" "fg=#e06c75")
       (list "syntax.tag" "fg=#e06c75")
       (list "syntax.attribute" "fg=#e5c07b")
       (list "syntax.operator" "fg=#56b6c2")
       (list "syntax.punctuation" "fg=#848b98")
       (list "syntax.punctuation.special" "fg=#c678dd")
       (list "syntax.embedded" "fg=#e06c75")
       ;; Markdown
       (list "syntax.text.title" "fg=#e06c75 bold")
       (list "syntax.text.literal" "fg=#98c379")
       (list "syntax.text.uri" "fg=#61afef underline")
       (list "syntax.text.reference" "fg=#61afef")
       (list "syntax.text.emphasis" "italic")
       (list "syntax.text.strong" "bold")))

;;; Languages by major mode

(define *mode-languages*
  (hash 'rust-mode "rust" 'scheme-mode "scheme" 'repl-mode "scheme"
        'javascript-mode "javascript" 'typescript-mode "typescript"
        'nix-mode "nix" 'markdown-mode "markdown"))

;; The language for the current buffer: its major mode's, with .tsx files
;; parsed as TSX.
(define (language-for-buffer)
  (let ([lang (hash-try-get *mode-languages* (major-mode))]
        [path (or (buffer-path) "")])
    (if (and (equal? lang "typescript") (ends-with? path ".tsx")) "tsx" lang)))

(define (define-mode-language! mode language)
  (set! *mode-languages* (hash-insert *mode-languages* mode language)))

(add-hook! 'major-mode
           (lambda (mode)
             (set-buffer-language! (or (language-for-buffer) ""))
             ;; Brace languages indent after { ( [ .
             (when (memq 'prog-mode (mode-lineage mode))
               (set-local-option! 'smartindent (not (memq mode '(scheme-mode lisp-mode repl-mode)))))))

;; :syntax-tree shows the current buffer's tree, for writing text objects.
(define-ex! '("syntax-tree")
  (lambda (ex)
    (let ([tree (syntax-tree)])
      (show-popup! (if tree (split-sexp tree) (list "no syntax tree (no language for this buffer)"))))))

;; Breaks a one-line S-expression into lines at each "(", indented by depth.
(define (split-sexp text)
  (let loop ([cs (string->list text)] [depth 0] [line '()] [lines '()])
    (cond
      [(null? cs) (reverse (if (null? line) lines (cons (list->string (reverse line)) lines)))]
      [(and (equal? (car cs) #\() (pair? line))
       (loop (cdr cs) (+ depth 1) (cons #\( (string->list (make-string (* 2 depth) #\space)) )
             (cons (list->string (reverse line)) lines))]
      [(equal? (car cs) #\() (loop (cdr cs) (+ depth 1) (cons #\( line) lines)]
      [(equal? (car cs) #\)) (loop (cdr cs) (- depth 1) (cons #\) line) lines)]
      [else (loop (cdr cs) depth (cons (car cs) line) lines)])))

;;; Structural text objects: af if (function), ac ic (class or type),
;;; aa ia (argument or parameter).

(define (node-kind n) (car n))
(define (node-field n) (cadr n))
(define (node-start n) (caddr n))
(define (node-end n) (cadddr n))

;; Node kinds per language. Add your own with define-syntax-objects!.
(define *syntax-objects* (hash))

(define (define-syntax-objects! language functions classes argument-lists)
  (set! *syntax-objects*
        (hash-insert *syntax-objects* language (list functions classes argument-lists))))

(define-syntax-objects! "rust"
  '("function_item" "closure_expression" "function_signature_item")
  '("struct_item" "enum_item" "impl_item" "trait_item" "union_item" "mod_item")
  '("arguments" "parameters" "type_arguments" "type_parameters" "tuple_expression" "array_expression"))

(define js-functions
  '("function_declaration" "function_expression" "function" "arrow_function" "method_definition"
    "generator_function_declaration" "generator_function"))
(define js-classes '("class_declaration" "class" "interface_declaration" "enum_declaration" "type_alias_declaration"))
(define js-lists '("arguments" "formal_parameters" "type_arguments" "type_parameters" "array"))
(for-each (lambda (l) (define-syntax-objects! l js-functions js-classes js-lists))
          '("javascript" "typescript" "tsx"))

(define-syntax-objects! "nix" '("function_expression") '("attrset_expression" "rec_attrset_expression")
  '("formals" "list_expression"))

(define-syntax-objects! "scheme" '("list") '("list") '("list"))

;; The `n`th innermost node around `at` whose kind is in `kinds`.
(define (enclosing-node at kinds n)
  (let loop ([nodes (syntax-ancestors at)] [n n])
    (cond [(null? nodes) #f]
          [(member (node-kind (car nodes)) kinds)
           (if (= n 1) (car nodes) (loop (cdr nodes) (- n 1)))]
          [else (loop (cdr nodes) n)])))

;; Scheme has no function nodes; a function is a list starting with
;; define or lambda.
(define (scheme-function? node)
  (let ([text (buffer-substring (+ 1 (node-start node)) (min (node-end node) (+ 8 (node-start node))))])
    (or (starts-with? text "define") (starts-with? text "lambda"))))

(define (syntax-kinds which)
  (let* ([lang (buffer-language)] [spec (and lang (hash-try-get *syntax-objects* lang))])
    (and spec (list-ref spec which))))

;; The inner part of a function or class: its body without the braces,
;; whole lines when the braces sit on their own lines, as i{ does.
(define (inner-range node)
  (let* ([body (let loop ([cs (syntax-children (node-start node) (node-end node))])
                 (cond [(null? cs) #f]
                       [(equal? (node-field (car cs)) "body") (car cs)]
                       [else (loop (cdr cs))]))]
         [b (or body node)]
         [s (node-start b)] [e (node-end b)]
         [open (buffer-char-at s)])
    (cond
      [(and (memv open (list #\{ #\( #\[)) (> e (+ s 1)))
       (let ([o s] [c (- e 1)])
         (if (and (equal? (buffer-char-at (+ o 1)) #\newline)
                  (only-blanks-before? c)
                  (> (offset->line c) (+ (offset->line o) 1)))
             (lines-range (+ (offset->line o) 1) (- (offset->line c) 1))
             (list (+ o 1) c #f)))]
      [else (list s e #f)])))

(define (syntax-object which inner?)
  (lambda (from n)
    (let ([kinds (syntax-kinds which)])
      (and kinds
           (let* ([scheme? (equal? (buffer-language) "scheme")]
                  [node (if (and scheme? (= which 0))
                            (let loop ([nodes (syntax-ancestors from)] [n n])
                              (cond [(null? nodes) #f]
                                    [(and (equal? (node-kind (car nodes)) "list") (scheme-function? (car nodes)))
                                     (if (= n 1) (car nodes) (loop (cdr nodes) (- n 1)))]
                                    [else (loop (cdr nodes) n)]))
                            (enclosing-node from kinds n))])
             (and node
                  (if inner?
                      (if scheme?
                          (list (+ 1 (node-start node)) (- (node-end node) 1) #f)
                          (inner-range node))
                      (list (node-start node) (node-end node) #f))))))))

;; aa and ia: an argument (or parameter, array element...). The node whose
;; parent is a list kind; aa takes the comma and space after it, or before
;; it if it is the last.
(define (argument-object around?)
  (lambda (from n)
    (let ([lists (syntax-kinds 2)])
      (and lists
           (let loop ([nodes (syntax-ancestors from)])
             (cond
               [(or (null? nodes) (null? (cdr nodes))) #f]
               [(member (node-kind (cadr nodes)) lists)
                (let ([arg (car nodes)] [parent (cadr nodes)])
                  (if (not around?)
                      (list (node-start arg) (node-end arg) #f)
                      (let* ([siblings (filter (lambda (c) (caddr (cddr c)))
                                               (syntax-children (node-start parent) (node-end parent)))]
                             [after (filter (lambda (c) (> (node-start c) (node-start arg))) siblings)])
                        (if (pair? after)
                            (list (node-start arg) (node-start (car after)) #f)
                            (let ([before (filter (lambda (c) (< (node-start c) (node-start arg))) siblings)])
                              (if (pair? before)
                                  (list (node-end (last before)) (node-end arg) #f)
                                  (list (node-start arg) (node-end arg) #f)))))))]
               [else (loop (cdr nodes))]))))))

(define-text-object! "af" (syntax-object 0 #f))
(define-text-object! "if" (syntax-object 0 #t))
(define-text-object! "ac" (syntax-object 1 #f))
(define-text-object! "ic" (syntax-object 1 #t))
(define-text-object! "aa" (argument-object #t))
(define-text-object! "ia" (argument-object #f))
