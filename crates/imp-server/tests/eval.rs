//! Evaluating Scheme inside the editor, and redefining things live.

mod common;

use common::*;

#[test]
fn eval_redefines_runtime_functions_for_their_callers() {
    let mut s = server("a\nb\n\nc\n");
    // `blank-line?` drives the paragraph text objects; redefine it live.
    type_keys(&mut s, ":eval (define (blank-line? line) #f)<ret>dip");
    assert_eq!(s.text(), "");
}

#[test]
fn eval_form_at_cursor() {
    let mut s = server("(+ 1 (* 2 3))\n");
    // On the closing paren of the outer form.
    type_keys(&mut s, "$");
    s.eval("(run-command 'eval-last-sexp)").unwrap();
    assert_eq!(s.status(), "7");
    // Inside the inner form: the innermost list... from its open paren.
    type_keys(&mut s, "0f(");
    s.eval("(run-command 'eval-last-sexp)").unwrap();
    assert_eq!(s.status(), "6");
    // On a symbol.
    type_keys(&mut s, "0l");
    s.eval("(run-command 'eval-last-sexp)").unwrap();
    assert!(
        s.status().contains("closure") || s.status().contains("function"),
        "{}",
        s.status()
    );
}

#[test]
fn eval_defun_finds_the_top_level_form() {
    let mut s = server("(define (sq x)\n  (* x x))\n(sq 9)\n");
    type_keys(&mut s, "jw");
    s.eval("(run-command 'eval-defun)").unwrap();
    type_keys(&mut s, "j$");
    s.eval("(run-command 'eval-last-sexp)").unwrap();
    assert_eq!(s.status(), "81");
}

#[test]
fn eval_buffer_and_region() {
    let mut s = server("(define zz 4)\n(* zz 10)\n");
    s.eval("(run-command 'eval-buffer)").unwrap();
    assert_eq!(s.status(), "40");
    type_keys(&mut s, "jV");
    s.eval("(run-command 'eval-region)").unwrap();
    assert_eq!(s.status(), "40");
}

#[test]
fn eval_errors_are_shown() {
    let mut s = server("");
    feed(&mut s, ":eval (car 5)<ret>");
    assert!(s.status().starts_with("error:"), "{}", s.status());
    feed(&mut s, ":eval (+ 1<ret>");
    assert!(s.status().starts_with("error:"), "{}", s.status());
}

#[test]
fn long_results_go_to_a_popup() {
    let mut s = server("");
    type_keys(&mut s, ":eval (range 0 60)<ret>");
    assert!(s
        .frame()
        .text_rows()
        .iter()
        .any(|r| r.starts_with("(0 1 2")));
}

#[test]
fn source_a_file() {
    let path = temp_path("source.scm");
    std::fs::write(
        &path,
        "(define-key! 'normal \"Q\" (lambda (n) (buffer-insert! 0 \"q\")))",
    )
    .unwrap();
    let mut s = server("x\n");
    type_keys(&mut s, &format!(":source {}<ret>Q", path.display()));
    assert_eq!(s.text(), "qx\n");
}

#[test]
fn messages_are_kept() {
    let mut s = server("");
    type_keys(&mut s, ":eval 1<ret>:eval 2<ret>:messages<ret>");
    let rows = s.frame().text_rows();
    let first = rows.iter().position(|r| r.trim_end() == "1").unwrap();
    assert_eq!(rows[first + 1].trim_end(), "2");
}

#[test]
fn key_echoes_and_clears_are_not_kept() {
    let mut s = server("");
    type_keys(&mut s, "<esc>");
    s.keys(&[" "]);
    // The leader still echoes, on the status line only.
    assert_eq!(s.status().trim(), "SPC");
    s.keys(&["<esc>", " ", "e", "<esc>"]);
    s.eval("(message \"kept\")").unwrap();
    assert_eq!(s.eval("*messages*").unwrap(), "(\"kept\")");
}

