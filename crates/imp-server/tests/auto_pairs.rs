//! Auto pairs (docs/specs/auto-pairs.md): typing an opening bracket or
//! quote also types its closer.

mod common;

use common::*;
use imp_core::ClientMsg;

/// The text after typing `keys` in a buffer holding `text`, and where the
/// cursor is.
fn typed(text: &str, keys: &str) -> (String, usize) {
    let mut s = server(text);
    type_keys(&mut s, keys);
    (s.text(), s.cursor())
}

#[test]
fn an_opener_types_its_closer() {
    for (open, pair) in [
        ("(", "()"),
        ("[", "[]"),
        ("{", "{}"),
        ("\"", "\"\""),
        ("'", "''"),
        ("`", "``"),
    ] {
        // The cursor stays between them.
        assert_eq!(
            typed("\n", &format!("i{open}")),
            (format!("{pair}\n"), 1),
            "{open}"
        );
    }
}

#[test]
fn only_before_a_gap() {
    // White space, the end of the line, a closing bracket, , ; : .
    assert_eq!(typed(" x\n", "i(").0, "() x\n");
    assert_eq!(typed("x\n", "A(").0, "x()\n");
    for after in [")", "]", "}", ",", ";", ":", "."] {
        assert_eq!(typed(&format!("{after}\n"), "i(").0, format!("(){after}\n"));
    }
    // Before a word, only the opener.
    assert_eq!(typed("foo\n", "i(").0, "(foo\n");
    assert_eq!(typed("foo\n", "i\"").0, "\"foo\n");
    // A quote isn't a closing bracket.
    assert_eq!(typed("\"\n", "i(").0, "(\"\n");
}

#[test]
fn a_quote_does_not_pair_after_a_letter_or_digit() {
    assert_eq!(typed("don\n", "A'").0, "don'\n");
    assert_eq!(typed("x2\n", "A\"").0, "x2\"\n");
    // After other chars it does, and a bracket pairs after a letter.
    assert_eq!(typed("x \n", "A'").0, "x ''\n");
    assert_eq!(typed("f_\n", "A\"").0, "f_\"\"\n");
    assert_eq!(typed("f\n", "A(").0, "f()\n");
}

#[test]
fn the_options_turn_it_off_and_choose_the_pairs() {
    let mut s = server("\n");
    s.eval("(set-option! 'auto-pairs #f)").unwrap();
    type_keys(&mut s, "i(\"");
    assert_eq!(s.text(), "(\"\n");
    let mut s = server("\n");
    s.eval("(set-local-option! 'auto-pairs-chars \"()<>\")")
        .unwrap();
    type_keys(&mut s, "i[<<esc>");
    assert_eq!(s.text(), "[<>\n");
}

#[test]
fn replace_mode_pastes_and_registers_do_not_pair() {
    assert_eq!(typed("abc\n", "R(").0, "(bc\n");
    // C-r inserts a register's text as it is.
    assert_eq!(typed("(x\n", "yli<C-r>0<esc>").0, "((x\n");
    let mut s = server("\n");
    type_keys(&mut s, "i");
    s.handle(ClientMsg::Paste("f(".into()));
    type_keys(&mut s, "<esc>");
    assert_eq!(s.text(), "f(\n");
    // Nor when . types the paste again.
    let mut s = server("\n");
    type_keys(&mut s, "i");
    s.handle(ClientMsg::Paste("(".into()));
    type_keys(&mut s, "<esc>.");
    assert_eq!(s.text(), "((\n");
}

#[test]
fn typing_a_closer_it_added_steps_over_it() {
    assert_eq!(typed("\n", "i(x)").0, "(x)\n");
    assert_eq!(typed("\n", "i\"hi\"").0, "\"hi\"\n");
    // Nested, each in turn, with the cursor past both.
    assert_eq!(typed("\n", "if([a])").0, "f([a])\n");
    assert_eq!(typed("\n", "if([a]);<esc>").0, "f([a]);\n");
    // A closer already in the buffer is typed, as Vim does.
    assert_eq!(typed(")\n", "i)").0, "))\n");
    // Forgotten once insert mode ends.
    assert_eq!(typed("\n", "i(<esc>a)").0, "())\n");
}

