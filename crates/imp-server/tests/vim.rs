//! Vim behavior, tested the way a client sees it: feed keys, check the
//! buffer and cursor. Each test runs on its own thread, so each gets its own
//! server.

use imp_core::Buffer;
use imp_server::{Options, Server};

fn server(text: &str) -> Server {
    Server::new(Buffer::from_text(text), Options { user_config: None }).expect("runtime loads")
}

/// Splits "dw" into ["d", "w"] and leaves "<esc>"-style names whole.
fn keys(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '<' && chars.peek().is_some_and(|c| c.is_ascii_lowercase()) {
            let mut name = String::from("<");
            for c in chars.by_ref() {
                name.push(c);
                if c == '>' {
                    break;
                }
            }
            out.push(name);
        } else {
            out.push(c.to_string());
        }
    }
    out
}

fn type_keys(s: &mut Server, input: &str) {
    let keys = keys(input);
    let refs: Vec<&str> = keys.iter().map(String::as_str).collect();
    s.keys(&refs);
    assert!(
        !s.status().starts_with("error"),
        "scheme error: {}",
        s.status()
    );
}

#[test]
fn hjkl_moves() {
    let mut s = server("abc\ndef\nghi\n");
    type_keys(&mut s, "ljj");
    assert_eq!(s.cursor(), 9); // line 2, col 1
    type_keys(&mut s, "kh");
    assert_eq!(s.cursor(), 4); // line 1, col 0
}

#[test]
fn h_and_l_stop_at_line_edges() {
    let mut s = server("ab\ncd\n");
    type_keys(&mut s, "hlllll");
    assert_eq!(s.cursor(), 1); // last char of "ab", not the newline
}

#[test]
fn j_keeps_goal_column() {
    let mut s = server("abcdef\nx\nabcdef\n");
    type_keys(&mut s, "$jj");
    assert_eq!(s.cursor(), 14); // col 5 of line 3 after passing a short line
}

#[test]
fn dw_deletes_a_word() {
    let mut s = server("one two three\n");
    type_keys(&mut s, "dw");
    assert_eq!(s.text(), "two three\n");
}

#[test]
fn dot_repeats_dw() {
    let mut s = server("one two three\n");
    type_keys(&mut s, "dw.");
    assert_eq!(s.text(), "three\n");
}

#[test]
fn dw_on_last_word_keeps_newline() {
    let mut s = server("one two\nthree\n");
    type_keys(&mut s, "wdw");
    assert_eq!(s.text(), "one \nthree\n");
}

#[test]
fn counts_multiply() {
    let mut s = server("a b c d e f g\n");
    type_keys(&mut s, "2d2w");
    assert_eq!(s.text(), "e f g\n");
}

#[test]
fn dd_and_dot() {
    let mut s = server("1\n2\n3\n4\n");
    type_keys(&mut s, "dd.");
    assert_eq!(s.text(), "3\n4\n");
}

#[test]
fn dd_on_last_line() {
    let mut s = server("1\n2\n");
    type_keys(&mut s, "jdd");
    assert_eq!(s.text(), "1\n");
}

#[test]
fn insert_and_dot_repeats_the_text() {
    let mut s = server("x\n");
    type_keys(&mut s, "ihi <esc>.");
    assert_eq!(s.text(), "hihi  x\n");
}

#[test]
fn change_word_and_dot() {
    let mut s = server("foo foo\n");
    type_keys(&mut s, "cwbar<esc>w.");
    assert_eq!(s.text(), "bar bar\n");
}

#[test]
fn undo_takes_back_a_whole_insert() {
    let mut s = server("x\n");
    type_keys(&mut s, "ihello<esc>u");
    assert_eq!(s.text(), "x\n");
    s.keys(&["C-r"]);
    assert_eq!(s.text(), "hellox\n");
}

#[test]
fn yank_and_paste_lines() {
    let mut s = server("a\nb\n");
    type_keys(&mut s, "yyjp");
    assert_eq!(s.text(), "a\nb\na\n");
}

#[test]
fn x_and_paste() {
    let mut s = server("ab\n");
    type_keys(&mut s, "xp");
    assert_eq!(s.text(), "ba\n");
}

#[test]
fn open_line_below() {
    let mut s = server("a\nc\n");
    type_keys(&mut s, "ob<esc>");
    assert_eq!(s.text(), "a\nb\nc\n");
}

#[test]
fn gg_and_g() {
    let mut s = server("1\n2\n3\n");
    type_keys(&mut s, "G");
    assert_eq!(s.cursor(), 4);
    type_keys(&mut s, "gg");
    assert_eq!(s.cursor(), 0);
    type_keys(&mut s, "2G");
    assert_eq!(s.cursor(), 2);
}

#[test]
fn quit_refuses_unsaved_changes() {
    let mut s = server("a\n");
    type_keys(&mut s, "x:q<ret>");
    assert!(!s.should_quit());
    type_keys(&mut s, ":q!<ret>");
    assert!(s.should_quit());
}

