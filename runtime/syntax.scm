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
        'html-mode "html" 'css-mode "css" 'json-mode "json"
        'yaml-mode "yaml" 'toml-mode "toml" 'shell-mode "bash"
        'c-mode "c" 'cpp-mode "cpp" 'go-mode "go" 'python-mode "python"
        'lua-mode "lua" 'elixir-mode "elixir" 'ruby-mode "ruby"))

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
             ;; A grammar that won't load says why, and the buffer is plain.
             (let ([loaded (set-buffer-language! (or (language-for-buffer) ""))])
               (when (string? loaded) (message loaded)))
             ;; Brace languages indent after { ( [ .
             (when (memq 'prog-mode (mode-lineage mode))
               (set-local-option! 'smartindent (not (memq mode '(scheme-mode lisp-mode repl-mode)))))))

(define-command! 'syntax-tree
  (lambda (count)
    "Show the current buffer's tree-sitter syntax tree, for writing text objects."
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

(define-syntax-objects! "c" '("function_definition")
  '("struct_specifier" "enum_specifier" "union_specifier")
  '("argument_list" "parameter_list" "initializer_list"))

(define-syntax-objects! "cpp" '("function_definition" "lambda_expression")
  '("class_specifier" "struct_specifier" "enum_specifier" "union_specifier" "namespace_definition")
  '("argument_list" "parameter_list" "template_argument_list" "template_parameter_list" "initializer_list"))

(define-syntax-objects! "go" '("function_declaration" "method_declaration" "func_literal")
  '("type_declaration")
  '("argument_list" "parameter_list" "literal_value"))

(define-syntax-objects! "python" '("function_definition" "lambda")
  '("class_definition")
  '("argument_list" "parameters" "list" "tuple"))

;; Lua has no classes. Elixir's def is a call like any other, so only fn
;; is a function node.
(define-syntax-objects! "lua" '("function_declaration" "function_definition") '()
  '("arguments" "parameters" "table_constructor"))

(define-syntax-objects! "elixir" '("anonymous_function") '()
  '("arguments" "list" "tuple" "map_content"))

(define-syntax-objects! "ruby" '("method" "singleton_method" "lambda")
  '("class" "module" "singleton_class")
  '("argument_list" "method_parameters" "lambda_parameters" "block_parameters" "array"))

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

;;; End tags: typing a start tag's > closes it (docs/specs/auto-pairs.md).
;;; insert mode and the Emacs state call close-tag-for! through
;;; *typed-char-handler*, as vim.scm loads first.

;; Whether typing a start tag's > adds its end tag.
(define-option! 'auto-close-tags #t '())

(define html-void-elements
  '("area" "base" "br" "col" "embed" "hr" "img" "input" "link" "meta" "param" "source" "track" "wbr"))

(define (node-text n)
  "The buffer's text that syntax node `n` spans."
  (buffer-substring (node-start n) (node-end n)))

(define (child-of-kind n kind)
  "The first child of syntax node `n` of `kind`, or #f."
  (let loop ([cs (syntax-children (node-start n) (node-end n))])
    (cond [(null? cs) #f]
          [(equal? (node-kind (car cs)) kind) (car cs)]
          [else (loop (cdr cs))])))

(define (element-name element)
  "The tag name of HTML `element`, from its start tag, or #f."
  (let* ([tag (child-of-kind element "start_tag")]
         [name (and tag (child-of-kind tag "tag_name"))])
    (and name (node-text name))))

(define (xml-file?)
  "Whether the buffer is an XML or SVG file, where no element is void."
  (let ([path (or (buffer-path) "")])
    (or (ends-with? path ".xml") (ends-with? path ".svg"))))

(define (html-end-tag-wanted nodes)
  "The end tag to add after the start tag the cursor just closed, or #f.
   `nodes` are HTML's nodes around its >, innermost first. An element
   with its end tag gets none, unless it took that end tag from an
   enclosing one of the same name, as the parser does when <div> is
   typed inside <div></div>. A start tag the parser couldn't place in an
   element (a lone <b> is an ERROR) has none."
  (and (pair? nodes) (pair? (cdr nodes))
       (equal? (node-kind (car nodes)) "start_tag")
       (= (node-end (car nodes)) (cursor))
       (let* ([tag-name (child-of-kind (car nodes) "tag_name")]
              [name (and tag-name (node-text tag-name))]
              [element (and (equal? (node-kind (cadr nodes)) "element") (cadr nodes))])
         (and name
              (or (xml-file?) (not (member (string-downcase name) html-void-elements)))
              (or (not element)
                  (not (child-of-kind element "end_tag"))
                  (let loop ([outer (cddr nodes)])
                    (cond [(null? outer) #f]
                          [(and (equal? (node-kind (car outer)) "element")
                                (equal? (element-name (car outer)) name)
                                (not (child-of-kind (car outer) "end_tag")))
                           #t]
                          [else (loop (cdr outer))])))
              (string-append "</" name ">")))))

(define (html-open-element-name nodes)
  "The name of the innermost element among `nodes` with no end tag, or #f.
   Start tags the parser left in an ERROR count as open elements."
  (let loop ([ns nodes])
    (cond
      [(null? ns) #f]
      [(and (equal? (node-kind (car ns)) "element") (not (child-of-kind (car ns) "end_tag")))
       (or (element-name (car ns)) (loop (cdr ns)))]
      [(equal? (node-kind (car ns)) "ERROR")
       (or (error-open-tag (car ns)) (loop (cdr ns)))]
      [else (loop (cdr ns))])))

(define (error-open-tag error)
  "The last start tag in ERROR node `error` not closed by an end tag in it
   before the cursor, or #f. The parser lays out tags it can't match flat
   in one: <p><b>x</ is an ERROR of p's start tag, b's and the text."
  (let loop ([cs (syntax-children (node-start error) (node-end error))] [open '()])
    (define (name-of tag kind)
      (let ([n (child-of-kind tag kind)]) (and n (node-text n))))
    (cond
      [(or (null? cs) (>= (node-start (car cs)) (cursor))) (and (pair? open) (car open))]
      [(equal? (node-kind (car cs)) "start_tag")
       (let ([name (name-of (car cs) "tag_name")])
         (loop (cdr cs)
               (if (and name (or (xml-file?) (not (member (string-downcase name) html-void-elements))))
                   (cons name open)
                   open)))]
      [(equal? (node-kind (car cs)) "end_tag")
       (let ([name (name-of (car cs) "tag_name")])
         (loop (cdr cs) (if (and (pair? open) (equal? (car open) name)) (cdr open) open)))]
      [else (loop (cdr cs) open)])))

(define (close-tag-for! c)
  "After `c` is typed: a start tag's > adds its end tag after the cursor,
   and the / of </ completes the innermost open element's end tag."
  (let ([p (cursor)])
    (when (and (option 'auto-close-tags) (> p 1))
      (cond
        [(equal? c #\>)
         (let* ([at (syntax-at (- p 1))]
                [end (and (pair? at) (equal? (car at) "html") (html-end-tag-wanted (cdr at)))])
           (when end (buffer-insert! p end)))]
        [(and (equal? c #\/) (equal? (buffer-char-at (- p 2)) #\<))
         ;; From the char before <, as an element that ends there is
         ;; open: the parser ends <b> at a </ it can't match yet.
         (let* ([at (syntax-at (max 0 (- p 3)))]
                [name (and (pair? at) (equal? (car at) "html") (html-open-element-name (cdr at)))])
           (when name
             (insert-text! (string-append name ">"))))]
        [else void])))
  void)

(set! *typed-char-handler* (lambda (c) (close-tag-for! c)))