#[test]
fn a_pair_is_forgotten_when_the_cursor_leaves_it() {
    // Out and back in with the arrows.
    assert_eq!(typed("\n", "i(<left><right>)").0, "())\n");
    // Deleting its opener.
    assert_eq!(typed("\n", "ia(b<left><bs><right>)").0, "ab))\n");
}

#[test]
fn backspace_deletes_an_empty_pair_it_added() {
    assert_eq!(typed("\n", "ix(<bs>").0, "x\n");
    assert_eq!(typed("\n", "i([<bs><bs>").0, "\n");
    // Emptied again, it still is one.
    assert_eq!(typed("\n", "i(a<bs><bs>").0, "\n");
    // Not with something between them, nor a pair already there.
    assert_eq!(typed("\n", "i(a<left><bs>").0, "a)\n");
    assert_eq!(typed("()\n", "a<bs>").0, ")\n");
}

#[test]
fn undo_and_repeat_take_the_pair_with_the_insert() {
    let mut s = server("\n");
    type_keys(&mut s, "Af(x)<esc>");
    assert_eq!(s.text(), "f(x)\n");
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "\n");
    type_keys(&mut s, "<C-r>");
    assert_eq!(s.text(), "f(x)\n");
    type_keys(&mut s, ".");
    assert_eq!(s.text(), "f(x)f(x)\n");
}

#[test]
fn return_inside_braces_opens_a_line() {
    let mut s = server("\n");
    s.eval("(set-option! 'smartindent #t) (set-option! 'shiftwidth 2) (set-option! 'expandtab #t)")
        .unwrap();
    type_keys(&mut s, "ifn {<ret>x<esc>");
    assert_eq!(s.text(), "fn {\n  x\n}\n");
}

/// The text after typing `keys` in a file named `name` holding `text`, so
/// it has its mode and syntax tree.
fn typed_in(name: &str, text: &str, keys: &str) -> String {
    let path = temp_path(name);
    std::fs::write(&path, text).unwrap();
    let mut s = server("");
    type_keys(&mut s, &format!(":e {}<ret>", path.display()));
    type_keys(&mut s, keys);
    s.text()
}

#[test]
fn a_quote_does_not_pair_in_a_string_or_comment() {
    // Rust: in a string, in a line comment (at its end too) and a block one.
    let rs = |keys| typed_in("pairs.rs", "let s = \"a b\";\n// see\n/* x */\n", keys);
    assert_eq!(rs("fbi`"), "let s = \"a `b\";\n// see\n/* x */\n");
    assert_eq!(rs("jA \""), "let s = \"a b\";\n// see \"\n/* x */\n");
    assert_eq!(rs("jjf a`"), "let s = \"a b\";\n// see\n/* `x */\n");
    // Past the string, it pairs again.
    assert_eq!(rs("f;i `"), "let s = \"a b\" ``;\n// see\n/* x */\n");
    // Scheme's strings and comments too.
    let scm = |keys| typed_in("pairs.scm", "(f \"a  b\") ; c\n", keys);
    assert_eq!(scm("2f a\""), "(f \"a \" b\") ; c\n");
    assert_eq!(scm("A \""), "(f \"a  b\") ; c \"\n");
    // Brackets still pair in both.
    assert_eq!(rs("jA ("), "let s = \"a b\";\n// see ()\n/* x */\n");
    // With no tree, only the letter-or-digit rule.
    assert_eq!(typed("\"a  b\"\n", "f a\""), ("\"a \"\" b\"\n".into(), 4));
}

