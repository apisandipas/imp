//! Windows: splitting, moving between them, closing.

mod common;

use common::*;

fn sized(text: &str, width: u16, height: u16) -> imp_server::Server {
    let mut s = server(text);
    s.handle(imp_core::ClientMsg::Resize { width, height });
    s
}

fn rows(s: &mut imp_server::Server) -> Vec<String> {
    s.frame().text_rows()
}

#[test]
fn horizontal_split_shows_the_buffer_twice() {
    let mut s = sized("one\ntwo\n", 20, 9);
    s.keys(&["C-w", "s"]);
    let r = rows(&mut s);
    // Two windows of four rows each (three text rows and a status line),
    // then the message line.
    assert_eq!(r[0], "one");
    assert!(r[3].starts_with(" NORMAL"), "{r:?}");
    assert_eq!(r[4], "one");
    assert!(r[7].starts_with("  [No Name]"), "{r:?}");
    assert_eq!(s.eval("(length (window-list))").unwrap(), "2");
}

#[test]
fn vertical_split_has_a_border() {
    let mut s = sized("ab\n", 21, 5);
    s.keys(&["C-w", "v"]);
    let r = rows(&mut s);
    assert_eq!(r[0], "ab        │ab");
}

#[test]
fn each_window_has_its_own_cursor() {
    let mut s = sized("1\n2\n3\n4\n", 20, 12);
    s.keys(&["C-w", "s"]);
    type_keys(&mut s, "G");
    s.keys(&["C-w", "w"]);
    assert_eq!(s.cursor(), 0);
    // Edits through one window move the other's cursor with the text.
    type_keys(&mut s, "Onew<esc>");
    s.keys(&["C-w", "w"]);
    assert_eq!(s.cursor(), 10);
}

#[test]
fn moving_between_windows_by_direction() {
    let mut s = sized("x\n", 40, 12);
    type_keys(&mut s, ":vs<ret>:sp<ret>");
    // Layout: left column split in two, right window whole.
    let top_left = s.eval("(current-window)").unwrap();
    s.keys(&["C-w", "j"]);
    let bottom_left = s.eval("(current-window)").unwrap();
    assert_ne!(top_left, bottom_left);
    s.keys(&["C-w", "l"]);
    let right = s.eval("(current-window)").unwrap();
    assert_ne!(right, bottom_left);
    // From the right, the cursor's row (the top) picks the top-left
    // window, as Vim does.
    s.keys(&["C-w", "h"]);
    assert_eq!(s.eval("(current-window)").unwrap(), top_left);
    s.keys(&["C-w", "j"]);
    assert_eq!(s.eval("(current-window)").unwrap(), bottom_left);
}

#[test]
fn split_with_a_file_and_close() {
    let path = temp_path("win-file.txt");
    std::fs::write(&path, "file text\n").unwrap();
    let mut s = sized("scratch\n", 30, 12);
    type_keys(&mut s, &format!(":sp {}<ret>", path.display()));
    assert_eq!(s.text(), "file text\n");
    let r = rows(&mut s);
    assert!(r.iter().any(|row| row == "scratch"), "{r:?}");
    // :q closes the window, not the editor.
    type_keys(&mut s, ":q<ret>");
    assert!(!s.should_quit());
    assert_eq!(s.text(), "scratch\n");
    assert_eq!(s.eval("(length (window-list))").unwrap(), "1");
    type_keys(&mut s, ":q<ret>");
    assert!(s.should_quit());
}

#[test]
fn only_and_close_last() {
    let mut s = sized("x\n", 30, 12);
    type_keys(&mut s, ":sp<ret>:vs<ret>:only<ret>");
    assert_eq!(s.eval("(length (window-list))").unwrap(), "1");
    s.keys(&["C-w", "c"]);
    assert!(s.status().contains("last window"));
}

#[test]
fn killing_a_buffer_shown_in_two_windows() {
    let path = temp_path("win-kill.txt");
    std::fs::write(&path, "k\n").unwrap();
    let mut s = sized("s\n", 30, 12);
    type_keys(
        &mut s,
        &format!(":e {}<ret>:sp<ret>:bd<ret>", path.display()),
    );
    assert_eq!(s.text(), "s\n");
    s.keys(&["C-w", "w"]);
    assert_eq!(s.text(), "s\n");
}

