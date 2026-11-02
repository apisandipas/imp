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
fn at_at_and_a_counted_macro_are_one_undo_step_each() {
    let mut s = server("x\n");
    type_keys(&mut s, "qqA1<esc>A2<esc>A3<esc>q@q");
    let seen: Vec<String> = ["@@", "u", "3@q", "u", "u"]
        .iter()
        .map(|keys| {
            type_keys(&mut s, keys);
            line(&s)
        })
        .collect();
    assert_eq!(
        seen,
        [
            "x123123123",
            "x123123",
            "x123123123123123",
            "x123123",
            "x123"
        ]
    );
}

/// Sets register q to `keys`, as a recorded macro holds them.
fn set_macro(s: &mut imp_server::Server, keys: &str) {
    s.eval(&format!("(register-set! #\\q {keys:?} #f 'macro)"))
        .unwrap();
}

/// Undo is kept per buffer: in Vim 9.2 a macro's changes in another buffer
/// are one step there, and each return to a buffer starts a step in it.
#[test]
fn a_macro_that_switches_buffers_makes_a_step_per_visit() {
    let a = temp_path("undo-macro-a.txt");
    let b = temp_path("undo-macro-b.txt");
    std::fs::write(&a, "x\n").unwrap();
    std::fs::write(&b, "y\n").unwrap();
    let mut s = server("");
    type_keys(&mut s, &format!(":e {}<ret>A0<esc>", a.display()));
    set_macro(
        &mut s,
        &format!(
            "A1<esc>:e {}<ret>A2<esc>A3<esc>:e {}<ret>A4<esc>",
            b.display(),
            a.display()
        ),
    );
    let eb = format!(":e {}<ret>", b.display());
    let ea = format!(":e {}<ret>", a.display());
    let seen = modified_after(&mut s, &["@q", "u", &eb, "u", &ea, "u"]);
    assert_eq!(
        seen,
        ["x014 mod", "x01 mod", "y23 mod", "y nomod", "x01 mod", "x0 mod"]
    );
}

/// A save inside a macro, checked against Vim 9.2: saved at its end, undo
/// and redo cross the saved text; saved in its middle, no step holds it.
#[test]
fn a_save_inside_a_macro() {
    for (keys, expected) in [
        ("A1<esc>:w<ret>", ["x1 nomod", "x mod", "x1 nomod"]),
        ("A1<esc>:w<ret>A2<esc>", ["x12 mod", "x mod", "x12 mod"]),
    ] {
        let path = temp_path("undo-macro-save.txt");
        std::fs::write(&path, "x\n").unwrap();
        let mut s = server("");
        type_keys(&mut s, &format!(":e {}<ret>", path.display()));
        set_macro(&mut s, keys);
        let seen = modified_after(&mut s, &["@q", "u", "<C-r>"]);
        assert_eq!(seen, expected, "{keys}");
    }
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

// The modified flag follows the undo tree as in Vim: reaching the state
// last written, or the text as opened, clears it, and leaving it sets it
// again. Each sequence was checked against Vim 9.2 (`&modified` after
// each step).

/// Types each of `steps` in turn, giving after each the first line and
/// whether the buffer is modified.
fn modified_after(s: &mut imp_server::Server, steps: &[&str]) -> Vec<String> {
    steps
        .iter()
        .map(|keys| {
            type_keys(s, keys);
            let modified = s.eval("(buffer-modified?)").unwrap() == "#true";
            format!("{} {}", line(s), if modified { "mod" } else { "nomod" })
        })
        .collect()
}

#[test]
fn undo_back_to_the_saved_text_clears_modified() {
    let path = temp_path("undo-saved.txt");
    std::fs::write(&path, "x\n").unwrap();
    let mut s = server("");
    type_keys(&mut s, &format!(":e {}<ret>", path.display()));
    let seen = modified_after(
        &mut s,
        &[
            "A1<esc>", "u", "<C-r>", ":w<ret>", "A2<esc>", "u", "u", "<C-r>", "<C-r>",
        ],
    );
    assert_eq!(
        seen,
        [
            "x1 mod", "x nomod", "x1 mod", "x1 nomod", "x12 mod", "x1 nomod", "x mod", "x1 nomod",
            "x12 mod",
        ]
    );
}

#[test]
fn saving_in_the_middle_of_the_history_moves_the_saved_state() {
    let path = temp_path("undo-middle.txt");
    std::fs::write(&path, "x\n").unwrap();
    let mut s = server("");
    type_keys(
        &mut s,
        &format!(":e {}<ret>A1<esc>A2<esc>uu:w<ret>", path.display()),
    );
    let seen = modified_after(&mut s, &["<C-r>", "u", "A3<esc>", "u", "g+", "g-"]);
    assert_eq!(
        seen,
        ["x1 mod", "x nomod", "x3 mod", "x nomod", "x1 mod", "x nomod"]
    );
}

#[test]
fn editing_back_to_the_saved_text_by_hand_stays_modified() {
    let mut s = server("x\n");
    let seen = modified_after(&mut s, &["A1<esc>", "x"]);
    assert_eq!(seen, ["x1 mod", "x mod"]);
}
