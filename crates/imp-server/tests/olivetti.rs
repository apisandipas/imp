//! The olivetti package (packages/olivetti): a centred column of text.
//! It comes with imp but is off until init.scm asks for it.

mod common;

use common::*;
use imp_core::ClientMsg;

/// An 80x10 screen with no line numbers, showing `text`.
fn screen(text: &str) -> imp_server::Server {
    let mut s = server(text);
    s.set_size(80, 10);
    s.eval("(set-option! 'number #f) (set-option! 'relativenumber #f)")
        .unwrap();
    s
}

#[test]
fn it_is_off_until_used() {
    let mut s = screen("hello\n");
    assert_eq!(s.eval("(command-proc 'olivetti-mode)").unwrap(), "#false");
    s.eval("(use-package! 'olivetti)").unwrap();
    assert_ne!(s.eval("(command-proc 'olivetti-mode)").unwrap(), "#false");
    type_keys(&mut s, ":packages<ret>");
    let rows = s.frame().text_rows().join("\n");
    assert!(
        rows.contains("olivetti") && rows.contains("built-in"),
        "{rows}"
    );
}

#[test]
fn text_is_a_centred_column_that_wraps_and_takes_clicks() {
    let mut s = screen("one two three four five six seven\nx\n");
    s.eval("(use-package! 'olivetti 'config (lambda () (set-option! 'olivetti-body-width 20) (set-option! 'olivetti-wrap #f)))")
        .unwrap();
    type_keys(&mut s, " to");
    assert_eq!(s.eval("(window-text-width)").unwrap(), "20");
    // 80 columns: 30 blank, 20 of text, which wraps there.
    let rows = s.frame().text_rows();
    let column = " ".repeat(30);
    assert_eq!(rows[0], format!("{column}one two three four f"), "{rows:?}");
    assert_eq!(rows[1], format!("{column}ive six seven"), "{rows:?}");
    assert_eq!(rows[2], format!("{column}x"), "{rows:?}");
    // The cursor is drawn in the column.
    type_keys(&mut s, "w");
    assert_eq!(s.frame().cursor, (34, 0));
    // A click in the column lands on the text under it.
    s.frame();
    for action in ["press", "release"] {
        s.handle(ClientMsg::Mouse {
            action: action.into(),
            button: "left".into(),
            x: 35,
            y: 1,
        });
    }
    assert_eq!(s.eval("(cursor)").unwrap(), "25"); // the i of "six"
                                                   // C-c } widens it in this buffer; SPC t o turns it off.
    s.keys(&["C-c", "}"]);
    assert_eq!(s.eval("(window-text-width)").unwrap(), "24");
    assert!(s.status().contains("24 columns"), "{}", s.status());
    type_keys(&mut s, " to");
    assert_eq!(s.eval("(window-text-width)").unwrap(), "80");
    assert!(s.frame().text_rows()[0].starts_with("one two"));
}

#[test]
fn modes_in_olivetti_modes_start_with_it_on() {
    let dir = temp_path("olivetti-modes");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("notes.org"), "* Notes\n").unwrap();
    std::fs::write(dir.join("code.rs"), "fn main() {}\n").unwrap();
    let mut s = screen("");
    s.eval("(use-package! 'olivetti 'config (lambda () (set-option! 'olivetti-modes '(org-mode)) (set-option! 'olivetti-body-width 40)))")
        .unwrap();
    type_keys(
        &mut s,
        &format!(":e {}<ret>", dir.join("notes.org").display()),
    );
    assert_eq!(s.eval("(body-width)").unwrap(), "40");
    assert_eq!(
        s.frame().text_rows()[0],
        format!("{}* Notes", " ".repeat(20))
    );
    type_keys(
        &mut s,
        &format!(":e {}<ret>", dir.join("code.rs").display()),
    );
    assert_eq!(s.eval("(body-width)").unwrap(), "0");
}

#[test]
fn a_package_of_your_own_with_the_same_name_wins() {
    let dir = temp_path("olivetti-own");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("olivetti")).unwrap();
    std::fs::write(
        dir.join("olivetti/olivetti.scm"),
        "(define (my-olivetti) \"Mine.\" 'mine)\n",
    )
    .unwrap();
    let mut s = screen("");
    s.eval(&format!(
        "(set-option! 'packages-dir {:?}) (use-package! 'olivetti)",
        dir.display().to_string()
    ))
    .unwrap();
    assert_eq!(s.eval("(my-olivetti)").unwrap(), "mine");
    assert_eq!(s.eval("(command-proc 'olivetti-mode)").unwrap(), "#false");
}

#[test]
fn prose_wraps_between_words_in_the_column() {
    let mut s = screen("one two three four five six seven\n");
    s.eval("(use-package! 'olivetti 'config (lambda () (set-option! 'olivetti-body-width 20)))")
        .unwrap();
    type_keys(&mut s, " to");
    let rows = s.frame().text_rows();
    let column = " ".repeat(30);
    assert_eq!(rows[0], format!("{column}one two three four "), "{rows:?}");
    assert_eq!(rows[1], format!("{column}five six seven"), "{rows:?}");
    // The cursor on "five" is at the start of the second row.
    type_keys(&mut s, "4w");
    assert_eq!(s.frame().cursor, (30, 1));
    // Off again, wrap and linebreak are as they were.
    type_keys(&mut s, " to");
    assert_eq!(s.eval("(option 'linebreak)").unwrap(), "#false");
}

#[test]
fn a_space_where_a_row_ends_does_not_start_the_next() {
    let mut s = screen("aaaa bbbb cccc dddd eeee\n");
    s.eval("(use-package! 'olivetti 'config (lambda () (set-option! 'olivetti-body-width 20)))")
        .unwrap();
    type_keys(&mut s, " to");
    let rows = s.frame().text_rows();
    let column = " ".repeat(30);
    assert_eq!(
        rows[0].trim_end(),
        format!("{column}aaaa bbbb cccc dddd"),
        "{rows:?}"
    );
    assert_eq!(rows[1], format!("{column}eeee"), "{rows:?}");
}
