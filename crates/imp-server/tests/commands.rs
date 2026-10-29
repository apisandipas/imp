//! Commands at the `:` line (docs/specs/commands.md): `:NAME` runs the
//! command NAME when no ex command has that name.

mod common;

use common::*;

/// The message line.
fn said(s: &mut imp_server::Server) -> String {
    s.frame().text_rows().last().unwrap().trim_end().to_string()
}

/// A server with a command `hello-world` that records its counts in
/// `*hellos*`.
fn with_hello() -> imp_server::Server {
    let mut s = server("one\ntwo\n");
    s.eval(
        "(define *hellos* '())
         (define-command! 'hello-world
           (lambda (count) \"Say hello.\" (set! *hellos* (cons count *hellos*))))",
    )
    .unwrap();
    s
}

#[test]
fn the_command_line_runs_a_command() {
    let mut s = with_hello();
    type_keys(&mut s, ":hello-world<ret>");
    assert_eq!(s.eval("*hellos*").unwrap(), "(1)");
    // A number before it is the count, even past the buffer's last line.
    type_keys(&mut s, ":3hello-world<ret>");
    type_keys(&mut s, ":12hello-world<ret>");
    assert_eq!(s.eval("*hellos*").unwrap(), "(12 3 1)");
}

#[test]
fn a_command_takes_no_other_range() {
    let mut s = with_hello();
    for keys in [":%", ":.,$", ":.", "Vj:"] {
        type_keys(&mut s, &format!("{keys}hello-world<ret>"));
        assert!(
            said(&mut s).contains("hello-world takes no range"),
            "{keys}: {}",
            said(&mut s)
        );
    }
    assert_eq!(s.eval("*hellos*").unwrap(), "()");
}

#[test]
fn an_ex_command_of_the_same_name_wins() {
    let mut s = server("one\n");
    s.eval(
        "(define *ran* #f)
         (define-command! 'noh (lambda (count) \"Not Vim's.\" (set! *ran* #t)))",
    )
    .unwrap();
    type_keys(&mut s, ":noh<ret>");
    assert_eq!(s.eval("*ran*").unwrap(), "#false");
}

#[test]
fn only_the_full_name_runs_a_command() {
    let mut s = with_hello();
    type_keys(&mut s, ":hello-wor<ret>");
    assert!(said(&mut s).contains("not an editor command: hello-wor"));
    type_keys(&mut s, ":nope<ret>");
    assert!(said(&mut s).contains("not an editor command: nope"));
    assert_eq!(s.eval("*hellos*").unwrap(), "()");
}

#[test]
fn an_error_in_a_command_shows_on_the_status_line() {
    let mut s = server("one\n");
    s.eval("(define-command! 'broken (lambda (count) \"Fail.\" (error \"it broke\")))")
        .unwrap();
    type_keys(&mut s, ":broken<ret>");
    assert!(said(&mut s).contains("it broke"), "{}", said(&mut s));
}
