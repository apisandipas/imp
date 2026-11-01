//! Vim behavior, tested the way a client sees it: feed keys, check the
//! buffer and cursor. Each test runs on its own thread, so each gets its own
//! server.

mod common;

use common::*;
use imp_server::Server;

#[test]
fn hjkl_moves() {
    let mut s = server("abc\ndef\nghi\n");
    type_keys(&mut s, "ljj");
    assert_eq!(s.cursor(), 9); // line 2, col 1
    type_keys(&mut s, "kh");
    assert_eq!(s.cursor(), 4); // line 1, col 0
}

#[test]
fn motions_that_cannot_move_cancel_operators() {
    let mut s = server("a\nb\n");
    type_keys(&mut s, "jdj");
    assert_eq!(s.text(), "a\nb\n");
    type_keys(&mut s, "dh");
    assert_eq!(s.text(), "a\nb\n");
    let mut s = server("\nb\n");
    type_keys(&mut s, "x");
    assert_eq!(s.text(), "\nb\n");
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

#[test]
fn visual_delete_and_yank() {
    let mut s = server("one two three\n");
    type_keys(&mut s, "wvlld");
    assert_eq!(s.text(), "one  three\n");
    let mut s = server("one two\n");
    type_keys(&mut s, "vey$p");
    assert_eq!(s.text(), "one twoone\n");
}

#[test]
fn visual_selection_is_highlighted() {
    let mut s = server("abcdef\n");
    type_keys(&mut s, "lvll");
    let row = &s.frame().rows[0];
    let texts: Vec<&str> = row.iter().map(|span| span.text.as_str()).collect();
    assert_eq!(texts, ["a", "bcd", "ef"]);
    assert!(row[1].style.bg.is_some());
    type_keys(&mut s, "<esc>");
    assert_eq!(s.frame().rows[0].len(), 1);
}

#[test]
fn visual_line_delete_and_change() {
    let mut s = server("1\n2\n3\n4\n");
    type_keys(&mut s, "jVjd");
    assert_eq!(s.text(), "1\n4\n");
    let mut s = server("1\n2\n3\n");
    type_keys(&mut s, "Vjcx<esc>");
    assert_eq!(s.text(), "x\n3\n");
    // x on a whole-line selection deletes the lines.
    let mut s = server("1\n2\n");
    type_keys(&mut s, "Vx");
    assert_eq!(s.text(), "2\n");
}

#[test]
fn visual_o_swaps_ends() {
    let mut s = server("abcdef\n");
    type_keys(&mut s, "llvlohd");
    assert_eq!(s.text(), "aef\n");
}

#[test]
fn visual_backwards_selection() {
    let mut s = server("abcdef\n");
    type_keys(&mut s, "$vhhd");
    assert_eq!(s.text(), "abc\n");
}

#[test]
fn visual_text_objects() {
    let mut s = server("foo (bar baz) qux\n");
    type_keys(&mut s, "6lvi(d");
    assert_eq!(s.text(), "foo () qux\n");
    let mut s = server("one two three\n");
    type_keys(&mut s, "wvawd");
    assert_eq!(s.text(), "one three\n");
    // ip selects lines, so the selection becomes linewise.
    let mut s = server("a\nb\n\nc\n");
    type_keys(&mut s, "vipd");
    assert_eq!(s.text(), "\nc\n");
}

#[test]
fn visual_dot_repeats_same_size() {
    let mut s = server("abcdefgh\n");
    type_keys(&mut s, "vld.");
    assert_eq!(s.text(), "efgh\n");
    let mut s = server("1\n2\n3\n4\n5\n");
    type_keys(&mut s, "Vjd.");
    assert_eq!(s.text(), "5\n");
}

#[test]
fn visual_paste_replaces_selection() {
    let mut s = server("one two\n");
    type_keys(&mut s, "yiwwviwp");
    assert_eq!(s.text(), "one one\n");
    // The replaced text is now in the register.
    type_keys(&mut s, "0P");
    assert_eq!(s.text(), "twoone one\n");
}

#[test]
fn gv_reselects() {
    let mut s = server("abcdef\n");
    type_keys(&mut s, "vl<esc>$gvd");
    assert_eq!(s.text(), "cdef\n");
}

#[test]
fn v_toggles_and_switches_kind() {
    let mut s = server("ab\ncd\n");
    type_keys(&mut s, "vv");
    assert!(status_row(&mut s).contains("NORMAL"));
    type_keys(&mut s, "vVd");
    assert_eq!(s.text(), "cd\n");
}

#[test]
fn search_forward_and_back() {
    let mut s = server("foo bar\nbaz bar\n");
    type_keys(&mut s, "/bar<ret>");
    assert_eq!(s.cursor(), 4);
    type_keys(&mut s, "n");
    assert_eq!(s.cursor(), 12);
    // n wraps to the top.
    type_keys(&mut s, "n");
    assert_eq!(s.cursor(), 4);
    assert!(s.status().contains("BOTTOM"));
    type_keys(&mut s, "N");
    assert_eq!(s.cursor(), 12);
    type_keys(&mut s, "gg?ba<ret>");
    assert_eq!(s.cursor(), 12);
}

#[test]
fn search_not_found_stays_put() {
    let mut s = server("abc\n");
    type_keys(&mut s, "l/zzz<ret>");
    assert_eq!(s.cursor(), 1);
    assert!(s.status().contains("Pattern not found"));
}

#[test]
fn search_bad_pattern_reports() {
    let mut s = server("abc\n");
    type_keys(&mut s, "/\\(<ret>");
    assert!(s.status().contains("bad pattern"), "{}", s.status());
}

#[test]
fn search_is_a_motion() {
    let mut s = server("one two three\n");
    type_keys(&mut s, "d/thr<ret>");
    assert_eq!(s.text(), "three\n");
    let mut s = server("a x b x c x\n");
    type_keys(&mut s, "d/x<ret>.");
    assert_eq!(s.text(), "x c x\n");
    let mut s = server("one two three\n");
    type_keys(&mut s, "dn");
    assert!(s.status().contains("no previous"));
}

#[test]
fn incremental_search_previews_and_escape_restores() {
    let mut s = server("abc xyz\n");
    type_keys(&mut s, "/xy");
    assert_eq!(s.cursor(), 4);
    type_keys(&mut s, "<esc>");
    assert_eq!(s.cursor(), 0);
}

#[test]
fn search_highlights_matches_until_noh() {
    let mut s = server("ab ab\n");
    type_keys(&mut s, "/ab<ret>");
    let row = &s.frame().rows[0];
    assert_eq!(row.len(), 3); // ab, space, ab
    type_keys(&mut s, ":noh<ret>");
    assert_eq!(s.frame().rows[0].len(), 1);
}

#[test]
fn star_and_hash_search_the_word() {
    let mut s = server("foo bar foobar foo\n");
    type_keys(&mut s, "*");
    assert_eq!(s.cursor(), 15); // whole word only, skipping foobar
    type_keys(&mut s, "#");
    assert_eq!(s.cursor(), 0);
    type_keys(&mut s, "g*");
    assert_eq!(s.cursor(), 8);
}

#[test]
fn visual_search_extends_selection() {
    let mut s = server("abc def ghi\n");
    type_keys(&mut s, "v/gh<ret>d");
    assert_eq!(s.text(), "hi\n");
}

#[test]
fn substitute() {
    let mut s = server("a a\na a\n");
    type_keys(&mut s, ":s/a/b/<ret>");
    assert_eq!(s.text(), "b a\na a\n");
    type_keys(&mut s, ":%s/a/c/g<ret>");
    assert_eq!(s.text(), "b c\nc c\n");
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "b a\na a\n");
}

