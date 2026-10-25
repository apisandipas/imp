//! Org mode (runtime/org.scm).

mod common;

use common::*;

/// A server without the fold column, so rows start with their text; the
/// column's own tests are in fold_column.rs.
fn server(text: &str) -> imp_server::Server {
    let mut s = common::server(text);
    s.eval("(set-option! 'foldcolumn \"no\")").unwrap();
    s
}

fn org(name: &str, text: &str) -> imp_server::Server {
    let path = temp_path(name);
    std::fs::write(&path, text).unwrap();
    let mut s = server("");
    type_keys(&mut s, &format!(":e {}<ret>", path.display()));
    assert_eq!(s.eval("(major-mode)").unwrap(), "org-mode");
    s
}

fn rows(s: &mut imp_server::Server) -> Vec<String> {
    s.frame()
        .text_rows()
        .into_iter()
        .map(|r| r.trim_end().to_string())
        .collect()
}

const OUTLINE: &str = "* A\ntext a\n** A1\nbody 1\n** A2\nbody 2\n* B\ntext b\n";

#[test]
fn tab_cycles_a_subtree() {
    let mut s = org("cycle.org", OUTLINE);
    type_keys(&mut s, "<tab>");
    assert_eq!(rows(&mut s)[..2], ["* A ··· 6 lines", "* B"]);
    type_keys(&mut s, "<tab>");
    assert_eq!(
        rows(&mut s)[..4],
        [
            "* A ··· 2 lines",
            "** A1 ··· 2 lines",
            "** A2 ··· 2 lines",
            "* B"
        ]
    );
    type_keys(&mut s, "<tab>");
    assert_eq!(rows(&mut s)[..3], ["* A", "text a", "** A1"]);
    // Off a heading, <tab> isn't a fold command.
    type_keys(&mut s, "j<tab>");
    assert_eq!(rows(&mut s)[1], "text a");
}

#[test]
fn shift_tab_cycles_the_buffer() {
    let mut s = org("global.org", OUTLINE);
    type_keys(&mut s, "<s-tab>");
    assert_eq!(rows(&mut s)[..2], ["* A ··· 6 lines", "* B ··· 2 lines"]);
    type_keys(&mut s, "<s-tab>");
    assert_eq!(
        rows(&mut s)[..4],
        [
            "* A ··· 2 lines",
            "** A1 ··· 2 lines",
            "** A2 ··· 2 lines",
            "* B ··· 2 lines"
        ]
    );
    type_keys(&mut s, "<s-tab>");
    assert_eq!(rows(&mut s)[..2], ["* A", "text a"]);
}

#[test]
fn ret_cycles_todo_keywords() {
    let mut s = org("todo.org", "** Write it\n");
    type_keys(&mut s, "<ret>");
    assert_eq!(s.text(), "** TODO Write it\n");
    type_keys(&mut s, "<ret>");
    assert_eq!(s.text(), "** DONE Write it\n");
    type_keys(&mut s, "<ret>");
    assert_eq!(s.text(), "** Write it\n");
    // One undo step each.
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "** DONE Write it\n");
    // The keywords are an option.
    s.eval("(set-option! 'org-todo-keywords '(\"TODO\" \"WAIT\" \"DONE\"))")
        .unwrap();
    type_keys(&mut s, ":e! <ret>");
    type_keys(&mut s, "<ret><ret>");
    assert_eq!(s.text(), "** WAIT Write it\n");
}

#[test]
fn checkboxes_and_their_cookie() {
    let mut s = org(
        "boxes.org",
        "* Tasks [0/3]\n- [ ] one\n- [ ] two\n  - [ ] nested\n* Other [0%]\n- [ ] x\n",
    );
    type_keys(&mut s, "j<ret>");
    assert!(
        s.text().starts_with("* Tasks [1/3]\n- [X] one\n"),
        "{}",
        s.text()
    );
    type_keys(&mut s, "jj<ret>");
    assert!(s.text().contains("* Tasks [2/3]"), "{}", s.text());
    assert!(s.text().contains("  - [X] nested"));
    type_keys(&mut s, "k<ret>");
    assert!(
        s.text().starts_with("* Tasks [3/3]\n- [X] one\n- [X] two"),
        "{}",
        s.text()
    );
    type_keys(&mut s, "<ret>");
    assert!(
        s.text().starts_with("* Tasks [2/3]\n- [X] one\n- [ ] two"),
        "{}",
        s.text()
    );
    type_keys(&mut s, "G<ret>");
    assert!(
        s.text().ends_with("* Other [100%]\n- [X] x\n"),
        "{}",
        s.text()
    );
}

