//! Emacs state: the holy bindings.

mod common;

use common::*;

fn emacs(text: &str) -> imp_server::Server {
    let mut s = server(text);
    s.keys(&["C-z"]);
    s
}

#[test]
fn c_z_toggles_states() {
    let mut s = server("x\n");
    s.keys(&["C-z"]);
    assert!(status_row(&mut s).contains("EMACS"));
    // Keys type text.
    type_keys(&mut s, "ab");
    assert_eq!(s.text(), "abx\n");
    s.keys(&["C-z"]);
    assert!(status_row(&mut s).contains("NORMAL"));
    // Unlike <esc> from insert, the cursor stays where point was, as in
    // Evil, so x takes the x.
    type_keys(&mut s, "x");
    assert_eq!(s.text(), "ab\n");
}

#[test]
fn movement_and_editing() {
    let mut s = emacs("hello world\nsecond\n");
    s.keys(&["C-e"]);
    assert_eq!(s.cursor(), 11);
    s.keys(&["C-a", "M-f"]);
    assert_eq!(s.cursor(), 5);
    s.keys(&["C-n"]);
    assert_eq!(s.cursor(), 17);
    s.keys(&["M-<", "C-d", "C-d"]);
    assert_eq!(s.text(), "llo world\nsecond\n");
    s.keys(&["M->"]);
    assert_eq!(s.cursor(), s.text().chars().count());
}

#[test]
fn kill_and_yank() {
    let mut s = emacs("one\ntwo\nthree\n");
    // C-k twice kills the line text, then the line break; together.
    s.keys(&["C-k", "C-k"]);
    assert_eq!(s.text(), "two\nthree\n");
    s.keys(&["C-n", "C-y"]);
    assert_eq!(s.text(), "two\none\nthree\n");
    // Vim's p sees the kill too.
    s.keys(&["C-z"]);
    assert_eq!(s.eval("(car (register-get #\\\"))").unwrap(), "\"one\\n\"");
}

#[test]
fn region_kill_copy_and_yank_pop() {
    let mut s = emacs("alpha beta\n");
    s.keys(&["C- ", "M-f", "M-w"]);
    assert!(s.status().contains("Copied"));
    s.keys(&["M-f"]);
    s.keys(&["C- ", "M-b", "C-w"]);
    assert_eq!(s.text(), "alpha \n");
    s.keys(&["C-y"]);
    assert_eq!(s.text(), "alpha beta\n");
    // M-y swaps in the older kill.
    s.keys(&["M-y"]);
    assert_eq!(s.text(), "alpha alpha\n");
}

#[test]
fn universal_argument() {
    let mut s = emacs("");
    s.keys(&["C-u", "x"]);
    assert_eq!(s.text(), "xxxx");
    s.keys(&["C-u", "3", "y"]);
    assert_eq!(s.text(), "xxxxyyy");
}

#[test]
fn prefix_keys_and_undo() {
    let path = temp_path("emacs-save.txt");
    std::fs::write(&path, "x\n").unwrap();
    let mut s = server("");
    type_keys(&mut s, &format!(":e {}<ret>", path.display()));
    s.keys(&["C-z"]);
    type_keys(&mut s, "ab");
    s.keys(&["C-x"]);
    assert!(s.frame().text_rows().join("\n").contains("C-s"));
    s.keys(&["C-s"]);
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "abx\n");
    // Typing was one undo step.
    s.keys(&["C-/"]);
    assert_eq!(s.text(), "x\n");
    s.keys(&["C-x", "C-q"]);
    assert!(s.status().contains("is undefined"));
}

#[test]
fn isearch() {
    let mut s = emacs("a foo b foo c\n");
    s.keys(&["C-s"]);
    type_keys(&mut s, "foo");
    assert_eq!(s.cursor(), 2);
    s.keys(&["C-s"]);
    assert_eq!(s.cursor(), 8);
    type_keys(&mut s, "<ret>");
    assert_eq!(s.cursor(), 8);
    assert!(status_row(&mut s).contains("EMACS"));
}

#[test]
fn eval_last_sexp_before_point() {
    let mut s = emacs("(+ 40 2)");
    s.keys(&["C-e", "C-x", "C-e"]);
    assert_eq!(s.status(), "42");
}

#[test]
fn start_in_emacs_state_from_init() {
    let path = temp_path("emacs-init.scm");
    std::fs::write(&path, "(set-option! 'editing-style \"emacs\")").unwrap();
    let mut s = imp_server::Server::new(
        imp_core::Buffer::from_text(""),
        imp_server::Options {
            user_config: Some(path),
        },
    )
    .unwrap();
    type_keys(&mut s, "hi");
    assert_eq!(s.text(), "hi");
}