#[test]
fn substitute_groups_ranges_and_delimiters() {
    let mut s = server("x=1\ny=2\nz=3\n");
    type_keys(&mut s, ":2,3s/\\(\\w\\)=\\(\\d\\)/\\2=\\1/<ret>");
    assert_eq!(s.text(), "x=1\n2=y\n3=z\n");
    let mut s = server("a/b\n");
    type_keys(&mut s, ":s#/#\\\\#<ret>");
    assert_eq!(s.text(), "a\\b\n");
    let mut s = server("one\n");
    type_keys(&mut s, ":s/n/&&/<ret>");
    assert_eq!(s.text(), "onne\n");
}

#[test]
fn substitute_on_visual_lines() {
    let mut s = server("a\na\na\n");
    type_keys(&mut s, "jVj:s/a/b/<ret>");
    assert_eq!(s.text(), "a\nb\nb\n");
}

#[test]
fn substitute_empty_pattern_uses_last_search() {
    let mut s = server("foo bar\n");
    type_keys(&mut s, "/bar<ret>:s//baz/<ret>");
    assert_eq!(s.text(), "foo baz\n");
}

#[test]
fn substitute_with_line_breaks() {
    let mut s = server("a,b\n");
    type_keys(&mut s, ":s/,/\\r/<ret>");
    assert_eq!(s.text(), "a\nb\n");
}

#[test]
fn ex_ranges() {
    let mut s = server("1\n2\n3\n4\n5\n");
    type_keys(&mut s, ":2,4d<ret>");
    assert_eq!(s.text(), "1\n5\n");
    let mut s = server("1\n2\n3\n4\n5\n");
    type_keys(&mut s, ":.,.+1d<ret>");
    assert_eq!(s.text(), "3\n4\n5\n");
    let mut s = server("1\n2\n3\n4\n5\n");
    type_keys(&mut s, ":$<ret>");
    assert_eq!(s.cursor(), 8);
    type_keys(&mut s, ":/2/<ret>");
    assert_eq!(s.cursor(), 2);
    type_keys(&mut s, ":4<ret>");
    assert_eq!(s.cursor(), 6);
    type_keys(&mut s, "2:d<ret>");
    assert_eq!(s.text(), "1\n2\n3\n");
}

#[test]
fn eval_runs_scheme() {
    let mut s = server("x\n");
    type_keys(&mut s, ":eval (+ 1 2)<ret>");
    assert_eq!(s.status(), "3");
    type_keys(
        &mut s,
        ":eval (define-key! 'normal \"Q\" (lambda (n) (set-status! \"hi\")))<ret>Q",
    );
    assert_eq!(s.status(), "hi");
}

#[test]
fn cmdline_editing_keys() {
    let mut s = server("1\n2\n3\n");
    type_keys(&mut s, ":foo bar");
    s.keys(&["C-w", "C-w"]);
    type_keys(&mut s, "3<ret>");
    assert_eq!(s.cursor(), 4);
}

#[test]
fn find_and_till() {
    let mut s = server("a,b,c,d\n");
    type_keys(&mut s, "f,");
    assert_eq!(s.cursor(), 1);
    type_keys(&mut s, ";");
    assert_eq!(s.cursor(), 3);
    type_keys(&mut s, ",");
    assert_eq!(s.cursor(), 1);
    type_keys(&mut s, "$F,");
    assert_eq!(s.cursor(), 5);
    type_keys(&mut s, "0t,");
    assert_eq!(s.cursor(), 0);
    // ; after t moves on instead of staying put.
    type_keys(&mut s, ";");
    assert_eq!(s.cursor(), 2);
    type_keys(&mut s, "$T,");
    assert_eq!(s.cursor(), 6);
    type_keys(&mut s, "02f,");
    assert_eq!(s.cursor(), 3);
}

#[test]
fn find_with_operators() {
    let mut s = server("foo(bar, baz)\n");
    type_keys(&mut s, "dt(");
    assert_eq!(s.text(), "(bar, baz)\n");
    let mut s = server("a.b.c.d\n");
    type_keys(&mut s, "df..");
    assert_eq!(s.text(), "c.d\n");
    // No match: nothing happens.
    let mut s = server("abc\n");
    type_keys(&mut s, "dfz");
    assert_eq!(s.text(), "abc\n");
    let mut s = server("abc def\n");
    type_keys(&mut s, "$dFa");
    assert_eq!(s.text(), "f\n");
}

#[test]
fn percent_matches_brackets() {
    let mut s = server("if (a[1]) {\n}\n");
    type_keys(&mut s, "%");
    assert_eq!(s.cursor(), 8);
    type_keys(&mut s, "%");
    assert_eq!(s.cursor(), 3);
    type_keys(&mut s, "$%");
    assert_eq!(s.cursor(), 12);
    let mut s = server("f(a(b)c)\n");
    type_keys(&mut s, "ld%");
    assert_eq!(s.text(), "f\n");
    // From before the bracket, d% deletes from the cursor.
    let mut s = server("f(a(b)c) x\n");
    type_keys(&mut s, "d%");
    assert_eq!(s.text(), " x\n");
    let mut s = server("1\n2\n3\n4\n");
    type_keys(&mut s, "50%");
    assert_eq!(s.cursor(), 2);
}

