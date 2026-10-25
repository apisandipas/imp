;;; org-export.scm -- exporting Org buffers through pandoc, after Org's
;;; export dispatcher and ox-pandoc.
;;;
;;;   (use-package! 'org-export)

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

(define (org-export-command format out)
  "The shell command that has pandoc turn Org on its stdin into `format`,
   written to file `out`, or to stdout when `out` is #f."
  (let ([args (option 'org-export-pandoc-args)])
    (string-append (shell-quote *org-export-pandoc*) " --from org --to " (cadr format) " --standalone"
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

(define (org-export! name target)
  "Exports the current buffer's text, unsaved edits included, in format
   `name` (one of *org-export-formats*), with pandoc running in the
   background from the file's directory. `target` says where it goes:
   'file, a file beside the buffer's; 'open, that file, then opened with
   xdg-open; 'buffer, an *Org Export: LABEL* buffer."
  (let* ([format (org-export-format name)]
         [path (and (buffer-path) (expand-path (buffer-path)))]
         [buffer? (eq? target 'buffer)])
    (cond
      [(not format) (message (string-append "no export format " name))]
      [(and buffer? (not (org-export-text? format)))
       (message (string-append (org-export-label format) " can't be exported to a buffer"))]
      [(and (not buffer?) (not path)) (message "the buffer has no file to export beside")]
      [(not (= (car (run-shell (string-append "command -v " (shell-quote *org-export-pandoc*) " >/dev/null") "")) 0))
       (message "org-export needs pandoc")]
      [else
       (let ([out (and (not buffer?) (org-export-file-for path (caddr format)))] [output ""] [errors ""])
         (message (string-append "exporting " (if out (file-name-of out) (org-export-label format)) "..."))
         (start-job! (string-append (if path (string-append "cd " (shell-quote (directory-of path)) " && ") "")
                                    (org-export-command format out))
                     (buffer-substring 0 (buffer-length))
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