#[test]
fn each_mode_has_its_pairs() {
    let all = "()[]{}\"\"''``";
    // What each of the six types at the start of an empty file.
    let pairs = |name: &str| {
        all.chars()
            .step_by(2)
            .filter(|c| typed_in(name, "\n", &format!("i{c}")).len() == 3)
            .collect::<String>()
    };
    assert_eq!(pairs("p.py"), "([{\"'`");
    assert_eq!(pairs("p.ts"), "([{\"'`");
    assert_eq!(pairs("p.rs"), "([{\"`");
    assert_eq!(pairs("p.scm"), "([{\"");
    assert_eq!(pairs("p.lisp"), "([{\"");
    assert_eq!(pairs("p.txt"), "([{\"");
    assert_eq!(pairs("p.org"), "([{\"");
    assert_eq!(pairs("p.md"), "([{\"`");
    // In a Markdown code fence, Markdown's.
    assert_eq!(
        typed_in("fence.md", "```rust\nx\n```\n", "jA '`"),
        "```rust\nx '``\n```\n"
    );
}

#[test]
fn the_repl_pairs_as_scheme_does() {
    let mut s = server("");
    type_keys(&mut s, ":repl<ret>'(");
    assert!(s.text().ends_with("imp> '()"), "{:?}", s.text());
}

#[test]
fn the_users_choice_wins_over_the_modes() {
    // Set globally, no mode changes it.
    let path = temp_path("chosen.rs");
    std::fs::write(&path, "\n").unwrap();
    let mut s = server("");
    s.eval("(set-option! 'auto-pairs-chars \"()''\")").unwrap();
    type_keys(&mut s, &format!(":e {}<ret>i'[", path.display()));
    assert_eq!(s.text(), "'['\n");
    // Or set for one buffer.
    let mut s = server("");
    type_keys(&mut s, &format!(":e {}<ret>", path.display()));
    s.eval("(set-local-option! 'auto-pairs-chars \"[]\")")
        .unwrap();
    type_keys(&mut s, "i([");
    assert_eq!(s.text(), "([]\n");
}

/// A server in the Emacs state.
fn emacs(text: &str) -> imp_server::Server {
    let mut s = server(text);
    s.keys(&["C-z"]);
    s
}

#[test]
fn the_emacs_state_pairs_too() {
    let mut s = emacs("\n");
    // Keys go one at a time, as type_keys would read C-... as a chord.
    for k in ["f", "(", "x", ")", ";"] {
        s.keys(&[k]);
    }
    assert_eq!(s.text(), "f(x);\n");
    // <bs> in an empty pair it added deletes both.
    let mut s = emacs("\n");
    s.keys(&["a", "[", "<bs>"]);
    assert_eq!(s.text(), "a\n");
    // A closer already there is typed.
    let mut s = emacs(")\n");
    s.keys(&[")"]);
    assert_eq!(s.text(), "))\n");
    // The pair undoes with the typing around it.
    let mut s = emacs("\n");
    s.keys(&["f", "(", "x", ")", "C-/"]);
    assert_eq!(s.text(), "\n");
}

#[test]
fn the_emacs_state_wraps_the_region() {
    // A quote wraps too, even after a letter.
    for k in ["\"", "("] {
        let mut s = emacs("one two\n");
        s.keys(&["C- ", "M-f", k]);
        let closer = if k == "(" { ")" } else { "\"" };
        assert_eq!(s.text(), format!("{k}one{closer} two\n"));
        // The cursor is after the closer, and the region is gone.
        assert_eq!(s.cursor(), 5);
        assert_eq!(s.eval("(region)").unwrap(), "#false");
    }
    // In one undo step, apart from typing before it.
    let mut s = emacs("one two\n");
    s.keys(&["x", "C- ", "M-f", "[", "C-/"]);
    assert_eq!(s.text(), "xone two\n");
    // With auto-pairs off, the region is dropped and ( typed at the
    // cursor, as before.
    let mut s = emacs("one two\n");
    s.eval("(set-option! 'auto-pairs #f)").unwrap();
    s.keys(&["C- ", "M-f", "("]);
    assert_eq!(s.text(), "one( two\n");
}

/// Types `text` a char at a time, so `<div>` isn't read as a key name.
fn type_text(s: &mut imp_server::Server, text: &str) {
    for c in text.chars() {
        s.keys(&[&c.to_string()]);
    }
}