#[test]
fn paragraph_motions() {
    let mut s = server("a\nb\n\nc\nd\n\ne\n");
    type_keys(&mut s, "}");
    assert_eq!(s.cursor(), 4);
    type_keys(&mut s, "}");
    assert_eq!(s.cursor(), 9);
    type_keys(&mut s, "{");
    assert_eq!(s.cursor(), 4);
    type_keys(&mut s, "gg2}");
    assert_eq!(s.cursor(), 9);
    // d} from the start of a paragraph deletes its lines.
    let mut s = server("a\nb\n\nc\n");
    type_keys(&mut s, "d}");
    assert_eq!(s.text(), "\nc\n");
}

#[test]
fn big_word_motions() {
    let mut s = server("a.b c-d e\n");
    type_keys(&mut s, "W");
    assert_eq!(s.cursor(), 4);
    type_keys(&mut s, "E");
    assert_eq!(s.cursor(), 6);
    type_keys(&mut s, "B");
    assert_eq!(s.cursor(), 4);
    type_keys(&mut s, "dW");
    assert_eq!(s.text(), "a.b e\n");
    let mut s = server("a.b c-d\n");
    type_keys(&mut s, "cWx<esc>");
    assert_eq!(s.text(), "x c-d\n");
}

#[test]
fn ge_goes_to_previous_word_end() {
    let mut s = server("foo bar baz\n");
    type_keys(&mut s, "$ge");
    assert_eq!(s.cursor(), 6);
    type_keys(&mut s, "2ge");
    assert_eq!(s.cursor(), 0);
    let mut s = server("foo bar\n");
    type_keys(&mut s, "$dge");
    assert_eq!(s.text(), "fo\n");
}

#[test]
fn dw_across_lines_with_count() {
    let mut s = server("a b\nc d\n");
    type_keys(&mut s, "wd2w");
    assert_eq!(s.text(), "a d\n");
    let mut s = server("one\ntwo\n");
    type_keys(&mut s, "dw");
    assert_eq!(s.text(), "\ntwo\n");
}

#[test]
fn line_motions() {
    let mut s = server("a\n  b\nc\n");
    type_keys(&mut s, "+");
    assert_eq!(s.cursor(), 4);
    type_keys(&mut s, "-");
    assert_eq!(s.cursor(), 0);
    type_keys(&mut s, "d<ret>");
    assert_eq!(s.text(), "c\n");
    let mut s = server("abcdef\n");
    type_keys(&mut s, "4|");
    assert_eq!(s.cursor(), 3);
}

#[test]
fn window_motions() {
    let text: String = (1..=50).map(|i| format!("{i}\n")).collect();
    let mut s = server(&text);
    s.handle(imp_core::ClientMsg::Resize {
        width: 20,
        height: 12,
    });
    s.frame();
    type_keys(&mut s, "L");
    assert_eq!(s.text()[..s.cursor()].matches('\n').count(), 9);
    type_keys(&mut s, "M");
    assert_eq!(s.text()[..s.cursor()].matches('\n').count(), 4);
    type_keys(&mut s, "3H");
    assert_eq!(s.text()[..s.cursor()].matches('\n').count(), 2);
}

/// The 0-based line the cursor is on.
fn line_of(s: &Server) -> usize {
    s.text()[..s.cursor()].matches('\n').count()
}

fn tall_server(lines: usize, height: u16) -> Server {
    let text: String = (1..=lines).map(|i| format!("{i}\n")).collect();
    let mut s = server(&text);
    s.handle(imp_core::ClientMsg::Resize { width: 20, height });
    s.frame();
    s
}

#[test]
fn half_and_full_page_scrolling() {
    // 10 text rows.
    let mut s = tall_server(100, 12);
    s.keys(&["C-d"]);
    assert_eq!(line_of(&s), 5);
    s.frame();
    assert_eq!(s.frame().text_rows()[0], "6");
    s.keys(&["C-u"]);
    assert_eq!(line_of(&s), 0);
    s.keys(&["C-f"]);
    s.frame();
    assert_eq!(s.frame().text_rows()[0], "9");
    assert_eq!(line_of(&s), 8);
    s.keys(&["C-b"]);
    s.frame();
    assert_eq!(s.frame().text_rows()[0], "1");
}

#[test]
fn line_scrolling_drags_the_cursor() {
    let mut s = tall_server(100, 12);
    s.keys(&["C-e", "C-e"]);
    s.frame();
    assert_eq!(s.frame().text_rows()[0], "3");
    assert_eq!(line_of(&s), 2);
    s.keys(&["C-y"]);
    assert_eq!(line_of(&s), 2);
}

#[test]
fn z_commands_place_the_cursor_line() {
    let mut s = tall_server(100, 12);
    type_keys(&mut s, "50Gzt");
    assert_eq!(s.frame().text_rows()[0], "50");
    type_keys(&mut s, "zz");
    assert_eq!(s.frame().text_rows()[0], "46");
    type_keys(&mut s, "zb");
    assert_eq!(s.frame().text_rows()[0], "41");
}

#[test]
fn replace_char() {
    let mut s = server("abcd\n");
    type_keys(&mut s, "rx");
    assert_eq!(s.text(), "xbcd\n");
    type_keys(&mut s, "l3ry");
    assert_eq!(s.text(), "xyyy\n");
    assert_eq!(s.cursor(), 3);
    // Not enough chars: nothing happens.
    type_keys(&mut s, "05rz");
    assert_eq!(s.text(), "xyyy\n");
    type_keys(&mut s, "l.");
    assert_eq!(s.text(), "xyyy\n");
    let mut s = server("ab\n");
    type_keys(&mut s, "r<ret>");
    assert_eq!(s.text(), "\nb\n");
}

#[test]
fn replace_mode() {
    let mut s = server("abcd\n");
    type_keys(&mut s, "Rxy<esc>");
    assert_eq!(s.text(), "xycd\n");
    let mut s = server("ab\n");
    type_keys(&mut s, "Rxyz<esc>");
    assert_eq!(s.text(), "xyz\n");
    // <bs> puts back what was overwritten.
    let mut s = server("abcd\n");
    type_keys(&mut s, "Rxy<bs><bs>z<esc>");
    assert_eq!(s.text(), "zbcd\n");
}

#[test]
fn join_lines() {
    let mut s = server("a\n  b\nc\n");
    type_keys(&mut s, "J");
    assert_eq!(s.text(), "a b\nc\n");
    assert_eq!(s.cursor(), 1);
    let mut s = server("a\nb\nc\nd\n");
    type_keys(&mut s, "3J");
    assert_eq!(s.text(), "a b c\nd\n");
    let mut s = server("f(\n)\n");
    type_keys(&mut s, "J");
    assert_eq!(s.text(), "f()\n");
    let mut s = server("a\n  b\n");
    type_keys(&mut s, "gJ");
    assert_eq!(s.text(), "a  b\n");
    let mut s = server("a\nb\nc\n");
    type_keys(&mut s, "VjjJ");
    assert_eq!(s.text(), "a b c\n");
}