#[test]
fn new_headings_and_items() {
    let mut s = org("new.org", OUTLINE);
    // From inside A1's subtree: a sibling after it.
    type_keys(&mut s, "jj");
    s.keys(&["M-<ret>"]);
    type_keys(&mut s, "A1b<esc>");
    assert_eq!(
        s.text(),
        "* A\ntext a\n** A1\nbody 1\n** A1b\n** A2\nbody 2\n* B\ntext b\n"
    );
    // At the last heading: after the end of the buffer.
    type_keys(&mut s, "G");
    s.keys(&["M-<ret>"]);
    type_keys(&mut s, "C<esc>");
    assert!(s.text().ends_with("* B\ntext b\n* C\n"), "{}", s.text());
    // On a list item: another item, with a checkbox if it has one.
    let mut s = org("items.org", "- [ ] one\n");
    s.keys(&["M-<ret>"]);
    type_keys(&mut s, "two<esc>");
    assert_eq!(s.text(), "- [ ] one\n- [ ] two\n");
}

#[test]
fn promote_demote_and_move() {
    let mut s = org("shift.org", OUTLINE);
    type_keys(&mut s, "jj<M-l>");
    assert!(s.text().contains("\n*** A1\n"));
    type_keys(&mut s, "<M-h><M-h>");
    assert!(s.text().contains("\n* A1\n"));
    type_keys(&mut s, "u");
    assert!(s.text().contains("\n** A1\n"));
    // The whole subtree.
    type_keys(&mut s, "gg<M-L>");
    assert!(
        s.text()
            .starts_with("** A\ntext a\n*** A1\nbody 1\n*** A2\n"),
        "{}",
        s.text()
    );
    type_keys(&mut s, "u");
    // Move A2 above A1, then A below B.
    type_keys(&mut s, "4j<M-k>");
    assert_eq!(
        s.text(),
        "* A\ntext a\n** A2\nbody 2\n** A1\nbody 1\n* B\ntext b\n"
    );
    assert_eq!(s.eval("(current-line)").unwrap(), "2");
    type_keys(&mut s, "gg<M-j>");
    assert_eq!(
        s.text(),
        "* B\ntext b\n* A\ntext a\n** A2\nbody 2\n** A1\nbody 1\n"
    );
    assert_eq!(s.eval("(current-line)").unwrap(), "2");
    // A list item indents.
    let mut s = org("list.org", "- a\n- b\n");
    type_keys(&mut s, "j<M-l>");
    assert_eq!(s.text(), "- a\n  - b\n");
}

#[test]
fn tables_align() {
    let mut s = org("table.org", "| name | n |\n|-\n| alpha | 10 |\n");
    type_keys(&mut s, "A<tab>");
    assert_eq!(s.text(), "| name  | n  |\n|-------+----|\n| alpha | 10 |\n");
    // The cursor went to the next row's first cell.
    assert_eq!(s.eval("(current-line)").unwrap(), "2");
    assert_eq!(s.eval("(current-col)").unwrap(), "2");
    // <tab> at the last cell makes a new row; typing keeps it aligned.
    type_keys(&mut s, "<esc>$i<tab>beta<tab>2<esc><ret>");
    assert_eq!(
        s.text(),
        "| name  | n  |\n|-------+----|\n| alpha | 10 |\n| beta  | 2  |\n"
    );
}

#[test]
fn tables_stay_aligned_while_typing() {
    let mut s = org("live.org", "| a | b |\n| cc | d |\n");
    // Append to the first cell: the column widens as you type.
    type_keys(&mut s, "0llaxyz");
    assert_eq!(s.text(), "| axyz | b |\n| cc   | d |\n");
    // The space before the next word stays, and the cursor with it.
    type_keys(&mut s, " w");
    assert_eq!(s.text(), "| axyz w | b |\n| cc     | d |\n");
    assert_eq!(s.eval("(current-col)").unwrap(), "8");
    // Deleting shrinks it again.
    type_keys(&mut s, "<bs><bs><bs><bs>");
    assert_eq!(s.text(), "| ax | b |\n| cc | d |\n");
    // The whole insert is one undo step.
    type_keys(&mut s, "<esc>u");
    assert_eq!(s.text(), "| a | b |\n| cc | d |\n");
}

