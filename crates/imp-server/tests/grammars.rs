//! Tree-sitter grammars built at runtime: loading, queries, installing.
//! The grammar is tests/fixtures/imptest, a tiny one built here with `cc`.

mod common;

use common::*;
use std::path::{Path, PathBuf};

/// Held for the whole of each test here. Making a server resets the
/// query directory, which is the whole process's, so a test making one
/// while another has set it would undo that.
static ONE_AT_A_TIME: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn one_at_a_time() -> std::sync::MutexGuard<'static, ()> {
    ONE_AT_A_TIME.lock().unwrap_or_else(|e| e.into_inner())
}

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/imptest")
}

/// Builds the fixture grammar into `name`.so in the test's temp
/// directory, its parser.c changed by `edit`, with `flags` for cc.
fn build(name: &str, edit: impl Fn(String) -> String, flags: &[&str]) -> PathBuf {
    let parser = temp_path(&format!("{name}-parser.c"));
    let source = std::fs::read_to_string(fixture().join("src/parser.c")).unwrap();
    std::fs::write(&parser, edit(source)).unwrap();
    let library = temp_path(&format!("{name}.so"));
    let status = std::process::Command::new("cc")
        .args(["-shared", "-fPIC", "-O1", "-I"])
        .arg(fixture().join("src"))
        .args(flags)
        .arg(&parser)
        .arg("-o")
        .arg(&library)
        .status()
        .expect("cc runs");
    assert!(status.success());
    library
}

/// Registers the fixture as grammar `name`, built so its function is
/// tree_sitter_`symbol`.
fn register(s: &mut imp_server::Server, name: &str, symbol: &str) {
    let define = format!("-Dtree_sitter_imptest=tree_sitter_{symbol}");
    let library = build(name, |s| s, &[&define]);
    s.eval(&format!(
        "(register-grammar! {:?} {:?} {:?})",
        name,
        library.display().to_string(),
        fixture().join("queries").display().to_string()
    ))
    .unwrap();
}

fn open(s: &mut imp_server::Server, name: &str, text: &str) {
    let path = temp_path(name);
    std::fs::write(&path, text).unwrap();
    type_keys(s, &format!(":e {}<ret>", path.display()));
}

