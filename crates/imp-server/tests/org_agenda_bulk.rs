//! The Org agenda's filters and bulk actions (runtime/org-agenda.scm).

mod common;

use common::*;

const TODAY: &str =
    r#"(define (calendar-today) (list 2026 10 21)) (define (org-agenda-now) "11:42")"#;

/// The agenda over `files` (name, text) in a fresh directory, on the
/// week of 21 October 2026, without the time grid.
fn agenda_files(name: &str, files: &[(&str, &str)]) -> (imp_server::Server, std::path::PathBuf) {
    let dir = temp_path(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    for (file, text) in files {
        std::fs::write(dir.join(file), text).unwrap();
    }
    let mut s = server("");
    s.eval(&format!(
        "(set-option! 'org-directory {:?})",
        dir.display().to_string()
    ))
    .unwrap();
    s.set_size(100, 50);
    s.eval(TODAY).unwrap();
    s.eval(r#"(set-option! 'org-todo-keywords '("TODO" "NEXT" "|" "DONE"))"#)
        .unwrap();
    s.eval("(set-option! 'org-agenda-use-time-grid #f)")
        .unwrap();
    type_keys(&mut s, ":org-agenda<ret>a");
    (s, dir)
}

fn lines(s: &imp_server::Server) -> Vec<String> {
    s.text().lines().map(|l| l.trim_end().to_string()).collect()
}

/// Whether the agenda shows a line holding `text`.
fn shows(s: &imp_server::Server, text: &str) -> bool {
    lines(s).iter().any(|l| l.contains(text))
}

/// Puts the cursor on the agenda line holding `text`.
fn go_to(s: &mut imp_server::Server, text: &str) {
    let at = lines(s)
        .iter()
        .position(|l| l.contains(text))
        .unwrap_or_else(|| panic!("no {text} in {:#?}", lines(s)));
    s.eval(&format!("(set-cursor! (line-start {at}))")).unwrap();
}

const MIXED: &str = "* Work
** TODO Report :office:
:PROPERTIES:
:Effort: 0:30
:END:
** TODO Slides :office:urgent:
:PROPERTIES:
:Effort: 2:00
:END:
* Home
** TODO Garden :outside:
** TODO Groceries
SCHEDULED: <2026-10-22 Thu>
";

#[test]
fn filters_by_tag_category_effort_regexp_and_top_heading() {
    let (mut s, _dir) = agenda_files(
        "agenda-filter",
        &[
            ("a.org", MIXED),
            ("b.org", "#+CATEGORY: errands\n* TODO Post office\n"),
        ],
    );
    // A tag, then one left out: they add up, and show in the title.
    type_keys(&mut s, "stoffice<ret>");
    assert!(shows(&s, "Report") && shows(&s, "Slides"));
    assert!(!shows(&s, "Garden") && !shows(&s, "Post office"));
    type_keys(&mut s, "st-urgent<ret>");
    assert!(shows(&s, "Report") && !shows(&s, "Slides"));
    assert!(shows(&s, "Filter: +office -urgent"), "{:#?}", lines(&s));
    // They last through moving and redrawing; S removes them.
    type_keys(&mut s, "fbgr");
    assert!(!shows(&s, "Slides"), "{:#?}", lines(&s));
    type_keys(&mut s, "S");
    assert!(shows(&s, "Slides") && shows(&s, "Post office") && !shows(&s, "Filter:"));
    // The category of the entry at the cursor.
    go_to(&mut s, "Post office");
    type_keys(&mut s, "sc");
    assert!(shows(&s, "Post office") && !shows(&s, "Report"));
    assert!(shows(&s, "Filter: cat:errands"), "{:#?}", lines(&s));
    type_keys(&mut s, "S");
    // Effort: only entries with one that fits.
    type_keys(&mut s, "se<1:00<ret>");
    assert!(shows(&s, "Report") && !shows(&s, "Slides") && !shows(&s, "Garden"));
    type_keys(&mut s, "S");
    // A regexp over the title, ignoring case.
    type_keys(&mut s, "sr^g<ret>");
    assert!(shows(&s, "Garden") && shows(&s, "Groceries") && !shows(&s, "Report"));
    type_keys(&mut s, "S");
    // The top-level heading of the entry at the cursor.
    go_to(&mut s, "Garden");
    type_keys(&mut s, "s^");
    assert!(shows(&s, "Garden") && shows(&s, "Groceries") && !shows(&s, "Slides"));
    assert!(shows(&s, "Filter: ^Home"), "{:#?}", lines(&s));
}

#[test]
fn a_section_left_empty_by_a_filter_goes() {
    let (mut s, _dir) = agenda_files("agenda-filter-empty", &[("a.org", MIXED)]);
    assert!(shows(&s, "To do"));
    // Only Groceries is left, on Thursday: no To do section.
    type_keys(&mut s, "srgroc<ret>");
    assert!(!shows(&s, "To do"), "{:#?}", lines(&s));
    assert!(shows(&s, "Groceries") && shows(&s, "Thursday 22 October"));
    // gD keeps the filter; a new view drops it.
    type_keys(&mut s, "gDd");
    assert!(shows(&s, "Filter:"), "{:#?}", lines(&s));
    type_keys(&mut s, ":org-agenda<ret>a");
    assert!(!shows(&s, "Filter:") && shows(&s, "To do"));
}

/// The agenda's line holding `text`.
fn line_with(s: &imp_server::Server, text: &str) -> String {
    lines(s)
        .into_iter()
        .find(|l| l.contains(text))
        .unwrap_or_else(|| panic!("no {text} in {:#?}", lines(s)))
}

fn marked(s: &imp_server::Server, text: &str) -> bool {
    line_with(s, text).contains('▸')
}

fn line_text(s: &mut imp_server::Server) -> String {
    let n: usize = s.eval("(current-line)").unwrap().parse().unwrap();
    lines(s)[n].clone()
}

#[test]
fn marks_toggle_add_up_and_clear() {
    let (mut s, _dir) = agenda_files("agenda-marks", &[("a.org", MIXED)]);
    // m marks and moves down; again unmarks.
    go_to(&mut s, "Report");
    type_keys(&mut s, "m");
    assert!(marked(&s, "Report") && !marked(&s, "Slides"));
    assert!(
        line_text(&mut s).contains("Slides"),
        "{}",
        line_text(&mut s)
    );
    type_keys(&mut s, "m");
    assert!(marked(&s, "Slides"));
    go_to(&mut s, "Report");
    type_keys(&mut s, "m");
    assert!(!marked(&s, "Report") && marked(&s, "Slides"));
    // ~ flips every mark; M clears them; * marks every entry.
    type_keys(&mut s, "~");
    assert!(marked(&s, "Report") && marked(&s, "Garden") && !marked(&s, "Slides"));
    type_keys(&mut s, "M");
    assert!(lines(&s).iter().all(|l| !l.contains('▸')));
    type_keys(&mut s, "*");
    assert!(marked(&s, "Report") && marked(&s, "Groceries"));
    type_keys(&mut s, "M");
    // % marks the titles a regexp matches; marks last through gr.
    type_keys(&mut s, "%^g<ret>gr");
    assert!(marked(&s, "Garden") && marked(&s, "Groceries") && !marked(&s, "Report"));
    // The mark is in the mark column, before the line's other parts.
    assert!(
        line_with(&s, "Garden").starts_with("  ▸ "),
        "{}",
        line_with(&s, "Garden")
    );
}

#[test]
fn the_marked_face_is_modus_s_selection_mark() {
    let mut s = server("");
    s.eval("(use-package! 'modus-themes) (load-theme! 'modus-vivendi)")
        .unwrap();
    assert_eq!(
        s.eval("(face-spec \"org.agenda.marked\")").unwrap(),
        "\"fg=#00d3d0 bg=#004065 bold\""
    );
}

fn file(dir: &std::path::Path, name: &str) -> String {
    std::fs::read_to_string(dir.join(name)).unwrap()
}

/// Marks the agenda lines holding each of `titles`.
fn mark(s: &mut imp_server::Server, titles: &[&str]) {
    for t in titles {
        go_to(s, t);
        type_keys(s, "m");
    }
}

#[test]
fn x_sets_keywords_dates_and_tags_on_the_marked_entries() {
    let (mut s, dir) = agenda_files("agenda-bulk", &[("a.org", MIXED)]);
    // Nothing marked: x says so.
    type_keys(&mut s, "x");
    assert!(s.status().contains("no marked"), "{}", s.status());
    // A keyword, once for both; the marks clear; u undoes it all.
    mark(&mut s, &["Report", "Garden"]);
    type_keys(&mut s, "xtNEXT<ret>");
    let a = file(&dir, "a.org");
    assert!(
        a.contains("** NEXT Report")
            && a.contains("** NEXT Garden")
            && a.contains("** TODO Slides"),
        "{a}"
    );
    assert!(lines(&s).iter().all(|l| !l.contains('▸')));
    assert!(s.status().contains("2 entries"), "{}", s.status());
    type_keys(&mut s, "u");
    assert_eq!(file(&dir, "a.org"), MIXED);
    // Schedule, then move the dates by two days.
    mark(&mut s, &["Slides", "Groceries"]);
    type_keys(&mut s, "xsfri<ret>");
    let a = file(&dir, "a.org");
    assert!(a.matches("SCHEDULED: <2026-10-23 Fri>").count() == 2, "{a}");
    mark(&mut s, &["Slides", "Groceries"]);
    type_keys(&mut s, "xS2<ret>");
    let a = file(&dir, "a.org");
    assert!(a.matches("SCHEDULED: <2026-10-25 Sun>").count() == 2, "{a}");
    // A deadline.
    mark(&mut s, &["Report"]);
    type_keys(&mut s, "xdfri<ret>");
    assert!(file(&dir, "a.org").contains("DEADLINE: <2026-10-23 Fri>"));
    // Add a tag, then remove one.
    mark(&mut s, &["Report", "Garden"]);
    type_keys(&mut s, "x+big<ret>");
    let a = file(&dir, "a.org");
    assert!(
        a.lines()
            .any(|l| l.starts_with("** TODO Report") && l.ends_with(":office:big:"))
            && a.lines()
                .any(|l| l.starts_with("** TODO Garden") && l.ends_with(":outside:big:")),
        "{a}"
    );
    mark(&mut s, &["Report", "Garden"]);
    type_keys(&mut s, "x-big<ret>");
    assert!(
        !file(&dir, "a.org").contains("big"),
        "{}",
        file(&dir, "a.org")
    );
}

#[test]
fn x_refiles_archives_and_deletes_the_marked_entries() {
    let (mut s, dir) = agenda_files(
        "agenda-bulk-move",
        &[
            (
                "a.org",
                "* TODO One\n* TODO Two\n* TODO Three\n* TODO Four\n* TODO Five\n* TODO Keep\n",
            ),
            ("b.org", "* Target\n"),
        ],
    );
    mark(&mut s, &["One", "Two"]);
    type_keys(&mut s, "xrb.org › Target<ret>");
    assert_eq!(file(&dir, "b.org"), "* Target\n** TODO One\n** TODO Two\n");
    mark(&mut s, &["Three", "Four"]);
    type_keys(&mut s, "x$");
    let archive = file(&dir, "a.org_archive");
    assert!(
        archive.contains("* TODO Three") && archive.contains("* TODO Four"),
        "{archive}"
    );
    // Delete asks first.
    mark(&mut s, &["Five"]);
    type_keys(&mut s, "xkn");
    assert!(file(&dir, "a.org").contains("Five"));
    type_keys(&mut s, "xky");
    assert_eq!(file(&dir, "a.org"), "* TODO Keep\n");
}