#[test]
fn links() {
    let dir = temp_path("org-links");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("other.org"), "first\nsecond\nthird\n").unwrap();
    let path = dir.join("links.org");
    std::fs::write(
        &path,
        "See [[file:other.org::2][the other file]].\nAnd [[*Target]].\n* Target\n",
    )
    .unwrap();
    let mut s = server("");
    type_keys(&mut s, &format!(":e {}<ret>", path.display()));
    type_keys(&mut s, "fo<ret>");
    assert!(s.eval("(buffer-name)").unwrap().contains("other.org"));
    assert_eq!(s.eval("(current-line)").unwrap(), "1");
    type_keys(&mut s, "<C-o>jfT<ret>");
    assert_eq!(s.eval("(current-line)").unwrap(), "2");
    // gx too.
    type_keys(&mut s, "ggfogx");
    assert!(s.eval("(buffer-name)").unwrap().contains("other.org"));
}

#[test]
fn priorities() {
    let mut s = org("prio.org", "* TODO Write [#B] notes\n* Plain\n");
    // C-c , then a letter sets it, after the keyword.
    s.keys(&["C-c", ","]);
    type_keys(&mut s, "a");
    assert_eq!(s.text(), "* TODO [#A] Write [#B] notes\n* Plain\n");
    // Again replaces it; space removes it.
    s.keys(&["C-c", ","]);
    type_keys(&mut s, "c");
    assert_eq!(s.text(), "* TODO [#C] Write [#B] notes\n* Plain\n");
    s.keys(&["C-c", ","]);
    s.keys(&[" "]);
    assert_eq!(s.text(), "* TODO Write [#B] notes\n* Plain\n");
    // A heading with no keyword.
    type_keys(&mut s, "j ");
    type_keys(&mut s, "mpb");
    assert_eq!(s.text(), "* TODO Write [#B] notes\n* [#B] Plain\n");
}

#[test]
fn headings_have_faces() {
    let mut s = org("faces.org", "* TODO Top\n** Sub\n");
    let frame = s.frame();
    let styled = |row: usize| {
        frame.rows[row]
            .iter()
            .any(|sp| sp.style.fg.is_some() && sp.style.bold)
    };
    assert!(styled(0) && styled(1));
}

#[test]
fn a_heading_link_matches_the_whole_title() {
    // Not "Big Foo", which only ends in Foo: Org matches the title
    // exactly, its keyword, priority, cookie and tags aside.
    let mut s = org(
        "exact.org",
        "[[*Foo]] and [[*Nope]]\n* Big Foo\n* TODO [#A] Foo [1/2] :work:\n",
    );
    type_keys(&mut s, "l<ret>");
    assert_eq!(s.eval("(current-line)").unwrap(), "2");
    type_keys(&mut s, "gg$h<ret>");
    assert_eq!(s.eval("(current-line)").unwrap(), "0");
    assert!(s.status().contains("no heading Nope"), "{}", s.status());
}

const KEYWORDS: &str =
    r#"(set-option! 'org-todo-keywords '("TODO" "NEXT" "|" "DONE" "CANCELLED"))"#;

#[test]
fn keywords_after_the_bar_are_done() {
    let mut s = server("");
    s.eval(KEYWORDS).unwrap();
    let path = temp_path("bar.org");
    std::fs::write(&path, "** Write it\n").unwrap();
    type_keys(&mut s, &format!(":e {}<ret>", path.display()));
    // Cycling skips the bar.
    for want in ["TODO ", "NEXT ", "DONE ", "CANCELLED ", ""] {
        type_keys(&mut s, "<ret>");
        assert_eq!(s.text(), format!("** {want}Write it\n"));
    }
    // CANCELLED and DONE look done, NEXT and TODO not.
    type_keys(
        &mut s,
        "ggdGi* TODO a<ret>* NEXT b<ret>* DONE c<ret>* CANCELLED d<esc>",
    );
    let frame = s.frame();
    let style = |word: &str| {
        frame
            .rows
            .iter()
            .flatten()
            .find(|sp| sp.text.contains(word))
            .unwrap_or_else(|| panic!("no {word}"))
            .style
    };
    assert_eq!(style("NEXT"), style("TODO"));
    assert_eq!(style("CANCELLED"), style("DONE"));
    assert_ne!(style("DONE"), style("TODO"));
}