/// A mode for files ending in `.ext` that parses them as `language`.
fn mode(s: &mut imp_server::Server, ext: &str, language: &str) {
    s.eval(&format!(
        "(define-major-mode! '{ext}-mode 'prog-mode '({ext:?}) (lambda () void))
         (define-mode-language! '{ext}-mode {language:?})"
    ))
    .unwrap();
}

/// The syntax face drawn on the first `word` in `text`, opened as `file`.
fn face_on(s: &mut imp_server::Server, file: &str, text: &str, word: &str) -> String {
    open(s, file, text);
    let at = text.find(word).unwrap();
    s.eval(&format!(
        "(list-find (lambda (f) (starts-with? f \"syntax.\")) (reverse (faces-at {at})))"
    ))
    .unwrap()
}

#[test]
fn a_registered_grammar_works_like_a_bundled_one() {
    let _serial = one_at_a_time();
    let mut s = server("");
    register(&mut s, "imptest", "imptest");
    mode(&mut s, "imptest", "imptest");
    let text = "# note\nfn main(a, b) {\n  let x = 1;\n}\nlet y = \"s\";\n";
    open(&mut s, "a.imptest", text);
    assert_eq!(s.eval("(buffer-language)").unwrap(), "\"imptest\"");
    for (word, face) in [
        ("let x", "syntax.keyword"),
        ("main", "syntax.function"),
        ("1;", "syntax.number"),
        ("\"s\"", "syntax.string"),
        ("# note", "syntax.comment"),
    ] {
        assert_eq!(
            face_on(&mut s, "a.imptest", text, word),
            format!("\"{face}\""),
            "{word}"
        );
    }
    // Text objects, from the grammar's node kinds.
    s.eval("(define-syntax-objects! \"imptest\" '(\"function\") '() '(\"parameters\"))")
        .unwrap();
    open(
        &mut s,
        "b.imptest",
        "fn f(a, b) {\n  let x = 1;\n}\nlet y = 2;\n",
    );
    type_keys(&mut s, "jdaf");
    assert_eq!(s.text(), "\nlet y = 2;\n");
    // And a Markdown fence names it, by name or alias.
    s.eval("(define-language-alias! \"impt\" \"imptest\")")
        .unwrap();
    for (i, info) in ["imptest", "impt"].into_iter().enumerate() {
        let md = format!("```{info}\nlet x = 1;\n```\n");
        assert_eq!(
            face_on(&mut s, &format!("fence{i}.md"), &md, "let"),
            "\"syntax.keyword\"",
            "{info}"
        );
    }
}

#[test]
fn a_registered_grammar_takes_a_bundled_ones_place() {
    let _serial = one_at_a_time();
    let mut s = server("");
    register(&mut s, "toml", "toml");
    assert_eq!(
        face_on(&mut s, "a.toml", "let x = 1;\n", "let"),
        "\"syntax.keyword\""
    );
}

#[test]
fn a_grammar_that_wont_load_says_why() {
    let _serial = one_at_a_time();
    let mut s = server("");
    // A library without the grammar's function.
    register(&mut s, "nosymbol", "other");
    mode(&mut s, "nosymbol", "nosymbol");
    open(&mut s, "a.nosymbol", "let x = 1;\n");
    assert_eq!(s.eval("(buffer-language)").unwrap(), "#false");
    let said = s.eval("(car *messages*)").unwrap();
    assert!(said.contains("has no tree_sitter_nosymbol"), "{said}");

    // One built for a tree-sitter imp can't read.
    let library = build(
        "newabi",
        |s| s.replace("#define LANGUAGE_VERSION 14", "#define LANGUAGE_VERSION 99"),
        &["-Dtree_sitter_imptest=tree_sitter_newabi"],
    );
    s.eval(&format!(
        "(register-grammar! \"newabi\" {:?} \"\")",
        library.display().to_string()
    ))
    .unwrap();
    mode(&mut s, "newabi", "newabi");
    open(&mut s, "a.newabi", "let x = 1;\n");
    assert_eq!(s.eval("(buffer-language)").unwrap(), "#false");
    let said = s.eval("(car *messages*)").unwrap();
    assert!(said.contains("ABI 99"), "{said}");
}

#[test]
fn queries_come_from_the_repository_or_the_config_directory() {
    let _serial = one_at_a_time();
    let mut s = server("");
    // Named apart from the other tests' grammar: the query directory is
    // the whole process's.
    register(&mut s, "queried", "queried");
    mode(&mut s, "queried", "queried");
    // The repository's injections query makes a raw block Python.
    assert_eq!(
        face_on(&mut s, "a.queried", "raw { if x: y }\n", "if"),
        "\"syntax.keyword\""
    );

    let dir = temp_path("queries");
    for (file, query) in [
        // A bundled language's, replaced.
        ("rust/highlights.scm", "\"fn\" @string\n"),
        // A runtime grammar's, replaced, inheriting from a language that
        // inherits back.
        (
            "queried/highlights.scm",
            "; a comment\n; inherits: shared\n(number) @string\n",
        ),
        (
            "shared/highlights.scm",
            "; inherits: queried\n\"let\" @function\n",
        ),
        (
            "queried/injections.scm",
            "((raw_text) @injection.content (#set! injection.language \"bash\"))\n",
        ),
    ] {
        let path = dir.join(file);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, query).unwrap();
    }
    s.eval(&format!("(set-query-dir! {:?})", dir.display().to_string()))
        .unwrap();
    assert_eq!(
        face_on(&mut s, "b.rs", "fn main() {}\n", "fn"),
        "\"syntax.string\""
    );
    let text = "let x = 1;\nraw { if true; then y; fi }\n";
    for (word, face) in [
        ("let", "\"syntax.function\""),
        ("1", "\"syntax.string\""),
        ("then", "\"syntax.keyword\""),
    ] {
        assert_eq!(face_on(&mut s, "b.queried", text, word), face, "{word}");
    }
    s.eval("(set-query-dir! \"\")").unwrap();
}