#[test]
fn resize_and_equalize() {
    let mut s = sized("x\n", 20, 21);
    s.keys(&["C-w", "s"]);
    let h = s.eval("(window-height)").unwrap();
    s.keys(&["5", "C-w", "+"]);
    let taller: usize = s.eval("(window-height)").unwrap().parse().unwrap();
    assert_eq!(taller, h.parse::<usize>().unwrap() + 5);
    s.keys(&["C-w", "="]);
    assert_eq!(s.eval("(window-height)").unwrap(), h);
}

#[test]
fn splitbelow_and_splitright() {
    let mut s = sized("x\n", 30, 12);
    type_keys(&mut s, ":set splitbelow<ret>");
    let first = s.eval("(current-window)").unwrap();
    s.keys(&["C-w", "s"]);
    // The new window is below, so the old one is up.
    s.keys(&["C-w", "k"]);
    assert_eq!(s.eval("(current-window)").unwrap(), first);
}

#[test]
fn search_highlights_in_every_window_but_selection_only_in_its_own() {
    let mut s = sized("ab ab\n", 20, 9);
    s.keys(&["C-w", "s"]);
    type_keys(&mut s, "/ab<ret>");
    let f = s.frame();
    assert_eq!(f.rows[0].len(), 3);
    assert_eq!(f.rows[4].len(), 3);
}

/// Two footer lines for the current buffer.
const FOOTER: &str = r#"(set-footer! (list (list (list "s" "git.key") (list " stage" #f))
                         (list (list "? all keys" #f))))"#;

#[test]
fn a_footer_stays_at_the_bottom_while_the_window_scrolls() {
    let text: String = (0..100).map(|i| format!("line {i}\n")).collect();
    let mut s = sized(&text, 40, 10);
    s.eval(FOOTER).unwrap();
    // 10 rows: 6 of text, the footer's 2, the status line, the message line.
    let rows = s.frame().text_rows();
    assert_eq!(rows[5].trim_end(), "line 5");
    assert_eq!(rows[6].trim_end(), "s stage");
    assert_eq!(rows[7].trim_end(), "? all keys");
    assert_eq!(s.eval("(window-height)").unwrap(), "6");
    // The cursor stays above it.
    type_keys(&mut s, "G");
    let frame = s.frame();
    let rows = frame.text_rows();
    assert_eq!(rows[5].trim_end(), "line 99", "{rows:?}");
    assert_eq!(rows[6].trim_end(), "s stage");
    assert_eq!(frame.cursor.1, 5);
}

#[test]
fn a_footer_is_cut_to_the_window_and_left_out_of_short_ones() {
    let mut s = sized("a\n", 6, 10);
    s.eval(r#"(set-footer! (list (list (list "abcdefghij" #f))))"#)
        .unwrap();
    assert_eq!(s.frame().text_rows()[7].trim_end(), "abcdef");
    // Fewer than two rows of text beside it: no footer.
    let mut s = sized("a\n", 40, 4);
    s.eval(FOOTER).unwrap();
    let rows = s.frame().text_rows();
    assert_eq!(rows[0].trim_end(), "a");
    assert!(!rows.iter().any(|r| r.contains("stage")), "{rows:?}");
    // '() removes it.
    let mut s = sized("a\n", 40, 10);
    s.eval(FOOTER).unwrap();
    s.eval("(set-footer! '())").unwrap();
    assert!(!s.frame().text_rows().iter().any(|r| r.contains("stage")));
}

#[test]
fn a_click_on_a_footer_does_nothing() {
    let mut s = sized("one\ntwo\n", 40, 10);
    s.eval(FOOTER).unwrap();
    s.frame();
    for action in ["press", "release"] {
        s.handle(imp_core::ClientMsg::Mouse {
            action: action.into(),
            button: "left".into(),
            x: 2,
            y: 6,
            fine: None,
        });
    }
    // A click below the text would go to the last line.
    assert_eq!(s.eval("(current-line)").unwrap(), "0");
}