#[test]
fn links_show_their_description_off_the_cursor_line() {
    let mut s = server("See [[https://x.org][the site]] now\nand [[notes.org]] here\n");
    s.eval("(set-major-mode! 'org-mode)").unwrap();
    let rows = |s: &mut imp_server::Server| {
        let r = s.frame().text_rows();
        (r[0].trim_end().to_string(), r[1].trim_end().to_string())
    };
    // The cursor's line shows whole, to edit.
    assert_eq!(
        rows(&mut s),
        (
            "See [[https://x.org][the site]] now".into(),
            "and notes.org here".into()
        )
    );
    type_keys(&mut s, "j");
    assert_eq!(
        rows(&mut s),
        ("See the site now".into(), "and [[notes.org]] here".into())
    );
    // A click lands on the char drawn there: "s" of "site".
    s.frame();
    for action in ["press", "release"] {
        s.handle(imp_core::ClientMsg::Mouse {
            action: action.into(),
            button: "left".into(),
            x: 8,
            y: 0,
            fine: None,
        });
    }
    assert_eq!(s.cursor(), 25);
    // Shown as written, everywhere.
    s.eval("(run-command 'org-toggle-link-display)").unwrap();
    type_keys(&mut s, "j");
    assert_eq!(rows(&mut s).0, "See [[https://x.org][the site]] now");
    s.eval("(run-command 'org-toggle-link-display)").unwrap();
    assert_eq!(rows(&mut s).0, "See the site now");
}

#[test]
fn drawers_start_closed_and_tab_toggles_them() {
    let mut s = server("* Task\n:PROPERTIES:\n:ID: 1\n:END:\nBody\n** Child\nMore\n");
    s.eval("(set-major-mode! 'org-mode)").unwrap();
    let shown = |s: &mut imp_server::Server| {
        s.frame()
            .text_rows()
            .iter()
            .take(6)
            .map(|r| r.trim_end().to_string())
            .collect::<Vec<_>>()
    };
    let rows = shown(&mut s);
    assert!(rows[1].starts_with(":PROPERTIES:"), "{rows:?}");
    assert_eq!(rows[2], "Body", "{rows:?}");
    // <tab> on it opens it, and again closes it.
    type_keys(&mut s, "j<tab>");
    assert_eq!(shown(&mut s)[2], ":ID: 1");
    type_keys(&mut s, "<tab>");
    assert_eq!(shown(&mut s)[2], "Body");
    // The heading still cycles, its drawer closed when it opens.
    type_keys(&mut s, "gg<tab>");
    assert_eq!(s.status(), "FOLDED");
    type_keys(&mut s, "<tab>");
    assert_eq!(s.status(), "CHILDREN");
    type_keys(&mut s, "<tab>");
    assert_eq!(s.status(), "SUBTREE");
    let rows = shown(&mut s);
    assert_eq!(rows[2], "Body", "{rows:?}");
    assert_eq!(rows[3], "** Child", "{rows:?}");
    type_keys(&mut s, "<tab>");
    assert_eq!(s.status(), "FOLDED");
}

