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
;;; orange, yellow, green, cyan, blue, magenta, debug-bg, and black and
;;; white for terminal buffers (dim and fg if left out), with bright-black
;;; ... bright-white for their bright colors (the plain ones if left out).

(define *themes* (hash))  ; name -> (palette extra-faces)
(define *theme* #f)       ; the theme loaded
(define *theme-face-names* '())  ; the faces it set

(define (define-theme! name parent palette faces)
  "Defines theme `name`, starting from theme `parent` (or #f).
   `palette` is a hash of the palette colors to set or change; `faces`
   is a list of (face spec) to set after the palette's faces:

     (define-theme! 'mine 'one-dark (hash 'bg \"#1a1b26\")
       (list (list \"syntax.comment\" \"fg=#565f89\")))

   Load it with (load-theme! 'mine). An unknown `parent` is an error."
  (let* ([base (cond [(not parent) (list (hash) '())]
                     [(hash-try-get *themes* parent) => (lambda (t) t)]
                     [else (error (string-append "no theme " (symbol->string parent)))])]
         [merged (foldl (lambda (k h) (hash-insert h k (hash-ref palette k))) (car base) (hash-keys->list palette))])
    (set! *themes* (hash-insert *themes* name (list merged (append (cadr base) faces)))))
  void)

(define (theme-faces p)
  "Every face as a (name spec) list, made from palette `p`."
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
     (list "fold-column" (fg 'dim))
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
     (list "status.mode.terminal" (mode-face 'cyan))
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
     ;; A path in a popup row: shortened from the start when the row is too wide.
     (list "popup.path" "")
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
     (list "dired.permissions" (fg 'dim))
     (list "dired.size" (fg 'cyan))
     (list "dired.date" (fg 'comment))
     ;; Org
     ;; The date picker (calendar.scm)
     (list "calendar.selected" (string-append "fg=" (c 'bg) " bg=" (c 'blue) " bold"))
     (list "calendar.today" (fg 'yellow "bold underline"))
     (list "calendar.weekend" (fg 'comment))
     ;; A heading's leading stars, drawn blank by org-indent
     (list "org.hide" (fg 'bg))
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
     (list "org.priority" (fg 'yellow "bold"))
     (list "org.code" (fg 'green))
     (list "org.link" (fg 'blue "underline"))
     ;; Git and diffs
     (list "git.section" (fg 'magenta "bold"))
     (list "git.head" (fg 'dim))
     (list "git.key" (fg 'yellow "bold"))
     ;; The status buffer's key lines, on the status line's background
     (list "git.footer" (string-append "fg=" (c 'fg) " bg=" (c 'bg-alt)))
     (list "git.footer.key" (string-append "fg=" (c 'yellow) " bg=" (c 'bg-alt) " bold"))
     (list "git.branch" (fg 'cyan "bold"))
     (list "git.remote" (fg 'green "bold"))
     (list "git.hash" (fg 'dim))
     (list "git.status" (fg 'yellow))
     (list "git.count" (fg 'dim))
     (list "start.title" (fg 'blue "bold"))
     (list "start.heading" (fg 'magenta "bold"))
     (list "start.key" (fg 'yellow "bold"))
     (list "start.dim" (fg 'comment))
     (list "start.file" "")
     (list "start.project" (fg 'cyan))
     (list "diff.added" (fg 'green))
     (list "diff.removed" (fg 'red))
     (list "diff.hunk" (fg 'cyan))
     (list "diff.header" "bold")
     ;; The git-gutter package's bars
     (list "git-gutter.added" (fg 'green))
     (list "git-gutter.changed" (fg 'orange))
     (list "git-gutter.removed" (fg 'red))
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

(define (terminal-palette p)
  "The 16 colors programs in a terminal buffer ask for by number: black,
   red, green, yellow, blue, magenta, cyan, white, then the bright ones.
   A bright color is the palette's bright-red and so on, else the plain
   one (bright black: dim)."
  (let* ([get (lambda (k fallback) (or (hash-try-get p k) (hash-ref p fallback)))]
         [colors (cons (get 'black 'dim)
                       (append (map (lambda (k) (hash-ref p k)) '(red green yellow blue magenta cyan))
                               (list (get 'white 'fg))))]
         [bright (lambda (k plain) (or (hash-try-get p k) plain))])
    (append colors
            (let loop ([keys '(bright-black bright-red bright-green bright-yellow bright-blue
                               bright-magenta bright-cyan bright-white)]
                       [plain (cons (hash-ref p 'dim) (cdr colors))])
              (if (null? keys) '() (cons (bright (car keys) (car plain)) (loop (cdr keys) (cdr plain))))))))

(define (load-theme! name)
  "Switches to theme `name`, a symbol, setting every face and the
   terminal colors from it. An unknown name raises an error:

     (load-theme! 'gruvbox-dark)"
  (let ([theme (hash-try-get *themes* name)])
    (if (not theme)
        (error (string-append "no theme " (symbol->string name)))
        (let ([faces (append (theme-faces (car theme)) (cadr theme))])
          ;; Faces the last theme set and this one doesn't go, so a theme
          ;; that sets syntax.function.builtin leaves builtins drawn as
          ;; syntax.function in the next.
          (let ([names (map car faces)])
            (for-each (lambda (name) (unless (member name names) (remove-face! name)))
                      *theme-face-names*)
            (set! *theme-face-names* names))
          (for-each (lambda (f) (set-face! (car f) (cadr f))) faces)
          (set-terminal-palette! (terminal-palette (car theme)))
          (set! *theme* name))))
  void)

(define-theme! 'one-dark #f
  (hash 'bg "#282c34" 'bg-alt "#21252b" 'bg-hl "#2c313a" 'selection "#3e4452" 'border "#3e4452"
        'fg "#abb2bf" 'dim "#5c6370" 'comment "#7f848e" 'punct "#848b98"
        'red "#e06c75" 'orange "#d19a66" 'yellow "#e5c07b" 'green "#98c379"
        'cyan "#56b6c2" 'blue "#61afef" 'magenta "#c678dd" 'debug-bg "#3b3a26"
        'black "#3f4451" 'white "#d7dae0")
  '())

(define-theme! 'gruvbox-dark #f
  (hash 'bg "#282828" 'bg-alt "#1d2021" 'bg-hl "#32302f" 'selection "#504945" 'border "#504945"
        'fg "#ebdbb2" 'dim "#7c6f64" 'comment "#928374" 'punct "#a89984"
        'red "#fb4934" 'orange "#fe8019" 'yellow "#fabd2f" 'green "#b8bb26"
        'cyan "#8ec07c" 'blue "#83a598" 'magenta "#d3869b" 'debug-bg "#3c3a24"
        'black "#504945" 'white "#d5c4a1")
  '())

(define-theme! 'one-light #f
  (hash 'bg "#fafafa" 'bg-alt "#eaeaeb" 'bg-hl "#f0f0f1" 'selection "#d4d6dc" 'border "#c8c9cc"
        'fg "#383a42" 'dim "#9d9d9f" 'comment "#a0a1a7" 'punct "#696c77"
        'red "#e45649" 'orange "#986801" 'yellow "#c18401" 'green "#50a14f"
        'cyan "#0184bc" 'blue "#4078f2" 'magenta "#a626a4" 'debug-bg "#fbf1d0"
        'black "#383a42" 'white "#9d9d9f")
  '())

;; Everforest dark, medium contrast (github.com/sainnhe/everforest), with
;; its own syntax colors: red keywords, green functions, aqua strings,
;; purple constants.
(define-theme! 'everforest-dark #f
  (hash 'bg "#2d353b" 'bg-alt "#232a2e" 'bg-hl "#343f44" 'selection "#543a48" 'border "#475258"
        'fg "#d3c6aa" 'dim "#7a8478" 'comment "#859289" 'punct "#9da9a0"
        'red "#e67e80" 'orange "#e69875" 'yellow "#dbbc7f" 'green "#a7c080"
        'cyan "#83c092" 'blue "#7fbbb3" 'magenta "#d699b6" 'debug-bg "#4d4c43"
        'black "#475258" 'white "#d3c6aa")
  (list (list "syntax.keyword" "fg=#e67e80")
        (list "syntax.function" "fg=#a7c080")
        (list "syntax.function.macro" "fg=#a7c080")
        (list "syntax.string" "fg=#83c092")
        (list "syntax.constant" "fg=#d699b6")
        (list "syntax.number" "fg=#d699b6")
        (list "syntax.boolean" "fg=#d699b6")
        (list "syntax.variable.builtin" "fg=#d699b6")
        (list "syntax.variable.parameter" "fg=#d3c6aa")
        (list "syntax.property" "fg=#7fbbb3")
        (list "syntax.operator" "fg=#e69875")
        (list "syntax.punctuation.special" "fg=#e69875")
        ;; Its statusline's mode colors: normal green, insert blue, visual red.
        (list "status.mode.normal" "fg=#2d353b bg=#a7c080 bold")
        (list "status.mode.insert" "fg=#2d353b bg=#7fbbb3 bold")
        (list "status.mode.visual" "fg=#2d353b bg=#e67e80 bold")))

;;; describe-face, list-faces
;;;
;;; Every color is a named face (theme.scm). describe-face (SPC h F) names
;;; the faces drawn under the cursor, bottom first; list-faces shows every
;;; face in its own colors. Either way, change one in init.scm with
;;; (set-face! "name" "fg=#rrggbb bg=#rrggbb bold italic underline").

(define (face-line name)
  "A line naming face `name` and its spec, for describe-face."
  (string-append (pad-right name 28) (or (face-spec name) "(not defined)")))

(define (face-change-hint name)
  "The set-face! line that would change face `name`, to copy to init.scm."
  (string-append "Change it: (set-face! \"" name "\" \"" (or (face-spec name) "fg=#rrggbb") "\")"))

(define (describe-face-at! at)
  "Shows the faces drawn at offset `at` in a popup, bottom first.
   \"normal\" is under everything: the text color and background."
  (let ([faces (cons "normal" (faces-at at))])
    (show-popup! (append (list "Faces at the cursor, bottom first:")
                         (map (lambda (f) (string-append "  " (face-line f))) faces)
                         (list "" (face-change-hint (last faces)))))))

(define-command! 'describe-face
  (lambda (count)
    "Show the faces drawn under the cursor and how to change them."
    (describe-face-at! (cursor))))

(define-major-mode! 'faces-mode 'special-mode '() #f)

(define-command! 'list-faces
  (lambda (count)
    "List every face with a sample drawn in it and its spec.
     <ret> on one shows how to change it."
    (display-buffer! (special-buffer "*faces*" 'faces-mode))
    (draw-begin!)
    (for-each (lambda (name)
                (draw-line! (list (list (pad-right name 28) #f)
                                  (list "Sample text 0123" name)
                                  (list (string-append "  " (or (face-spec name) "")) "status.dim"))
                            (list 'face name)))
              (face-names))
    (draw-finish!)))

(define-mode-key! 'faces-mode 'normal "<ret>"
  (lambda (n)
    (let ([item (line-item)])
      (when (and item (eq? (car item) 'face))
        (show-popup! (list (face-line (cadr item)) "" (face-change-hint (cadr item))))))))

(define (theme-names)
  "The names of the themes defined, sorted, as strings."
  (sort (map symbol->string (hash-keys->list *themes*)) string<?))

(define-command! 'load-theme
  (lambda (count)
    "Pick a theme by name and switch to it."
    (set! *completion-category* 'theme)
    (completing-read "Theme: " (theme-names) (lambda (name) (load-theme! (string->symbol name))))))

(define-ex! '("theme" "colo" "colorscheme")
  (lambda (ex)
    (let ([arg (ex-args ex)])
      (cond [(equal? arg "") (message (if *theme* (symbol->string *theme*) "no theme"))]
            [(hash-contains? *themes* (string->symbol arg)) (load-theme! (string->symbol arg))]
            [else (message (string-append "no theme " arg "; there are " (string-join (theme-names) ", ")))]))))

(define-ex-completion! '("theme" "colo" "colorscheme")
  (lambda (typed) (filter (lambda (n) (starts-with? n typed)) (theme-names))))

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

(define (update-statusline! _value)
  "Hands the statusline options to the renderer. The watcher of both
   options, so it reads them itself and ignores the value it is passed."
  (set-statusline! (option 'statusline) (option 'statusline-inactive)))
(watch-option! 'statusline update-statusline!)
(watch-option! 'statusline-inactive update-statusline!)

;;; The window: its font, space around the text, and how see-through the
;;; theme's background is (the compositor shows what is behind it).
;;;
;;;   (set-option! 'font "VictorMono Nerd Font Mono")
;;;   (set-option! 'font-size 16)
;;;   (set-option! 'window-padding 40)        ; pixels, in the background color
;;;   (set-option! 'window-divider-width 40)  ; pixels between side-by-side windows
;;;   (set-option! 'background-opacity 0.9)   ; 1 is opaque
;;;
;;; --font and --font-size on the command line win over these. In a
;;; terminal, (set-option! 'terminal-background #f) leaves the theme's
;;; background unpainted, so the terminal's own (and its opacity) shows.

(define *appearance* (hash))

(define (define-appearance-option! name default apply)
  "Defines option `name` for how the window looks, set to `default`.
   `apply` gets each new value, and raises an error for a bad one."
  (set! *appearance* (hash-insert *appearance* name default))
  (define-computed-option! name '()
    (lambda () (hash-ref *appearance* name))
    (lambda (value)
      (apply value)
      (set! *appearance* (hash-insert *appearance* name value)))))

(define (check-number name value low high)
  "Raises an error unless `value` is a number from `low` to `high`.
   `name` is the option the error message names."
  (unless (and (number? value) (<= low value high))
    (error (string-append (symbol->string name) " is a number from "
                          (number->string low) " to " (number->string high)))))

(define-appearance-option! 'font ""
  (lambda (v) (unless (string? v) (error "font is a family name, \"\" for the default"))
              (set-appearance! "font" v)))
(define-appearance-option! 'font-size 0
  (lambda (v) (check-number 'font-size v 0 400) (set-appearance! "font-size" v)))
(define-appearance-option! 'window-padding 0
  (lambda (v) (check-number 'window-padding v 0 1000) (set-appearance! "padding" v)))
;; Pixels between side-by-side windows, rounded to whole columns (0: one
;; column, as in a terminal, which always gets one).
(define-appearance-option! 'window-divider-width 0
  (lambda (v) (check-number 'window-divider-width v 0 1000) (set-appearance! "divider" v)))
(define-appearance-option! 'background-opacity 1
  (lambda (v) (check-number 'background-opacity v 0 1)
              (set-appearance! "transparency" (* 100 (- 1 v)))))
(define-appearance-option! 'terminal-background #t
  (lambda (v) (set-appearance! "clear-terminal-background" (not v))))
