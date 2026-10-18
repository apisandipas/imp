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
    assert!(s.frame().text_rows().last().unwrap().contains("NORMAL"));
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
        height: 11,
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
    let mut s = tall_server(100, 11);
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
    let mut s = tall_server(100, 11);
    s.keys(&["C-e", "C-e"]);
    s.frame();
    assert_eq!(s.frame().text_rows()[0], "3");
    assert_eq!(line_of(&s), 2);
    s.keys(&["C-y"]);
    assert_eq!(line_of(&s), 2);
}

#[test]
fn z_commands_place_the_cursor_line() {
    let mut s = tall_server(100, 11);
    type_keys(&mut s, "50Gzt");
    assert_eq!(s.frame().text_rows()[0], "50");
    type_keys(&mut s, "zz");
    assert_eq!(s.frame().text_rows()[0], "46");
    type_keys(&mut s, "zb");
    assert_eq!(s.frame().text_rows()[0], "41");
}