#[test]
fn org_indent_draws_sections_under_their_headings() {
    let mut s = server("Intro\n* One\nText one\n** Two\nText two\n*** Three\nText three\n");
    s.eval("(set-option! 'org-indent #t) (set-major-mode! 'org-mode)")
        .unwrap();
    let rows: Vec<String> = s.frame().text_rows()[..7]
        .iter()
        .map(|r| r.trim_end().to_string())
        .collect();
    assert_eq!(
        rows,
        [
            "Intro",
            "* One",
            "  Text one",
            " ** Two",
            "    Text two",
            "  *** Three",
            "      Text three",
        ]
    );
    // The cursor sits on the char, past the indent: "Text two"'s "x".
    type_keys(&mut s, "5G2l");
    assert_eq!(s.frame().cursor, (6, 4));
    // A click finds the char drawn there.
    s.frame();
    for action in ["press", "release"] {
        s.handle(imp_core::ClientMsg::Mouse {
            action: action.into(),
            button: "left".into(),
            x: 9,
            y: 6,
            fine: None,
        });
    }
    assert_eq!(s.eval("(current-col)").unwrap(), "3");
    // The file is unchanged; the command turns it off.
    assert!(s.text().starts_with("Intro\n* One\nText one\n"));
    s.eval("(run-command 'org-indent-mode)").unwrap();
    assert_eq!(s.frame().text_rows()[2].trim_end(), "Text one");
}

