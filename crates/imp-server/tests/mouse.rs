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
