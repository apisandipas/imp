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
fn a_narrower_capture_wins_over_the_one_around_it() {
    // The Rust query lists strings before escapes; the escape inside a
    // string still wins.
    let mut s = server("");
    open(&mut s, "esc.rs", "fn f() { \"a\\nb\"; }\n");
    let at = s.text().find("\\n").unwrap();
    assert_eq!(
        s.eval(&format!(
            "(list-find (lambda (f) (starts-with? f \"syntax.\")) (reverse (faces-at {at})))"
        ))
        .unwrap(),
        "\"syntax.escape\""
    );
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
        ("a.html", "html"),
        ("a.svg", "html"),
        ("a.css", "css"),
        ("a.scss", "css"),
        ("a.json", "json"),
        ("a.yaml", "yaml"),
        ("a.toml", "toml"),
        ("a.sh", "bash"),
        ("a.c", "c"),
        ("a.h", "c"),
        ("a.go", "go"),
        ("a.py", "python"),
        ("a.lua", "lua"),
    ] {
        open(&mut s, file, "x\n");
        assert_eq!(s.eval("(buffer-language)").unwrap(), format!("\"{lang}\""));
    }
    open(&mut s, "a.txt", "x\n");
    assert_eq!(s.eval("(buffer-language)").unwrap(), "#false");
}

