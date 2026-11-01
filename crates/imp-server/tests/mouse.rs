//! The mouse (runtime/mouse.scm): clicks move the cursor, drags select,
//! the wheel scrolls. The screen is 80x24.

mod common;

use common::*;
use imp_core::ClientMsg;

fn mouse(s: &mut imp_server::Server, action: &str, x: u16, y: u16) {
    s.frame(); // positions are worked out from the last frame drawn
    let button = if action.starts_with("scroll") {
        ""
    } else {
        "left"
    };
    s.handle(ClientMsg::Mouse {
        action: action.into(),
        button: button.into(),
        x,
        y,
        fine: None,
    });
    assert!(!s.status().starts_with("error"), "{}", s.status());
}

fn click(s: &mut imp_server::Server, x: u16, y: u16) {
    mouse(s, "press", x, y);
    mouse(s, "release", x, y);
}

#[test]
fn a_click_moves_the_cursor() {
    let mut s = server("hello world\nsecond line\n");
    click(&mut s, 6, 0);
    assert_eq!(s.cursor(), 6);
    // Past the end of a line, normal mode stops on its last char.
    click(&mut s, 50, 1);
    assert_eq!(s.cursor(), 22);
    // Below the text: the last line.
    click(&mut s, 0, 10);
    assert_eq!(s.eval("(current-line)").unwrap(), "1");
}

#[test]
fn clicks_count_a_control_char_as_its_caret_notation() {
    // "a^[bc": the ESC takes cells 1 and 2.
    let mut s = server("a\x1bbc\n");
    click(&mut s, 2, 0);
    assert_eq!(s.cursor(), 1);
    click(&mut s, 3, 0);
    assert_eq!(s.cursor(), 2);
}

#[test]
fn insert_mode_stays_in_insert_mode() {
    let mut s = server("hello world\nsecond line\n");
    type_keys(&mut s, "i");
    click(&mut s, 50, 1);
    assert_eq!(s.cursor(), 23);
    type_keys(&mut s, "!<esc>");
    assert_eq!(s.text(), "hello world\nsecond line!\n");
}

#[test]
fn a_click_ends_visual_mode_and_pending_commands() {
    let mut s = server("hello world\n");
    type_keys(&mut s, "vl");
    click(&mut s, 8, 0);
    assert_eq!(s.eval("*mode*").unwrap(), "normal");
    type_keys(&mut s, "d");
    click(&mut s, 0, 0);
    type_keys(&mut s, "x");
    assert_eq!(s.text(), "ello world\n");
}

#[test]
fn dragging_selects() {
    let mut s = server("hello world\n");
    mouse(&mut s, "press", 0, 0);
    mouse(&mut s, "drag", 2, 0);
    mouse(&mut s, "drag", 4, 0);
    mouse(&mut s, "release", 4, 0);
    assert_eq!(s.eval("*mode*").unwrap(), "visual");
    type_keys(&mut s, "d");
    assert_eq!(s.text(), " world\n");
}

#[test]
fn the_wheel_scrolls_without_moving_the_cursor() {
    let text: String = (0..100).map(|i| format!("line {i}\n")).collect();
    let mut s = server(&text);
    type_keys(&mut s, "5G");
    mouse(&mut s, "scroll-down", 0, 0);
    assert_eq!(s.eval("(window-top)").unwrap(), "3");
    assert_eq!(s.eval("(current-line)").unwrap(), "4");
    // Once the cursor's line leaves the window, it follows.
    mouse(&mut s, "scroll-down", 0, 0);
    mouse(&mut s, "scroll-down", 0, 0);
    assert_eq!(s.eval("(current-line)").unwrap(), "9");
    mouse(&mut s, "scroll-up", 0, 0);
    assert_eq!(s.eval("(window-top)").unwrap(), "6");
}

#[test]
fn a_click_on_text_runs_the_mouse_click_hook() {
    let mut s = server("hello world\nsecond line\n");
    s.eval("(define clicks '()) (add-hook! 'mouse-click (lambda (at) (set! clicks (cons (list at (cursor)) clicks))))")
        .unwrap();
    // It runs once the cursor has moved, with the offset clicked, before
    // normal mode keeps the cursor off the line's end.
    click(&mut s, 6, 1);
    assert_eq!(s.eval("clicks").unwrap(), "((18 18))");
    click(&mut s, 50, 1);
    assert_eq!(s.eval("(car clicks)").unwrap(), "(23 22)");
    // A click on the status line (row 22) only focuses the window.
    click(&mut s, 6, 22);
    assert_eq!(s.eval("(length clicks)").unwrap(), "2");
}

