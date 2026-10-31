//! Floating boxes (docs/specs/showkeys.md): lines in a border at a corner
//! or the middle of an edge, over the windows and under popups.

mod common;

use common::*;
use imp_core::ClientMsg;

/// A 30 by 10 screen: one window of 8 rows and its status line, then the
/// message line.
fn screen() -> imp_server::Server {
    let mut s = server("one\ntwo\nthree\n");
    s.handle(ClientMsg::Resize {
        width: 30,
        height: 10,
    });
    s
}

fn rows(s: &mut imp_server::Server) -> Vec<String> {
    s.frame().text_rows()
}

/// Shows box `name` with `text` at `position`.
fn show(s: &mut imp_server::Server, name: &str, text: &str, position: &str) {
    s.eval(&format!(
        "(float-show! {name:?} (list (list (list {text:?} \"\"))) '{position})"
    ))
    .unwrap();
}

#[test]
fn a_box_in_each_corner_and_edge() {
    let mut s = screen();
    show(&mut s, "a", "hi", "bottom-right");
    let r = rows(&mut s);
    // One cell in from the right (the rows aren't padded past the box);
    // ending above the status line (row 8).
    let pad = " ".repeat(22);
    assert_eq!(r[5], format!("~{pad}╭────╮"));
    assert_eq!(r[6], format!("~{pad}│ hi │"));
    assert_eq!(r[7], format!("~{pad}╰────╯"));
    assert!(
        r[8].contains("[No Name]") || !r[8].contains('╯'),
        "{:?}",
        r[8]
    );

    s.eval("(float-hide! \"a\")").unwrap();
    show(&mut s, "a", "hi", "top-left");
    let r = rows(&mut s);
    assert!(r[0].starts_with("o╭────╮"), "{:?}", r[0]);
    assert!(r[1].starts_with("t│ hi │"), "{:?}", r[1]);

    s.eval("(float-hide! \"a\")").unwrap();
    show(&mut s, "a", "hi", "bottom-center");
    let r = rows(&mut s);
    assert_eq!(&r[6], "~           │ hi │");
    s.eval("(float-hide! \"a\")").unwrap();
    assert!(!rows(&mut s).join("\n").contains('│'));
}

#[test]
fn a_name_is_replaced_and_boxes_stack() {
    let mut s = screen();
    show(&mut s, "a", "one", "top-right");
    show(&mut s, "a", "two", "top-right");
    let r = rows(&mut s);
    assert!(r[1].contains("│ two │"), "{:?}", r[1]);
    assert!(!r.join("\n").contains("one │"));
    // A second name at the same position goes below the first.
    show(&mut s, "b", "three", "top-right");
    let r = rows(&mut s);
    assert!(r[1].contains("│ two │"), "{:?}", r[1]);
    assert!(r[4].contains("│ three │"), "{:?}", r[4]);
}

#[test]
fn too_big_is_cut_and_a_bad_position_is_an_error() {
    let mut s = screen();
    let long = "x".repeat(60);
    show(&mut s, "a", &long, "top-left");
    let r = rows(&mut s);
    // 30 wide: one cell either side, so 28 with the border.
    assert_eq!(r[1].chars().filter(|c| *c == 'x').count(), 24, "{:?}", r[1]);
    assert!(r[1].starts_with("t│ x"), "{:?}", r[1]);
    assert!(r[1].ends_with("x │"), "{:?}", r[1]);
    let lines: Vec<String> = (0..20)
        .map(|i| format!("(list (list \"{i}\" \"\"))"))
        .collect();
    s.eval(&format!(
        "(float-show! \"a\" (list {}) 'top-left)",
        lines.join(" ")
    ))
    .unwrap();
    let r = rows(&mut s);
    // The window's 8 rows above its status line: 6 lines and the border.
    assert!(r[0].contains('╭') && r[7].contains('╰'), "{r:?}");
    assert!(!r[8].contains('│'), "{:?}", r[8]);
    assert!(s.eval("(float-show! \"a\" '() 'middle)").is_err());
}

#[test]
fn popups_are_drawn_over_it() {
    let mut s = screen();
    show(&mut s, "a", "under", "bottom-left");
    s.eval("(set-popup! (list (list (list \"over the box\" \"\"))))")
        .unwrap();
    let r = rows(&mut s);
    assert!(r.iter().any(|row| row.contains("over the box")), "{r:?}");
}
