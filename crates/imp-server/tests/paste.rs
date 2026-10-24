//! Pasted text arriving whole (the terminal client's bracketed paste, the
//! window client's paste keys).

mod common;

use common::*;
use imp_core::ClientMsg;

fn paste(s: &mut imp_server::Server, text: &str) {
    s.handle(ClientMsg::Paste(text.into()));
    assert!(!s.status().starts_with("error"), "{}", s.status());
}

#[test]
fn insert_state_takes_it_as_it_is() {
    let mut s = server("\n");
    s.eval("(set-option! 'autoindent #t)").unwrap();
    type_keys(&mut s, "i  ");
    // No autoindent on the pasted lines.
    paste(&mut s, "if x:\nreturn 1\n");
    type_keys(&mut s, "end<esc>");
    assert_eq!(s.text(), "  if x:\nreturn 1\nend\n");
}

#[test]
fn normal_state_inserts_at_the_cursor_as_one_change() {
    let mut s = server("ab\n");
    type_keys(&mut s, "l");
    paste(&mut s, "XY");
    assert_eq!(s.text(), "aXYb\n");
    assert_eq!(s.cursor(), 2);
    assert!(status_row(&mut s).contains("NORMAL"));
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "ab\n");
}

#[test]
fn the_command_line_types_it() {
    let mut s = server("one\n");
    type_keys(&mut s, ":");
    paste(&mut s, "s/one/two\n");
    type_keys(&mut s, "<bs><ret>");
    assert_eq!(s.text(), "two\n");
}

#[test]
fn after_change_runs_for_a_paste() {
    let mut s = server("\n");
    s.eval("(define changes 0) (add-hook! 'after-change (lambda () (set! changes (+ changes 1))))")
        .unwrap();
    type_keys(&mut s, "i");
    paste(&mut s, "abc");
    assert_eq!(s.eval("changes").unwrap(), "1");
}

#[test]
fn an_empty_paste_says_so() {
    let mut s = server("ab\n");
    type_keys(&mut s, "i");
    paste(&mut s, "");
    assert_eq!(s.text(), "ab\n");
    assert_eq!(s.status(), "Nothing to paste");
}
