//! Themes, the status line format and popup placement (theme.scm and
//! render.rs).

mod common;

use common::*;
use imp_core::{ClientMsg, Color};

fn themed(text: &str) -> imp_server::Server {
    let mut s = server(text);
    s.eval("(load-theme! 'one-dark)").unwrap();
    s
}

#[test]
fn themes_set_the_background_and_switch_completely() {
    let mut s = themed("hello\n");
    let f = s.frame();
    // The background reaches the right edge.
    assert_eq!(
        f.rows[0].last().unwrap().style.bg,
        Some(Color::Rgb(0x28, 0x2c, 0x34))
    );
    assert_eq!(f.text_rows()[0].chars().count(), 80);
    type_keys(&mut s, ":theme one-light<ret>");
    let f = s.frame();
    assert_eq!(f.rows[0][0].style.bg, Some(Color::Rgb(0xfa, 0xfa, 0xfa)));
    type_keys(&mut s, ":theme nope<ret>");
    assert!(s.status().starts_with("no theme nope"), "{}", s.status());
    type_keys(&mut s, ":theme<ret>");
    assert_eq!(s.status(), "one-light");
}

#[test]
fn a_theme_can_build_on_another() {
    let mut s = themed("x\n");
    s.eval(
        r##"(define-theme! 'mine 'one-dark (hash 'bg "#000000")
             (list (list "syntax.comment" "fg=#123456")))
           (load-theme! 'mine)"##,
    )
    .unwrap();
    assert_eq!(s.frame().rows[0][0].style.bg, Some(Color::Rgb(0, 0, 0)));
}

#[test]
fn the_status_line_follows_its_format() {
    let mut s = server("one\ntwo\nthree\nfour\n");
    s.eval(r#"(set-option! 'statusline "[%m] %f%M %{answer}%=%l/%L %p")"#)
        .unwrap();
    s.eval(r#"(set-status-value! "answer" "42" #f)"#).unwrap();
    type_keys(&mut s, "jx");
    let rows = s.frame().text_rows();
    let status = &rows[rows.len() - 2];
    assert!(status.starts_with("[NORMAL] [No Name]● 42"), "{status:?}");
    assert!(status.ends_with("2/4 50%"), "{status:?}");
    // The mode's face follows the mode.
    s.eval(r#"(set-option! 'statusline "%#mode#%m")"#).unwrap();
    type_keys(&mut s, "i");
    let f = s.frame();
    let mode_span = &f.rows[f.rows.len() - 2][0];
    assert_eq!(mode_span.text, "INSERT");
    assert_eq!(mode_span.style.bg, Some(Color::Rgb(0x98, 0xc3, 0x79)));
}

#[test]
fn a_popup_at_the_cursor_is_a_box_beside_it() {
    let mut s = server("hello\n");
    s.handle(ClientMsg::Resize {
        width: 30,
        height: 10,
    });
    type_keys(&mut s, "ll");
    s.eval(r#"(set-popup! (list "first" (list "second " (list "dim" "popup.detail"))))"#)
        .unwrap();
    s.eval(r#"(set-popup-place! "cursor" 0 "Menu")"#).unwrap();
    let rows = s.frame().text_rows();
    assert!(rows[1].starts_with("~╭─ Menu ─"), "{rows:?}");
    assert!(rows[2].starts_with("~│ first"), "{rows:?}");
    assert!(rows[3].starts_with("~│ second dim │"), "{rows:?}");
    assert!(rows[4].starts_with("~╰────"), "{rows:?}");
    // Clearing it puts popups back at the bottom.
    s.eval("(set-popup! '()) (set-popup! (list \"bottom\"))")
        .unwrap();
    let rows = s.frame().text_rows();
    assert!(rows[7].starts_with("───"), "{rows:?}");
    assert!(rows[8].starts_with("bottom"), "{rows:?}");
}
