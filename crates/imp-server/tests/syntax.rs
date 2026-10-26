//! Tree-sitter: highlighting, structural text objects, smart indent.

mod common;

use common::*;
use imp_core::Color;

fn open(s: &mut imp_server::Server, name: &str, text: &str) {
    let path = temp_path(name);
    std::fs::write(&path, text).unwrap();
    type_keys(s, &format!(":e {}<ret>", path.display()));
}

#[test]
fn rust_is_highlighted() {
    let mut s = server("");
    open(&mut s, "hl.rs", "fn main() { let s = \"hi\"; }\n");
    assert_eq!(s.eval("(buffer-language)").unwrap(), "\"rust\"");
    let row = &s.frame().rows[0];
    let fn_span = row
        .iter()
        .find(|sp| sp.text == "fn")
        .expect("fn is its own span");
    assert_eq!(fn_span.style.fg, Some(Color::Rgb(0xc6, 0x78, 0xdd)));
    let string = row.iter().find(|sp| sp.text.contains("\"hi\"")).unwrap();
    assert_eq!(string.style.fg, Some(Color::Rgb(0x98, 0xc3, 0x79)));
}

#[test]
fn a_more_specific_capture_of_the_same_text_wins() {
    // The Rust query captures a doc comment as comment, then as
    // comment.documentation; a theme that colors the second sees it.
    let mut s = server("");
    s.eval(r#"(set-face! "syntax.comment.documentation" "fg=#ff0000")"#)
        .unwrap();
    open(&mut s, "doc.rs", "/// Docs.\n// Plain.\nfn f() {}\n");
    let fg = |s: &mut imp_server::Server, row: usize| {
        s.frame().rows[row]
            .iter()
            .find(|sp| sp.text.contains("Docs") || sp.text.contains("Plain"))
            .and_then(|sp| sp.style.fg)
    };
    assert_eq!(fg(&mut s, 0), Some(Color::Rgb(0xff, 0, 0)));
    assert_ne!(fg(&mut s, 1), Some(Color::Rgb(0xff, 0, 0)));
}

#[test]
fn highlighting_follows_edits() {
    let mut s = server("");
    open(&mut s, "edit.rs", "x\n");
    s.frame();
    type_keys(&mut s, "ccfn f() {}<esc>");
    let row = &s.frame().rows[0];
    assert!(
        row.iter()
            .any(|sp| sp.text == "fn" && sp.style.fg.is_some()),
        "{row:?}"
    );
    // Undo resets the tree.
    type_keys(&mut s, "u");
    let row = &s.frame().rows[0];
    assert!(row.iter().all(|sp| sp.text != "fn"));
}

#[test]
fn every_bundled_language_attaches() {
    let mut s = server("");
    for (file, lang) in [
        ("a.scm", "scheme"),
        ("a.ts", "typescript"),
        ("a.tsx", "tsx"),
        ("a.js", "javascript"),
        ("a.nix", "nix"),
        ("a.md", "markdown"),
    ] {
        open(&mut s, file, "x\n");
        assert_eq!(s.eval("(buffer-language)").unwrap(), format!("\"{lang}\""));
    }
    open(&mut s, "a.txt", "x\n");
    assert_eq!(s.eval("(buffer-language)").unwrap(), "#false");
}

#[test]
fn function_objects() {
    let mut s = server("");
    open(
        &mut s,
        "obj.rs",
        "fn a() {\n    one();\n    two();\n}\nfn b() {}\n",
    );
    type_keys(&mut s, "jdif");
    assert_eq!(s.text(), "fn a() {\n}\nfn b() {}\n");
    type_keys(&mut s, "u");
    type_keys(&mut s, "jdaf");
    assert_eq!(s.text(), "\nfn b() {}\n");
}

#[test]
fn class_objects() {
    let mut s = server("");
    open(&mut s, "cls.rs", "struct P {\n    x: i32,\n}\n");
    type_keys(&mut s, "jvacd");
    assert_eq!(s.text(), "\n");
}

#[test]
fn argument_objects() {
    let mut s = server("");
    open(&mut s, "args.rs", "fn f() { g(alpha, beta, gamma); }\n");
    type_keys(&mut s, "fbdaa");
    assert_eq!(s.text(), "fn f() { g(alpha, gamma); }\n");
    type_keys(&mut s, "fgdaa");
    assert_eq!(s.text(), "fn f() { g(alpha); }\n");
    type_keys(&mut s, "0fpcia");
    type_keys(&mut s, "x<esc>");
    assert_eq!(s.text(), "fn f() { g(x); }\n");
}

#[test]
fn typescript_function_objects() {
    let mut s = server("");
    open(
        &mut s,
        "f.ts",
        "const f = (a: number) => {\n  return a;\n};\n",
    );
    type_keys(&mut s, "jyif");
    s.eval("(set-option! 'clipboard \"\")").unwrap();
    assert_eq!(
        s.eval("(car (register-get #\\0))").unwrap(),
        "\"  return a;\\n\""
    );
}

#[test]
fn smartindent_after_brackets() {
    let mut s = server("");
    open(&mut s, "ind.rs", "fn a() {}\n");
    // <ret> between braces opens an indented line inside.
    type_keys(&mut s, "f{a<ret>x<esc>");
    assert_eq!(s.text(), "fn a() {\n    x\n}\n");
    // A closing brace typed first on a line dedents it.
    type_keys(&mut s, "o}<esc>");
    assert_eq!(s.text(), "fn a() {\n    x\n}\n}\n");
}

#[test]
fn syntax_tree_command() {
    let mut s = server("");
    open(&mut s, "tree.rs", "fn a() {}\n");
    type_keys(&mut s, ":syntax-tree<ret>");
    let rows = s.frame().text_rows().join("\n");
    assert!(rows.contains("(function_item"), "{rows}");
}
