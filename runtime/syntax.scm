;;; syntax.scm -- tree-sitter: highlighting, structural text objects.
;;;
;;; Rust parses each buffer that has a language and keeps the tree up to
;;; date as you type. Highlighting draws faces named after the grammar's
;;; captures (syntax.keyword, syntax.function.method...), most specific
;;; first, so a theme is a set of set-face! calls. Text objects are defined
;;; here from node kinds, using two primitives: syntax-ancestors (the nodes
;;; around a position) and syntax-children (a node's children).

;;; The colors are faces named syntax.<capture>; theme.scm sets them.

;;; Languages by major mode

(define *mode-languages*
  (hash 'rust-mode "rust" 'scheme-mode "scheme" 'repl-mode "scheme"
        'javascript-mode "javascript" 'typescript-mode "typescript"
        'nix-mode "nix" 'markdown-mode "markdown"
        'html-mode "html" 'css-mode "css" 'json-mode "json"))

(define (language-for-buffer)
  "The tree-sitter language for the current buffer, or #f for none.
   It is its major mode's, except that .tsx files are parsed as TSX."
  (let ([lang (hash-try-get *mode-languages* (major-mode))]
        [path (or (buffer-path) "")])
    (if (and (equal? lang "typescript") (ends-with? path ".tsx")) "tsx" lang)))

(define (define-mode-language! mode language)
  "Parses buffers in major mode `mode` with tree-sitter grammar
   `language` (a name like \"rust\")."
  (set! *mode-languages* (hash-insert *mode-languages* mode language))
  void)

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

(define (split-sexp text)
  "Breaks a one-line S-expression into lines at each \"(\", indented by depth."
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

(define (node-kind n)
  "The kind of syntax node `n`, like \"function_item\"."
  (car n))
(define (node-field n)
  "The field name syntax node `n` has in its parent, or \"\" for none."
  (cadr n))
(define (node-start n)
  "The offset where syntax node `n` starts."
  (caddr n))
(define (node-end n)
  "The offset just past the end of syntax node `n`."
  (cadddr n))

;; Node kinds per language. Add your own with define-syntax-objects!.
(define *syntax-objects* (hash))

(define (define-syntax-objects! language functions classes argument-lists)
  "Sets the node kinds the structural text objects use for `language`.
   `functions` are for af and if, `classes` for ac and ic, and
   `argument-lists` the lists whose children aa and ia select."
  (set! *syntax-objects*
        (hash-insert *syntax-objects* language (list functions classes argument-lists)))
  void)

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

(define (enclosing-node at kinds n)
  "The `n`th innermost node around `at` whose kind is in `kinds`."
  (let loop ([nodes (syntax-ancestors at)] [n n])
    (cond [(null? nodes) #f]
          [(member (node-kind (car nodes)) kinds)
           (if (= n 1) (car nodes) (loop (cdr nodes) (- n 1)))]
          [else (loop (cdr nodes) n)])))

(define (scheme-function? node)
  "Whether Scheme list `node` is a function: starts with define or lambda.
   Scheme's grammar has no function nodes, only lists."
  (let ([text (buffer-substring (+ 1 (node-start node)) (min (node-end node) (+ 8 (node-start node))))])
    (or (starts-with? text "define") (starts-with? text "lambda"))))

(define (syntax-kinds which)
  "The node kinds of text object group `which` for the buffer's language.
   `which` is 0 for functions, 1 for classes, 2 for argument lists; #f
   when the language has none defined."
  (let* ([lang (buffer-language)] [spec (and lang (hash-try-get *syntax-objects* lang))])
    (and spec (list-ref spec which))))

(define (inner-range node)
  "The range of the inner part of function or class `node`.
   That is its body without the braces, as whole lines when the braces
   sit on their own lines, as i{ does."
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
  "A text object for the `n`th enclosing function (`which` 0) or class
   (1); `inner?` selects only its body.
   In Scheme a function is a list starting with define or lambda, and its
   inner part is the list without its parentheses."
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

(define (argument-object around?)
  "The text object aa (`around?`) or ia: an argument or parameter.
   It is the node around the cursor whose parent is a list kind (an
   argument list, parameters, an array...); aa takes the comma and space
   after it, or before it if it is the last."
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
