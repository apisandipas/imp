//! The showkeys package (docs/specs/showkeys.md): the last keys pressed,
//! in a floating box.

mod common;

use common::*;
use imp_core::ClientMsg;

/// A 30 by 10 screen with showkeys loaded and turned on.
fn screen() -> imp_server::Server {
    let mut s = server("one\ntwo\nthree\nfour\n");
    s.handle(ClientMsg::Resize {
        width: 30,
        height: 10,
    });
    s.eval("(use-package! 'showkeys)").unwrap();
    s.eval("(run-command 'showkeys-mode)").unwrap();
    s
}

/// The text in the box, or None if no box is shown.
fn shown(s: &mut imp_server::Server) -> Option<String> {
    let rows = s.frame().text_rows();
    let row = rows.iter().find(|r| r.contains("│ "))?;
    let start = row.find("│ ")? + "│ ".len();
    let end = row.rfind(" │")?;
    Some(row[start..end].trim_end().to_string())
}

fn name(s: &mut imp_server::Server, key: &str) -> String {
    s.eval(&format!("(showkeys-name {key:?})"))
        .unwrap()
        .trim_matches('"')
        .to_string()
}

#[test]
fn the_last_keys_pressed_newest_on_the_right() {
    let mut s = screen();
    assert_eq!(shown(&mut s), None);
    s.keys(&["j"]);
    assert_eq!(shown(&mut s).as_deref(), Some("j"));
    s.keys(&["k", "l", "h"]);
    assert_eq!(shown(&mut s).as_deref(), Some("k l h"));
    // Bottom-right, above the status line.
    let rows = s.frame().text_rows();
    assert!(rows[6].ends_with("│ k l h │"), "{:?}", rows[6]);
    s.eval("(set-option! 'showkeys-max 2)").unwrap();
    s.keys(&["j"]);
    assert_eq!(shown(&mut s).as_deref(), Some("h j"));
}

#[test]
fn off_until_turned_on_and_hidden_when_turned_off() {
    let mut s = server("one\ntwo\n");
    s.eval("(use-package! 'showkeys)").unwrap();
    s.keys(&["j"]);
    assert_eq!(shown(&mut s), None);
    s.eval("(run-command 'showkeys-mode)").unwrap();
    s.keys(&["k"]);
    assert_eq!(shown(&mut s).as_deref(), Some("k"));
    s.eval("(run-command 'showkeys-mode)").unwrap();
    assert_eq!(shown(&mut s), None);
    s.keys(&["j"]);
    assert_eq!(shown(&mut s), None);
}

#[test]
fn it_hides_after_the_timeout_and_forgets_the_keys() {
    let mut s = screen();
    s.eval("(set-option! 'showkeys-timeout 0.1)").unwrap();
    s.keys(&["j"]);
    assert_eq!(shown(&mut s).as_deref(), Some("j"));
    s.pump(std::time::Duration::from_millis(300));
    assert_eq!(shown(&mut s), None);
    s.keys(&["k"]);
    assert_eq!(shown(&mut s).as_deref(), Some("k"));
}

#[test]
fn keys_as_imp_names_them_with_a_few_symbols() {
    let mut s = screen();
    assert_eq!(name(&mut s, " "), "SPC");
    assert_eq!(name(&mut s, "C-x"), "C-x");
    assert_eq!(name(&mut s, "<bs>"), "⌫");
    assert_eq!(name(&mut s, "<ret>"), "⏎");
    assert_eq!(name(&mut s, "M-<ret>"), "M-⏎");
    assert_eq!(name(&mut s, "<left>"), "←");
    assert_eq!(name(&mut s, "<esc>"), "Esc");
    assert_eq!(name(&mut s, "<home>"), "Home");
    assert_eq!(name(&mut s, "<"), "<");
    assert_eq!(name(&mut s, "C--"), "C--");
    s.eval(r#"(set-option! 'showkeys-format '(("<esc>" "⎋") ("j" "down")))"#)
        .unwrap();
    assert_eq!(name(&mut s, "<esc>"), "⎋");
    s.keys(&["j"]);
    assert_eq!(shown(&mut s).as_deref(), Some("down"));
}

#[test]
fn a_repeated_key_with_a_count() {
    let mut s = screen();
    s.keys(&["j", "j"]);
    assert_eq!(shown(&mut s).as_deref(), Some("j j"));
    s.eval("(set-option! 'showkeys-count #t)").unwrap();
    s.keys(&["k", "j", "j", "j", "j"]);
    assert_eq!(shown(&mut s).as_deref(), Some("j k j ×4"));
}

#[test]
fn excluded_states_by_the_state_the_key_was_pressed_in() {
    let mut s = screen();
    s.eval("(set-option! 'showkeys-excluded-states '(insert))")
        .unwrap();
    // The <esc> leaving insert state was pressed in it.
    type_keys(&mut s, "iab<esc>l");
    assert_eq!(shown(&mut s).as_deref(), Some("i l"));
}

#[test]
fn only_keys_pressed_not_pastes_or_macros() {
    let mut s = screen();
    s.keys(&["q", "a", "j", "q"]);
    assert_eq!(shown(&mut s).as_deref(), Some("a j q"));
    // The macro's j isn't pressed again.
    s.keys(&["@", "a"]);
    assert_eq!(shown(&mut s).as_deref(), Some("q @ a"));
    s.handle(ClientMsg::Paste("xyz".into()));
    assert_eq!(shown(&mut s).as_deref(), Some("q @ a"));
}

#[test]
fn where_it_goes() {
    let mut s = screen();
    s.eval("(set-option! 'showkeys-position 'top-left)")
        .unwrap();
    s.keys(&["j"]);
    let rows = s.frame().text_rows();
    assert!(rows[1].starts_with("t│ j │"), "{:?}", rows[1]);
}

#[test]
fn its_faces_or_the_floating_boxs() {
    let mut s = screen();
    s.eval(r#"(set-face! "float.border" "fg=#ff0000") (set-face! "float" "fg=#00ff00")"#)
        .unwrap();
    s.keys(&["j"]);
    let style = |s: &mut imp_server::Server, text: &str| {
        let f = s.frame();
        f.rows
            .iter()
            .flatten()
            .find(|span| span.text.contains(text))
            .unwrap_or_else(|| panic!("no {text:?}"))
            .style
    };
    // Unset, the keys and border are the floating box's.
    assert_eq!(
        style(&mut s, "j").fg,
        Some(imp_core::Color::Rgb(0, 0xff, 0))
    );
    assert_eq!(
        style(&mut s, "╭").fg,
        Some(imp_core::Color::Rgb(0xff, 0, 0))
    );
    s.eval(r#"(set-face! "showkeys" "bold") (set-face! "showkeys.border" "fg=#0000ff")"#)
        .unwrap();
    s.keys(&["k"]);
    let keys = style(&mut s, "j k");
    assert!(keys.bold);
    assert_eq!(keys.fg, Some(imp_core::Color::Rgb(0, 0xff, 0)));
    assert_eq!(
        style(&mut s, "╭").fg,
        Some(imp_core::Color::Rgb(0, 0, 0xff))
    );
}
