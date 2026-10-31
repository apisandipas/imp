//! Snippets (runtime/snippet.scm): expanding them, filling in their stops,
//! and snippets of your own.

mod common;

use common::*;

#[test]
fn parsing_stops_placeholders_choices_and_escapes() {
    let mut s = server("");
    let parse = |s: &mut imp_server::Server, body: &str| {
        s.eval(&format!("(snippet-parse {body:?} \"  \" \"\\t\")"))
            .unwrap()
    };
    assert_eq!(
        parse(&mut s, "f(${1:x}, $2)$0"),
        r#"("f(x, )" ((1 2 3 ()) (2 5 5 ()) (0 6 6 ())))"#
    );
    assert_eq!(
        parse(&mut s, "${1|a,b\\,c|} \\$1 {\\}"),
        r#"("a $1 {}" ((1 0 1 ("a" "b,c"))))"#
    );
    // Nested placeholders; new lines keep the indent.
    assert_eq!(
        parse(&mut s, "${1:a ${2:b}}\nx"),
        r#"("a b\n  x" ((2 2 3 ()) (1 0 3 ())))"#
    );
    // A variable, and one unknown that keeps its default.
    assert_eq!(
        parse(&mut s, "${TM_LINE_NUMBER}${NOPE:dflt}"),
        r#"("1dflt" ())"#
    );
}

#[test]
fn filling_in_a_snippet() {
    let mut s = server("");
    type_keys(&mut s, "i");
    s.eval(r#"(snippet-insert! (cursor) (cursor) "fn ${1:name}($2) -> $1 {\n\t$0\n}")"#)
        .unwrap();
    // The placeholder is selected: typing replaces it, and the mirror
    // follows once we move on.
    type_keys(&mut s, "go<tab>x: i32<tab>");
    assert_eq!(s.text(), "fn go(x: i32) -> go {\n    \n}");
    assert_eq!(s.cursor(), "fn go(x: i32) -> go {\n    ".len());
    assert_eq!(s.eval("*snippet*").unwrap(), "#false");
    // <tab> is a tab again.
    type_keys(&mut s, "<tab>");
    assert_eq!(s.text(), "fn go(x: i32) -> go {\n        \n}");
}

#[test]
fn back_and_leaving() {
    let mut s = server("");
    type_keys(&mut s, "i");
    s.eval(r#"(snippet-insert! 0 0 "<${1:a}>${2:b}</$1>")"#)
        .unwrap();
    // Leave a placeholder as it is with <tab>; come back with <s-tab>.
    type_keys(&mut s, "<tab><s-tab>div<tab>");
    assert_eq!(s.text(), "<div>b</div>");
    // Leaving insert state ends it.
    type_keys(&mut s, "<esc>");
    assert_eq!(s.eval("*snippet*").unwrap(), "#false");
    assert_eq!(s.eval("(minor-modes)").unwrap(), "()");
}

#[test]
fn choices_come_in_a_menu() {
    let mut s = server("");
    type_keys(&mut s, "i");
    s.eval(r#"(snippet-insert! 0 0 "${1|let,const|} x")"#)
        .unwrap();
    assert_eq!(
        s.eval("(map car *menu-matches*)").unwrap(),
        r#"("let" "const")"#
    );
    type_keys(&mut s, "<C-n><C-y><tab>");
    assert_eq!(s.text(), "const x");
}

#[test]
fn your_own_snippets_complete_and_expand() {
    let mut s = server("");
    s.eval(r#"(define-snippet! 'fundamental-mode "todo" "TODO(${1:me}): $0" "a todo")"#)
        .unwrap();
    type_keys(&mut s, "itod");
    s.keys(&["C-n"]);
    let detail = s.eval("(cadr (car *menu-matches*))").unwrap();
    assert_eq!(detail, "\"a todo\"");
    type_keys(&mut s, "<C-y>bob<tab>fix");
    assert_eq!(s.text(), "TODO(bob): fix");
}

#[test]
fn vscode_snippet_files() {
    let path = temp_path("snippets.json");
    std::fs::write(
        &path,
        r#"{"Print": {"prefix": ["pr", "print"], "body": ["print($1)", "$0"], "description": "print it"}}"#,
    )
    .unwrap();
    let mut s = server("");
    assert_eq!(
        s.eval(&format!(
            "(load-snippets! 'all {:?})",
            path.display().to_string()
        ))
        .unwrap(),
        "2"
    );
    type_keys(&mut s, "iprint");
    s.keys(&["C-n"]);
    type_keys(&mut s, "<C-y>1<tab>");
    assert_eq!(s.text(), "print(1)\n");
}

#[test]
fn the_menu_opening_during_a_snippet_leaves_its_keys_working() {
    let mut s = server("alpha\n");
    type_keys(&mut s, "Go");
    s.eval(r#"(snippet-insert! (cursor) (cursor) "al${1:pha} end")"#)
        .unwrap();
    // The placeholder is selected, after "al"; the menu opens over it.
    s.eval("(complete-with! 'words #t)").unwrap();
    assert_eq!(s.eval("(overlay-open? 'completion)").unwrap(), "#true");
    // A typed char still replaces the placeholder.
    type_keys(&mut s, "z");
    assert_eq!(s.text(), "alpha\nalz end\n");
}
