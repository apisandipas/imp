//! The Org agenda's diary dates and habits (runtime/org-agenda.scm).

mod common;

use common::*;

/// A directory holding `files` (name, text), fresh each run.
fn org_dir(name: &str, files: &[(&str, &str)]) -> std::path::PathBuf {
    let dir = temp_path(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    for (file, text) in files {
        std::fs::write(dir.join(file), text).unwrap();
    }
    dir
}

const TODAY: &str =
    r#"(define (calendar-today) (list 2026 10 21)) (define (org-agenda-now) "11:42")"#;

/// The agenda over one file holding `text`, `width` columns wide, today
/// TODAY, after `setup`.
fn agenda(name: &str, text: &str, width: u16, setup: &str) -> imp_server::Server {
    let dir = org_dir(name, &[("a.org", text)]);
    let mut s = server("");
    s.eval(&format!(
        "(set-option! 'org-directory {:?})",
        dir.display().to_string()
    ))
    .unwrap();
    s.set_size(width, 60);
    s.eval(TODAY).unwrap();
    if !setup.is_empty() {
        s.eval(setup).unwrap();
    }
    type_keys(&mut s, ":OrgAgenda<ret>a");
    s
}

fn lines(s: &imp_server::Server) -> Vec<String> {
    s.text().lines().map(|l| l.trim_end().to_string()).collect()
}

/// The entry lines under `header`, words joined by one space.
fn under(lines: &[String], header: &str) -> Vec<String> {
    let at = lines
        .iter()
        .position(|l| l.trim_start_matches(['▌', ' ']) == header)
        .unwrap_or_else(|| panic!("no {header} in {lines:#?}"));
    lines[at + 2..]
        .iter()
        .take_while(|l| !l.is_empty())
        .filter(|l| !l.contains('┄') && !l.contains('━'))
        .map(|l| l.split_whitespace().collect::<Vec<_>>().join(" "))
        .collect()
}

const DIARY: &str = "* Ana is %d <%%(diary-anniversary 10 22 1990)>
* Thanksgiving
<%%(diary-float 11 4 4)>
* Book club <%%(diary-float t 3 3) 19:00>
* Trip
<%%(diary-block 10 19 2026 10 20 2026)>
* Bins <%%(diary-cyclic 14 10 10 2026)>
* Payday <%%(diary-date t 23 t)>
* Moon <%%(lunar-phases)>
";

#[test]
fn diary_dates_fall_on_the_days_they_give() {
    let s = agenda("org-diary-days", DIARY, 72, "");
    let lines = lines(&s);
    assert_eq!(under(&lines, "Monday 19 October"), ["Trip a"], "{lines:#?}");
    assert_eq!(under(&lines, "Tuesday 20 October"), ["Trip a"]);
    assert_eq!(
        under(&lines, "Wednesday 21 October · today"),
        ["19:00 Book club a"]
    );
    // The count of years in place of %d, the sexp itself not shown.
    assert_eq!(under(&lines, "Thursday 22 October"), ["Ana is 36 a"]);
    assert_eq!(under(&lines, "Friday 23 October"), ["Payday a"]);
    assert_eq!(under(&lines, "Saturday 24 October"), ["Bins a"]);
    // The 4th Thursday of November comes later.
    let later = under(&lines, "Later");
    assert!(
        later.contains(&"Thu 26 Nov Thanksgiving a".to_string()),
        "{later:?}"
    );
    // A sexp it doesn't read is skipped, and the last line says so.
    assert!(!s.text().contains("Moon"), "{lines:#?}");
    let last = lines.iter().rev().find(|l| !l.is_empty()).unwrap();
    assert!(last.contains("1 diary sexp skipped"), "{last}");
}

#[test]
fn diary_dates_follow_calendar_date_style() {
    let text = "* Ana is %d <%%(diary-anniversary 22 10 1990)>\n* Trip <%%(diary-block 2026 10 19 2026 10 19)>\n";
    let s = agenda(
        "org-diary-european",
        text,
        72,
        "(set-option! 'calendar-date-style 'european)",
    );
    let shown = lines(&s);
    assert_eq!(
        under(&shown, "Thursday 22 October"),
        ["Ana is 36 a"],
        "{shown:#?}"
    );
    // In European order the block's 2026 is a day, so it falls nowhere.
    assert!(under(&shown, "Monday 19 October").is_empty());
    let s = agenda(
        "org-diary-iso",
        text,
        72,
        "(set-option! 'calendar-date-style 'iso)",
    );
    assert_eq!(under(&lines(&s), "Monday 19 October"), ["Trip a"]);
}

#[test]
fn diary_forms_count_from_the_month_s_end_and_skip_leap_days() {
    // The last Friday of each month; 29 February in other years is 1
    // March, as Emacs.
    let mut s = server("");
    s.eval(TODAY).unwrap();
    let on = |s: &mut imp_server::Server, form: &str, day: &str| {
        s.eval(&format!(
            "(org-diary-on? (org-diary-parse {form:?}) (list {day}))"
        ))
        .unwrap()
    };
    assert_eq!(on(&mut s, "diary-float t 5 -1", "2026 10 30"), "#true");
    assert_eq!(on(&mut s, "diary-float t 5 -1", "2026 10 23"), "#false");
    assert_eq!(
        on(&mut s, "diary-anniversary 2 29 2000", "2027 3 1"),
        "#true"
    );
    assert_eq!(
        on(&mut s, "diary-anniversary 2 29 2000", "2028 2 29"),
        "#true"
    );
    assert_eq!(
        on(&mut s, "diary-anniversary 2 29 2000", "2028 3 1"),
        "#false"
    );
    // Not on its own day, only the years after.
    assert_eq!(
        on(&mut s, "diary-anniversary 10 22 2026", "2026 10 22"),
        "#false"
    );
    assert_eq!(
        on(&mut s, "diary-cyclic 3 10 20 2026", "2026 10 19"),
        "#false"
    );
    assert_eq!(
        on(&mut s, "diary-cyclic 3 10 20 2026", "2026 10 23"),
        "#true"
    );
    assert_eq!(
        s.eval(r#"(org-diary-parse "diary-float 13 1 1")"#).unwrap(),
        r#"(unknown "diary-float 13 1 1")"#
    );
}

#[test]
fn a_diary_date_can_t_be_moved() {
    let mut s = agenda("org-diary-move", DIARY, 72, "");
    let line = s.text().lines().position(|l| l.contains("Payday")).unwrap();
    s.eval(&format!("(set-cursor! (line-start {line}))"))
        .unwrap();
    type_keys(&mut s, "L");
    assert!(s.status().contains("can't be moved"), "{}", s.status());
}

const HABITS: &str = "* TODO Exercise
SCHEDULED: <2026-10-21 Wed .+2d>
:PROPERTIES:
:STYLE:    habit
:END:
:LOGBOOK:
- State \"DONE\"       from \"TODO\"       [2026-10-19 Mon 08:00]
- State \"DONE\"       from \"TODO\"       [2026-10-17 Sat 08:00]
- State \"DONE\"       from \"TODO\"       [2026-10-10 Sat 08:00]
:END:
* TODO Stretch
SCHEDULED: <2026-10-18 Sun .+1d>
:PROPERTIES:
:STYLE:    habit
:END:
* TODO Water the plants
SCHEDULED: <2026-10-23 Fri ++1w>
:PROPERTIES:
:STYLE:    habit
:END:
* TODO Not a habit
SCHEDULED: <2026-10-18 Sun +1d>
";

#[test]
fn habits_show_on_today_only_with_a_graph() {
    let s = agenda("org-habits", HABITS, 100, "");
    let lines = lines(&s);
    let today = under(&lines, "Wednesday 21 October · today");
    // Due today, and 3 days late; Water the plants isn't due until
    // Friday. Not a habit repeats, so it is on each day too.
    assert_eq!(today.len(), 3, "{lines:#?}");
    assert!(today[0].starts_with("Sched. TODO Exercise *"), "{today:?}");
    assert!(
        today
            .iter()
            .any(|l| l.starts_with("Sched. 3x TODO Stretch")),
        "{today:?}"
    );
    assert!(today
        .iter()
        .any(|l| l.starts_with("Sched. TODO Not a habit")));
    // The graph: done on the 10th, 17th and 19th, ! today.
    let exercise = lines.iter().find(|l| l.contains("Exercise")).unwrap();
    assert!(exercise.contains("*      * * !      "), "{exercise}");
    // Never overdue or later, nor on another day.
    assert_eq!(
        under(&lines, "Overdue"),
        ["Sched. 3x TODO Not a habit a"],
        "{lines:#?}"
    );
    assert_eq!(
        under(&lines, "Later"),
        ["Sun 25 Oct Sched. TODO Not a habit a"]
    );
    assert!(!s.text().contains("Water"), "{lines:#?}");
}

/// The faces of habit `title`'s graph on TODAY, as names after
/// org.agenda.habit.
fn graph_faces(s: &mut imp_server::Server, title: &str) -> Vec<String> {
    let out = s
        .eval(&format!(
            "(map cadr (org-habit-graph (car (filter (lambda (e) (equal? (cadddr e) {title:?})) \
             (apply append (map org-file-entries (org-agenda-file-list))))) (list 2026 10 21)))"
        ))
        .unwrap();
    out.split('"')
        .filter(|p| p.starts_with("org.agenda.habit."))
        .map(|p| p["org.agenda.habit.".len()..].to_string())
        .collect()
}

#[test]
fn the_graph_is_colored_as_org_s() {
    let mut s = agenda("org-habit-faces", HABITS, 100, "");
    let mut want: Vec<&str> = vec!["clear-future"; 10]; // 30 Sep to 9 Oct
    want.push("ready"); // done on the 10th, its first
    want.push("clear-future"); // the 11th, before it was due again
    want.push("alert-future"); // the 12th, its last day, not done
    want.extend(["overdue"; 4]); // the 13th to 16th
    want.push("overdue"); // done late on the 17th
    want.push("clear-future"); // the 18th
    want.push("ready"); // done on the 19th, when due
    want.push("clear-future"); // the 20th
    want.push("alert"); // today, its last day
    want.extend(["overdue-future"; 6]); // the days after
    assert_eq!(graph_faces(&mut s, "Exercise"), want);
}

#[test]
fn a_habit_may_give_the_most_it_may_wait() {
    let mut s = agenda(
        "org-habit-most",
        "* TODO Run\nSCHEDULED: <2026-10-21 Wed .+2d/4d>\n:PROPERTIES:\n:STYLE: habit\n:END:\n",
        100,
        "",
    );
    // Due from today until two days on: ready today, alert on the 23rd.
    let faces = graph_faces(&mut s, "Run");
    assert_eq!(&faces[21..24], ["ready", "ready-future", "alert-future"]);
    // The repeater is kept as written.
    assert_eq!(
        s.eval(r#"(org-stamp->string (org-parse-stamp "<2026-10-21 Wed .+2d/4d>"))"#)
            .unwrap(),
        r#""<2026-10-21 Wed .+2d/4d>""#
    );
}

#[test]
fn every_theme_colors_the_habit_graph() {
    let mut s = agenda("org-habit-themes", HABITS, 100, "");
    let themes = s.eval("(hash-keys->list *themes*)").unwrap();
    for theme in themes
        .trim_matches(|c| c == '(' || c == ')')
        .split_whitespace()
    {
        s.eval(&format!("(load-theme! '{theme})")).unwrap();
        for face in ["clear", "ready", "alert", "overdue"] {
            for name in [face.to_string(), format!("{face}-future")] {
                let spec = s
                    .eval(&format!("(face-spec \"org.agenda.habit.{name}\")"))
                    .unwrap();
                assert!(spec.contains("bg=#"), "{theme} {name}: {spec}");
            }
        }
    }
    // Modus Vivendi's org-habit faces.
    s.eval("(use-package! 'modus-themes) (load-theme! 'modus-vivendi)")
        .unwrap();
    assert_eq!(
        s.eval("(face-spec \"org.agenda.habit.clear\")").unwrap(),
        "\"fg=#000000 bg=#2fafef\""
    );
}
