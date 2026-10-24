//! Folds worked out from the text: foldmethod indent, expr and syntax.

mod common;

use common::*;

/// The folds as "first-last" with + for closed, sorted.
fn folds(s: &mut imp_server::Server) -> String {
    s.eval(
        r#"(string-join
             (map (lambda (f) (string-append (number->string (fold-first f)) "-" (number->string (fold-last f))
                                             (if (fold-closed? f) "+" "")))
                  (sort (buffer-folds)
                        (lambda (a b) (or (< (fold-first a) (fold-first b))
                                          (and (= (fold-first a) (fold-first b)) (> (fold-last a) (fold-last b)))))))
             " ")"#,
    )
    .unwrap()
}

const CODE: &str =
    "fn a\n    one\n    if x\n        two\n        three\n\n    four\nfn b\n    five\n    six\n";

#[test]
fn indent_folds_nest_and_start_closed() {
    let mut s = server(CODE);
    s.eval("(set-option! 'shiftwidth 4)").unwrap();
    type_keys(&mut s, ":setlocal foldmethod=indent<ret>");
    // The block under each header, the nested if body, and the blank line
    // inside the first block belongs to it; foldlevel 0 closes them all.
    assert_eq!(folds(&mut s), r#""1-6+ 3-4+ 8-9+""#);
    // Closed folds show as one line each.
    let rows = s.frame().text_rows();
    assert_eq!(rows[0], "fn a");
    assert!(rows[1].starts_with("    one"), "{rows:?}");
    assert!(rows[1].contains("··· 6 lines"), "{rows:?}");
    assert_eq!(rows[2], "fn b");
}

#[test]
fn edits_keep_a_fold_s_state() {
    let mut s = server(CODE);
    s.eval("(set-option! 'shiftwidth 4)").unwrap();
    type_keys(&mut s, ":setlocal fdm=indent<ret>");
    // Open the first block, then add a line to the second one.
    type_keys(&mut s, "jzo");
    assert_eq!(folds(&mut s), r#""1-6 3-4+ 8-9+""#);
    // yy on a closed fold takes it whole: two lines more in that block.
    type_keys(&mut s, "Gyyp");
    assert_eq!(folds(&mut s), r#""1-6 3-4+ 8-11+""#);
    // A new block appears open.
    type_keys(&mut s, "ggOfn z<ret>    p<ret>q<esc>");
    assert_eq!(folds(&mut s), r#""1-2 4-9 6-7+ 11-14+""#);
}

#[test]
fn foldlevel_closes_deeper_folds_only() {
    let mut s = server(CODE);
    s.eval("(set-option! 'shiftwidth 4)").unwrap();
    type_keys(&mut s, ":setlocal fdl=1<ret>:setlocal fdm=indent<ret>");
    assert_eq!(folds(&mut s), r#""1-6 3-4+ 8-9""#);
    type_keys(&mut s, ":setlocal fdl=0<ret>");
    assert_eq!(folds(&mut s), r#""1-6+ 3-4+ 8-9+""#);
}

#[test]
fn expr_folds_from_a_procedure() {
    let mut s = server("# one\na\nb\n# two\nc\nd\ne\n");
    s.eval(
        r##"(set-local-option! 'foldexpr (lambda (l) (if (starts-with? (buffer-substring (line-start l) (line-end l)) "#") 0 1)))
           (set-local-option! 'foldlevel 1)
           (set-local-option! 'foldmethod "expr")"##,
    )
    .unwrap();
    assert_eq!(folds(&mut s), r#""1-2 4-6""#);
}