#[test]
fn a_click_in_another_window_focuses_it() {
    let mut s = server("left text\n");
    type_keys(&mut s, ":vnew<ret>iright<esc>");
    let right = s.eval("(current-window)").unwrap();
    // :vnew puts the new window on the left; the original is on the right.
    click(&mut s, 45, 0);
    assert_ne!(s.eval("(current-window)").unwrap(), right);
    assert_eq!(s.eval("(buffer-substring 0 4)").unwrap(), "\"left\"");
    assert_eq!(s.cursor(), 45 - 40);
}

#[test]
fn clicks_account_for_the_gutter_and_wrapped_lines() {
    let long = "x".repeat(100);
    let mut s = server(&format!("{long}\nshort\n"));
    // The 100-char line takes two rows; row 1 starts at char 80.
    click(&mut s, 5, 1);
    assert_eq!(s.cursor(), 85);
    click(&mut s, 2, 2);
    assert_eq!(s.cursor(), 103);
    type_keys(&mut s, ":set nu<ret>");
    // The gutter is four cells; the text width is 76.
    click(&mut s, 6, 0);
    assert_eq!(s.cursor(), 2);
    click(&mut s, 4, 1);
    assert_eq!(s.cursor(), 76);
}

#[test]
fn nomouse_ignores_it() {
    let mut s = server("hello world\n");
    type_keys(&mut s, ":set nomouse<ret>");
    click(&mut s, 6, 0);
    assert_eq!(s.cursor(), 0);
}

#[test]
fn dragging_the_border_between_windows_resizes_them() {
    let mut s = server("ab\n");
    s.handle(ClientMsg::Resize {
        width: 21,
        height: 6,
    });
    s.keys(&["C-w", "v"]);
    mouse(&mut s, "press", 10, 1);
    mouse(&mut s, "drag", 14, 1);
    mouse(&mut s, "release", 14, 1);
    assert_eq!(s.frame().text_rows()[0], "ab            │ab");
    // The window there didn't take the click.
    assert_eq!(s.eval("(current-col)").unwrap(), "0");
}

#[test]
fn dragging_a_status_line_resizes_the_windows_above_and_below() {
    let mut s = server("ab\n");
    s.handle(ClientMsg::Resize {
        width: 20,
        height: 11,
    });
    s.keys(&["C-w", "s"]);
    // Two windows of five rows; the first's status line is row 4.
    mouse(&mut s, "press", 3, 4);
    mouse(&mut s, "drag", 3, 2);
    mouse(&mut s, "release", 3, 2);
    let r = s.frame().text_rows();
    assert!(r[2].starts_with(" NORMAL"), "{r:?}");
}

#[test]
fn window_divider_width_is_in_the_clients_pixels() {
    let mut s = server("ab\n");
    s.handle(ClientMsg::Resize {
        width: 23,
        height: 6,
    });
    // Cells 10 pixels wide: a 30 pixel divider is three columns.
    s.handle(ClientMsg::Cell { width: 1000 });
    s.eval("(set-option! 'window-divider-width 30)").unwrap();
    s.keys(&["C-w", "v"]);
    assert_eq!(s.frame().text_rows()[0], "ab         │ ab");
    // Grabbed anywhere in it.
    mouse(&mut s, "press", 12, 1);
    mouse(&mut s, "drag", 8, 1);
    assert_eq!(s.frame().text_rows()[0], "ab     │ ab");
    // A terminal (no cell width) gets one column.
    s.set_cell_width(0);
    assert_eq!(s.frame().text_rows()[0], "ab    │ab");
}

#[test]
fn a_click_waits_for_the_leader_and_closes_a_popup() {
    let mut s = server("hello world\n");
    s.eval("(set-option! 'which-key-delay 0)").unwrap();
    // The leader takes keys and doesn't close on a click: the click is
    // ignored.
    type_keys(&mut s, " ");
    click(&mut s, 6, 0);
    assert_eq!(s.cursor(), 0);
    assert_eq!(s.eval("(overlay-open? 'leader)").unwrap(), "#true");
    type_keys(&mut s, "<esc>");
    // A popup closes on a click, and the click moves the cursor.
    s.eval("(show-popup! (list (list (list \"output\" \"\"))))")
        .unwrap();
    click(&mut s, 6, 0);
    assert_eq!(s.eval("(overlay-open?)").unwrap(), "#false");
    assert_eq!(s.cursor(), 6);
}