#[test]
fn case_changes() {
    let mut s = server("hello world\n");
    type_keys(&mut s, "gUiw");
    assert_eq!(s.text(), "HELLO world\n");
    type_keys(&mut s, "w~~");
    assert_eq!(s.text(), "HELLO WOrld\n");
    type_keys(&mut s, "guu");
    assert_eq!(s.text(), "hello world\n");
    type_keys(&mut s, "g~~");
    assert_eq!(s.text(), "HELLO WORLD\n");
    type_keys(&mut s, "0vlu");
    assert_eq!(s.text(), "heLLO WORLD\n");
    type_keys(&mut s, "g??");
    assert_eq!(s.text(), "urYYB JBEYQ\n");
}

#[test]
fn shift_lines() {
    let mut s = server("a\nb\n\nc\n");
    type_keys(&mut s, ">>");
    assert_eq!(s.text(), "    a\nb\n\nc\n");
    type_keys(&mut s, "3>>");
    assert_eq!(s.text(), "        a\n    b\n\nc\n");
    // "<" followed by a letter would read as a key name, so send it alone.
    s.keys(&["<", "j"]);
    assert_eq!(s.text(), "    a\nb\n\nc\n");
    type_keys(&mut s, "Vj2>");
    assert_eq!(s.text(), "            a\n        b\n\nc\n");
    type_keys(&mut s, ":set sw=2 noet ts=8<ret>gg");
    s.keys(&["<", "<"]);
    assert_eq!(s.text(), "\t  a\n        b\n\nc\n");
}

#[test]
fn increment_numbers() {
    let mut s = server("x 9 y\n");
    s.keys(&["C-a"]);
    assert_eq!(s.text(), "x 10 y\n");
    assert_eq!(s.cursor(), 3);
    type_keys(&mut s, "5");
    s.keys(&["C-x"]);
    assert_eq!(s.text(), "x 5 y\n");
    let mut s = server("a-1\n");
    type_keys(&mut s, "3");
    s.keys(&["C-a"]);
    assert_eq!(s.text(), "a2\n");
    let mut s = server("0xfe\n");
    s.keys(&["C-a", "C-a"]);
    assert_eq!(s.text(), "0x100\n");
    let mut s = server("0x0F\n");
    s.keys(&["C-a"]);
    assert_eq!(s.text(), "0x10\n");
    // Hex keeps its width, padded with zeros, the cursor on the last digit
    // (as in Vim).
    let mut s = server("0x0009\n");
    s.keys(&["C-a"]);
    assert_eq!(s.text(), "0x000a\n");
    assert_eq!(s.cursor(), 5);
    let mut s = server("no number\n");
    s.keys(&["C-a"]);
    assert_eq!(s.text(), "no number\n");
}

#[test]
fn insert_with_count() {
    let mut s = server("x\n");
    type_keys(&mut s, "3ihi<esc>");
    assert_eq!(s.text(), "hihihix\n");
    let mut s = server("x\n");
    type_keys(&mut s, "2oab<esc>");
    assert_eq!(s.text(), "x\nab\nab\n");
    let mut s = server("x\n");
    type_keys(&mut s, "ia<esc>3.");
    assert_eq!(s.text(), "aaaax\n");
}

#[test]
fn paste_with_count() {
    let mut s = server("ab\n");
    type_keys(&mut s, "yl3p");
    assert_eq!(s.text(), "aaaab\n");
    let mut s = server("a\n");
    type_keys(&mut s, "yy2p");
    assert_eq!(s.text(), "a\na\na\n");
}

#[test]
fn autoindent() {
    let mut s = server("    a\n");
    type_keys(&mut s, "ob<esc>");
    assert_eq!(s.text(), "    a\n    b\n");
    type_keys(&mut s, "A<ret>c<esc>");
    assert_eq!(s.text(), "    a\n    b\n    c\n");
    // Indent that nothing was typed after is removed.
    let mut s = server("    a\n");
    type_keys(&mut s, "o<esc>");
    assert_eq!(s.text(), "    a\n\n");
    let mut s = server("  a\n");
    type_keys(&mut s, "A<ret><ret>b<esc>");
    assert_eq!(s.text(), "  a\n\n  b\n");
}

#[test]
fn insert_editing_keys() {
    let mut s = server("\n");
    type_keys(&mut s, "ifoo bar");
    s.keys(&["C-w"]);
    type_keys(&mut s, "baz<esc>");
    assert_eq!(s.text(), "foo baz\n");
    let mut s = server("keep\n");
    type_keys(&mut s, "A typed");
    s.keys(&["C-u"]);
    type_keys(&mut s, "<esc>");
    assert_eq!(s.text(), "keep\n");
    let mut s = server("abc\n");
    type_keys(&mut s, "i<del>x<end>y<home>z<esc>");
    assert_eq!(s.text(), "zxbcy\n");
    let mut s = server("a\n");
    type_keys(&mut s, "i");
    s.keys(&["C-t"]);
    type_keys(&mut s, "<esc>");
    assert_eq!(s.text(), "    a\n");
}

#[test]
fn insert_tab_follows_expandtab() {
    let mut s = server("\n");
    type_keys(&mut s, "ia<tab>b<esc>");
    assert_eq!(s.text(), "a   b\n");
    type_keys(&mut s, ":set noet<ret>o<tab>c<esc>");
    assert_eq!(s.text(), "a   b\n\tc\n");
}

#[test]
fn ctrl_o_runs_one_command() {
    let mut s = server("abc def\n");
    type_keys(&mut s, "ix");
    s.keys(&["C-o"]);
    type_keys(&mut s, "wy<esc>");
    assert_eq!(s.text(), "xabc ydef\n");
}

#[test]
fn small_commands() {
    let mut s = server("a\nb\n");
    type_keys(&mut s, "Sx<esc>");
    assert_eq!(s.text(), "x\nb\n");
    type_keys(&mut s, "Yp");
    assert_eq!(s.text(), "x\nx\nb\n");
    type_keys(&mut s, "<del>");
    assert_eq!(s.text(), "x\n\nb\n");
    let mut s = server("ab\ncd\n");
    type_keys(&mut s, "ix<esc>jgiy<esc>");
    assert_eq!(s.text(), "xyab\ncd\n");
}

