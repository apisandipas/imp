//! What the client is sent: rows of styled spans.

use imp_core::{Buffer, Color, Span, Style};
use imp_server::{Options, Server};

fn server(text: &str) -> Server {
    Server::new(Buffer::from_text(text), Options { user_config: None }).expect("runtime loads")
}

#[test]
fn rows_show_text_and_tildes() {
    let mut s = server("one\n\ttwo\n");
    s.handle(imp_core::ClientMsg::Resize {
        width: 20,
        height: 4,
    });
    let rows = s.frame().text_rows();
    assert_eq!(rows[0], "one");
    assert_eq!(rows[1], "    two");
    assert_eq!(rows[2], "~");
    assert!(rows[3].starts_with(" NORMAL"));
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
