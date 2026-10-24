//! Vim's :map family (runtime/map.scm).

mod common;

use common::*;

#[test]
fn vim_key_notation() {
    let mut s = server("");
    let keys =
        |s: &mut imp_server::Server, text: &str| s.eval(&format!("(vim-keys {text:?})")).unwrap();
    assert_eq!(
        keys(&mut s, "<C-w>j:w<CR>"),
        r#"("C-w" "j" ":" "w" "<ret>")"#
    );
    // Names are case-insensitive; <C-X> is <C-x>.
    assert_eq!(
        keys(&mut s, "<esc><Esc><TAB><c-X><M-x><Space><Leader>"),
        r#"("<esc>" "<esc>" "<tab>" "C-x" "M-x" " " " ")"#
    );
    assert_eq!(
        keys(&mut s, "<lt>a<Bar><BS><F5><Up>"),
        r#"("<" "a" "|" "<bs>" "<f5>" "<up>")"#
    );
    // Not a key name: typed as it is.
    assert_eq!(keys(&mut s, "<foo>"), r#"("<" "f" "o" "o" ">")"#);
    assert_eq!(keys(&mut s, "a<b"), r#"("a" "<" "b")"#);
}