#[test]
fn set_options() {
    let mut s = server("a\n");
    type_keys(&mut s, ":set sw?<ret>");
    assert_eq!(s.status(), "shiftwidth=4");
    type_keys(&mut s, ":set shiftwidth=2<ret>:set sw?<ret>");
    assert_eq!(s.status(), "shiftwidth=2");
    type_keys(&mut s, ":set noai<ret>:set ai?<ret>");
    assert_eq!(s.status(), "autoindent=#false");
    type_keys(&mut s, ":set bogus<ret>");
    assert!(s.status().contains("unknown option"));
}

#[test]
fn named_registers() {
    let mut s = server("one two\n");
    type_keys(&mut s, "\"ayiww\"byiw\"ap\"bP");
    assert_eq!(s.text(), "one tontwoewo\n");
    // Appending with a capital.
    let mut s = server("a b\n");
    type_keys(&mut s, "\"xylw\"Xyl$\"xp");
    assert_eq!(s.text(), "a bab\n");
}

#[test]
fn yank_register_survives_deletes() {
    let mut s = server("keep\nzap\n");
    type_keys(&mut s, "yyjdd\"0P");
    assert_eq!(s.text(), "keep\nkeep\n");
    // The unnamed register still has the delete.
    type_keys(&mut s, "p");
    assert_eq!(s.text(), "keep\nzap\nkeep\n");
}

#[test]
fn numbered_registers_shift() {
    let mut s = server("1\n2\n3\nx\n");
    type_keys(&mut s, "dddddd\"1p\"2p\"3p");
    assert_eq!(s.text(), "x\n3\n2\n1\n");
    // "1p... pastes "1, then "2, then "3.
    let mut s = server("1\n2\n3\nx\n");
    type_keys(&mut s, "dddddd\"1p..");
    assert_eq!(s.text(), "x\n3\n2\n1\n");
}

#[test]
fn small_delete_register() {
    let mut s = server("ab cd\n");
    type_keys(&mut s, "dwyl$\"-p");
    assert_eq!(s.text(), "cdab \n");
}

#[test]
fn black_hole_register() {
    let mut s = server("a\nb\n");
    type_keys(&mut s, "yyj\"_ddP");
    assert_eq!(s.text(), "a\na\n");
}

#[test]
fn count_before_register() {
    let mut s = server("1\n2\n3\n4\n");
    type_keys(&mut s, "2\"ayyG\"ap");
    assert_eq!(s.text(), "1\n2\n3\n4\n1\n2\n");
}

#[test]
fn read_only_registers() {
    let mut s = server("\n");
    type_keys(&mut s, "ihello<esc>\".p");
    assert_eq!(s.text(), "hellohello\n");
    let mut s = server("\n");
    type_keys(&mut s, ":eval 1<ret>\":p");
    assert_eq!(s.text(), "eval 1\n");
    let mut s = server("foo\n");
    type_keys(&mut s, "/oo<ret>\"/P");
    assert_eq!(s.text(), "foooo\n");
}

#[test]
fn insert_and_cmdline_ctrl_r() {
    let mut s = server("word\n");
    type_keys(&mut s, "yiwA ");
    s.keys(&["C-r", "\""]);
    type_keys(&mut s, "<esc>");
    assert_eq!(s.text(), "word word\n");
    let mut s = server("abc abc\n");
    type_keys(&mut s, ":s/");
    s.keys(&["C-r", "C-w"]);
    type_keys(&mut s, "/x/g<ret>");
    assert_eq!(s.text(), "x x\n");
}

#[test]
fn macros_record_and_play() {
    let mut s = server("1\n2\n3\n4\n");
    type_keys(&mut s, "qaA!<esc>jq");
    assert_eq!(s.text(), "1!\n2\n3\n4\n");
    type_keys(&mut s, "@a");
    assert_eq!(s.text(), "1!\n2!\n3\n4\n");
    type_keys(&mut s, "@@");
    assert_eq!(s.text(), "1!\n2!\n3!\n4\n");
    // The macro is text in its register.
    type_keys(&mut s, "G\"ap");
    assert_eq!(s.text(), "1!\n2!\n3!\n4A!<esc>j\n");
}

#[test]
fn macro_with_count_stops_on_failure() {
    let mut s = server("a1\na2\na3\n");
    // j fails on the last line, which ends the macro early.
    type_keys(&mut s, "qq0xjq10@q");
    assert_eq!(s.text(), "1\n2\n3\n");
}

#[test]
fn recording_shows_in_mode_line() {
    let mut s = server("a\n");
    type_keys(&mut s, "qz");
    assert!(status_row(&mut s).contains("recording @z"));
    type_keys(&mut s, "q");
    assert!(!status_row(&mut s).contains("recording"));
}

#[test]
fn gp_leaves_cursor_after_text() {
    let mut s = server("a\nb\n");
    type_keys(&mut s, "yygpix<esc>");
    assert_eq!(s.text(), "a\na\nxb\n");
}

#[test]
fn macro_keys_round_trip() {
    let mut s = server("");
    let out = s
        .eval(r#"(string->keys (keys->string (list "a" "<" "<esc>" "C-r" "<ret>")))"#)
        .unwrap();
    assert_eq!(out, r#"("a" "<" "<esc>" "C-r" "<ret>")"#);
}

#[test]
fn undo_moves_cursor_to_the_change() {
    let mut s = server("one\ntwo\nthree\n");
    type_keys(&mut s, "jjdwgg");
    type_keys(&mut s, "u");
    assert_eq!(s.cursor(), 8);
    type_keys(&mut s, "gg");
    s.keys(&["C-r"]);
    assert_eq!(s.cursor(), 8);
}

#[test]
fn undo_and_redo_take_counts() {
    let mut s = server("abc\n");
    type_keys(&mut s, "xxx3u");
    assert_eq!(s.text(), "abc\n");
    s.keys(&["2", "C-r"]);
    assert_eq!(s.text(), "c\n");
}

#[test]
fn a_change_after_undo_is_undone_alone() {
    let mut s = server("abcd\n");
    type_keys(&mut s, "xxux");
    assert_eq!(s.text(), "cd\n");
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "bcd\n");
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "abcd\n");
    // And after a redo.
    let mut s = server("abcd\n");
    type_keys(&mut s, "xxu");
    s.keys(&["C-r"]);
    type_keys(&mut s, "xu");
    assert_eq!(s.text(), "cd\n");
}

#[test]
fn line_undo() {
    let mut s = server("abc\nxyz\n");
    type_keys(&mut s, "xx$x");
    assert_eq!(s.text(), "\nxyz\n");
    type_keys(&mut s, "U");
    assert_eq!(s.text(), "abc\nxyz\n");
    type_keys(&mut s, "U");
    assert_eq!(s.text(), "\nxyz\n");
    // U is itself undoable.
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "abc\nxyz\n");
}

