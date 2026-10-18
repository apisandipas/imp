//! The editor documents itself from its own source.

mod common;

use common::*;

fn popup_text(s: &mut imp_server::Server) -> String {
    s.frame().text_rows().join("\n")
}

#[test]
fn describe_function_shows_comment_and_location() {
    let mut s = server("");
    type_keys(&mut s, ":help line-first-nonblank<ret>");
    let text = popup_text(&mut s);
    assert!(text.contains("Defined in runtime/core.scm:"), "{text}");
    assert!(
        text.contains("Offset of the first non-blank char"),
        "{text}"
    );
}

#[test]
fn describe_key_finds_the_binding() {
    let mut s = server("");
    s.eval("(run-command 'describe-key)").unwrap();
    type_keys(&mut s, "w");
    let text = popup_text(&mut s);
    assert!(text.contains("w runs the motion w"), "{text}");
    assert!(text.contains("define-motion! \"w\""), "{text}");
    // Prefix keys wait for the rest.
    type_keys(&mut s, "<esc>");
    s.eval("(run-command 'describe-key)").unwrap();
    type_keys(&mut s, "gg");
    assert!(popup_text(&mut s).contains("gg runs the motion gg"));
    type_keys(&mut s, "<esc>");
    s.eval("(run-command 'describe-key)").unwrap();
    type_keys(&mut s, "fx");
    assert!(popup_text(&mut s).contains("motion taking a char f"));
    type_keys(&mut s, "<esc>");
    s.eval("(run-command 'describe-key)").unwrap();
    type_keys(&mut s, "p");
    assert!(popup_text(&mut s).contains("paste-command! \"p\""));
}

#[test]
fn describe_key_names_commands() {
    let mut s = server("");
    s.eval("(define-key! 'normal \"Q\" 'eval-buffer)").unwrap();
    s.eval("(run-command 'describe-key)").unwrap();
    type_keys(&mut s, "Q");
    let text = popup_text(&mut s);
    assert!(text.contains("Q runs the command eval-buffer"), "{text}");
    assert!(text.contains("Evaluate the whole buffer."), "{text}");
}

#[test]
fn help_for_options_and_ex_commands() {
    let mut s = server("");
    type_keys(&mut s, ":help sw<ret>");
    assert!(popup_text(&mut s).contains("shiftwidth = 4"));
    type_keys(&mut s, "<esc>:help sort<ret>");
    assert!(popup_text(&mut s).contains(":sort"));
}

#[test]
fn apropos_lists_matching_names() {
    let mut s = server("");
    type_keys(&mut s, ":apropos paragraph<ret>");
    let text = popup_text(&mut s);
    assert!(text.contains("paragraph-forward"), "{text}");
}

#[test]
fn definitions_in_init_win() {
    let mut s = server("");
    s.eval("(record-source! \"init.scm\" \"\" \";; Mine now.\\n(define (line-first-nonblank line) 0)\\n\")")
        .unwrap();
    type_keys(&mut s, ":help line-first-nonblank<ret>");
    let text = popup_text(&mut s);
    assert!(text.contains("Defined in init.scm:2"), "{text}");
    assert!(text.contains("Mine now."), "{text}");
}

#[test]
fn find_definition_opens_the_source() {
    let mut s = server("");
    type_keys(&mut s, ":find-definition blank-line?<ret>");
    assert!(s.text().contains(";;; vim.scm"));
    let line_start = s.text()[..s.cursor()].rfind('\n').map_or(0, |i| i + 1);
    assert!(s.text()[line_start..].starts_with("(define (blank-line? line)"));
    // The copy is not modified, so it can be left.
    type_keys(&mut s, ":bd<ret>");
    assert_eq!(s.text(), "");
}