#[test]
fn cpp_elixir_and_ruby_have_modes_but_no_bundled_grammar() {
    let mut s = server("");
    for (file, mode) in [
        ("a.cpp", "cpp-mode"),
        ("a.ex", "elixir-mode"),
        ("a.exs", "elixir-mode"),
        ("a.rb", "ruby-mode"),
        ("Rakefile", "ruby-mode"),
        ("Gemfile", "ruby-mode"),
    ] {
        open(&mut s, file, "x\n");
        assert_eq!(s.eval("(major-mode)").unwrap(), mode);
        assert_eq!(s.eval("(buffer-language)").unwrap(), "#false");
    }
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
fn html_css_and_json_are_highlighted() {
    let mut s = server("");
    for (file, text, word, face) in [
        (
            "hl.html",
            "<div class=\"x\">hi</div>\n",
            "div",
            "syntax.tag",
        ),
        (
            "hl.html",
            "<div class=\"x\">hi</div>\n",
            "class",
            "syntax.attribute",
        ),
        ("hl.css", "a { color: red; }\n", "color", "syntax.property"),
        (
            "hl.json",
            "{\"k\": \"v\", \"n\": 1}\n",
            "1",
            "syntax.number",
        ),
        (
            "hl.json",
            "{\"k\": \"v\", \"n\": 1}\n",
            "\"v\"",
            "syntax.string",
        ),
    ] {
        assert_eq!(
            face_on(&mut s, file, text, word),
            format!("\"{face}\""),
            "{word} in {file}"
        );
    }
}

#[test]
fn html_script_and_style_are_their_languages() {
    let mut s = server("");
    let page =
        "<p>const</p>\n<script>\nconst x = 1;\n</script>\n<style>\na { color: red; }\n</style>\n";
    for (word, face) in [
        ("const x", "syntax.keyword"),
        ("1;", "syntax.number"),
        ("color", "syntax.property"),
        ("script", "syntax.tag"),
    ] {
        assert_eq!(
            face_on(&mut s, "embed.html", page, word),
            format!("\"{face}\""),
            "{word}"
        );
    }
    // HTML's own text isn't JavaScript.
    assert_eq!(face_on(&mut s, "embed.html", page, "const"), "#false");
}

#[test]
fn typing_in_a_script_keeps_it_highlighted() {
    let mut s = server("");
    open(&mut s, "typed.html", "<script>\nlet x = 1;\n</script>\n");
    type_keys(&mut s, "jOreturn<esc>");
    let text = s.text();
    assert_eq!(text, "<script>\nreturn\nlet x = 1;\n</script>\n");
    for word in ["return", "let"] {
        let at = text.find(word).unwrap();
        assert_eq!(
            s.eval(&format!(
                "(list-find (lambda (f) (starts-with? f \"syntax.\")) (reverse (faces-at {at})))"
            ))
            .unwrap(),
            "\"syntax.keyword\"",
            "{word}"
        );
    }
}

#[test]
fn markdown_fences_are_their_languages() {
    let mut s = server("");
    s.eval("(define-language-alias! \"Snek\" \"python\")")
        .unwrap();
    for (i, (info, code)) in [
        ("python", "if x:\n    y"),
        ("PY", "if x:\n    y"),
        ("snek", "if x:\n    y"),
        ("sh", "if true; then y; fi"),
    ]
    .into_iter()
    .enumerate()
    {
        let text = format!("# Code\n\n```{info}\n{code}\n```\n");
        assert_eq!(
            face_on(&mut s, &format!("fence{i}.md"), &text, "if"),
            "\"syntax.keyword\"",
            "{info}"
        );
    }
}

#[test]
fn an_unknown_fence_language_is_left_as_markdown_draws_it() {
    let mut s = server("");
    let plain = face_on(&mut s, "plain.md", "```\ndef f\n```\n", "def");
    assert_ne!(plain, "\"syntax.keyword\"");
    // Ruby has an alias but no bundled grammar.
    for (i, info) in ["zzz", "rb"].into_iter().enumerate() {
        let text = format!("```{info}\ndef f\n```\n");
        assert_eq!(
            face_on(&mut s, &format!("unknown{i}.md"), &text, "def"),
            plain,
            "{info}"
        );
        let rows = s.frame().text_rows().join("\n");
        assert!(
            !rows.contains("grammar") && !rows.contains("ruby"),
            "{rows}"
        );
    }
}

#[test]
fn markdown_front_matter_is_yaml_or_toml() {
    let mut s = server("");
    assert_eq!(
        face_on(&mut s, "front.md", "---\ntitle: x\n---\n# H\n", "title"),
        "\"syntax.property\""
    );
    assert_eq!(
        face_on(&mut s, "front2.md", "+++\ntitle = 1\n+++\n# H\n", "1"),
        "\"syntax.number\""
    );
}

#[test]
fn markdown_inline_syntax_is_highlighted() {
    let mut s = server("");
    let text = "# A *b* title\n\nSome *em*, **strong**, `code` and [a link](https://x.y).\n";
    for (word, face) in [
        ("em*", "syntax.text.emphasis"),
        ("b*", "syntax.text.emphasis"),
        ("strong", "syntax.text.strong"),
        ("code", "syntax.text.literal"),
        ("a link", "syntax.text.reference"),
        ("https", "syntax.text.uri"),
    ] {
        assert_eq!(
            face_on(&mut s, "inline.md", text, word),
            format!("\"{face}\""),
            "{word}"
        );
    }
    assert_eq!(face_on(&mut s, "inline.md", text, "Some"), "#false");
}

#[test]
fn embedded_languages_nest() {
    let mut s = server("");
    let text = "# Page\n\n```html\n<script>\nconst x = 1;\n</script>\n```\n";
    assert_eq!(
        face_on(&mut s, "nest.md", text, "const"),
        "\"syntax.keyword\""
    );
    assert_eq!(face_on(&mut s, "nest.md", text, "script"), "\"syntax.tag\"");
}

#[test]
fn the_other_bundled_grammars_embed_languages() {
    let mut s = server("");
    for (file, text, word, face) in [
        // A macro's body is Rust.
        (
            "inj.rs",
            "fn f() { println!(\"{}\", g(1)); }\n",
            "g(",
            "syntax.function",
        ),
        // A build phase is Bash.
        (
            "inj.nix",
            "{ buildPhase = ''\n  if true; then make; fi\n''; }\n",
            "if",
            "syntax.keyword",
        ),
        // A tagged template is its tag's language.
        (
            "inj.js",
            "const s = css`a { color: red; }`;\n",
            "color",
            "syntax.property",
        ),
        // LuaJIT's ffi.cdef is C.
        (
            "inj.lua",
            "ffi.cdef[[ int f(void); ]]\n",
            "int",
            "syntax.type",
        ),
    ] {
        assert_eq!(
            face_on(&mut s, file, text, word),
            format!("\"{face}\""),
            "{word} in {file}"
        );
    }
}

#[test]
fn yaml_toml_and_bash_are_highlighted() {
    let mut s = server("");
    for (file, text, word, face) in [
        ("hl.yaml", "name: imp # c\n", "name", "syntax.property"),
        ("hl.yaml", "name: imp # c\n", "imp", "syntax.string"),
        ("hl.yaml", "name: imp # c\n", "# c", "syntax.comment"),
        ("hl.toml", "[a]\nx = 1\n", "x", "syntax.type"),
        ("hl.toml", "[a]\nx = 1\n", "1", "syntax.number"),
        (
            "hl.sh",
            "if true; then echo \"hi\"; fi\n",
            "if",
            "syntax.keyword",
        ),
        (
            "hl.sh",
            "if true; then echo \"hi\"; fi\n",
            "\"hi\"",
            "syntax.string",
        ),
    ] {
        assert_eq!(
            face_on(&mut s, file, text, word),
            format!("\"{face}\""),
            "{word} in {file}"
        );
    }
}

#[test]
fn c_go_and_python_are_highlighted() {
    let mut s = server("");
    for (file, text, word, face) in [
        (
            "hl.c",
            "int main(void) { return 0; }\n",
            "return",
            "syntax.keyword",
        ),
        (
            "hl.go",
            "func main() { s := \"hi\" }\n",
            "func",
            "syntax.keyword",
        ),
        (
            "hl.go",
            "func main() { s := \"hi\" }\n",
            "\"hi\"",
            "syntax.string",
        ),
        (
            "hl.py",
            "def f():\n    return \"hi\"\n",
            "def",
            "syntax.keyword",
        ),
        (
            "hl.py",
            "def f():\n    return \"hi\"\n",
            "f()",
            "syntax.function",
        ),
    ] {
        assert_eq!(
            face_on(&mut s, file, text, word),
            format!("\"{face}\""),
            "{word} in {file}"
        );
    }
}

#[test]
fn lua_is_highlighted() {
    let mut s = server("");
    for (file, text, word, face) in [
        (
            "hl.lua",
            "local x = \"hi\" -- c\n",
            "local",
            "syntax.keyword",
        ),
        (
            "hl.lua",
            "local x = \"hi\" -- c\n",
            "\"hi\"",
            "syntax.string",
        ),
    ] {
        assert_eq!(
            face_on(&mut s, file, text, word),
            format!("\"{face}\""),
            "{word} in {file}"
        );
    }
}

#[test]
fn lua_text_objects() {
    let mut s = server("");
    for (i, (file, text, keys, left)) in [
        (
            "o.lua",
            "function f(a, b)\n  return a\nend\nx = 1\n",
            "jdaf",
            "\nx = 1\n",
        ),
        ("o.lua", "f(a, b)\n", "fadaa", "f(b)\n"),
    ]
    .into_iter()
    .enumerate()
    {
        let file = format!("{i}{file}");
        assert_eq!(after(&mut s, &file, text, keys), left, "{keys} in {text:?}");
    }
}

/// The text left after typing `keys` in `text`, opened as `file`.
fn after(s: &mut imp_server::Server, file: &str, text: &str, keys: &str) -> String {
    open(s, file, text);
    type_keys(s, keys);
    s.text()
}

#[test]
fn c_go_and_python_text_objects() {
    let mut s = server("");
    for (i, (file, text, keys, left)) in [
        (
            "o.c",
            "int f(int a, int b) {\n    return a;\n}\nint g;\n",
            "jdaf",
            "\nint g;\n",
        ),
        ("o.c", "struct P {\n    int x;\n};\n", "jdac", ";\n"),
        (
            "o.c",
            "int f(int a, int b) {}\n",
            "fadaa",
            "int f(int b) {}\n",
        ),
        (
            "o.go",
            "func f(a int, b int) {\n\tg()\n}\n",
            "jdif",
            "func f(a int, b int) {\n}\n",
        ),
        (
            "o.go",
            "func f(a int, b int) {}\n",
            "fadaa",
            "func f(b int) {}\n",
        ),
        ("o.go", "type P struct {\n\tx int\n}\n", "jdac", "\n"),
        (
            "o.py",
            "def f(a, b):\n    return a\n\nx = 1\n",
            "jdaf",
            "\n\nx = 1\n",
        ),
        ("o.py", "class A:\n    x = 1\n", "jdac", "\n"),
        ("o.py", "f(a, b)\n", "fadaa", "f(b)\n"),
    ]
    .into_iter()
    .enumerate()
    {
        let file = format!("{i}{file}");
        assert_eq!(after(&mut s, &file, text, keys), left, "{keys} in {text:?}");
    }
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

/// What `syntax-at` gives at the first char of `word`: the language, and
/// the kinds of the nodes around it, innermost first.
fn syntax_at(s: &mut imp_server::Server, word: &str) -> (String, Vec<String>) {
    let at = s.text().find(word).unwrap();
    let lang = s.eval(&format!("(car (syntax-at {at}))")).unwrap();
    let kinds = s
        .eval(&format!("(map car (cdr (syntax-at {at})))"))
        .unwrap()
        .trim_matches(|c| c == '(' || c == ')')
        .split_whitespace()
        .map(|w| w.trim_matches('"').to_string())
        .collect();
    (lang.trim_matches('"').to_string(), kinds)
}

#[test]
fn syntax_at_is_the_innermost_language() {
    let mut s = server("");
    open(
        &mut s,
        "at.md",
        "# Page\n\nSome text.\n\n```html\n<div><b>x</b></div>\n<script>\nlet y = 1;\n</script>\n```\n",
    );
    // A fence of HTML is HTML, its elements' names in its own tree.
    let (lang, kinds) = syntax_at(&mut s, "b>x");
    assert_eq!(lang, "html");
    assert_eq!(&kinds[..4], ["tag_name", "start_tag", "element", "element"]);
    // A <script> inside it is JavaScript.
    assert_eq!(syntax_at(&mut s, "let").0, "javascript");
    // Markdown's text is its inline grammar, and the rest Markdown's own.
    assert_eq!(syntax_at(&mut s, "Some").0, "markdown_inline");
    assert_eq!(syntax_at(&mut s, "```").0, "markdown");
    // With no tree, nothing.
    let mut s = server("plain\n");
    assert_eq!(s.eval("(syntax-at 1)").unwrap(), "()");
}