#[test]
fn marks_set_and_jump() {
    let mut s = server("one\n  two\nthree\n");
    type_keys(&mut s, "jllmaG'a");
    assert_eq!(s.cursor(), 6);
    type_keys(&mut s, "G`a");
    assert_eq!(s.cursor(), 6);
    type_keys(&mut s, "gg");
    // Marks move with the text.
    type_keys(&mut s, "Onew<esc>`a");
    assert_eq!(s.cursor(), 10);
}

#[test]
fn marks_as_motions() {
    let mut s = server("1\n2\n3\n4\n");
    type_keys(&mut s, "majjd'a");
    assert_eq!(s.text(), "4\n");
    let mut s = server("abcdef\n");
    type_keys(&mut s, "lmb$d`b");
    assert_eq!(s.text(), "af\n");
    let mut s = server("abc\n");
    type_keys(&mut s, "'z");
    assert!(s.status().contains("mark not set"));
}

/// m takes a-z, A-Z and ' ` [ ] < > (:help m); other characters are not
/// marks, and jumping to one says so (Vim's E78) instead of "not set".
#[test]
fn which_marks_m_and_jumps_accept() {
    let mut s = server("ab\ncd\n");
    type_keys(&mut s, "jlm[gg`[");
    assert_eq!(s.cursor(), 4);
    type_keys(&mut s, "m.");
    assert!(s.status().contains("invalid mark"));
    type_keys(&mut s, "m1");
    assert!(s.status().contains("invalid mark"));
    type_keys(&mut s, ":mark !<ret>");
    assert!(s.status().contains("invalid mark"));
    type_keys(&mut s, "'!");
    assert!(s.status().contains("unknown mark"));
    type_keys(&mut s, "'1");
    assert!(s.status().contains("mark not set"));
}

#[test]
fn backtick_backtick_returns_from_jump() {
    let mut s = server("1\n2\n3\n4\n");
    type_keys(&mut s, "jG''");
    assert_eq!(s.cursor(), 2);
    type_keys(&mut s, "``");
    assert_eq!(s.cursor(), 6);
}

#[test]
fn jump_list() {
    let mut s = server("1\n2\n3\n4\n5\n");
    type_keys(&mut s, "3G5Ggg");
    s.keys(&["C-o"]);
    assert_eq!(s.cursor(), 8);
    s.keys(&["C-o"]);
    assert_eq!(s.cursor(), 4);
    // As in Vim, going back from the newest position added it to the end
    // of the list and dropped the older entry for the same line, so there
    // is nothing further back.
    s.keys(&["C-o"]);
    assert_eq!(s.cursor(), 4);
    s.keys(&["<tab>"]);
    assert_eq!(s.cursor(), 8);
    s.keys(&["C-i", "C-i"]);
    assert_eq!(s.cursor(), 0);
}

#[test]
fn search_is_a_jump() {
    let mut s = server("a\nb\nc\n");
    type_keys(&mut s, "/c<ret>");
    s.keys(&["C-o"]);
    assert_eq!(s.cursor(), 0);
}

#[test]
fn special_marks() {
    let mut s = server("one two\nthree\n");
    type_keys(&mut s, "wcwX<esc>gg`.");
    assert_eq!(s.cursor(), 4);
    // `^ is just past the insert, which normal mode shows on the last char.
    type_keys(&mut s, "jAyz<esc>gg`^");
    assert_eq!(s.cursor(), 12);
    type_keys(&mut s, "ggyiw`]");
    assert_eq!(s.cursor(), 2);
    type_keys(&mut s, "wvj<esc>gg'>");
    assert_eq!(s.cursor(), 6);
}

#[test]
fn ex_mark_addresses() {
    let mut s = server("1\n2\n3\n4\n");
    type_keys(&mut s, "jmajmbgg:'a,'bd<ret>");
    assert_eq!(s.text(), "1\n4\n");
}

#[test]
fn popups_list_and_close() {
    let mut s = server("hello\n");
    type_keys(&mut s, "ma:marks<ret>");
    let rows = s.frame().text_rows();
    assert!(rows.iter().any(|r| r.starts_with(" a   1")), "{rows:?}");
    // Any key closes it; j also runs.
    type_keys(&mut s, "x");
    assert!(!s
        .frame()
        .text_rows()
        .iter()
        .any(|r| r.contains("mark line")));
    assert_eq!(s.text(), "ello\n");
    type_keys(&mut s, "\"ayy:reg<ret>");
    assert!(s
        .frame()
        .text_rows()
        .iter()
        .any(|r| r.contains("\"a  l    ello^J")));
    type_keys(&mut s, "<ret>");
    assert_eq!(s.text(), "ello\n");
}

#[test]
fn delmarks() {
    let mut s = server("a\n");
    type_keys(&mut s, "ma:delm a<ret>'a");
    assert!(s.status().contains("mark not set"));
}

#[test]
fn cmdline_shows_on_bottom_row_with_cursor() {
    let mut s = server("a\n");
    type_keys(&mut s, ":abc<left>");
    let f = s.frame();
    assert_eq!(f.text_rows().last().unwrap().trim_end(), ":abc");
    assert_eq!(f.cursor, (3, 23));
    type_keys(&mut s, "X<home>Y");
    assert_eq!(s.frame().text_rows().last().unwrap().trim_end(), ":YabXc");
}

#[test]
fn cmdline_history() {
    let mut s = server("1\n2\n3\n");
    type_keys(&mut s, ":2<ret>:3<ret>:eval 9<ret>:");
    s.keys(&["<up>"]);
    assert_eq!(s.frame().text_rows().last().unwrap().trim_end(), ":eval 9");
    s.keys(&["<up>"]);
    assert_eq!(s.frame().text_rows().last().unwrap().trim_end(), ":3");
    s.keys(&["<down>", "<down>"]);
    assert_eq!(s.frame().text_rows().last().unwrap().trim_end(), ":");
    // <up> matches what was typed.
    type_keys(&mut s, "2");
    s.keys(&["<up>"]);
    assert_eq!(s.frame().text_rows().last().unwrap().trim_end(), ":2");
    type_keys(&mut s, "<esc>/x<ret>/");
    s.keys(&["<up>"]);
    assert_eq!(s.frame().text_rows().last().unwrap(), "/x");
}

#[test]
fn cmdline_tab_completes_commands() {
    let mut s = server("a\n");
    type_keys(&mut s, ":noh<tab>");
    assert_eq!(
        s.frame().text_rows().last().unwrap().trim_end(),
        ":nohlsearch"
    );
}