#[test]
fn dd_last_line_then_paste() {
    let mut s = server("1\n2\n");
    type_keys(&mut s, "jddP");
    assert_eq!(s.text(), "2\n1\n");
}

#[test]
fn paste_line_into_file_without_final_newline() {
    let mut s = server("a\nb");
    type_keys(&mut s, "yyjp");
    assert_eq!(s.text(), "a\nb\na");
}

#[test]
fn cc_on_last_line_keeps_previous_line() {
    let mut s = server("a\nb\n");
    type_keys(&mut s, "jccX<esc>");
    assert_eq!(s.text(), "a\nX\n");
}

#[test]
fn d_to_end_and_start_of_file() {
    let mut s = server("1\n2\n3\n");
    type_keys(&mut s, "jdG");
    assert_eq!(s.text(), "1\n");
    let mut s = server("1\n2\n3\n");
    type_keys(&mut s, "jdgg");
    assert_eq!(s.text(), "3\n");
}

#[test]
fn inner_and_a_word() {
    let mut s = server("one two three\n");
    type_keys(&mut s, "wdiw");
    assert_eq!(s.text(), "one  three\n");
    let mut s = server("one two three\n");
    type_keys(&mut s, "wdaw");
    assert_eq!(s.text(), "one three\n");
    // The last word has no white space after it, so aw takes the space before.
    let mut s = server("one two\n");
    type_keys(&mut s, "wdaw");
    assert_eq!(s.text(), "one\n");
    // Counts cover word and white space runs.
    let mut s = server("a b c d\n");
    type_keys(&mut s, "d3iw");
    assert_eq!(s.text(), " c d\n");
}

#[test]
fn inner_word_on_punctuation_and_words() {
    let mut s = server("foo.bar baz\n");
    type_keys(&mut s, "ldiw");
    assert_eq!(s.text(), ".bar baz\n");
    let mut s = server("foo.bar baz\n");
    type_keys(&mut s, "ldiW");
    assert_eq!(s.text(), " baz\n");
}

#[test]
fn change_inner_word_and_dot() {
    let mut s = server("foo bar\n");
    type_keys(&mut s, "ciwx<esc>w.");
    assert_eq!(s.text(), "x x\n");
}

#[test]
fn quote_objects() {
    let mut s = server("say \"hello there\" now\n");
    type_keys(&mut s, "5ldi\"");
    assert_eq!(s.text(), "say \"\" now\n");
    let mut s = server("say \"hello\" now\n");
    type_keys(&mut s, "8lda\"");
    assert_eq!(s.text(), "say now\n");
    // Before the first quote, the next quoted string on the line is used.
    let mut s = server("x = 'abc'\n");
    type_keys(&mut s, "ci'z<esc>");
    assert_eq!(s.text(), "x = 'z'\n");
}

#[test]
fn bracket_objects() {
    let mut s = server("f(a, (b), c)\n");
    type_keys(&mut s, "6ldi(");
    assert_eq!(s.text(), "f(a, (), c)\n");
    let mut s = server("f(a, (b), c)\n");
    type_keys(&mut s, "6ld2i(");
    assert_eq!(s.text(), "f()\n");
    let mut s = server("x[1] y\n");
    type_keys(&mut s, "lda]");
    assert_eq!(s.text(), "x y\n");
    let mut s = server("f(a)\n");
    type_keys(&mut s, "$dib");
    assert_eq!(s.text(), "f()\n");
}

#[test]
fn inner_block_on_own_lines_is_linewise() {
    let mut s = server("if x {\n    a\n    b\n}\n");
    type_keys(&mut s, "jdi{");
    assert_eq!(s.text(), "if x {\n}\n");
    let mut s = server("if x {\n    a\n}\n");
    type_keys(&mut s, "jyi{Gp");
    assert_eq!(s.text(), "if x {\n    a\n}\n    a\n");
}

#[test]
fn tag_objects() {
    let mut s = server("<a><b>text</b></a>\n");
    type_keys(&mut s, "7ldit");
    assert_eq!(s.text(), "<a><b></b></a>\n");
    let mut s = server("<a><b>text</b></a>\n");
    type_keys(&mut s, "7ld2it");
    assert_eq!(s.text(), "<a></a>\n");
    let mut s = server("<a><b>text</b></a>\n");
    type_keys(&mut s, "7ldat");
    assert_eq!(s.text(), "<a></a>\n");
}

#[test]
fn paragraph_objects() {
    let mut s = server("a\nb\n\nc\n");
    type_keys(&mut s, "dip");
    assert_eq!(s.text(), "\nc\n");
    let mut s = server("a\nb\n\nc\n");
    type_keys(&mut s, "dap");
    assert_eq!(s.text(), "c\n");
    // No blank lines after the last paragraph: ap takes the ones before.
    let mut s = server("a\n\nc\n");
    type_keys(&mut s, "Gdap");
    assert_eq!(s.text(), "a\n");
}