#[test]
fn named_commands_bound_to_keys_follow_redefinition() {
    let mut s = server("x\n");
    s.eval(
        r#"(define-command! 'shout (lambda (n) (buffer-insert! 0 "a")))
           (define-key! 'normal "Q" 'shout)"#,
    )
    .unwrap();
    type_keys(&mut s, "Q");
    s.eval(r#"(define-command! 'shout (lambda (n) (buffer-insert! 0 "b")))"#)
        .unwrap();
    type_keys(&mut s, "Q");
    assert_eq!(s.text(), "bax\n");
}

#[test]
fn forward_references_work_within_one_evaluation() {
    let mut s = server("");
    assert_eq!(
        s.eval("(define (a1) (b1)) (define (b1) 7) (a1)").unwrap(),
        "7"
    );
}

#[test]
fn user_functions_stay_redefinable() {
    let mut s = server("");
    // Defined together, so Steel would otherwise compile call-k's call to
    // k directly.
    s.eval("(define (k) 1) (define (call-k) (k))").unwrap();
    s.eval("(define (k) 2)").unwrap();
    assert_eq!(s.eval("(call-k)").unwrap(), "2");
}

#[test]
fn names_defined_later_are_allowed() {
    let mut s = server("");
    // later-fn doesn't exist when this is compiled...
    s.eval("(define (use-later) (later-fn))").unwrap();
    let err = s.eval("(use-later)").unwrap_err();
    assert!(err.contains("later-fn is not defined"), "{err}");
    // ...and once it is, callers get it.
    s.eval("(define (later-fn) 'here)").unwrap();
    assert_eq!(s.eval("(use-later)").unwrap(), "here");
}

#[test]
fn repl_buffer_evaluates_input() {
    let mut s = server("");
    type_keys(&mut s, ":repl<ret>(+ 1 2)<ret>");
    assert!(
        s.text().ends_with("imp> (+ 1 2)\n3\nimp> "),
        "{:?}",
        s.text()
    );
    // A define prints the name; a function called for its effect, nothing.
    type_keys(&mut s, "(define (sq x) (* x x))<ret>");
    assert!(s.text().ends_with("x))\nsq\nimp> "), "{:?}", s.text());
    type_keys(&mut s, "(sq 5)<ret>(message \"hi\")<ret>");
    assert!(
        s.text()
            .ends_with("(sq 5)\n25\nimp> (message \"hi\")\nimp> "),
        "{:?}",
        s.text()
    );
    feed(&mut s, "(car 1)<ret>");
    assert!(s.text().contains("error: car"), "{:?}", s.text());
}

#[test]
fn eval_shows_nothing_for_effects() {
    let mut s = server("");
    // The message stays: void shows nothing over it.
    type_keys(&mut s, ":eval (message \"hi\")<ret>");
    assert_eq!(s.status(), "hi");
    assert_eq!(s.eval("(define x 1)").unwrap(), "x");
    assert_eq!(s.eval("(define x 2)").unwrap(), "x");
    assert_eq!(s.eval("(add-hook! 'after-save (lambda () 1))").unwrap(), "");
}

/// `set!` returns the variable's old value, so a function whose last
/// expression is a `set!` hands that back, and the REPL and `:eval` print
/// it. Every runtime and package function ends with `void` instead.
#[test]
fn no_runtime_function_returns_a_set() {
    let mut s = server("");
    s.eval("(for-each (lambda (n) (use-package! (string->symbol n))) (builtin-package-names))")
        .unwrap();
    let found = s
        .eval(
            r#"(begin
  (define (set-tails e)
    ;; The set! forms in tail position in `e`.
    (cond
      [(not (pair? e)) '()]
      [(eq? (car e) 'set!) (list e)]
      [(memq (car e) '(begin when unless let let* letrec letrec* with-handler))
       (if (null? (cdr e)) '() (set-tails (last e)))]
      [(eq? (car e) 'if) (apply append (map set-tails (if (pair? (cdr e)) (cddr e) '())))]
      [(memq (car e) '(cond case))
       (apply append (map (lambda (c) (if (and (pair? c) (pair? (cdr c))) (set-tails (last c)) '()))
                          (if (eq? (car e) 'case) (cddr e) (cdr e))))]
      [else '()]))
  (define (function-body form)
    (and (pair? form) (eq? (car form) 'define) (pair? (cdr form)) (pair? (cddr form))
         (cond [(pair? (cadr form)) (cddr form)]
               [(and (pair? (caddr form)) (eq? (car (caddr form)) 'lambda) (pair? (cddr (caddr form))))
                (cddr (caddr form))]
               [else #f])))
  (define (offenders src)
    (let ([port (open-input-string (or (source-text src) ""))])
      (let loop ([form (read port)] [acc '()])
        (if (eof-object? form)
            (reverse acc)
            (let ([body (function-body form)])
              (loop (read port)
                    (if (and body (pair? (set-tails (last body))))
                        (cons (string-append src " " (to-string (cadr form))) acc)
                        acc)))))))
  (apply append (map offenders (filter (lambda (n) (or (starts-with? n "runtime/") (starts-with? n "packages/")))
                                       (source-names)))))"#,
        )
        .unwrap();
    assert_eq!(found, "()", "functions that return a set!'s old value");
}
