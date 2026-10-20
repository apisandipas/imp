//! Org mode (runtime/org.scm).

mod common;

use common::*;

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
    // <tab> at the last cell makes a new row.
    // <ret> in normal state aligns, as typing doesn't.
    type_keys(&mut s, "<esc>$i<tab>beta<tab>2<esc><ret>");
    assert_eq!(
        s.text(),
        "| name  | n  |\n|-------+----|\n| alpha | 10 |\n| beta  | 2  |\n"
    );
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
fn agenda_and_capture() {
    let dir = temp_path("org-agenda");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("work.org"),
        "* TODO Write report\nSCHEDULED: <2000-01-02 Sun>\n* DONE Old thing\nDEADLINE: <2000-01-01 Sat>\n* TODO Plan trip\n* TODO Future\nDEADLINE: <2999-01-01 Thu>\n* Notes\n",
    )
    .unwrap();
    let mut s = server("");
    s.eval(&format!(
        "(set-option! 'org-directory {:?})",
        dir.display().to_string()
    ))
    .unwrap();
    type_keys(&mut s, ":OrgAgenda<ret>");
    let text = s.text();
    let overdue = text.find("Overdue").unwrap();
    let upcoming = text.find("Upcoming").unwrap();
    let todo = text.find("To do").unwrap();
    let report = text.find("Scheduled:  TODO Write report").expect(&text);
    let future = text.find("Deadline:   TODO Future").expect(&text);
    let trip = text.find("TODO Plan trip").expect(&text);
    assert!(
        overdue < report && report < upcoming && upcoming < future && future < todo && todo < trip,
        "{text}"
    );
    assert!(
        !text.contains("Old thing"),
        "DONE items are left out: {text}"
    );
    // <ret> visits the entry.
    let line = text.lines().position(|l| l.contains("Plan trip")).unwrap();
    s.eval(&format!("(set-cursor! (line-start {line}))"))
        .unwrap();
    type_keys(&mut s, "<ret>");
    assert!(s.eval("(buffer-name)").unwrap().contains("work.org"));
    assert_eq!(s.eval("(current-line)").unwrap(), "4");
    // Capture files into the notes file (tests/capture.rs has the rest).
    type_keys(&mut s, ":OrgCapture<ret>tBuy milk<C-c><C-c>");
    let inbox = std::fs::read_to_string(dir.join("inbox.org")).unwrap();
    assert!(inbox.starts_with("* Tasks\n** TODO Buy milk\n"), "{inbox}");
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
fn the_agenda_leaves_out_every_done_keyword() {
    let dir = temp_path("org-agenda-bar");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("work.org"),
        "* TODO Write\n* NEXT Plan\n* DONE Old\n* CANCELLED Dropped\n",
    )
    .unwrap();
    let mut s = server("");
    s.eval(KEYWORDS).unwrap();
    s.eval(&format!(
        "(set-option! 'org-directory {:?})",
        dir.display().to_string()
    ))
    .unwrap();
    type_keys(&mut s, ":OrgAgenda<ret>");
    let text = s.text();
    assert!(
        text.contains("TODO Write") && text.contains("NEXT Plan"),
        "{text}"
    );
    assert!(!text.contains("Old") && !text.contains("Dropped"), "{text}");
}
