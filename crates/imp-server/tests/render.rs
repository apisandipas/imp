//! What the client is sent: rows of styled spans.

use imp_core::{Buffer, Color, Span, Style};
use imp_server::{Options, Server};

/// A server without the theme's background or the default status line
/// format and faces, so rows hold just what each test draws.
fn server(text: &str) -> Server {
    let mut s =
        Server::new(Buffer::from_text(text), Options { user_config: None }).expect("runtime loads");
    s.eval(r#"(set-face! "normal" "") (set-statusline! "" "")"#)
        .unwrap();
    s
}

#[test]
fn rows_show_text_and_tildes() {
    let mut s = server("one\n\ttwo\n");
    s.handle(imp_core::ClientMsg::Resize {
        width: 20,
        height: 5,
    });
    let rows = s.frame().text_rows();
    assert_eq!(rows[0], "one");
    assert_eq!(rows[1], "    two");
    assert_eq!(rows[2], "~");
    // The window's status line, then the message line.
    assert!(rows[3].starts_with(" NORMAL"), "{:?}", rows[3]);
    assert_eq!(rows[4], "");
}

#[test]
fn highlights_split_rows_into_spans() {
    let mut s = server("hello world\n");
    s.eval(r#"(set-face! "test" "fg=red bold") (highlight-add! "search" 6 11 "test")"#)
        .unwrap();
    let row = &s.frame().rows[0];
    let red = Style {
        fg: Some(Color::Indexed(1)),
        bold: true,
        ..Style::default()
    };
    assert_eq!(
        row,
        &vec![
            Span::new("hello ", Style::default()),
            Span::new("world", red)
        ]
    );
}

#[test]
fn later_layers_draw_over_earlier_ones() {
    let mut s = server("abcd\n");
    s.eval(
        r#"(set-face! "a" "fg=red") (set-face! "b" "bg=blue")
           (highlight-add! "visual" 0 2 "b") (highlight-add! "search" 0 4 "a")"#,
    )
    .unwrap();
    let row = &s.frame().rows[0];
    assert_eq!(row.len(), 2);
    // visual (bg) is declared after search in core.scm, so both apply.
    assert_eq!(row[0].style.bg, Some(Color::Indexed(4)));
    assert_eq!(row[0].style.fg, Some(Color::Indexed(1)));
    assert_eq!(row[1].style.bg, None);
}

#[test]
fn bad_face_spec_is_an_error() {
    let mut s = server("");
    assert!(s.eval(r#"(set-face! "x" "fg=nope")"#).is_err());
}

fn sized(text: &str, width: u16, height: u16) -> Server {
    let mut s = server(text);
    s.handle(imp_core::ClientMsg::Resize { width, height });
    s
}

#[test]
fn line_numbers() {
    let mut s = sized("a\nb\nc\n", 20, 5);
    s.eval("(set-option! 'number #t)").unwrap();
    let f = s.frame();
    assert_eq!(f.text_rows()[0], "  1 a");
    assert_eq!(f.text_rows()[2], "  3 c");
    assert_eq!(f.cursor, (4, 0));
    s.eval("(set-option! 'relativenumber #t)").unwrap();
    s.keys(&["j"]);
    let rows = s.frame().text_rows();
    assert_eq!(rows[0], "  1 a");
    assert_eq!(rows[1], "2   b");
    s.eval("(set-option! 'number #f)").unwrap();
    assert_eq!(s.frame().text_rows()[1], "  0 b");
}

#[test]
fn long_lines_scroll_sideways() {
    let mut s = sized("0123456789abcdefghij\nxy\n", 10, 4);
    s.eval("(set-option! 'wrap #f)").unwrap();
    s.keys(&["$"]);
    let f = s.frame();
    // The cursor's end of the line is in view, and the cursor is drawn.
    assert_eq!(f.text_rows()[0], "abcdefghij");
    assert_eq!(f.cursor, (9, 0));
    // Other lines scroll with it.
    assert_eq!(f.text_rows()[1], "");
    s.keys(&["0"]);
    assert_eq!(s.frame().text_rows()[0], "0123456789");
}

#[test]
fn tabs_count_display_columns() {
    let mut s = sized("\tx\n", 20, 4);
    s.eval("(set-option! 'tabstop 4)").unwrap();
    s.keys(&["l"]);
    let f = s.frame();
    assert_eq!(f.text_rows()[0], "    x");
    assert_eq!(f.cursor, (4, 0));
}

#[test]
fn cursorline_fills_the_row() {
    let mut s = sized("ab\ncd\n", 10, 4);
    s.eval("(set-option! 'cursorline #t)").unwrap();
    let row = &s.frame().rows[0];
    let text: String = row.iter().map(|sp| sp.text.as_str()).collect();
    assert_eq!(text, "ab        ");
    assert!(row.iter().all(|sp| sp.style.bg.is_some()));
    assert_eq!(s.frame().rows[1].len(), 1);
}

#[test]
fn long_lines_wrap() {
    let mut s = sized("0123456789abcdef\nnext\n", 10, 6);
    let f = s.frame();
    assert_eq!(f.text_rows()[0], "0123456789");
    assert_eq!(f.text_rows()[1], "abcdef");
    assert_eq!(f.text_rows()[2], "next");
    s.keys(&["$"]);
    assert_eq!(s.frame().cursor, (5, 1));
    // With numbers, continuation rows get an empty gutter.
    s.eval("(set-option! 'number #t)").unwrap();
    let rows = s.frame().text_rows();
    assert_eq!(rows[0], "  1 012345");
    assert_eq!(rows[1], "    6789ab");
}

#[test]
fn wrapped_lines_scroll_by_whole_lines() {
    let text = format!("{}\n{}\nend\n", "a".repeat(25), "b".repeat(25));
    let mut s = sized(&text, 10, 5);
    // Three text rows: the first line alone takes all three.
    s.keys(&["j"]);
    let rows = s.frame().text_rows();
    assert_eq!(rows[0], "bbbbbbbbbb");
    s.keys(&["j"]);
    assert_eq!(s.frame().text_rows()[0], "end");
}

#[test]
fn wide_chars_take_two_cells() {
    let mut s = sized("日本語x\n", 20, 4);
    s.keys(&["l", "l"]);
    let f = s.frame();
    assert_eq!(f.text_rows()[0], "日本語x");
    assert_eq!(f.cursor, (4, 0));
    s.keys(&["l"]);
    assert_eq!(s.frame().cursor, (6, 0));
}

#[test]
fn wide_chars_wrap_whole() {
    let mut s = sized("aaaa日\n", 5, 5);
    let rows = s.frame().text_rows();
    assert_eq!(rows[0], "aaaa");
    assert_eq!(rows[1], "日");
}

#[test]
fn gj_and_gk_move_by_screen_rows() {
    let mut s = sized("0123456789abcdefghij12\nxyz\n", 10, 8);
    s.keys(&["l", "l", "g", "j"]);
    assert_eq!(s.cursor(), 12);
    // The last row is "12": column 2 is past its end, so the cursor
    // lands on its last char, but keeps wanting column 2.
    s.keys(&["g", "j"]);
    assert_eq!(s.cursor(), 21);
    s.keys(&["g", "j"]);
    assert_eq!(s.cursor(), 25);
    s.keys(&["g", "k"]);
    assert_eq!(s.cursor(), 21);
    s.keys(&["g", "k", "g", "k"]);
    assert_eq!(s.cursor(), 2);
}

#[test]
fn narrow_status_lines_keep_the_position() {
    let mut s = sized("x\n", 16, 4);
    s.eval("(set-buffer-name! \"a-very-long-buffer-name\")")
        .unwrap();
    let rows = s.frame().text_rows();
    assert_eq!(rows[2].chars().count(), 16);
    assert!(rows[2].ends_with("1:1 "), "{:?}", rows[2]);
}

#[test]
fn jumping_far_with_wrap_is_quick() {
    // Scrolling used to step one line at a time and re-measure everything
    // above the cursor each step: quadratic in the jump.
    let text: String = (0..200_000).map(|i| format!("line {i}\n")).collect();
    let mut s = sized(&text, 40, 10);
    s.frame();
    let t = std::time::Instant::now();
    s.keys(&["G"]);
    let rows = s.frame().text_rows();
    assert!(
        t.elapsed() < std::time::Duration::from_secs(2),
        "{:?}",
        t.elapsed()
    );
    assert_eq!(rows[7], "line 199999");
}
