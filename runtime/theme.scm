;;; theme.scm -- how imp looks: themes, and the status line.
;;;
;;; Every color is a face (core.scm). A theme here is a palette of a few
;;; named colors, from which theme-faces makes every face, so switching
;;; themes leaves nothing behind. :theme NAME (or M-x load-theme) switches;
;;; in init.scm:
;;;
;;;   (load-theme! 'gruvbox-dark)
;;;   (define-theme! 'mine 'one-dark                ; start from one-dark
;;;     (hash 'blue "#7aa2f7" 'bg "#1a1b26")        ; change some colors
;;;     (list (list "syntax.comment" "fg=#565f89"))) ; and some faces
;;;
;;; Palette names: bg (text background), bg-alt (status line, popups),
;;; bg-hl (cursor line), selection, border, fg, dim, comment, punct, red,
;;; orange, yellow, green, cyan, blue, magenta, debug-bg.

(define *themes* (hash))  ; name -> (palette extra-faces)
(define *theme* #f)       ; the theme loaded

(define (define-theme! name parent palette faces)
  (let* ([base (if parent (hash-ref *themes* parent) (list (hash) '()))]
         [merged (foldl (lambda (k h) (hash-insert h k (hash-ref palette k))) (car base) (hash-keys->list palette))])
    (set! *themes* (hash-insert *themes* name (list merged (append (cadr base) faces))))))

;; Every face, from a palette.
(define (theme-faces p)
  (let* ([c (lambda (name) (hash-ref p name))]
         [fg (lambda (name . more)
               (apply string-append (cons (string-append "fg=" (c name)) (map (lambda (m) (string-append " " m)) more))))]
         [mode-face (lambda (name) (string-append "fg=" (c 'bg) " bg=" (c name) " bold"))])
    (list
     ;; The text and the frame around it
     (list "normal" (string-append "fg=" (c 'fg) " bg=" (c 'bg)))
     (list "nontext" (fg 'border))
     (list "line-number" (fg 'dim))
     (list "line-number-current" (fg 'yellow "bold"))
     (list "cursorline" (string-append "bg=" (c 'bg-hl)))
     (list "sign-column" "")
     (list "separator" (fg 'border))
     (list "visual" (string-append "bg=" (c 'selection)))
     (list "search" (string-append "fg=" (c 'bg) " bg=" (c 'yellow)))
     (list "search-current" (string-append "fg=" (c 'bg) " bg=" (c 'orange) " bold"))
     ;; The status line
     (list "status" (string-append "fg=" (c 'fg) " bg=" (c 'bg-alt)))
     (list "status-inactive" (string-append "fg=" (c 'dim) " bg=" (c 'bg-alt)))
     (list "status.mode.normal" (mode-face 'blue))
     (list "status.mode.insert" (mode-face 'green))
     (list "status.mode.visual" (mode-face 'magenta))
     (list "status.mode.replace" (mode-face 'red))
     (list "status.mode.command" (mode-face 'yellow))
     (list "status.mode.emacs" (mode-face 'orange))
     (list "status.file" "bold")
     (list "status.modified" (fg 'yellow))
     (list "status.dim" (fg 'dim))
     (list "status.error" (fg 'red "bold"))
     (list "status.warning" (fg 'yellow "bold"))
     ;; Popups: which-key, menus, hover
     (list "popup" (string-append "fg=" (c 'fg) " bg=" (c 'bg-alt)))
     (list "popup-selected" (string-append "bg=" (c 'selection) " bold"))
     (list "popup-border" (string-append "fg=" (c 'border) " bg=" (c 'bg-alt)))
     (list "popup-title" (fg 'blue "bold"))
     (list "popup.detail" (fg 'dim))
     (list "popup.match" (fg 'blue "bold"))
     (list "which-key.key" (fg 'magenta "bold"))
     (list "which-key.separator" (fg 'dim))
     (list "which-key.group" (fg 'blue))
     (list "which-key.command" "")
     ;; Diagnostics and debugging
     (list "diagnostic.error" (fg 'red "underline"))
     (list "diagnostic.warning" (fg 'yellow "underline"))
     (list "diagnostic.info" "underline")
     (list "diagnostic.hint" "underline")
     (list "sign.error" (fg 'red "bold"))
     (list "sign.warning" (fg 'yellow "bold"))
     (list "sign.info" (fg 'blue))
     (list "sign.hint" (fg 'dim))
     (list "sign.breakpoint" (fg 'red "bold"))
     (list "sign.debug" (fg 'yellow "bold"))
     (list "debug-line" (string-append "bg=" (c 'debug-bg)))
     (list "fold" (fg 'comment))
     (list "grep.location" (fg 'magenta))
     ;; The file browser
     (list "dired.directory" (fg 'blue "bold"))
     (list "dired.hidden" (fg 'dim))
     ;; Org
     (list "org.level1" (fg 'blue "bold"))
     (list "org.level2" (fg 'magenta "bold"))
     (list "org.level3" (fg 'cyan "bold"))
     (list "org.level4" (fg 'green "bold"))
     (list "org.todo" (fg 'red "bold"))
     (list "org.done" (fg 'green "bold"))
     (list "org.tag" (fg 'dim))
     (list "org.meta" (fg 'comment))
     (list "org.table" (fg 'blue))
     (list "org.special" (fg 'dim))
     (list "org.date" (fg 'cyan "underline"))
     (list "org.checkbox" (fg 'yellow "bold"))
     (list "org.code" (fg 'green))
     (list "org.link" (fg 'blue "underline"))
     ;; Git and diffs
     (list "git.section" (fg 'magenta "bold"))
     (list "git.head" (fg 'dim))
     (list "git.branch" (fg 'cyan "bold"))
     (list "git.remote" (fg 'green "bold"))
     (list "git.hash" (fg 'dim))
     (list "git.status" (fg 'yellow))
     (list "git.count" (fg 'dim))
     (list "diff.added" (fg 'green))
     (list "diff.removed" (fg 'red))
     (list "diff.hunk" (fg 'cyan))
     (list "diff.header" "bold")
     ;; Code (tree-sitter captures)
     (list "syntax.keyword" (fg 'magenta))
     (list "syntax.string" (fg 'green))
     (list "syntax.string.special" (fg 'cyan))
     (list "syntax.escape" (fg 'cyan))
     (list "syntax.comment" (fg 'comment "italic"))
     (list "syntax.function" (fg 'blue))
     (list "syntax.function.macro" (fg 'cyan))
     (list "syntax.type" (fg 'yellow))
     (list "syntax.constructor" (fg 'yellow))
     (list "syntax.module" (fg 'yellow))
     (list "syntax.constant" (fg 'orange))
     (list "syntax.number" (fg 'orange))
     (list "syntax.boolean" (fg 'orange))
     (list "syntax.variable.builtin" (fg 'red))
     (list "syntax.variable.parameter" (fg 'red))
     (list "syntax.property" (fg 'red))
     (list "syntax.label" (fg 'red))
     (list "syntax.tag" (fg 'red))
     (list "syntax.attribute" (fg 'yellow))
     (list "syntax.operator" (fg 'cyan))
     (list "syntax.punctuation" (fg 'punct))
     (list "syntax.punctuation.special" (fg 'magenta))
     (list "syntax.embedded" (fg 'red))
     (list "syntax.text.title" (fg 'red "bold"))
     (list "syntax.text.literal" (fg 'green))
     (list "syntax.text.uri" (fg 'blue "underline"))
     (list "syntax.text.reference" (fg 'blue))
     (list "syntax.text.emphasis" "italic")
     (list "syntax.text.strong" "bold"))))

(define (load-theme! name)
  (let ([theme (hash-try-get *themes* name)])
    (if (not theme)
        (error (string-append "no theme " (symbol->string name)))
        (begin
          (for-each (lambda (f) (set-face! (car f) (cadr f)))
                    (append (theme-faces (car theme)) (cadr theme)))
          (set! *theme* name)))))

(define-theme! 'one-dark #f
  (hash 'bg "#282c34" 'bg-alt "#21252b" 'bg-hl "#2c313a" 'selection "#3e4452" 'border "#3e4452"
        'fg "#abb2bf" 'dim "#5c6370" 'comment "#7f848e" 'punct "#848b98"
        'red "#e06c75" 'orange "#d19a66" 'yellow "#e5c07b" 'green "#98c379"
        'cyan "#56b6c2" 'blue "#61afef" 'magenta "#c678dd" 'debug-bg "#3b3a26")
  '())

(define-theme! 'gruvbox-dark #f
  (hash 'bg "#282828" 'bg-alt "#1d2021" 'bg-hl "#32302f" 'selection "#504945" 'border "#504945"
        'fg "#ebdbb2" 'dim "#7c6f64" 'comment "#928374" 'punct "#a89984"
        'red "#fb4934" 'orange "#fe8019" 'yellow "#fabd2f" 'green "#b8bb26"
        'cyan "#8ec07c" 'blue "#83a598" 'magenta "#d3869b" 'debug-bg "#3c3a24")
  '())

(define-theme! 'one-light #f
  (hash 'bg "#fafafa" 'bg-alt "#eaeaeb" 'bg-hl "#f0f0f1" 'selection "#d4d6dc" 'border "#c8c9cc"
        'fg "#383a42" 'dim "#9d9d9f" 'comment "#a0a1a7" 'punct "#696c77"
        'red "#e45649" 'orange "#986801" 'yellow "#c18401" 'green "#50a14f"
        'cyan "#0184bc" 'blue "#4078f2" 'magenta "#a626a4" 'debug-bg "#fbf1d0")
  '())

(define (theme-names) (sort (map symbol->string (hash-keys->list *themes*)) string<?))

(define-command! 'load-theme
  (lambda (count)
    (completing-read "Theme: " (theme-names) (lambda (name) (load-theme! (string->symbol name))))))

(define-ex! '("theme" "colo" "colorscheme")
  (lambda (ex)
    (let ([arg (ex-args ex)])
      (cond [(equal? arg "") (message (if *theme* (symbol->string *theme*) "no theme"))]
            [(hash-contains? *themes* (string->symbol arg)) (load-theme! (string->symbol arg))]
            [else (message (string-append "no theme " arg "; there are " (string-join (theme-names) ", ")))]))))

(define-leader! "tT" 'load-theme "theme")

(load-theme! 'one-dark)

;;; The status line
;;;
;;; Formats as in Vim's 'statusline' (see render.rs status_line): %m mode,
;;; %f file, %M modified, %l %c position, %p percent, %{name} a value set
;;; with set-status-value! (major: the major mode, diagnostics: counts),
;;; %#face# a face (%#mode# the mode's), %* the status face, %= right side.

(define-option! 'statusline
  "%#mode# %m %* %#status.file#%f%* %#status.modified#%M%* %{diagnostics}%=%#status.dim#%{major}%*  %l:%c %#mode# %p %*"
  '(stl))
(define-option! 'statusline-inactive "  %f %M%=%{major}  %l:%c   " '())

(define (update-statusline! value) (set-statusline! (option 'statusline) (option 'statusline-inactive)))
(watch-option! 'statusline update-statusline!)
(watch-option! 'statusline-inactive update-statusline!)
