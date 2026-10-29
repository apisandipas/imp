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