/// The text after opening `name` holding `text`, typing `keys`, then
/// typing `text_typed` a char at a time; and the cursor.
fn tags(name: &str, text: &str, keys: &str, typed: &str) -> (String, usize) {
    // A file of its own: tests run in parallel.
    static N: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
    let n = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let path = temp_path(&format!("{n}-{name}"));
    std::fs::write(&path, text).unwrap();
    let mut s = server("");
    type_keys(&mut s, &format!(":e {}<ret>", path.display()));
    type_keys(&mut s, keys);
    type_text(&mut s, typed);
    (s.text(), s.cursor())
}

#[test]
fn a_start_tags_angle_closes_it() {
    // The cursor stays between them.
    assert_eq!(
        tags("t.html", "\n", "i", "<div class=\"x\">"),
        ("<div class=\"x\"></div>\n".into(), 15)
    );
    // Inside another element, and on a line of its own.
    assert_eq!(
        tags("t.html", "<p>a</p>\n", "fai", "<b>").0,
        "<p><b></b>a</p>\n"
    );
    assert_eq!(
        tags("t.html", "<ul>\n</ul>\n", "o", "<li>").0,
        "<ul>\n<li></li>\n</ul>\n"
    );
    // Typed inside one of the same name, whose end tag the parser gives
    // the new one.
    assert_eq!(
        tags("t.html", "<div></div>\n", "f>a", "<div>").0,
        "<div><div></div></div>\n"
    );
}

#[test]
fn some_tags_are_not_closed() {
    // Self-closing, and HTML's void elements, whatever their case.
    assert_eq!(tags("t.html", "\n", "i", "<x/>").0, "<x/>\n");
    for void in ["<br>", "<img src=\"a.png\">", "<input>", "<BR>"] {
        assert_eq!(tags("t.html", "\n", "i", void).0, format!("{void}\n"));
    }
    // One that has its end tag: > typed again after deleting it.
    assert_eq!(tags("t.html", "<b></b>\n", "f>xi", ">").0, "<b></b>\n");
    // Not a tag at all.
    assert_eq!(tags("t.html", "\n", "i", "a -> b").0, "a -> b\n");
    // In XML and SVG, a void element's name is closed like any other.
    assert_eq!(tags("t.xml", "\n", "i", "<br>").0, "<br></br>\n");
    assert_eq!(tags("t.svg", "\n", "i", "<g>").0, "<g></g>\n");
    // Nor in a file of another language.
    assert_eq!(tags("t.txt", "\n", "i", "<b>").0, "<b>\n");
}

#[test]
fn the_option_turns_end_tags_off() {
    let path = temp_path("off.html");
    std::fs::write(&path, "\n").unwrap();
    let mut s = server("");
    s.eval("(set-option! 'auto-close-tags #f)").unwrap();
    type_keys(&mut s, &format!(":e {}<ret>i", path.display()));
    type_text(&mut s, "<b>");
    assert_eq!(s.text(), "<b>\n");
}

#[test]
fn an_end_tag_undoes_and_repeats_with_the_insert() {
    let path = temp_path("undo.html");
    std::fs::write(&path, "\n").unwrap();
    let mut s = server("");
    type_keys(&mut s, &format!(":e {}<ret>A", path.display()));
    type_text(&mut s, "<b>x");
    type_keys(&mut s, "<esc>");
    assert_eq!(s.text(), "<b>x</b>\n");
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "\n");
    type_keys(&mut s, "<C-r>.");
    assert_eq!(s.text(), "<b>x</b><b>x</b>\n");
}

#[test]
fn the_emacs_state_closes_tags_too() {
    let path = temp_path("emacs.html");
    std::fs::write(&path, "\n").unwrap();
    let mut s = server("");
    type_keys(&mut s, &format!(":e {}<ret>", path.display()));
    s.keys(&["C-z"]);
    type_text(&mut s, "<p>");
    assert_eq!(s.text(), "<p></p>\n");
}

