;;; org-export.scm -- exporting Org buffers through pandoc, after Org's
;;; export dispatcher and ox-pandoc.
;;;
;;;   (use-package! 'org-export)
;;;
;;; In an Org buffer, C-c C-e (or SPC m e) opens the export menu, as Org's
;;; dispatcher does: a key picks the format, a second what to do with it
;;; (see lore:spec/org-export).
;;;
;;;   h HTML   p PDF   m Markdown   d Word   l LaTeX   o OpenDocument   t text
;;;
;;;   h h   write notes.html beside notes.org
;;;   h o   write it, then open it with xdg-open (o O for OpenDocument)
;;;   h H   export into an *Org Export: HTML* buffer (text formats only)
;;;
;;; Before the format, C-s exports only the subtree at the cursor, C-b
;;; only the body (no <head> or preamble) and C-v only what folds don't
;;; hide; the menu's title shows the toggles that are on. :OrgExport FORMAT
;;; writes the file without the menu.
;;;
;;; The buffer's text is exported, unsaved edits included, by pandoc in the
;;; background, from the file's directory. org-export-pdf-engine (xelatex)
;;; makes PDFs; org-export-pandoc-args is added to every run, as "--toc".
;;; When pandoc fails, its errors are in the *org-export* buffer.

;; The LaTeX engine pandoc makes PDFs with; xelatex copes with Unicode.
(define-option! 'org-export-pdf-engine "xelatex" '())
;; Flags added to every pandoc run, as "--toc".
(define-option! 'org-export-pandoc-args "" '())

;; The programs run; the tests put fakes in their place.
(define *org-export-pandoc* "pandoc")
(define *org-export-open* "xdg-open")

;; (name pandoc-format extension label text?): text formats can go in a
;; buffer.
(define *org-export-formats*
  '(("html" "html" "html" "HTML" #t)
    ("pdf" "latex" "pdf" "PDF" #f)
    ("markdown" "gfm" "md" "Markdown" #t)
    ("docx" "docx" "docx" "Word" #f)
    ("latex" "latex" "tex" "LaTeX" #t)
    ("odt" "odt" "odt" "OpenDocument" #f)
    ("text" "plain" "txt" "Text" #t)))

(define (org-export-label format)
  "The name `format` is shown by: HTML, Markdown."
  (list-ref format 3))
(define (org-export-text? format)
  "Whether `format` is text, which can go in a buffer."
  (list-ref format 4))

(define (org-export-format name)
  "The entry of *org-export-formats* called `name`, or #f."
  (list-find (lambda (f) (equal? (car f) name)) *org-export-formats*))

(define (org-export-file-for path ext)
  "`path` with its extension changed to `ext`: notes.org to notes.html."
  (let* ([name (file-name-of path)]
         [old (extension-of name)]
         [stem (if old (substring path 0 (- (string-length path) (string-length old) 1)) path)])
    (string-append stem "." ext)))

(define (org-export-hidden? line)
  "Whether `line` is hidden inside a closed fold."
  (and (list-find (lambda (f) (and (fold-closed? f) (> line (fold-first f)) (<= line (fold-last f))))
                  (buffer-folds))
       #t))

(define (org-export-first-heading)
  "The current buffer's first heading line, or the line after the last."
  (let loop ([l 0]) (cond [(> l (last-line)) l] [(org-level l) l] [else (loop (+ l 1))])))

(define (org-export-text toggles)
  "The current buffer's text to export, as `toggles` say: with 'subtree,
   the heading at the cursor and what is under it, its title the
   document's (after the file's other #+ settings) and its headings
   promoted so its children are at level 1; with 'visible, without the
   text closed folds hide. #f when 'subtree is asked for outside any heading."
  (let* ([subtree? (memq 'subtree toggles)]
         [visible? (memq 'visible toggles)]
         [h (and subtree? (org-heading-line (current-line)))])
    (cond
      [(and subtree? (not h)) #f]
      [(not (or subtree? visible?)) (buffer-substring 0 (buffer-length))]
      [else
       (let* ([first (if h (+ h 1) 0)]
              [last (if h (org-subtree-end h) (last-line))]
              [lines (filter (lambda (l) (not (and visible? (org-export-hidden? l)))) (range first (+ last 1)))]
              [up (if h (org-level h) 0)]
              [promote (lambda (text)
                         (if (and (> up 0) (org-level-of text)) (substring text up (string-length text)) text))]
              [settings (if h
                            (filter (lambda (text) (and (starts-with? text "#+")
                                                        (not (starts-with? text "#+TITLE:"))
                                                        (not (starts-with? text "#+title:"))))
                                    (map line-text (range 0 (org-export-first-heading))))
                            '())]
              [header (if h
                          (append settings (list (string-append "#+TITLE: " (org-heading-title (line-text h)))))
                          '())])
         (apply string-append
                (map (lambda (text) (string-append text "\n"))
                     (append header (map (lambda (l) (promote (line-text l))) lines)))))])))

(define (org-export-command format out toggles)
  "The shell command that has pandoc turn Org on its stdin into `format`,
   written to file `out`, or to stdout when `out` is #f; a whole document
   unless `toggles` has 'body."
  (let ([args (option 'org-export-pandoc-args)])
    (string-append (shell-quote *org-export-pandoc*) " --from org --to " (cadr format)
                   (if (memq 'body toggles) "" " --standalone")
                   (if (equal? (car format) "pdf")
                       (string-append " --pdf-engine=" (shell-quote (option 'org-export-pdf-engine)))
                       "")
                   (if (equal? args "") "" (string-append " " args))
                   (if out (string-append " --output " (shell-quote out)) ""))))

(define (org-export-failed! errors)
  "Says the export failed, with pandoc's `errors` in *org-export*."
  (let ([id (special-buffer "*org-export*" 'special-mode)])
    (with-buffer id (lambda () (set-buffer-contents! errors))))
  (message "export failed: see *org-export*"))

(define (org-export-show! format text)
  "Shows `text`, exported in `format`, in its *Org Export: LABEL* buffer,
   in the mode for the format's files."
  (let ([id (special-buffer (string-append "*Org Export: " (org-export-label format) "*")
                            (mode-for-path (string-append "export." (caddr format))))])
    (with-buffer id (lambda () (set-buffer-contents! text) (set-cursor! 0)))
    (display-buffer! id)))

(define (org-export! name target toggles)
  "Exports the current buffer's text, unsaved edits included, in format
   `name` (one of *org-export-formats*), with pandoc running in the
   background from the file's directory. `target` says where it goes:
   'file, a file beside the buffer's; 'open, that file, then opened with
   xdg-open; 'buffer, an *Org Export: LABEL* buffer. `toggles` lists the
   menu's toggles that are on: 'subtree, 'body, 'visible (see
   org-export-text)."
  (let* ([format (org-export-format name)]
         [path (and (buffer-path) (expand-path (buffer-path)))]
         [buffer? (eq? target 'buffer)]
         [text (org-export-text toggles)])
    (cond
      [(not format) (message (string-append "no export format " name))]
      [(and buffer? (not (org-export-text? format)))
       (message (string-append (org-export-label format) " can't be exported to a buffer"))]
      [(and (not buffer?) (not path)) (message "the buffer has no file to export beside")]
      [(not text) (message "not under a heading")]
      [(not (= (car (run-shell (string-append "command -v " (shell-quote *org-export-pandoc*) " >/dev/null") "")) 0))
       (message "org-export needs pandoc")]
      [else
       (let ([out (and (not buffer?) (org-export-file-for path (caddr format)))] [output ""] [errors ""])
         (message (string-append "exporting " (if out (file-name-of out) (org-export-label format)) "..."))
         (start-job! (string-append (if path (string-append "cd " (shell-quote (directory-of path)) " && ") "")
                                    (org-export-command format out toggles))
                     text
                     (lambda (text stream)
                       (if (equal? stream "stderr")
                           (set! errors (string-append errors text))
                           (set! output (string-append output text))))
                     (lambda (code)
                       (cond [(not (= code 0)) (org-export-failed! errors)]
                             [buffer? (message "") (org-export-show! format output)]
                             [else
                              (message (string-append "exported " (file-name-of out)))
                              (when (eq? target 'open)
                                (start-job! (string-append (shell-quote *org-export-open*) " " (shell-quote out))
                                            "" #f #f))]))))]))
  void)

;;; The menu, after Org's dispatcher: a key picks the format, a second
;;; what to do with it; C-s, C-b and C-v flip the toggles first.

;; (key format) in the menu, in order.
(define *org-export-keys*
  '(("h" "html") ("p" "pdf") ("m" "markdown") ("d" "docx") ("l" "latex") ("o" "odt") ("t" "text")))
;; (key toggle label).
(define *org-export-toggle-keys*
  '(("C-s" subtree "subtree only") ("C-b" body "body only") ("C-v" visible "visible only")))

;; The toggles that are on in the open menu.
(define *org-export-toggles* '())

(define (org-export-title)
  "The menu's title, naming the toggles that are on."
  (let ([on (filter (lambda (t) (memq (cadr t) *org-export-toggles*)) *org-export-toggle-keys*)])
    (if (null? on)
        "Export"
        (string-append "Export (" (string-join (map caddr on) ", ") ")"))))

(define (org-export-format-menu! key name)
  "The second level of the menu, for format `name` picked with `key`:
   key again writes the file, o (O for ODT, whose key is o) writes and
   opens it, the capital exports a text format into a buffer."
  (let* ([format (org-export-format name)]
         [toggles *org-export-toggles*]
         [open-key (if (equal? key "o") "O" "o")]
         [run (lambda (target) (lambda () (org-export! name target toggles)))])
    (menu! (string-append (org-export-title) ": " (org-export-label format))
           (append (list (list key "to file" (run 'file))
                         (list open-key "to file and open" (run 'open)))
                   (if (and (org-export-text? format) (not (equal? key "o")))
                       (list (list (string-upcase key) "to buffer" (run 'buffer)))
                       '())))))

(define (org-export-menu-again!)
  "Shows the export menu, keeping the toggles."
  (menu! (org-export-title)
         (append (map (lambda (k)
                        (list (car k) (org-export-label (org-export-format (cadr k)))
                              (lambda () (org-export-format-menu! (car k) (cadr k)))))
                      *org-export-keys*)
                 (map (lambda (t)
                        (list (car t) (caddr t)
                              (lambda ()
                                (set! *org-export-toggles*
                                      (if (memq (cadr t) *org-export-toggles*)
                                          (filter (lambda (x) (not (eq? x (cadr t)))) *org-export-toggles*)
                                          (cons (cadr t) *org-export-toggles*)))
                                (org-export-menu-again!))))
                      *org-export-toggle-keys*))))

(define (org-export-menu!)
  "Opens the export menu, its toggles off."
  (set! *org-export-toggles* '())
  (org-export-menu-again!))

(define-command! 'org-export
  (lambda (count)
    "Export the Org buffer through pandoc: a menu of formats (C-c C-e)."
    (org-export-menu!)))

(for-each (lambda (state) (define-mode-key! 'org-mode state "C-cC-e" 'org-export "export"))
          '(normal insert))
(define-mode-leader! 'org-mode "e" (lambda (n) (org-export-menu!)) "export")

(define-ex! '("OrgExport")
  (lambda (ex)
    (let ([name (trim-end (trim-start (ex-args ex)))])
      (if (equal? name "")
          (message "OrgExport needs a format: html, pdf, markdown, docx, latex, odt or text")
          (org-export! name 'file '())))))
(define-ex-completion! '("OrgExport")
  (lambda (typed) (filter (lambda (n) (starts-with? n typed)) (map car *org-export-formats*))))
