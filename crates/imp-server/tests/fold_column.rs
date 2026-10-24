//! The fold column: a chevron on each fold's first line, between the
//! line numbers and the text.

mod common;

use common::*;

const CODE: &str = "fn a\n    one\n    if x\n        two\nfn b\n    three\n";

fn rows(s: &mut imp_server::Server) -> Vec<String> {
    s.frame()
        .text_rows()
        .iter()
        .map(|r| r.trim_end().to_string())
        .collect()
}

fn indented(text: &str) -> imp_server::Server {
    let mut s = server(text);
    s.eval("(set-option! 'shiftwidth 4)").unwrap();
    type_keys(&mut s, ":setlocal fdm=indent<ret>");
    s
}

#[test]
fn chevrons_mark_open_and_closed_folds() {
    let mut s = indented(CODE);
    assert_eq!(
        rows(&mut s)[..6],
        [
            "▾ fn a",
            "      one",
            "▾     if x",
            "          two",
            "▾ fn b",
            "      three"
        ]
    );
    type_keys(&mut s, "Gzc");
    assert_eq!(rows(&mut s)[4], "▸ fn b ··· 2 lines");
}

#[test]
fn it_sits_between_the_numbers_and_the_text() {
    let mut s = indented(CODE);
    type_keys(&mut s, ":set nu<ret>");
    let r = rows(&mut s);
    assert_eq!(r[0], "  1 ▾ fn a");
    assert_eq!(r[1], "  2       one");
}

#[test]
fn a_line_shows_its_outermost_fold() {
    let mut s = server("a\nb\nc\nd\n");
    // An open fold over all four lines, and a closed one inside it from
    // the same line (zf makes a closed fold).
    type_keys(&mut s, "zf3jzozfj");
    assert_eq!(rows(&mut s)[0], "▾ a ··· 2 lines");
}

#[test]
fn a_wrapped_line_has_it_on_its_first_row() {
    let mut s = server(&format!("{}\n    b\n", "x".repeat(150)));
    s.eval("(set-option! 'shiftwidth 4)").unwrap();
    type_keys(&mut s, ":set wrap<ret>:setlocal fdm=indent<ret>");
    let r = rows(&mut s);
    assert!(r[0].starts_with("▾ x"), "{r:?}");
    assert!(r[1].starts_with("  x"), "{r:?}");
}

#[test]
fn foldcolumn_says_when_it_shows() {
    // auto: only while the buffer has a fold.
    let mut s = server("a\nb\n");
    assert_eq!(rows(&mut s)[0], "a");
    type_keys(&mut s, ":setlocal fdc=yes<ret>");
    assert_eq!(rows(&mut s)[0], "  a");
    let mut s = indented(CODE);
    type_keys(&mut s, ":setlocal foldcolumn=no<ret>");
    assert_eq!(rows(&mut s)[0], "fn a");
}
