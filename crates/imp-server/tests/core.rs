//! runtime/core.scm: keymaps, hooks, advice, imp-eval-string and the
//! small helpers the runtime and packages share. hooks.rs covers the hooks
//! the editor runs and eval.rs live redefinition through :eval; these
//! check the procedures themselves.

mod common;

use common::*;

#[test]
fn define_key_binds_procedures_and_command_names() {
    let mut s = server("x\n");
    assert_eq!(s.eval("(hash-length (keymap 'no-such-mode))").unwrap(), "0");
    s.eval(
        r#"(define hits 0)
           (define-key! 'normal "Q" (lambda (count) (set! hits (+ hits count))))
           (define-command! 'add-ten (lambda (count) (set! hits (+ hits 10))))
           (define-key! 'normal "gQ" 'add-ten "add ten")"#,
    )
    .unwrap();
    // A procedure is bound as itself, a name as the name.
    assert_eq!(
        s.eval(r#"(procedure? (key-binding 'normal "Q"))"#).unwrap(),
        "#true"
    );
    assert_eq!(s.eval(r#"(key-binding 'normal "gQ")"#).unwrap(), "add-ten");
    // lookup-key resolves a name to its command's procedure.
    assert_eq!(
        s.eval(r#"(eq? (lookup-key 'normal "gQ") (command-proc 'add-ten))"#)
            .unwrap(),
        "#true"
    );
    assert_eq!(
        s.eval(r#"(lookup-key 'normal "no such key")"#).unwrap(),
        "#false"
    );
    assert_eq!(
        s.eval(r#"(binding-label-in 'normal "gQ")"#).unwrap(),
        r#""add ten""#
    );
    type_keys(&mut s, "3QgQ");
    assert_eq!(s.eval("hits").unwrap(), "13");
    // Binding again without a label forgets the old one.
    s.eval(r#"(define-key! 'normal "gQ" 'add-ten)"#).unwrap();
    assert_eq!(
        s.eval(r#"(binding-label-in 'normal "gQ")"#).unwrap(),
        "#false"
    );
}

#[test]
fn local_keymaps_come_before_the_modes_own() {
    let mut s = server("x\n");
    s.eval(
        r#"(define-key! 'normal "Q" 'from-normal)
           (define-key! 'my-local "Q" 'from-local)
           (define saved-local-keymaps *local-keymaps*)
           (set! *local-keymaps* (lambda (mode) (if (eq? mode 'normal) '(my-local) '())))"#,
    )
    .unwrap();
    assert_eq!(
        s.eval(r#"(key-binding 'normal "Q")"#).unwrap(),
        "from-local"
    );
    assert_eq!(
        s.eval(r#"(local-key-binding 'normal "Q")"#).unwrap(),
        "from-local"
    );
    assert_eq!(
        s.eval(r#"(local-key-binding 'insert "Q")"#).unwrap(),
        "#false"
    );
    s.eval("(set! *local-keymaps* saved-local-keymaps)")
        .unwrap();
    assert_eq!(
        s.eval(r#"(key-binding 'normal "Q")"#).unwrap(),
        "from-normal"
    );
}

#[test]
fn run_command_runs_by_name_and_reports_unknown_names() {
    let mut s = server("");
    s.eval("(define got #f) (define-command! 'note-count (lambda (n) (set! got n)))")
        .unwrap();
    s.eval("(run-command 'note-count)").unwrap();
    assert_eq!(s.eval("got").unwrap(), "1");
    s.eval("(run-command 'note-count 4)").unwrap();
    assert_eq!(s.eval("got").unwrap(), "4");
    assert!(s.eval("(member 'note-count (command-names))").unwrap() != "#false");
    s.eval("(run-command 'no-such-command)").unwrap();
    assert_eq!(s.status(), "no command no-such-command");
}

#[test]
fn hooks_add_run_and_remove() {
    let mut s = server("");
    s.eval(
        r#"(define seen '())
           (define (first-proc a b) (set! seen (cons (list 'first a b) seen)))
           (define (second-proc a b) (set! seen (cons (list 'second a b) seen)))
           (add-hook! 'my-hook first-proc)
           (add-hook! 'my-hook second-proc)
           (add-hook! 'my-hook first-proc)"#,
    )
    .unwrap();
    // Adding a procedure twice keeps one; they run in the order added,
    // with the hook's arguments.
    assert_eq!(s.eval("(length (hook-procs 'my-hook))").unwrap(), "2");
    s.eval("(run-hooks 'my-hook 1 2)").unwrap();
    assert_eq!(
        s.eval("(reverse seen)").unwrap(),
        "((first 1 2) (second 1 2))"
    );
    s.eval("(set! seen '()) (remove-hook! 'my-hook first-proc) (run-hooks 'my-hook 3 4)")
        .unwrap();
    assert_eq!(s.eval("seen").unwrap(), "((second 3 4))");
    // A hook nothing was added to runs nothing.
    s.eval("(run-hooks 'empty-hook)").unwrap();
    assert_eq!(s.eval("(hook-procs 'empty-hook)").unwrap(), "()");
}

#[test]
fn advice_is_added_once_and_removed_to_the_original() {
    let mut s = server("");
    s.eval(
        r#"(define n 0)
           (define (bump x) (set! n (+ n 1)))
           (define (double x) (* 2 x))"#,
    )
    .unwrap();
    s.eval("(advice-add! 'double 'before bump) (advice-add! 'double 'before bump)")
        .unwrap();
    assert_eq!(s.eval("(double 5)").unwrap(), "10");
    assert_eq!(s.eval("n").unwrap(), "1");
    let err = s.eval("(advice-add! 'double 'beside bump)").unwrap_err();
    assert!(err.contains("before, after or around, not beside"), "{err}");
    s.eval("(advice-remove! 'double bump)").unwrap();
    assert_eq!(s.eval("(advised 'double)").unwrap(), "#false");
    assert_eq!(s.eval("(double 5)").unwrap(), "10");
    assert_eq!(s.eval("n").unwrap(), "1");
    // Removing advice a function doesn't have does nothing.
    s.eval("(advice-remove! 'double bump)").unwrap();
    assert_eq!(s.eval("(double 2)").unwrap(), "4");
}

#[test]
fn eval_string_runs_every_form_as_one_unit() {
    let mut s = server("");
    // The last form's value, and forms may use what earlier ones define,
    // macros included.
    assert_eq!(
        s.eval(
            r#"(define-syntax twice (syntax-rules () [(_ e) (begin e e)]))
               (define count 0)
               (twice (set! count (+ count 1)))
               (+ count 40)"#
        )
        .unwrap(),
        "42"
    );
    // A definition returns its name.
    assert_eq!(s.eval("(define answer 42)").unwrap(), "answer");
    // Nothing at all is fine.
    assert_eq!(s.eval("").unwrap(), "");
    assert_eq!(s.eval("; just a comment\n").unwrap(), "");
}

#[test]
fn eval_string_rejects_text_that_does_not_parse() {
    let mut s = server("");
    let err = s.eval("(define parsed-anyway 1) (+ 1").unwrap_err();
    assert!(!err.is_empty());
    // Nothing in the text ran, not even the forms before the bad one.
    assert_eq!(s.eval("(bound? 'parsed-anyway)").unwrap(), "#false");
}

#[test]
fn shared_helpers() {
    let mut s = server("");
    let checks = [
        r#"(pad-left "7" 3)"#,
        r#"(pad-left "1234" 3)"#,
        "(two-digits 7)",
        "(two-digits 0)",
        "(two-digits 12)",
        "(child-path \"/\" \"etc\")",
        "(child-path \"/home/me\" \"notes.org\")",
    ];
    let got: Vec<String> = checks.iter().map(|c| s.eval(c).unwrap()).collect();
    assert_eq!(
        got,
        [
            r#""  7""#,
            r#""1234""#,
            r#""07""#,
            r#""00""#,
            r#""12""#,
            r#""/etc""#,
            r#""/home/me/notes.org""#,
        ]
    );
    // shell-quote: compared in Scheme so the printer's escaping doesn't
    // get in the way. A quote inside ends the quoting, adds \' and
    // reopens it.
    assert_eq!(
        s.eval(r#"(equal? (shell-quote "a b") "'a b'")"#).unwrap(),
        "#true"
    );
    assert_eq!(
        s.eval(r#"(equal? (shell-quote "it's") (string-append "'it'" "\\" "''s'"))"#)
            .unwrap(),
        "#true"
    );
    assert_eq!(
        s.eval(r#"(equal? (shell-quote "") "''")"#).unwrap(),
        "#true"
    );
}

#[test]
fn shell_quote_survives_a_real_shell() {
    let mut s = server("");
    let quoted = s.eval(r#"(shell-quote "it's $HOME `x` \"q\"")"#).unwrap();
    // The printed string, unescaped by Steel's printer as a Rust string.
    let quoted = unprint(&quoted);
    let out = std::process::Command::new("sh")
        .arg("-c")
        .arg(format!("printf %s {quoted}"))
        .output()
        .unwrap();
    assert_eq!(String::from_utf8_lossy(&out.stdout), "it's $HOME `x` \"q\"");
}

/// Undoes the printer's quoting of a string: the surrounding quotes, and
/// backslash escapes of `"` and `\`.
fn unprint(printed: &str) -> String {
    let inner = &printed[1..printed.len() - 1];
    let mut out = String::new();
    let mut chars = inner.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            out.extend(chars.next());
        } else {
            out.push(c);
        }
    }
    out
}
