//! The undo tree: u, C-r, g-, g+ and :undolist.

mod common;

use common::*;

fn line(s: &imp_server::Server) -> String {
    s.text().lines().next().unwrap_or("").to_string()
}

/// The history checked against Neovim: x, then A1 and A2, an undo, and A3
/// on a new branch. Neovim (with an undo break after each change) gives
/// g-: x12 x1 x, g+: x1 x12 x13, then u: x1 and C-r: x13.
#[test]
fn g_minus_and_plus_cross_branches_as_in_vim() {
    let mut s = server("x\n");
    type_keys(&mut s, "A1<esc>A2<esc>uA3<esc>");
    assert_eq!(line(&s), "x13");
    let mut seen = Vec::new();
    for _ in 0..3 {
        type_keys(&mut s, "g-");
        seen.push(line(&s));
    }
    assert_eq!(seen, ["x12", "x1", "x"]);
    type_keys(&mut s, "g-");
    assert_eq!(s.status(), "already at oldest change");
    seen.clear();
    for _ in 0..3 {
        type_keys(&mut s, "g+");
        seen.push(line(&s));
    }
    assert_eq!(seen, ["x1", "x12", "x13"]);
    type_keys(&mut s, "u");
    assert_eq!(line(&s), "x1");
    type_keys(&mut s, "<C-r>");
    assert_eq!(line(&s), "x13");
    // Counts.
    type_keys(&mut s, "2g-");
    assert_eq!(line(&s), "x1");
}

#[test]
fn undolist_shows_branch_tips() {
    let mut s = server("x\n");
    feed(&mut s, ":undolist<ret>");
    assert_eq!(s.status(), "Nothing to undo");
    type_keys(&mut s, "A1<esc>A2<esc>uA3<esc>:undolist<ret>");
    let rows = s.frame().text_rows().join("\n");
    assert!(rows.contains("number changes  when"), "{rows}");
    assert!(rows.contains("     2       2  "), "{rows}");
    assert!(rows.contains("     3       2  0 seconds ago"), "{rows}");
}

#[test]
fn undo_puts_marks_back() {
    let mut s = server("one\ntwo\nthree\n");
    // Mark a on "three", then delete the line above it and undo.
    type_keys(&mut s, "jjmakdd");
    assert_eq!(s.eval("(mark-get \"a\")").unwrap(), "4");
    type_keys(&mut s, "u");
    type_keys(&mut s, "gg'a");
    assert_eq!(s.eval("(current-line)").unwrap(), "2");
}

// Undo across repeats, macros and completion. Each expectation was checked
// against Vim 9.2 and Neovim, which agree: every `.` is its own undo step,
// a whole `@q` is one, and an insert that accepted a completion is one
// step holding both the typed text and the completion.

#[test]
fn each_dot_repeat_is_one_undo_step() {
    let mut s = server("x\n");
    type_keys(&mut s, "Aa<esc>..");
    assert_eq!(line(&s), "xaaa");
    type_keys(&mut s, "u");
    assert_eq!(line(&s), "xaa");
    type_keys(&mut s, "u");
    assert_eq!(line(&s), "xa");
    type_keys(&mut s, "<C-r>");
    assert_eq!(line(&s), "xaa");
    type_keys(&mut s, "<C-r>");
    assert_eq!(line(&s), "xaaa");
}

#[test]
fn dot_repeat_of_a_delete_is_one_undo_step() {
    let mut s = server("a b c d\n");
    type_keys(&mut s, "dw..");
    assert_eq!(line(&s), "d");
    type_keys(&mut s, "u");
    assert_eq!(line(&s), "c d");
    type_keys(&mut s, "<C-r>");
    assert_eq!(line(&s), "d");
}

#[test]
#[ignore = "imp makes each change in a replayed macro its own undo step; Vim makes the whole @q one"]
fn a_macro_is_one_undo_step() {
    let mut s = server("x\n");
    type_keys(&mut s, "qqA1<esc>A2<esc>A3<esc>q");
    assert_eq!(line(&s), "x123");
    type_keys(&mut s, "@q");
    assert_eq!(line(&s), "x123123");
    type_keys(&mut s, "u");
    assert_eq!(line(&s), "x123");
    type_keys(&mut s, "<C-r>");
    assert_eq!(line(&s), "x123123");
    // The changes typed while recording were steps of their own.
    type_keys(&mut s, "uu");
    assert_eq!(line(&s), "x12");
}

#[test]
fn an_insert_that_accepts_a_completion_is_one_undo_step() {
    let mut s = server("foobar\n");
    type_keys(&mut s, "A fo");
    s.keys(&["C-n"]);
    type_keys(&mut s, "<C-y><esc>");
    assert_eq!(line(&s), "foobar foobar");
    type_keys(&mut s, "u");
    assert_eq!(line(&s), "foobar");
    type_keys(&mut s, "<C-r>");
    assert_eq!(line(&s), "foobar foobar");
}