#[test]
fn write_and_read_files() {
    let copy = temp_path("copy.txt");
    let _ = std::fs::remove_file(&copy);
    let mut s = server("hello\n");
    type_keys(&mut s, &format!(":w {}<ret>", copy.display()));
    assert_eq!(std::fs::read_to_string(&copy).unwrap(), "hello\n");
    // It now has a name (the scratch buffer had none).
    assert!(status_row(&mut s).contains("copy.txt"));
    // Refuses to overwrite another existing file without !.
    let other = temp_path("other.txt");
    std::fs::write(&other, "x\n").unwrap();
    type_keys(&mut s, &format!(":w {}<ret>", other.display()));
    assert!(s.status().contains("exists"));
    type_keys(&mut s, &format!(":w! {}<ret>", other.display()));
    assert_eq!(std::fs::read_to_string(&other).unwrap(), "hello\n");
    type_keys(&mut s, &format!(":r {}<ret>", other.display()));
    assert_eq!(s.text(), "hello\nhello\n");
}

#[test]
fn shell_commands() {
    let mut s = server("b\na\nc\n");
    type_keys(&mut s, ":%!sort<ret>");
    assert_eq!(s.text(), "a\nb\nc\n");
    type_keys(&mut s, ":r !echo hi<ret>");
    assert_eq!(s.text(), "a\nhi\nb\nc\n");
    type_keys(&mut s, ":!echo out<ret>");
    assert!(s.frame().text_rows().iter().any(|r| r.starts_with("out")));
}

#[test]
fn move_and_copy_lines() {
    let mut s = server("1\n2\n3\n4\n");
    type_keys(&mut s, ":1m3<ret>");
    assert_eq!(s.text(), "2\n3\n1\n4\n");
    type_keys(&mut s, ":4m0<ret>");
    assert_eq!(s.text(), "4\n2\n3\n1\n");
    type_keys(&mut s, ":1,2t$<ret>");
    assert_eq!(s.text(), "4\n2\n3\n1\n4\n2\n");
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "4\n2\n3\n1\n");
}

#[test]
fn ex_shift_join_put_mark() {
    let mut s = server("a\nb\nc\n");
    type_keys(&mut s, ":2><ret>");
    assert_eq!(s.text(), "a\n    b\nc\n");
    type_keys(&mut s, ":1,3j<ret>");
    assert_eq!(s.text(), "a b c\n");
    type_keys(&mut s, "0yiw:pu<ret>");
    assert_eq!(s.text(), "a b c\na\n");
    type_keys(&mut s, ":1k z<ret>G'z");
    assert_eq!(s.cursor(), 0);
}

#[test]
fn sort_lines() {
    let mut s = server("b\nA\na\nb\n");
    type_keys(&mut s, ":sort<ret>");
    assert_eq!(s.text(), "A\na\nb\nb\n");
    type_keys(&mut s, ":sort u<ret>");
    assert_eq!(s.text(), "A\na\nb\n");
    type_keys(&mut s, ":sort!<ret>");
    assert_eq!(s.text(), "b\na\nA\n");
    let mut s = server("x10\nx9\nx100\n");
    type_keys(&mut s, ":sort n<ret>");
    assert_eq!(s.text(), "x9\nx10\nx100\n");
}

#[test]
fn normal_command() {
    let mut s = server("a\nb\nc\n");
    type_keys(&mut s, ":%norm A;<ret>");
    assert_eq!(s.text(), "a;\nb;\nc;\n");
    // One undo step for the whole command.
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "a\nb\nc\n");
    type_keys(&mut s, ":norm dd<ret>");
    assert_eq!(s.text(), "b\nc\n");
}

#[test]
fn global_command() {
    let mut s = server("keep\ndrop 1\nkeep\ndrop 2\n");
    type_keys(&mut s, ":g/drop/d<ret>");
    assert_eq!(s.text(), "keep\nkeep\n");
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "keep\ndrop 1\nkeep\ndrop 2\n");
    type_keys(&mut s, ":v/drop/s/keep/k/<ret>");
    assert_eq!(s.text(), "k\ndrop 1\nk\ndrop 2\n");
    type_keys(&mut s, ":g/drop/norm A!<ret>");
    assert_eq!(s.text(), "k\ndrop 1!\nk\ndrop 2!\n");
    type_keys(&mut s, ":g/drop<ret>");
    let rows = s.frame().text_rows();
    assert!(rows.iter().any(|r| r == "drop 1!"), "{rows:?}");
    // :g/pat/m0 reverses the matching lines.
    let mut s = server("1\n2\n3\n");
    type_keys(&mut s, ":g/^/m0<ret>");
    assert_eq!(s.text(), "3\n2\n1\n");
}

#[test]
fn block_delete_and_yank() {
    let mut s = server("abcd\nefgh\nijkl\n");
    s.keys(&["l", "C-v", "j", "l", "d"]);
    assert_eq!(s.text(), "ad\neh\nijkl\n");
    // The block pastes back as a block.
    type_keys(&mut s, "P");
    assert_eq!(s.text(), "abcd\nefgh\nijkl\n");
    let mut s = server("ab\ncd\n");
    s.keys(&["C-v", "j", "y", "$", "p"]);
    assert_eq!(s.text(), "aba\ncdc\n");
}

#[test]
fn block_is_highlighted_per_line() {
    let mut s = server("abcd\nefgh\n");
    s.keys(&["l", "C-v", "j", "l"]);
    let f = s.frame();
    for row in &f.rows[..2] {
        let texts: Vec<&str> = row.iter().map(|sp| sp.text.as_str()).collect();
        assert_eq!(texts.len(), 3, "{texts:?}");
        assert!(row[1].style.bg.is_some());
    }
    assert!(f.text_rows()[f.text_rows().len() - 2].contains("VISUAL BLOCK"));
}

#[test]
fn block_insert_and_append() {
    let mut s = server("ab\ncd\nef\n");
    s.keys(&["l", "C-v", "j", "j"]);
    type_keys(&mut s, "IX<esc>");
    assert_eq!(s.text(), "aXb\ncXd\neXf\n");
    let mut s = server("ab\nc\nef\n");
    s.keys(&["l", "C-v", "j", "j"]);
    type_keys(&mut s, "AY<esc>");
    assert_eq!(s.text(), "abY\nc Y\nefY\n");
    // $A appends at each line's end.
    let mut s = server("a\nbcd\n");
    s.keys(&["C-v", "j", "$"]);
    type_keys(&mut s, "A;<esc>");
    assert_eq!(s.text(), "a;\nbcd;\n");
}

