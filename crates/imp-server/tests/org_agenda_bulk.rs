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
    type_keys(&mut s, ":OrgAgenda<ret>a");
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
    type_keys(&mut s, ":OrgAgenda<ret>a");
    assert!(!shows(&s, "Filter:") && shows(&s, "To do"));
}
