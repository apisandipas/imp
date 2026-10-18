//! Hooks and advice.

mod common;

use common::*;

#[test]
fn advice_before_after_around() {
    let mut s = server("");
    s.eval(
        r#"(define calls '())
           (define (greet name) (set! calls (cons (string-append "hi " name) calls)) name)
           (define (call-greet) (greet "bo"))"#,
    )
    .unwrap();
    s.eval(
        r#"(define (b name) (set! calls (cons "before" calls)))
           (define (a name) (set! calls (cons "after" calls)))
           (define (wrap orig name) (string-append "<" (orig (string-append name "!")) ">"))
           (advice-add! 'greet 'before b)
           (advice-add! 'greet 'after a)
           (advice-add! 'greet 'around wrap)"#,
    )
    .unwrap();
    // Callers compiled before the advice see it.
    assert_eq!(s.eval("(call-greet)").unwrap(), r#""<bo!>""#);
    assert_eq!(
        s.eval("(reverse calls)").unwrap(),
        r#"("before" "hi bo!" "after")"#
    );
    s.eval("(advice-remove! 'greet b) (advice-remove! 'greet a) (advice-remove! 'greet wrap)")
        .unwrap();
    assert_eq!(s.eval("(call-greet)").unwrap(), r#""bo""#);
}

#[test]
fn advice_on_a_runtime_function() {
    let mut s = server("  abc\n");
    // ^ calls line-first-nonblank; shift where it lands by one.
    s.eval("(advice-add! 'line-first-nonblank 'around (lambda (orig line) (+ 1 (orig line))))")
        .unwrap();
    type_keys(&mut s, "$^");
    assert_eq!(s.cursor(), 3);
}

#[test]
fn editor_hooks_run() {
    let mut s = server("x\n");
    s.eval(
        r#"(define events '())
           (define (note e) (lambda args (set! events (cons e events))))
           (add-hook! 'insert-enter (note 'enter))
           (add-hook! 'insert-leave (note 'leave))
           (add-hook! 'after-change (note 'change))
           (add-hook! 'mode-change (lambda (old new) (set! events (cons new events))))"#,
    )
    .unwrap();
    type_keys(&mut s, "ia<esc>j");
    assert_eq!(
        s.eval("(reverse events)").unwrap(),
        "(enter insert change leave normal)"
    );
}

#[test]
fn post_command_runs_after_each_key() {
    let mut s = server("x\n");
    s.eval("(define n 0) (add-hook! 'post-command (lambda () (set! n (+ n 1))))")
        .unwrap();
    type_keys(&mut s, "jkdw");
    assert_eq!(s.eval("n").unwrap(), "4");
}

#[test]
fn a_failing_hook_does_not_stop_the_others() {
    let mut s = server("x\n");
    s.eval(
        r#"(define ran #f)
           (add-hook! 'post-command (lambda () (car 1)))
           (add-hook! 'post-command (lambda () (set! ran #t)))"#,
    )
    .unwrap();
    s.keys(&["j"]);
    assert_eq!(s.eval("ran").unwrap(), "#true");
    assert!(s.status().contains("post-command hook"));
}
