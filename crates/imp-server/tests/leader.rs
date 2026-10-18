//! The leader key and which-key.

mod common;

use common::*;

fn rows(s: &mut imp_server::Server) -> String {
    s.frame().text_rows().join("\n")
}

#[test]
fn which_key_shows_the_next_keys() {
    let mut s = server("");
    type_keys(&mut s, " ");
    let r = rows(&mut s);
    assert!(r.contains("b   → +buffer"), "{r}");
    assert!(r.contains("SPC → find file"), "{r}");
    type_keys(&mut s, "h");
    let r = rows(&mut s);
    assert!(r.contains("k   → describe key"), "{r}");
    assert!(!r.contains("+buffer"));
    assert!(s.status().starts_with("SPC h"));
    type_keys(&mut s, "<esc>");
    assert!(!rows(&mut s).contains("describe key"));
}

#[test]
fn leader_runs_commands() {
    let mut s = server("(* 6 7)\n");
    type_keys(&mut s, " eb");
    assert_eq!(s.status(), "42");
    type_keys(&mut s, " hk");
    type_keys(&mut s, "w");
    assert!(rows(&mut s).contains("runs the motion w"));
}

#[test]
fn undefined_sequences_say_so() {
    let mut s = server("x\n");
    feed(&mut s, " bz");
    assert!(s.status().contains("is undefined"), "{}", s.status());
    // Back to normal: x deletes.
    type_keys(&mut s, "x");
    assert_eq!(s.text(), "\n");
}

#[test]
fn user_leader_bindings() {
    let mut s = server("");
    s.eval(
        r#"(define-leader-group! "o" "open")
           (define-leader! "ox" (lambda (n) (buffer-insert! 0 "hi")) "say hi")"#,
    )
    .unwrap();
    type_keys(&mut s, " ");
    assert!(rows(&mut s).contains("o   → +open"));
    type_keys(&mut s, "o");
    assert!(rows(&mut s).contains("x   → say hi"));
    type_keys(&mut s, "x");
    assert_eq!(s.text(), "hi");
}

#[test]
fn leader_in_visual_mode() {
    let mut s = server("(+ 1 1)\n(+ 2 2)\n");
    type_keys(&mut s, "V er");
    assert_eq!(s.status(), "2");
}
