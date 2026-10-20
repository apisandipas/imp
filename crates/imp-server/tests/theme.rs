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
fn everforest_has_its_own_syntax_colors_and_leaves_none_behind() {
    let mut s = themed("");
    let path = temp_path("everforest.rs");
    std::fs::write(&path, "fn main() { let s = \"hi\"; }\n").unwrap();
    type_keys(&mut s, &format!(":e {}<ret>", path.display()));
    let fg = |s: &mut imp_server::Server, text: &str| {
        let row = &s.frame().rows[0];
        row.iter()
            .find(|sp| sp.text.contains(text))
            .unwrap()
            .style
            .fg
    };
    type_keys(&mut s, ":theme everforest-dark<ret>");
    assert_eq!(
        s.frame().rows[0][0].style.bg,
        Some(Color::Rgb(0x2d, 0x35, 0x3b))
    );
    assert_eq!(fg(&mut s, "fn"), Some(Color::Rgb(0xe6, 0x7e, 0x80)));
    assert_eq!(fg(&mut s, "\"hi\""), Some(Color::Rgb(0x83, 0xc0, 0x92)));
    // Switching away resets the faces Everforest changed.
    type_keys(&mut s, ":theme one-dark<ret>");
    assert_eq!(fg(&mut s, "fn"), Some(Color::Rgb(0xc6, 0x78, 0xdd)));
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

#[test]
fn describe_face_names_the_faces_under_the_cursor() {
    let mut s = themed("");
    let path = temp_path("faces.rs");
    std::fs::write(&path, "fn main() {}\n").unwrap();
    type_keys(&mut s, &format!(":e {}<ret>", path.display()));
    s.eval(r#"(buffer-highlight-add! "test" 0 2 "diff.added")"#)
        .unwrap();
    s.eval("(run-command 'describe-face)").unwrap();
    let text = s.frame().text_rows().join("\n");
    // Bottom first: the text's own face, the syntax face, the highlight.
    let normal = text.find("normal").expect(&text);
    let keyword = text.find("syntax.keyword").expect(&text);
    let added = text.find("diff.added").expect(&text);
    assert!(normal < keyword && keyword < added, "{text}");
    assert!(text.contains("fg=#c678dd"), "{text}");
    assert!(
        text.contains(r#"(set-face! "diff.added" "fg=#98c379")"#),
        "{text}"
    );
}

#[test]
fn list_faces_draws_each_face_in_itself() {
    let mut s = themed("");
    // Wide enough for the samples in the window down the right.
    s.set_size(220, 30);
    s.eval("(run-command 'list-faces)").unwrap();
    assert_eq!(s.eval("(buffer-name)").unwrap(), "\"*faces*\"");
    type_keys(&mut s, "/^syntax.keyword <ret>");
    let f = s.frame();
    let row = f
        .rows
        .iter()
        .find(|r| r.iter().any(|sp| sp.text.starts_with("syntax.keyword ")))
        .unwrap();
    let sample = row.iter().find(|sp| sp.text.contains("Sample")).unwrap();
    assert_eq!(sample.style.fg, Some(Color::Rgb(0xc6, 0x78, 0xdd)));
    type_keys(&mut s, "<ret>");
    let text = s.frame().text_rows().join("\n");
    assert!(
        text.contains(r#"(set-face! "syntax.keyword" "fg=#c678dd")"#),
        "{text}"
    );
}

#[test]
fn window_options_reach_the_frame() {
    let mut s = themed("hello\n");
    let a = s.frame().appearance;
    assert_eq!(a.background, Some(Color::Rgb(0x28, 0x2c, 0x34)));
    assert_eq!((a.padding, a.transparency, a.font_size), (0, 0, 0));
    s.eval(
        r#"(set-option! 'font "Victor Mono")
           (set-option! 'font-size 16)
           (set-option! 'window-padding 40)
           (set-option! 'background-opacity 0.9)
           (set-option! 'terminal-background #f)"#,
    )
    .unwrap();
    let a = s.frame().appearance;
    assert_eq!(a.font, "Victor Mono");
    assert_eq!((a.font_size, a.padding, a.transparency), (16, 40, 10));
    assert!(a.clear_terminal_background);
    assert_eq!(s.eval("(option 'window-padding)").unwrap(), "40");
    // :set works too, and bad values are refused.
    type_keys(&mut s, ":set window-padding=8<ret>");
    assert_eq!(s.frame().appearance.padding, 8);
    assert!(s.eval("(set-option! 'background-opacity 2)").is_err());
    assert_eq!(s.frame().appearance.transparency, 10);
}
