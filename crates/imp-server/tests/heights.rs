//! Text heights (org headings) for clients that draw them: each window
//! comes as a block of rows, each as tall as its tallest text.

mod common;

use common::*;
use imp_core::{Frame, WindowBlock};

/// An org buffer of `text` for a client that draws heights, 40x12.
fn setup(text: &str) -> imp_server::Server {
    let mut s = server(text);
    s.set_size(40, 12);
    s.set_heights(true);
    s.eval("(set-major-mode! 'org-mode)").unwrap();
    s
}

fn block(frame: &Frame, i: usize) -> &WindowBlock {
    &frame.windows[i]
}

/// Each row's text and height.
fn rows(b: &WindowBlock) -> Vec<(String, u16)> {
    b.rows
        .iter()
        .map(|r| {
            (
                r.spans
                    .iter()
                    .map(|s| s.text.as_str())
                    .collect::<String>()
                    .trim_end()
                    .to_string(),
                r.height,
            )
        })
        .collect()
}

#[test]
fn headings_are_taller_and_the_window_holds_less() {
    let mut text = String::from("* Heading one\n");
    for i in 0..20 {
        text.push_str(&format!("line {i}\n"));
    }
    let mut s = setup(&text);
    let f = s.frame();
    let b = block(&f, 0);
    // The window's text area: all but the status line, rows left blank.
    assert_eq!((b.x, b.y, b.w, b.h), (0, 0, 40, 10));
    assert!(f.text_rows()[..10].iter().all(|r| r.trim().is_empty()));
    let r = rows(b);
    assert_eq!(r[0], ("* Heading one".into(), 140));
    assert_eq!(r[1], ("line 0".into(), 100));
    // 1.4 + 8 rows fit in 10; a ninth plain one would not.
    assert_eq!(r.len(), 9);
    let total: u32 = b.rows.iter().map(|r| r.height as u32).sum();
    assert!(total <= 1000, "{total}");
    assert_eq!(b.cursor, Some((0, 0)));
    // The status line is in the screen's rows as before.
    assert!(!f.text_rows()[10].trim().is_empty(), "{:?}", f.text_rows());
}

#[test]
fn a_taller_line_has_fewer_cells_across() {
    let long = "x".repeat(60);
    let mut s = setup(&format!("* {long}\n"));
    s.eval("(set-option! 'wrap #f)").unwrap();
    let f = s.frame();
    let r = rows(block(&f, 0));
    // 40 cells of the font hold 28 at 1.4 times its size.
    assert_eq!(r[0].0.chars().count(), 28);
    // With wrap, the rest goes to a second row as tall.
    s.eval("(set-option! 'wrap #t)").unwrap();
    let f = s.frame();
    let r = rows(block(&f, 0));
    assert_eq!(
        r[..3].iter().map(|r| r.1).collect::<Vec<_>>(),
        [140, 140, 140]
    );
    assert_eq!(
        r[..3].iter().map(|r| r.0.chars().count()).sum::<usize>(),
        62
    );
}

#[test]
fn the_cursor_stays_in_view_past_headings() {
    let mut text = String::new();
    for i in 0..30 {
        text.push_str(&format!("* Heading {i}\n"));
    }
    let mut s = setup(&text);
    // Seven 1.4-row headings fit in 10 rows.
    assert_eq!(rows(block(&s.frame(), 0)).len(), 7);
    type_keys(&mut s, "10j");
    let f = s.frame();
    let b = block(&f, 0);
    let r = rows(b);
    // The cursor's heading is the last one shown, and on screen.
    assert_eq!(r.last().unwrap().0, "* Heading 10");
    assert_eq!(b.cursor.map(|c| c.0 as usize), Some(r.len() - 1));
    // The screen's cursor is on the cell its row ends in, inside the window.
    assert!(f.cursor.1 < 10, "{:?}", f.cursor);
    type_keys(&mut s, "G");
    let f = s.frame();
    let r = rows(block(&f, 0));
    assert_eq!(r.last().unwrap().0, "* Heading 29");
}

#[test]
fn a_window_beside_it_keeps_its_rows() {
    let mut s = setup("* Big\nplain\n");
    s.set_size(81, 12);
    // Beside it, a new buffer (not org) with the same text.
    type_keys(&mut s, ":vsplit<ret>:enew<ret>i* Big<ret>plain<esc>");
    let f = s.frame();
    assert_eq!(f.windows.len(), 2);
    // The org window shows the heading at its height; the other one at
    // one row, each in its own rectangle.
    let heights: Vec<Vec<u16>> = f
        .windows
        .iter()
        .map(|b| b.rows.iter().take(2).map(|r| r.height).collect())
        .collect();
    assert!(heights.contains(&vec![100, 100]), "{heights:?}");
    assert!(heights.contains(&vec![140, 100]), "{heights:?}");
    assert_ne!(f.windows[0].x, f.windows[1].x);
    // Only the focused window has the cursor.
    assert_eq!(f.windows.iter().filter(|b| b.cursor.is_some()).count(), 1);
}

#[test]
fn a_client_that_draws_one_size_gets_rows_as_before() {
    let mut s = setup("* Big\nplain\n");
    s.set_heights(false);
    let f = s.frame();
    assert!(f.windows.is_empty());
    assert_eq!(f.text_rows()[0].trim_end(), "* Big");
    assert_eq!(f.rows[0][0].style.height, 0);
    // The command line takes the cursor from the window.
    s.set_heights(true);
    type_keys(&mut s, ":");
    assert_eq!(s.frame().windows[0].cursor, None);
}
