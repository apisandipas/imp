//! The move-lines package (packages/move-lines): J and K move the lines
//! of a visual line selection.

mod common;

use common::*;

fn moving(text: &str) -> imp_server::Server {
    let mut s = server(text);
    s.eval("(use-package! 'move-lines)").unwrap();
    s
}

#[test]
fn j_and_k_move_the_selected_lines_and_keep_them_selected() {
    let mut s = moving("a\nb\nc\nd\ne\n");
    type_keys(&mut s, "jVjJ");
    assert_eq!(s.text(), "a\nd\nb\nc\ne\n");
    assert_eq!(s.eval("*mode*").unwrap(), "visual");
    // Still selected: again, then a count.
    type_keys(&mut s, "J");
    assert_eq!(s.text(), "a\nd\ne\nb\nc\n");
    // At the bottom it stays put.
    type_keys(&mut s, "J");
    assert_eq!(s.text(), "a\nd\ne\nb\nc\n");
    type_keys(&mut s, "2K");
    assert_eq!(s.text(), "a\nb\nc\nd\ne\n");
    type_keys(&mut s, "5K");
    assert_eq!(s.text(), "b\nc\na\nd\ne\n");
    // What's selected is what moved; d deletes it.
    type_keys(&mut s, "d");
    assert_eq!(s.text(), "a\nd\ne\n");
    // Each move is one undo step.
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "b\nc\na\nd\ne\n");
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "a\nb\nc\nd\ne\n");
}

#[test]
fn other_visual_modes_keep_vim_j() {
    let mut s = moving("one\ntwo\n");
    type_keys(&mut s, "vJ");
    assert_eq!(s.text(), "one two\n");
}

#[test]
fn moving_the_last_line_up() {
    let mut s = moving("a\nb\nc");
    type_keys(&mut s, "GVK");
    assert_eq!(s.text(), "a\nc\nb");
}