#[test]
fn heading_heights_come_from_the_option() {
    let mut s = server("* One\n** Two\nText\n");
    s.eval("(set-major-mode! 'org-mode)").unwrap();
    assert_eq!(
        s.eval(r#"(face-spec "org.height1")"#).unwrap(),
        "\"height=1.4\""
    );
    assert_eq!(
        s.eval(r#"(face-spec "org.height3")"#).unwrap(),
        "\"height=1.1\""
    );
    assert_eq!(s.eval(r#"(face-spec "org.height4")"#).unwrap(), "\"\"");
    // For a client that draws heights, a heading's text carries its
    // height; a theme change keeps it.
    s.eval("(load-theme! 'gruvbox-dark)").unwrap();
    assert_eq!(s.frame().rows[0][0].style.height, 0);
    s.set_heights(true);
    let style =
        |s: &mut imp_server::Server, row: usize| s.frame().windows[0].rows[row].spans[0].style;
    assert_eq!(style(&mut s, 0).height, 140);
    assert_eq!(style(&mut s, 1).height, 125);
    assert_eq!(style(&mut s, 2).height, 0);
    s.eval("(set-option! 'org-heading-heights '(2))").unwrap();
    assert_eq!(style(&mut s, 0).height, 200);
    assert_eq!(style(&mut s, 1).height, 0);
}

const PROPERTIES: &str = "#+property: owner Ann\n* Project\n:PROPERTIES:\n:Effort: 2h\n:CATEGORY: work\n:END:\n** TODO Task\nSCHEDULED: <2026-10-24 Sat>\n:PROPERTIES:\n:effort:   30m\n:END:\nbody\n:PROPERTIES:\n:Late: no\n:END:\n** Other\n* Loose\n";

#[test]
fn properties_are_read_from_the_drawer() {
    let mut s = server(PROPERTIES);
    let mut get = |line: usize, name: &str, inherit: bool| {
        s.eval(&format!(
            "(org-entry-property {line} {name:?} {})",
            if inherit { "#t" } else { "#f" }
        ))
        .unwrap()
    };
    // Its own drawer, after the planning line, any case.
    assert_eq!(get(6, "EFFORT", false), "\"30m\"");
    assert_eq!(get(11, "Effort", false), "\"30m\"");
    // A drawer further down the body isn't the property drawer.
    assert_eq!(get(6, "late", false), "#false");
    // Inherited from the parent, then the file.
    assert_eq!(get(15, "effort", false), "#false");
    assert_eq!(get(15, "effort", true), "\"2h\"");
    assert_eq!(get(15, "category", true), "\"work\"");
    assert_eq!(get(16, "owner", true), "\"Ann\"");
    assert_eq!(get(16, "owner", false), "#false");
    assert_eq!(get(0, "owner", true), "\"Ann\"");
}

#[test]
fn c_c_c_x_p_sets_and_removes_properties() {
    let mut s = server("* TODO Task\nSCHEDULED: <2026-10-24 Sat>\nbody\n* Next\n:PROPERTIES:\n:Effort: 1h\n:END:\n");
    s.eval("(set-major-mode! 'org-mode)").unwrap();
    // No drawer yet: made after the planning line.
    type_keys(&mut s, "<C-c><C-x>pOwner<ret>Ann<ret>");
    assert_eq!(
        s.text(),
        "* TODO Task\nSCHEDULED: <2026-10-24 Sat>\n:PROPERTIES:\n:Owner: Ann\n:END:\nbody\n* Next\n:PROPERTIES:\n:Effort: 1h\n:END:\n"
    );
    // One undo step.
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "* TODO Task\nSCHEDULED: <2026-10-24 Sat>\nbody\n* Next\n:PROPERTIES:\n:Effort: 1h\n:END:\n");
    // Names complete from the buffer's; another goes in the drawer.
    type_keys(&mut s, "G<C-c><C-x>peff<ret>");
    // The value starts as the current one.
    type_keys(&mut s, "<bs><bs>30m<ret>");
    assert_eq!(
        s.text(),
        "* TODO Task\nSCHEDULED: <2026-10-24 Sat>\nbody\n* Next\n:PROPERTIES:\n:Effort: 30m\n:END:\n"
    );
    type_keys(&mut s, " mPSize<ret>L<ret>");
    assert!(
        s.text().ends_with(":Effort: 30m\n:Size: L\n:END:\n"),
        "{}",
        s.text()
    );
    // An empty value removes it, and the last one takes the drawer.
    type_keys(&mut s, " mPSize<ret><bs><ret>");
    type_keys(&mut s, " mPEffort<ret><bs><bs><bs><ret>");
    assert_eq!(
        s.text(),
        "* TODO Task\nSCHEDULED: <2026-10-24 Sat>\nbody\n* Next\n"
    );
}

#[test]
fn c_c_c_q_adds_and_removes_tags() {
    let mut s = org(
        "tags.org",
        "* TODO Write the report\nbody\n* Other :home:\n",
    );
    s.eval("(set-option! 'org-agenda-files '())").unwrap();
    // A new tag, then one completed from the file's, then the first again
    // to take it off; <esc> ends.
    type_keys(&mut s, "j<C-c><C-q>work<ret>hom<ret>work<ret><esc>");
    let first = s.text().lines().next().unwrap().to_string();
    assert_eq!(
        first,
        format!("* TODO Write the report{}:home:", " ".repeat(77 - 23 - 6))
    );
    assert_eq!(first.chars().count(), 77);
    // A title too long for the column gets one space.
    s.eval("(set-option! 'org-tags-column -20)").unwrap();
    type_keys(&mut s, "gg<C-c><C-q>work<ret><esc>");
    assert_eq!(
        s.text().lines().next().unwrap(),
        "* TODO Write the report :home:work:"
    );
    // SPC m q too; taking every tag off leaves the title alone.
    type_keys(&mut s, " mqhome<ret>work<ret><esc>");
    assert_eq!(s.text().lines().next().unwrap(), "* TODO Write the report");
}

#[test]
fn c_c_c_x_e_sets_the_effort() {
    let mut s = org("effort.org", "* TODO Write\nSCHEDULED: <2026-10-24 Sat>\n");
    type_keys(&mut s, "<C-c><C-x>e0:45<ret>");
    assert_eq!(
        s.text(),
        "* TODO Write\nSCHEDULED: <2026-10-24 Sat>\n:PROPERTIES:\n:Effort: 0:45\n:END:\n"
    );
    // SPC m c E shows the effort to change; empty removes it.
    type_keys(&mut s, " mcE<C-u><ret>");
    assert_eq!(s.text(), "* TODO Write\nSCHEDULED: <2026-10-24 Sat>\n");
}

/// A directory holding `files`, as org-directory, and `name` open.
fn org_files(
    dir: &str,
    files: &[(&str, &str)],
    name: &str,
) -> (imp_server::Server, std::path::PathBuf) {
    let dir = temp_path(dir);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    for (f, text) in files {
        std::fs::write(dir.join(f), text).unwrap();
    }
    let mut s = server("");
    s.eval(&format!(
        "(set-option! 'org-directory {:?})",
        dir.display().to_string()
    ))
    .unwrap();
    type_keys(&mut s, &format!(":e {}<ret>", dir.join(name).display()));
    (s, dir)
}

#[test]
fn c_c_c_w_refiles_a_subtree_in_the_same_file() {
    let (mut s, _) = org_files(
        "org-refile-same",
        &[(
            "a.org",
            "* Inbox\n** TODO Call Ann\nnotes\n*** Sub\n* Projects\n** Garden\nplan\n* Later\n",
        )],
        "a.org",
    );
    // Under Projects, at the end of its subtree, one level below it.
    type_keys(&mut s, "j<C-c><C-w>Projects<ret>");
    assert_eq!(
        s.text(),
        "* Inbox\n* Projects\n** Garden\nplan\n** TODO Call Ann\nnotes\n*** Sub\n* Later\n"
    );
    // One undo step.
    type_keys(&mut s, "u");
    assert_eq!(
        s.text(),
        "* Inbox\n** TODO Call Ann\nnotes\n*** Sub\n* Projects\n** Garden\nplan\n* Later\n"
    );
    // Not under itself.
    type_keys(&mut s, "gg5j<C-c><C-w>Garden<ret>");
    assert!(s.status().contains("under itself"), "{}", s.status());
    // A level-2 heading under a level-1 one stays level 2.
    type_keys(&mut s, "gg5j mrInbox<ret>");
    assert_eq!(
        s.text(),
        "* Inbox\n** TODO Call Ann\nnotes\n*** Sub\n** Garden\nplan\n* Projects\n* Later\n"
    );
}

#[test]
fn c_c_c_w_refiles_into_another_file() {
    let (mut s, dir) = org_files(
        "org-refile-other",
        &[
            ("a.org", "* TODO Move me\nbody\n* Stay\n"),
            ("b.org", "* Target\n** Old\n"),
        ],
        "a.org",
    );
    type_keys(&mut s, "<C-c><C-w>b.org › Target<ret>");
    assert_eq!(s.text(), "* Stay\n");
    // b.org wasn't open: it is written.
    assert_eq!(
        std::fs::read_to_string(dir.join("b.org")).unwrap(),
        "* Target\n** Old\n** TODO Move me\nbody\n"
    );
}

#[test]
fn c_c_c_x_c_a_archives_a_subtree() {
    let (mut s, dir) = org_files(
        "org-archive",
        &[(
            "work.org",
            "#+CATEGORY: job\n* Projects\n** TODO Old task\nnotes\n*** Sub\n* Keep\n",
        )],
        "work.org",
    );
    s.eval(r#"(define (capture-clock) (list "2026-10-25" "Sun" "11:42" "Sunday" "October"))"#)
        .unwrap();
    type_keys(&mut s, "jj<C-c><C-x><C-a>");
    assert_eq!(s.text(), "#+CATEGORY: job\n* Projects\n* Keep\n");
    let path = dir.join("work.org").display().to_string();
    assert_eq!(
        std::fs::read_to_string(dir.join("work.org_archive")).unwrap(),
        format!(
            "#    -*- mode: org -*-\n\n\nArchived entries from file {path}\n\n\n* TODO Old task\n:PROPERTIES:\n:ARCHIVE_TIME: 2026-10-25 Sun 11:42\n:ARCHIVE_FILE: {path}\n:ARCHIVE_OLPATH: Projects\n:ARCHIVE_CATEGORY: job\n:ARCHIVE_TODO: TODO\n:END:\nnotes\n** Sub\n"
        )
    );
    // One undo puts it back, properties and all.
    type_keys(&mut s, "u");
    assert_eq!(
        s.text(),
        "#+CATEGORY: job\n* Projects\n** TODO Old task\nnotes\n*** Sub\n* Keep\n"
    );
    // Under a heading of a file of its own; the agenda doesn't read it.
    s.eval(r#"(set-option! 'org-archive-location "archive.org::* From %s")"#)
        .unwrap();
    type_keys(&mut s, "G mA");
    assert_eq!(
        std::fs::read_to_string(dir.join("archive.org"))
            .unwrap()
            .split("\n\n\n")
            .last()
            .unwrap(),
        "* From work.org\n** Keep\n:PROPERTIES:\n:ARCHIVE_TIME: 2026-10-25 Sun 11:42\n:ARCHIVE_FILE: "
            .to_string()
            + &path
            + "\n:ARCHIVE_CATEGORY: job\n:END:\n"
    );
    let files = s.eval("(org-agenda-file-list)").unwrap();
    assert!(
        files.contains("work.org") && !files.contains("archive.org"),
        "{files}"
    );
}
