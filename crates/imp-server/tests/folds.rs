//! Folds (runtime/fold.scm, the z keys in vim.scm, drawn by render.rs),
//! matched against Vim's manual folds.

mod common;

use common::*;

/// A server without the fold column, so rows start with their text; the
/// column's own tests are in fold_column.rs.
fn server(text: &str) -> imp_server::Server {
    let mut s = common::server(text);
    s.eval("(set-option! 'foldcolumn \"no\")").unwrap();
    s
}

const TEXT: &str = "one\ntwo\nthree\nfour\nfive\nsix\n";

fn rows(s: &mut imp_server::Server) -> Vec<String> {
    s.frame().text_rows()
}

#[test]
fn zf_makes_a_closed_fold_that_j_and_k_step_over() {
    let mut s = server(TEXT);
    type_keys(&mut s, "jzfj");
    let r = rows(&mut s);
    assert_eq!(r[0].trim_end(), "one");
    assert_eq!(r[1].trim_end(), "two ··· 2 lines");
    assert_eq!(r[2].trim_end(), "four");
    assert_eq!(s.eval("(current-line)").unwrap(), "1");
    // j from the fold goes past it; k comes back to its first line.
    type_keys(&mut s, "j");
    assert_eq!(s.eval("(current-line)").unwrap(), "3");
    type_keys(&mut s, "k");
    assert_eq!(s.eval("(current-line)").unwrap(), "1");
    type_keys(&mut s, "k");
    assert_eq!(s.eval("(current-line)").unwrap(), "0");
    // A count counts the fold as one line.
    type_keys(&mut s, "2j");
    assert_eq!(s.eval("(current-line)").unwrap(), "3");
    // The cursor on a fold shows at its start.
    s.eval("(set-cursor! 6)").unwrap();
    assert_eq!(s.frame().cursor, (0, 1));
}

#[test]
fn horizontal_motions_open_a_fold() {
    // Vim's default 'foldopen' has hor: h, l, w, f and the like.
    for keys in ["l", "e", "w", "$", "fo"] {
        let mut s = server(TEXT);
        type_keys(&mut s, "jzfjk");
        type_keys(&mut s, "j");
        type_keys(&mut s, keys);
        assert_eq!(rows(&mut s)[2].trim_end(), "three", "{keys}");
    }
    // j and k don't.
    let mut s = server(TEXT);
    type_keys(&mut s, "jzfjjk");
    assert_eq!(rows(&mut s)[1].trim_end(), "two ··· 2 lines");
}

#[test]
fn open_close_toggle() {
    let mut s = server(TEXT);
    type_keys(&mut s, "jzfj");
    type_keys(&mut s, "zo");
    assert_eq!(rows(&mut s)[2].trim_end(), "three");
    type_keys(&mut s, "jzc");
    assert_eq!(rows(&mut s)[1].trim_end(), "two ··· 2 lines");
    assert_eq!(s.eval("(current-line)").unwrap(), "1");
    type_keys(&mut s, "za");
    assert_eq!(rows(&mut s)[2].trim_end(), "three");
    type_keys(&mut s, "za");
    assert_eq!(rows(&mut s)[2].trim_end(), "four");
    type_keys(&mut s, "zR");
    assert_eq!(rows(&mut s)[2].trim_end(), "three");
    type_keys(&mut s, "zM");
    assert_eq!(rows(&mut s)[2].trim_end(), "four");
    // zd removes the fold, leaving the text.
    type_keys(&mut s, "zd");
    assert_eq!(rows(&mut s)[2].trim_end(), "three");
    assert_eq!(s.text(), TEXT);
    feed(&mut s, "zo");
    assert!(s.status().contains("E490"), "{}", s.status());
}

#[test]
fn nested_folds() {
    let mut s = server(TEXT);
    // A closed inner fold on three-four, then an outer one around it.
    type_keys(&mut s, "jjzfj");
    type_keys(&mut s, ":2,5fold<ret>");
    assert_eq!(rows(&mut s)[1].trim_end(), "two ··· 4 lines");
    // zo opens the outer one; the inner stays closed.
    type_keys(&mut s, "zo");
    assert_eq!(rows(&mut s)[2].trim_end(), "three ··· 2 lines");
    assert_eq!(rows(&mut s)[3].trim_end(), "five");
    // The cursor stayed on three, the inner fold; zO opens everything there.
    assert_eq!(s.eval("(current-line)").unwrap(), "2");
    type_keys(&mut s, "zO");
    assert_eq!(rows(&mut s)[3].trim_end(), "four");
    // zC closes every fold at the cursor.
    type_keys(&mut s, "zC");
    assert_eq!(rows(&mut s)[1].trim_end(), "two ··· 4 lines");
    type_keys(&mut s, "zE");
    assert_eq!(rows(&mut s)[2].trim_end(), "three");
}

#[test]
fn linewise_operators_take_a_closed_fold_whole() {
    let mut s = server(TEXT);
    type_keys(&mut s, "jzfj");
    type_keys(&mut s, "yyGp");
    assert_eq!(s.text(), "one\ntwo\nthree\nfour\nfive\nsix\ntwo\nthree\n");
    type_keys(&mut s, "ggjdd");
    assert_eq!(s.text(), "one\nfour\nfive\nsix\ntwo\nthree\n");
    // The fold went with its lines.
    assert_eq!(rows(&mut s)[1].trim_end(), "four");
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "one\ntwo\nthree\nfour\nfive\nsix\ntwo\nthree\n");
    // dj from the line above a fold deletes through the whole fold.
    type_keys(&mut s, "zEggjzfjggdj");
    assert_eq!(s.text(), "four\nfive\nsix\ntwo\nthree\n");
}

#[test]
fn folds_follow_edits() {
    let mut s = server(TEXT);
    type_keys(&mut s, "jjzfj");
    type_keys(&mut s, "ggOzero<esc>");
    let r = rows(&mut s);
    assert_eq!(r[3].trim_end(), "three ··· 2 lines");
    assert_eq!(r[4].trim_end(), "five");
}

#[test]
fn search_and_jumps_open_folds() {
    let mut s = server(TEXT);
    type_keys(&mut s, "jzf3j");
    type_keys(&mut s, "gg/four<ret>");
    assert_eq!(s.eval("(current-line)").unwrap(), "3");
    assert_eq!(rows(&mut s)[3].trim_end(), "four");
}

#[test]
fn ex_commands() {
    let mut s = server(TEXT);
    type_keys(&mut s, ":2,4fold<ret>");
    assert_eq!(rows(&mut s)[1].trim_end(), "two ··· 3 lines");
    type_keys(&mut s, ":%foldopen<ret>");
    assert_eq!(rows(&mut s)[2].trim_end(), "three");
    type_keys(&mut s, ":%foldclose<ret>");
    assert_eq!(rows(&mut s)[1].trim_end(), "two ··· 3 lines");
}

#[test]
fn relative_numbers_count_a_fold_as_one_line() {
    let mut s = server(TEXT);
    type_keys(&mut s, "jzfjgg:set rnu<ret>");
    let r = rows(&mut s);
    assert!(r[1].starts_with("  1 two ··· 2 lines"), "{r:?}");
    assert!(r[2].starts_with("  2 four"), "{r:?}");
}
