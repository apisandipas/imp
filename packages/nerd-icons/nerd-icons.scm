;;; nerd-icons.scm -- Nerd Font icons in the status line and the menus,
;;; after Emacs's nerd-icons.
;;;
;;;   (use-package! 'nerd-icons)
;;;
;;; The status line gets the buffer's file-type icon before its name and
;;; the git branch (with its icon) on the right; M-x, find-file,
;;; switch-buffer and the other pickers get an icon before each candidate
;;; (a file's by its type, a buffer's by its mode, a command's...); the
;;; insert-mode completion menu gets the language server's kind of each
;;; candidate (function, variable, class...) and file and folder icons;
;;; dired and the file tree get each entry's icon before its name.
;;;
;;; The icons are in Nerd Fonts' private-use characters, so the font
;;; needs them: a "Nerd Font Mono" (set-option! 'font "VictorMono Nerd
;;; Font Mono"), whose icons are one cell wide. Add or change one:
;;;
;;;   (set-nerd-icon! 'extension "zig" "E6A9")   ; nf-seti-zig
;;;   (set-nerd-icon! 'mode 'zig-mode "E6A9")

(define (hex->char hex)
  "The character whose code point is hexadecimal string `hex`."
  (integer->char
   (foldl (lambda (c n) (+ (* n 16) (let ([d (char->integer (char-upcase c))])
                                       (if (>= d 65) (- d 55) (- d 48)))))
          0 (string->list hex))))

(define (nerd hex)
  "Icon `hex` (its code point in hexadecimal) as a string."
  (string (hex->char hex)))

;; The tables: (kind key) -> icon string.
(define *nerd-icons* (hash))

(define (set-nerd-icon! kind key hex)
  "Uses icon `hex` (a Nerd Font code point in hexadecimal) for `key` of
   `kind`: 'extension (a file extension, without the dot), 'name (a whole
   file name), 'mode (a major mode), 'category (a picker's: 'command,
   'symbol...) or 'lsp-kind (a completion item kind number)."
  (set! *nerd-icons* (hash-insert *nerd-icons* (list kind key) (nerd hex)))
  void)

(define (nerd-icon kind key)
  "The icon for `key` of `kind`, or #f."
  (hash-try-get *nerd-icons* (list kind key)))

(for-each (lambda (e) (set-nerd-icon! 'extension (car e) (cadr e)))
          '(("rs" "E7A8") ("scm" "F0627") ("ss" "F0627") ("rkt" "F0627") ("el" "F0627")
            ("lisp" "F0627") ("clj" "F0627") ("fnl" "F0627")
            ("ts" "E628") ("tsx" "E628") ("js" "E60C") ("jsx" "E60C") ("mjs" "E60C")
            ("nix" "F313") ("md" "E73E") ("markdown" "E73E") ("org" "E633")
            ("py" "E73C") ("json" "E60B") ("toml" "E615") ("yaml" "E615") ("yml" "E615")
            ("kdl" "E615") ("ini" "E615") ("conf" "E615")
            ("sh" "E795") ("bash" "E795") ("zsh" "E795") ("fish" "E795")
            ("c" "E61E") ("h" "E61E") ("cpp" "E61D") ("hpp" "E61D") ("go" "E724") ("lua" "E620")
            ("html" "E736") ("css" "E749") ("scss" "E749") ("zig" "E6A9")
            ("txt" "F0F6") ("lock" "F023") ("svg" "F1C5") ("png" "F1C5") ("jpg" "F1C5")
            ("pdf" "F1C1") ("wasm" "E6A1")))
(for-each (lambda (e) (set-nerd-icon! 'name (car e) (cadr e)))
          '(("Makefile" "E779") ("Cargo.toml" "E7A8") ("flake.nix" "F313") ("flake.lock" "F313")
            (".gitignore" "E702") ("README.md" "F48A") ("LICENSE" "F02D") ("Dockerfile" "E7B0")))
(for-each (lambda (e) (set-nerd-icon! 'mode (car e) (cadr e)))
          '((rust-mode "E7A8") (scheme-mode "F0627") (repl-mode "F0627") (lisp-mode "F0627")
            (typescript-mode "E628") (javascript-mode "E60C") (nix-mode "F313")
            (markdown-mode "E73E") (org-mode "E633") (python-mode "E73C") (json-mode "E60B")
            (toml-mode "E615") (sh-mode "E795") (c-mode "E61E") (go-mode "E724") (lua-mode "E620")
            (makefile-mode "E779") (text-mode "F0F6") (fundamental-mode "F016")
            (dired-mode "F07C") (term-mode "E795") (start-mode "F015") (faces-mode "F03D8")
            (git-status-mode "E702") (git-log-mode "E702") (git-diff-mode "E702")
            (git-commit-mode "E702") (grep-mode "F002") (org-agenda-mode "F073")
            (special-mode "F0F6")))
(for-each (lambda (e) (set-nerd-icon! 'category (car e) (cadr e)))
          '((command "F0E7") (symbol "F0627") (option "F013") (project "F401") (theme "F03D8")))
;; LSP CompletionItemKind: Text Method Function Constructor Field Variable
;; Class Interface Module Property Unit Value Enum Keyword Snippet Color
;; File Reference Folder EnumMember Constant Struct Event Operator
;; TypeParameter, as codicons.
(let loop ([kind 1]
           [hexes '("EA93" "EA8C" "EA8C" "EA8C" "EB5F" "EA88" "EB5B" "EB61" "EA8B" "EB65" "EA96"
                    "EA95" "EA95" "EB62" "EB66" "EB5C" "EA7B" "EA94" "EA83" "EB5E" "EB5D" "EA91"
                    "EA86" "EB64" "EA92")])
  (unless (null? hexes)
    (set-nerd-icon! 'lsp-kind kind (car hexes))
    (loop (+ kind 1) (cdr hexes))))

(define nerd-folder (nerd "F07B"))
(define nerd-file (nerd "F016"))
(define nerd-branch (nerd "E725"))
(define nerd-robot (nerd "F06A9"))

(define (nerd-file-icon path)
  "The icon for file `path` (a name ending in / is a folder): by its whole
   name, then its extension, else a plain file."
  (let ([name (file-name-of (if (ends-with? path "/") (substring path 0 (- (string-length path) 1)) path))])
    (cond [(ends-with? path "/") nerd-folder]
          [(nerd-icon 'name name) => (lambda (i) i)]
          [(nerd-icon 'extension (extension-of name)) => (lambda (i) i)]
          [else nerd-file])))

(define (nerd-buffer-icon id)
  "The icon for buffer `id`: its file's, else its major mode's."
  (let ([path (cadr (buffer-info id))])
    (if path
        (nerd-file-icon path)
        (let ([mode (with-buffer id (lambda () (major-mode)))])
          (cond [(with-buffer id (lambda () (buffer-local 'claude-root))) nerd-robot]
                [(nerd-icon 'mode mode) => (lambda (i) i)]
                [else nerd-file])))))

;;; The pickers and the completion menu

(set! *completion-icon*
      (lambda (category candidate)
        (case category
          [(file) (nerd-file-icon candidate)]
          [(buffer) (let ([id (list-find (lambda (id) (equal? (car (buffer-info id)) candidate)) (buffer-list))])
                      (if id (nerd-buffer-icon id) nerd-file))]
          [else (and category (nerd-icon 'category category))])))

(set! *menu-icon*
      (lambda (source candidate)
        (case source
          [(file) (nerd-file-icon (car candidate))]
          [(lsp) (let ([item (car (cddddr candidate))])
                   (or (let ([kind (completion-item-kind item)]) (and kind (nerd-icon 'lsp-kind kind)))
                       (nerd-icon 'lsp-kind 1)))]
          [(scheme) (nerd-icon 'category 'symbol)]
          [(snippets snippet-choice) (nerd-icon 'lsp-kind 15)]
          ;; The command line's menu: files by type, the rest as commands.
          [(cmdline) (let ([l (car candidate)])
                       (if (or (string-contains? l "/") (string-contains? l "."))
                           (nerd-file-icon l)
                           (nerd-icon 'category 'command)))]
          [else (nerd-icon 'lsp-kind 1)])))

(set! *dired-icon* nerd-file-icon)
(set! *open-folder-icon* (nerd "F07C"))
(for-each (lambda (id) (with-buffer id (lambda () (when (eq? (major-mode) 'dired-mode) (dired-show-details!)))))
          (buffer-list))

;;; The status line

(define-option! 'nerd-icons-statusline #t '())

(define (nerd-statusline format)
  "Status line `format` with %{icon} before the file name and %{branch}
   at the start of the right-hand side, unless it has them already."
  (let* ([format (if (or (string-contains? format "%{icon}") (not (string-contains? format "%f")))
                     format
                     (string-replace-first format "%#status.file#%f" "%{icon} %#status.file#%f"))]
         [format (if (or (string-contains? format "%{branch}") (not (string-contains? format "%=")))
                     format
                     (string-replace-first format "%=" "%=%#status.dim#%{branch}%*"))])
    format))

(define (string-replace-first text old new)
  "`text` with its first `old` replaced by `new` (unchanged without one)."
  (let ([n (string-length old)])
    (let loop ([i 0])
      (cond [(> (+ i n) (string-length text)) text]
            [(equal? (substring text i (+ i n)) old)
             (string-append (substring text 0 i) new (substring text (+ i n) (string-length text)))]
            [else (loop (+ i 1))]))))

(define (nerd-branch-of path)
  "The git branch of the repository holding file `path`, or #f."
  (let ([root (git-root-of (directory-of (absolute-path path)))])
    (and root
         (let ([b (trim (git-output root "branch --show-current"))])
           (and (not (equal? b "")) b)))))

(define (nerd-update-status!)
  "Sets the current buffer's %{icon} and %{branch}."
  (set-status-value! "icon" (nerd-buffer-icon (current-buffer)) #f)
  (let ([branch (and (buffer-path) (nerd-branch-of (buffer-path)))])
    (set-status-value! "branch" (if branch (string-append nerd-branch " " branch "  ") "") #f)))

(when (option 'nerd-icons-statusline)
  (set-option! 'statusline (nerd-statusline (option 'statusline)))
  (add-hook! 'major-mode (lambda (mode) (nerd-update-status!)))
  (add-hook! 'buffer-renamed (lambda args (nerd-update-status!)))
  (for-each (lambda (id) (with-buffer id nerd-update-status!)) (buffer-list)))
