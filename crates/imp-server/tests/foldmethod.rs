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
    // Each block with the header that opens it, the nested if with its
    // line, and the blank line inside the first block belongs to it;
    // foldlevel 0 closes them all.
    assert_eq!(folds(&mut s), r#""0-6+ 2-4+ 7-9+""#);
    // A closed block shows as its header line and a note.
    let rows = s.frame().text_rows();
    assert!(rows[0].starts_with("fn a"), "{rows:?}");
    assert!(rows[0].contains("··· 7 lines"), "{rows:?}");
    assert!(rows[1].starts_with("fn b"), "{rows:?}");
    assert!(rows[1].contains("··· 3 lines"), "{rows:?}");
}

#[test]
fn a_block_at_the_top_has_no_header() {
    let mut s = server("    one\n    two\nthree\n    four\n");
    s.eval("(set-option! 'shiftwidth 4)").unwrap();
    type_keys(&mut s, ":setlocal fdm=indent<ret>");
    assert_eq!(folds(&mut s), r#""0-1+ 2-3+""#);
}

#[test]
fn edits_keep_a_fold_s_state() {
    let mut s = server(CODE);
    s.eval("(set-option! 'shiftwidth 4)").unwrap();
    type_keys(&mut s, ":setlocal fdm=indent<ret>");
    // Open the first block, then add a line inside the second one.
    type_keys(&mut s, "zo");
    assert_eq!(folds(&mut s), r#""0-6 2-4+ 7-9+""#);
    type_keys(&mut s, "Gzoyyp");
    assert_eq!(folds(&mut s), r#""0-6 2-4+ 7-10""#);
    type_keys(&mut s, "zc");
    // A new block appears open.
    type_keys(&mut s, "ggOfn z<ret>    p<ret>q<esc>");
    assert_eq!(folds(&mut s), r#""0-2 3-9 5-7+ 10-13+""#);
}

#[test]
fn foldlevel_closes_deeper_folds_only() {
    let mut s = server(CODE);
    s.eval("(set-option! 'shiftwidth 4)").unwrap();
    type_keys(&mut s, ":setlocal fdl=1<ret>:setlocal fdm=indent<ret>");
    assert_eq!(folds(&mut s), r#""0-6 2-4+ 7-9""#);
    type_keys(&mut s, ":setlocal fdl=0<ret>");
    assert_eq!(folds(&mut s), r#""0-6+ 2-4+ 7-9+""#);
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

const RUST: &str = "fn a() {\n    let x = 1;\n}\n\nstruct S {\n    f: u8,\n}\nimpl S {\n    fn m(&self) {\n        1;\n    }\n}\n";

fn open(s: &mut imp_server::Server, name: &str, text: &str) {
    let path = temp_path(name);
    std::fs::write(&path, text).unwrap();
    type_keys(s, &format!(":e {}<ret>", path.display()));
}

#[test]
fn syntax_folds_functions_and_classes() {
    let mut s = server("");
    open(&mut s, "folds.rs", RUST);
    type_keys(&mut s, ":setlocal fdm=syntax<ret>");
    // Functions and the struct and impl, nested, all closed.
    assert_eq!(folds(&mut s), r#""0-2+ 4-6+ 7-11+ 8-10+""#);
    // A language's own fold kinds.
    s.eval(r#"(define-syntax-folds! "rust" '("impl_item"))"#)
        .unwrap();
    type_keys(&mut s, ":setlocal fdm=syntax<ret>");
    assert_eq!(folds(&mut s), r#""7-11+""#);
}

#[test]
fn a_file_opened_with_foldmethod_set_starts_folded() {
    let mut s = server("");
    s.eval("(set-option! 'foldmethod \"syntax\")").unwrap();
    open(&mut s, "folded.rs", RUST);
    assert_eq!(folds(&mut s), r#""0-2+ 4-6+ 7-11+ 8-10+""#);
}

#[test]
fn hand_made_folds_are_for_manual() {
    let mut s = server(CODE);
    s.eval("(set-option! 'shiftwidth 4)").unwrap();
    type_keys(&mut s, ":setlocal fdm=indent<ret>");
    for keys in ["zfj", "zE", "jzd"] {
        type_keys(&mut s, keys);
        assert_eq!(
            s.status(),
            "can't make or delete folds with foldmethod=indent",
            "{keys}"
        );
        assert_eq!(folds(&mut s), r#""0-6+ 2-4+ 7-9+""#, "{keys}");
        type_keys(&mut s, "gg");
    }
    // Back to manual: the folds stay, and can be deleted by hand.
    type_keys(&mut s, ":setlocal fdm=manual<ret>zd");
    assert_eq!(folds(&mut s), r#""2-4+ 7-9+""#);
}
