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

#[test]
fn nnoremap_wins_over_vim_keys() {
    let mut s = server("one\ntwo\nthree\n");
    type_keys(&mut s, ":nnoremap j k<ret>:nnoremap k j<ret>");
    // Swapped: noremap {rhs} runs Vim's own j and k.
    type_keys(&mut s, "k");
    assert_eq!(s.cursor(), 4);
    type_keys(&mut s, "j");
    assert_eq!(s.cursor(), 0);
    // A count applies to the {rhs}.
    type_keys(&mut s, "2k");
    assert_eq!(s.cursor(), 8);
}

#[test]
fn map_uses_other_mappings_and_stops_recursion() {
    let mut s = server("abc\n");
    type_keys(&mut s, ":nmap Q x<ret>:nmap gq Q<ret>");
    type_keys(&mut s, "gq");
    assert_eq!(s.text(), "bc\n");
    // noremap doesn't see the mapping: gQ runs Vim's own Q, which does
    // nothing here.
    type_keys(&mut s, ":nnoremap gQ Q<ret>gQ");
    assert_eq!(s.text(), "bc\n");
    // A mapping that maps itself stops with an error.
    feed(&mut s, ":nmap gr gr<ret>gr");
    assert!(s.status().contains("recursive mapping"), "{}", s.status());
    type_keys(&mut s, "x");
    assert_eq!(s.text(), "c\n");
}

#[test]
fn rhs_can_be_an_ex_command() {
    let mut s = server("a\nb\n");
    type_keys(&mut s, ":nnoremap gb :2<CR>dd<ret>gb");
    assert_eq!(s.text(), "a\n");
}

#[test]
fn visual_and_both_states() {
    let mut s = server("abc def\n");
    type_keys(&mut s, ":vnoremap Q U<ret>veQ");
    assert_eq!(s.text(), "ABC def\n");
    // :map covers normal and visual.
    type_keys(&mut s, "<esc>:noremap gk ~<ret>wgk");
    assert_eq!(s.text(), "ABC Def\n");
    type_keys(&mut s, "vlgk");
    assert_eq!(s.text(), "ABC DEF\n");
}

#[test]
fn leader_mappings_and_labels() {
    let mut s = server("abc\n");
    s.eval("(set-option! 'which-key-delay 0)").unwrap();
    type_keys(&mut s, ":nnoremap <Leader>zz x<ret>");
    type_keys(&mut s, " z");
    assert!(
        s.frame().text_rows().join("\n").contains("z → x"),
        "{}",
        s.frame().text_rows().join("\n")
    );
    type_keys(&mut s, "z");
    assert_eq!(s.text(), "bc\n");
    // Which-key shows a mapping's {rhs}. (type_keys reads <leader> as
    // one key, so tests write <Leader>.)
    type_keys(&mut s, ":nnoremap gb :ls<CR><ret>g");
    assert!(s.frame().text_rows().join("\n").contains("b → :ls<CR>"));
}

#[test]
fn lhs_rules() {
    let mut s = server("abc\n");
    // An unbound first key becomes a prefix.
    type_keys(&mut s, ":nnoremap Qa x<ret>Qa");
    assert_eq!(s.text(), "bc\n");
    feed(&mut s, ":nnoremap xw x<ret>");
    assert!(
        s.status().contains("x already does something"),
        "{}",
        s.status()
    );
    feed(&mut s, ":nnoremap gab x<ret>");
    assert!(s.status().contains("only two keys"), "{}", s.status());
    feed(&mut s, ":nnoremap <Buffer> x y<ret>");
    assert!(s.status().contains("isn't supported"), "{}", s.status());
    // <silent> is accepted.
    type_keys(&mut s, ":nnoremap <Silent> gx x<ret>gx");
    assert_eq!(s.text(), "c\n");
}

#[test]
fn mode_keys_come_first() {
    let mut s = server("abc\n");
    s.eval(
        r#"(define-major-mode! 'map-test-mode #f '() #f)
           (define-mode-key! 'map-test-mode 'normal "Q" (lambda (n) (message "mode")))"#,
    )
    .unwrap();
    type_keys(&mut s, ":nnoremap Q x<ret>");
    s.eval("(set-major-mode! 'map-test-mode)").unwrap();
    type_keys(&mut s, "Q");
    assert_eq!(s.text(), "abc\n");
    assert_eq!(s.status(), "mode");
}