#[test]
fn block_change_and_replace() {
    let mut s = server("abc\ndef\n");
    s.keys(&["C-v", "j", "l"]);
    type_keys(&mut s, "cZ<esc>");
    assert_eq!(s.text(), "Zc\nZf\n");
    let mut s = server("abc\ndef\n");
    s.keys(&["l", "C-v", "j"]);
    type_keys(&mut s, "r-");
    assert_eq!(s.text(), "a-c\nd-f\n");
    let mut s = server("abc\ndef\n");
    s.keys(&["l", "C-v", "j", "U"]);
    assert_eq!(s.text(), "aBc\ndEf\n");
}

/// c on a block leaves lines that end before the block alone; a line
/// that reaches the block's left column still gets the text, as in Vim.
#[test]
fn block_change_skips_short_lines() {
    let mut s = server("abcd\nx\nab\nefgh\n");
    s.keys(&["l", "l", "C-v", "j", "j", "j", "l"]);
    type_keys(&mut s, "cZ<esc>");
    assert_eq!(s.text(), "abZ\nx\nabZ\nefZ\n");
}

/// A command name bound in insert state runs as a command, with a count of
/// 1; a procedure bound there is still called with no arguments.
#[test]
fn insert_state_runs_command_names() {
    let mut s = server("\n");
    s.eval(
        r#"(define-command! 'insert-count (lambda (count) (insert-text! (number->string count))))
           (define-key! 'insert "C-s" 'insert-count)
           (define-key! 'insert "C-g" (lambda () (insert-text! "!")))"#,
    )
    .unwrap();
    type_keys(&mut s, "ia<C-s>b<C-g><esc>");
    assert_eq!(s.text(), "a1b!\n");
}

/// Blocks are display columns, as in Vim (checked against Neovim with
/// tabstop=8): a tab or wide char at a corner widens the block to all of
/// it, and one cut by the block's edge becomes spaces where text is taken
/// out or put in.
#[test]
fn blocks_use_display_columns() {
    let reg = |s: &mut imp_server::Server| s.eval("(car (register-get #\\\"))").unwrap();
    let tabs = |text: &str| {
        let mut s = server(text);
        s.eval("(set-option! 'tabstop 8)").unwrap();
        s
    };
    // A corner on a tab takes in the whole tab.
    let mut s = tabs("a\tbcd\nabcdefghijkl\n");
    s.keys(&["l", "C-v", "j", "0", "l", "l", "d"]);
    assert_eq!(s.text(), "abcd\naijkl\n");
    // Lines below a tab line are cut at the same display columns.
    let mut s = tabs("a\tbcd\nabcdefghijkl\n");
    s.keys(&["j", "8", "l", "C-v", "l", "k", "0", "l", "l", "l", "d"]);
    assert_eq!(s.text(), "a\td\nabcdefghkl\n");
    // A tab cut by the block: d leaves its outside part as spaces, y takes
    // its inside part as spaces.
    let block = "abcdefghijkl\na\tbcd\nabcdefghijkl\n";
    let mut s = tabs(block);
    s.keys(&["l", "l", "C-v", "l", "j", "j", "y"]);
    assert_eq!(reg(&mut s), "\"cd\\n  \\ncd\"");
    s.keys(&["g", "v", "d"]);
    assert_eq!(s.text(), "abefghijkl\na     bcd\nabefghijkl\n");
    let mut s = tabs(block);
    s.keys(&["l", "l", "C-v", "l", "j", "j"]);
    type_keys(&mut s, "cX<esc>");
    assert_eq!(s.text(), "abXefghijkl\na X    bcd\nabXefghijkl\n");
    let mut s = tabs(block);
    s.keys(&["l", "l", "C-v", "j", "j"]);
    type_keys(&mut s, "IX<esc>");
    assert_eq!(s.text(), "abXcdefghijkl\na X      bcd\nabXcdefghijkl\n");
    let mut s = tabs(block);
    s.keys(&["l", "l", "C-v", "l", "j", "j"]);
    type_keys(&mut s, "AX<esc>");
    assert_eq!(s.text(), "abcdXefghijkl\na   X    bcd\nabcdXefghijkl\n");
    // Wide chars are two columns; one cut gets spaces before it on I.
    let wide = "abcdef\n中文字\nabcdef\n";
    let mut s = server(wide);
    s.keys(&["l", "C-v", "l", "j", "j", "y"]);
    assert_eq!(reg(&mut s), "\"bc\\n  \\nbc\"");
    s.keys(&["g", "v", "d"]);
    assert_eq!(s.text(), "adef\n  字\nadef\n");
    let mut s = server(wide);
    s.keys(&["l", "C-v", "j", "j"]);
    type_keys(&mut s, "IX<esc>");
    assert_eq!(s.text(), "aXbcdef\n X中文字\naXbcdef\n");
    // A line ending before the block yanks as spaces; one ending at its
    // left edge, as nothing.
    let mut s = server("abcdefgh\nab\nabcdefgh\n");
    s.keys(&["4", "l", "C-v", "l", "j", "j", "y"]);
    assert_eq!(reg(&mut s), "\"ef\\n  \\nef\"");
    let mut s = server("abcd\nab\nabcd\n");
    s.keys(&["l", "l", "C-v", "l", "j", "j", "y"]);
    assert_eq!(reg(&mut s), "\"cd\\n\\ncd\"");
    // A block puts at the cursor's display column.
    let mut s = tabs("XY\nZW\na\tbcd\nabcdefghijkl\n");
    s.keys(&["C-v", "j", "l", "y", "j", "j", "l", "l", "p"]);
    assert_eq!(s.text(), "XY\nZW\na\tbXYcd\nabcdefghiZWjkl\n");
}

#[test]
fn block_d_to_line_ends() {
    let mut s = server("abc\nde\n");
    s.keys(&["l", "C-v", "j", "D"]);
    assert_eq!(s.text(), "a\nd\n");
}

/// cw on a word's last char changes only that char (Vim's end_word with
/// stop set); with a count it goes on to later word ends.
#[test]
fn cw_on_the_last_char_of_a_word() {
    let mut s = server("a.txt one\n");
    type_keys(&mut s, "cwc<esc>");
    assert_eq!(s.text(), "c.txt one\n");
    let mut s = server("ab cd ef\n");
    type_keys(&mut s, "lcwX<esc>");
    assert_eq!(s.text(), "aX cd ef\n");
    let mut s = server("ab cd ef\n");
    type_keys(&mut s, "l2cwX<esc>");
    assert_eq!(s.text(), "aX ef\n");
    let mut s = server("a.b c\n");
    type_keys(&mut s, "cWX<esc>");
    assert_eq!(s.text(), "X c\n");
}