#[test]
fn a_slash_after_a_less_than_closes_the_open_element() {
    // The cursor goes past the end tag.
    assert_eq!(
        tags("t.html", "<div>\n", "A", "x</"),
        ("<div>x</div>\n".into(), 12)
    );
    // The innermost open one, not one that has its end tag.
    assert_eq!(
        tags("t.html", "<ul>\n<li>a\n</ul>\n", "jA", "</").0,
        "<ul>\n<li>a</li>\n</ul>\n"
    );
    // Then the next one out.
    assert_eq!(
        tags("t.html", "<p><b>\n", "A", "x</</").0,
        "<p><b>x</b></p>\n"
    );
    // With none open, or / not right after <, only the /.
    assert_eq!(tags("t.html", "\n", "i", "</").0, "</\n");
    assert_eq!(
        tags("t.html", "<div></div>\n", "f>a", "</").0,
        "<div></</div>\n"
    );
    assert_eq!(tags("t.html", "<div>\n", "A", "a/").0, "<div>a/\n");
}

#[test]
fn a_markdown_fence_of_html_closes_tags() {
    let text = "Text\n\n```html\n<div>\n```\n";
    // In the fence, as in an HTML file, void elements included.
    assert_eq!(
        tags("f.md", text, "jjjA", "<b>").0,
        "Text\n\n```html\n<div><b></b>\n```\n"
    );
    assert_eq!(
        tags("f.md", text, "jjjA", "x</").0,
        "Text\n\n```html\n<div>x</div>\n```\n"
    );
    assert_eq!(
        tags("f.md", text, "jjjA", "<br>").0,
        "Text\n\n```html\n<div><br>\n```\n"
    );
    // Outside it, < and > are plain, even around a tag.
    assert_eq!(
        tags("f.md", text, "A", " <b>").0,
        "Text <b>\n\n```html\n<div>\n```\n"
    );
    // And a fence of another language is that language's.
    assert_eq!(
        tags("f.md", "```rust\nx\n```\n", "jA", " <T>").0,
        "```rust\nx <T>\n```\n"
    );
}

#[test]
fn jsx_elements_close_too() {
    // An element, with the cursor between, and a fragment.
    assert_eq!(
        tags("j.tsx", "const a = \n", "A", "<div className=\"x\">"),
        ("const a = <div className=\"x\"></div>\n".into(), 29)
    );
    assert_eq!(
        tags("j.tsx", "const a = \n", "A", "<>").0,
        "const a = <></>\n"
    );
    assert_eq!(
        tags("j.jsx", "const a = \n", "A", "<Foo.Bar>").0,
        "const a = <Foo.Bar></Foo.Bar>\n"
    );
    // Inside another, whose end tag the parser gives the new one.
    assert_eq!(
        tags("j.jsx", "const a = (\n  <ul>\n  </ul>\n);\n", "jA", "<li>").0,
        "const a = (\n  <ul><li></li>\n  </ul>\n);\n"
    );
    assert_eq!(
        tags("j.tsx", "const a = <div></div>;\n", "f>a", "<div>").0,
        "const a = <div><div></div></div>;\n"
    );
    // Self-closing, and one with its end tag already.
    assert_eq!(
        tags("j.tsx", "const a = \n", "A", "<br />").0,
        "const a = <br />\n"
    );
    assert_eq!(
        tags("j.tsx", "const a = <b></b>;\n", "f>xi", ">").0,
        "const a = <b></b>;\n"
    );
    // </ closes the innermost open one, a fragment too.
    assert_eq!(
        tags("j.tsx", "const a = <div>\n", "A", "x</").0,
        "const a = <div>x</div>\n"
    );
    assert_eq!(
        tags("j.tsx", "const a = <>\n", "A", "x</").0,
        "const a = <>x</>\n"
    );
}

#[test]
fn generics_and_comparisons_are_not_tags() {
    assert_eq!(tags("g.tsx", "f\n", "A", "<T>").0, "f<T>\n");
    assert_eq!(tags("g.ts", "f\n", "A", "<T>").0, "f<T>\n");
    assert_eq!(
        tags("g.tsx", "let x: Array\n", "A", "<string>").0,
        "let x: Array<string>\n"
    );
    assert_eq!(
        tags("g.js", "if (a \n", "A", "< b && c > d) {}").0,
        "if (a < b && c > d) {}\n"
    );
}
