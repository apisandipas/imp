//! The Scheme REPL's input history (runtime/repl.scm).

mod common;

use common::*;

/// A server with the REPL open and a state directory of its own, so
/// tests don't share history.
fn repl(name: &str) -> imp_server::Server {
    let mut s = server("");
    let dir = temp_path(name);
    let _ = std::fs::remove_dir_all(&dir);
    s.eval(&format!(
        "(set-option! 'state-directory {:?})",
        dir.display().to_string()
    ))
    .unwrap();
    type_keys(&mut s, ":repl<ret>");
    s
}

/// The input after the last prompt.
fn input(s: &imp_server::Server) -> String {
    let text = s.text();
    text[text.rfind("imp> ").unwrap() + 5..].to_string()
}

#[test]
fn meta_p_and_n_step_through_inputs() {
    let mut s = repl("repl-steps");
    type_keys(&mut s, "(+ 1 1)<ret>(define x 5)<ret>(+ 2 2)<ret>");
    type_keys(&mut s, "<M-p>");
    assert_eq!(input(&s), "(+ 2 2)");
    type_keys(&mut s, "<M-p><M-p>");
    assert_eq!(input(&s), "(+ 1 1)");
    // Past the oldest stays there.
    type_keys(&mut s, "<M-p>");
    assert_eq!(input(&s), "(+ 1 1)");
    type_keys(&mut s, "<M-n>");
    assert_eq!(input(&s), "(define x 5)");
    // Past the newest brings back what was typed.
    type_keys(&mut s, "<M-n><M-n>");
    assert_eq!(input(&s), "");
    // Sending a recalled input runs it again, and it becomes the newest.
    type_keys(&mut s, "<M-p><M-p><M-p><ret>");
    assert!(s.text().ends_with("(+ 1 1)\n2\nimp> "), "{:?}", s.text());
    type_keys(&mut s, "<M-p>");
    assert_eq!(input(&s), "(+ 1 1)");
    type_keys(&mut s, "<M-p>");
    assert_eq!(input(&s), "(+ 2 2)");
}

#[test]
fn history_matches_what_was_typed() {
    let mut s = repl("repl-prefix");
    type_keys(&mut s, "(+ 1 1)<ret>(define y 1)<ret>(+ 3 3)<ret>");
    type_keys(&mut s, "(d<M-p>");
    assert_eq!(input(&s), "(define y 1)");
    type_keys(&mut s, "<M-n>");
    assert_eq!(input(&s), "(d");
}

#[test]
fn arrows_step_on_the_prompt_line_only() {
    let mut s = repl("repl-arrows");
    type_keys(&mut s, "(+ 1 1)<ret>");
    type_keys(&mut s, "<up>");
    assert_eq!(input(&s), "(+ 1 1)");
    type_keys(&mut s, "<down>");
    assert_eq!(input(&s), "");
    // In a two-line input, <up> from the second line moves to the first.
    s.eval("(repl-print! \"(list 1\n 2)\")").unwrap();
    type_keys(&mut s, "<up>");
    assert_eq!(input(&s), "(list 1\n 2)");
    // The column is kept, as insert state's <up> keeps it.
    assert_eq!(s.cursor(), s.text().rfind("imp> ").unwrap() + 3);
    // There it steps history, which holds nothing starting with this.
    type_keys(&mut s, "<up>");
    assert_eq!(input(&s), "(list 1\n 2)");
    // A sent two-line input comes back whole.
    type_keys(&mut s, "<down>");
    s.eval("(repl-set-input! \"(list 1\n 2)\")").unwrap();
    type_keys(&mut s, "<ret><M-p>");
    assert_eq!(input(&s), "(list 1\n 2)");
}

#[test]
fn normal_state_steps_too() {
    let mut s = repl("repl-normal");
    type_keys(&mut s, "(+ 1 1)<ret>(+ 2 2)<ret><esc>");
    type_keys(&mut s, "<M-p>");
    assert_eq!(input(&s), "(+ 2 2)");
    type_keys(&mut s, "<M-p>");
    assert_eq!(input(&s), "(+ 1 1)");
}
