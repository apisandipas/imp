;;; wasm.scm -- WASM plugins: sandboxed functions from text to text.
;;;
;;; Built with the `wasm` feature (wasm.rs has the ABI). A plugin is a
;;; .wasm (or .wat) module whose functions take a string and return one,
;;; with no access to files, the network or the editor, and a time and
;;; memory budget. That suits formatters, linters and transforms. In
;;; init.scm:
;;;
;;;   (load-wasm-plugin! 'case "~/.config/imp/plugins/case.wasm")
;;;   (define-operator! "gs" (wasm-operator 'case "snake"))  ; gsiw, gsap, visual gs
;;;   (define-wasm-filter! 'snake-buffer 'case "snake")     ; M-x snake-buffer
;;;
;;; :[range]wasm PLUGIN FUNCTION runs a function over lines (the whole
;;; buffer without a range); :wasm alone lists plugins and functions;
;;; :wasm-log shows what plugins logged.

(define *wasm-plugins* (hash))  ; name -> handle

(define (load-wasm-plugin! name path)
  (let ([handle (wasm-load (expand-path path))])
    (set! *wasm-plugins* (hash-insert *wasm-plugins* name handle))
    handle))

(define (wasm-plugin name)
  (let ([handle (hash-try-get *wasm-plugins* name)])
    (or handle (error (string-append "no WASM plugin " (symbol->string name))))))

;; Replaces start..end with (FUNCTION text) from the plugin, as one change.
(define (wasm-replace! plugin function start end)
  (let* ([text (buffer-substring start end)]
         [result (wasm-call (wasm-plugin plugin) function text)])
    (unless (equal? result text)
      (begin-change!)
      (replace-range! start end result))))

;; An operator (define-operator!) that runs FUNCTION over the text moved over.
(define (wasm-operator plugin function)
  (lambda (start end linewise?)
    (wasm-replace! plugin function start end)
    (set-cursor! (if linewise? (line-first-nonblank (offset->line start)) (min start (max 0 (- (buffer-length) 1)))))))

;; A command that runs FUNCTION over the whole buffer, keeping the cursor's
;; line.
(define (define-wasm-filter! command plugin function)
  (define-command! command
    (lambda (count)
      (let ([line (current-line)])
        (wasm-replace! plugin function 0 (buffer-length))
        (set-cursor! (line-first-nonblank (min line (- (buffer-line-count) 1))))))))

(define (wasm-plugin-lines)
  (if (= (hash-length *wasm-plugins*) 0)
      (list (if (wasm-available?) "no WASM plugins loaded" "imp was built without the wasm feature"))
      (map (lambda (name)
             (string-append (symbol->string name) ": "
                            (string-join (wasm-exports (hash-ref *wasm-plugins* name)) " ")))
           (sort (hash-keys->list *wasm-plugins*) (lambda (a b) (string<? (symbol->string a) (symbol->string b)))))))

(define-ex! "wasm"
  (lambda (ex)
    (let ([words (split-whitespace (ex-args ex))])
      (cond [(null? words) (show-popup! (wasm-plugin-lines))]
            [(not (= (length words) 2)) (message "usage: :[range]wasm PLUGIN FUNCTION")]
            [else
             (let* ([plugin (string->symbol (car words))]
                    [lines (if (ex-range-given? ex) (ex-range ex) (list 0 (- (buffer-line-count) 1)))]
                    [r (lines-range (car lines) (cadr lines))])
               (wasm-replace! plugin (cadr words) (car r) (cadr r))
               (set-cursor! (line-first-nonblank (min (car lines) (- (buffer-line-count) 1)))))]))))

(define-ex! "wasm-log"
  (lambda (ex)
    (let ([log (wasm-log)])
      (show-popup! (if (null? log) (list "nothing yet") log)))))
