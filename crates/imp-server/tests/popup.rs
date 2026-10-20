//! Popup rules (runtime/special.scm): where generated buffers open.

mod common;

use common::*;

fn windows(s: &mut imp_server::Server) -> usize {
    s.eval("(length (window-list))").unwrap().parse().unwrap()
}

fn buffer_name(s: &mut imp_server::Server) -> String {
    s.eval("(buffer-name-of (current-buffer))")
        .unwrap()
        .trim_matches('"')
        .to_string()
}

/// A special buffer `name`, shown with display-buffer!.
fn display(s: &mut imp_server::Server, name: &str) {
    s.eval(&format!(
        "(display-buffer! (special-buffer {name:?} 'special-mode))"
    ))
    .unwrap();
}

#[test]
fn a_rule_opens_the_buffer_beside_and_q_closes_it() {
    let mut s = server("text\n");
    s.set_size(101, 30);
    s.eval(r#"(define-popup-rule! "*thing" 'side 'right 'size 0.25)"#)
        .unwrap();
    display(&mut s, "*thing*");
    assert_eq!(windows(&mut s), 2);
    assert_eq!(buffer_name(&mut s), "*thing*");
    // A quarter of the 100 columns left after the border.
    let rows = s.frame().text_rows();
    assert_eq!(rows[0].chars().nth(75), Some('│'), "{rows:?}");
    // Shown again, the same window.
    s.eval("(go-to-window! (car (window-list)))").unwrap();
    display(&mut s, "*thing*");
    assert_eq!(windows(&mut s), 2);
    assert_eq!(buffer_name(&mut s), "*thing*");
    type_keys(&mut s, "q");
    assert_eq!(windows(&mut s), 1);
    assert_eq!(s.text(), "text\n");
}

#[test]
fn without_a_rule_the_buffer_takes_the_window() {
    let mut s = server("text\n");
    display(&mut s, "*other*");
    assert_eq!(windows(&mut s), 1);
    assert_eq!(buffer_name(&mut s), "*other*");
    type_keys(&mut s, "q");
    assert_eq!(s.text(), "text\n");
}

#[test]
fn a_popup_opened_from_a_popup_stays_in_its_window() {
    let mut s = server("text\n");
    s.eval(r#"(define-popup-rule! "*p" 'side 'bottom)"#)
        .unwrap();
    display(&mut s, "*p one*");
    display(&mut s, "*p two*");
    assert_eq!(windows(&mut s), 2);
    // q goes back to the first, then closes the window.
    type_keys(&mut s, "q");
    assert_eq!(buffer_name(&mut s), "*p one*");
    assert_eq!(windows(&mut s), 2);
    type_keys(&mut s, "q");
    assert_eq!(windows(&mut s), 1);
    assert_eq!(s.text(), "text\n");
}

#[test]
fn select_off_leaves_the_cursor_where_it_was_and_quit_off_keeps_the_window() {
    let mut s = server("text\n");
    s.eval(r#"(define-popup-rule! "*log" 'select #f 'quit #f)"#)
        .unwrap();
    display(&mut s, "*log*");
    assert_eq!(windows(&mut s), 2);
    assert_eq!(s.text(), "text\n");
    s.eval("(go-to-window! (cadr (window-list)))").unwrap();
    assert_eq!(buffer_name(&mut s), "*log*");
    // q goes back to the buffer before it, in the same window.
    type_keys(&mut s, "q");
    assert_eq!(windows(&mut s), 2);
    assert_eq!(s.text(), "text\n");
}

#[test]
fn a_file_opened_from_a_popup_opens_in_the_window_it_came_from() {
    let path = temp_path("popup-target.txt");
    std::fs::write(&path, "target\n").unwrap();
    let mut s = server("text\n");
    display(&mut s, "*grep*");
    assert_eq!(windows(&mut s), 2);
    let popup = s.eval("(current-window)").unwrap();
    type_keys(&mut s, &format!(":e {}<ret>", path.display()));
    assert_eq!(s.text(), "target\n");
    assert_ne!(s.eval("(current-window)").unwrap(), popup);
    // The popup is still there.
    assert_eq!(
        s.eval(&format!("(buffer-name-of (window-buffer {popup}))"))
            .unwrap(),
        "\"*grep*\""
    );
}

#[test]
fn removing_a_rule() {
    let mut s = server("text\n");
    s.eval(r#"(remove-popup-rule! "*grep*")"#).unwrap();
    display(&mut s, "*grep*");
    assert_eq!(windows(&mut s), 1);
}
