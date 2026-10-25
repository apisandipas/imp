//! The Org agenda (runtime/org-agenda.scm).

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

/// A server whose org-directory is `dir`.
fn agenda_server(dir: &std::path::Path) -> imp_server::Server {
    let mut s = server("");
    s.eval(&format!(
        "(set-option! 'org-directory {:?})",
        dir.display().to_string()
    ))
    .unwrap();
    s
}

/// Where in `text` the first line holding each of `parts`, in order,
/// starts.
fn find_line(text: &str, parts: &[&str]) -> usize {
    let mut at = 0;
    for line in text.split_inclusive('\n') {
        let mut from = 0;
        if parts
            .iter()
            .all(|p| line[from..].find(p).map(|i| from += i + p.len()).is_some())
        {
            return at;
        }
        at += line.len();
    }
    panic!("no line with {parts:?} in\n{text}")
}

/// `expr` over the entries the agenda reads from `file` in `dir`.
fn entries(s: &mut imp_server::Server, dir: &std::path::Path, file: &str, expr: &str) -> String {
    s.eval(&format!(
        "(map {expr} (org-file-entries {:?}))",
        dir.join(file).display().to_string()
    ))
    .unwrap()
}

#[test]
fn the_agenda_sorts_by_priority() {
    let dir = org_dir(
        "org-prio-agenda",
        &[(
            "p.org",
            "* TODO [#C] Low\n* TODO None first\n* TODO [#A] High\n* TODO None second\n* TODO [#C] Due low\nDEADLINE: <2000-01-01 Sat>\n* TODO [#A] Due high\nDEADLINE: <2000-01-01 Sat>\n",
        )],
    );
    let mut s = agenda_server(&dir);
    type_keys(&mut s, ":OrgAgenda<ret>");
    let text = s.text();
    let at = |what: &str| {
        text.find(what)
            .unwrap_or_else(|| panic!("{what} in {text}"))
    };
    // Same date: A before C. No date: A, then the ones with none (as B) in
    // file order, then C.
    assert!(at("Due high") < at("Due low"), "{text}");
    assert!(
        at("High") < at("None first")
            && at("None first") < at("None second")
            && at("None second") < at("[#C] Low"),
        "{text}"
    );
}

#[test]
fn agenda_and_capture() {
    let dir = org_dir(
        "org-agenda",
        &[(
            "work.org",
            "* TODO Write report\nSCHEDULED: <2000-01-02 Sun>\n* DONE Old thing\nDEADLINE: <2000-01-01 Sat>\n* TODO Plan trip\n* TODO Future\nDEADLINE: <2999-01-01 Thu>\n* Notes\n",
        )],
    );
    let mut s = agenda_server(&dir);
    type_keys(&mut s, ":OrgAgenda<ret>");
    let text = s.text();
    let overdue = text.find("Overdue").unwrap();
    let todo = text.find("To do").unwrap();
    let report = find_line(&text, &["Sched.", "TODO", "Write report"]);
    let trip = find_line(&text, &["TODO", "Plan trip"]);
    assert!(overdue < report && report < todo && todo < trip, "{text}");
    // A date after the week is under Later, before To do.
    let later = text.find("Later").expect(&text);
    let future = find_line(&text, &["Jan 2999", "Deadline", "TODO", "Future"]);
    assert!(report < later && later < future && future < todo, "{text}");
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
fn the_agenda_leaves_out_every_done_keyword() {
    let dir = org_dir(
        "org-agenda-bar",
        &[(
            "work.org",
            "* TODO Write\n* NEXT Plan\n* DONE Old\n* CANCELLED Dropped\n",
        )],
    );
    let mut s = agenda_server(&dir);
    s.eval(r#"(set-option! 'org-todo-keywords '("TODO" "NEXT" "|" "DONE" "CANCELLED"))"#)
        .unwrap();
    type_keys(&mut s, ":OrgAgenda<ret>");
    let text = s.text();
    find_line(&text, &["TODO", "Write"]);
    find_line(&text, &["NEXT", "Plan"]);
    assert!(!text.contains("Old") && !text.contains("Dropped"), "{text}");
}

const TAGGED: &str = "#+FILETAGS: :home:
* Projects :work:
** TODO Write <2026-10-25 Sun 10:00-11:00> :urgent:work:
Meet <2026-10-26 Mon>--<2026-10-28 Wed>, not [2026-10-01 Thu]
SCHEDULED: <2026-10-24 Sat> DEADLINE: <2026-10-30 Fri -3d>
* Other
";

#[test]
fn an_entry_s_tags_are_its_own_then_inherited() {
    let dir = org_dir("org-agenda-tags", &[("t.org", TAGGED)]);
    let mut s = agenda_server(&dir);
    // Own first, then the headings' above, then the file's; each once.
    assert_eq!(
        entries(
            &mut s,
            &dir,
            "t.org",
            "(lambda (e) (map car (org-entry-tags e)))"
        ),
        r#"(("work" "home") ("urgent" "work" "home") ("home"))"#
    );
    assert_eq!(
        entries(
            &mut s,
            &dir,
            "t.org",
            "(lambda (e) (map cdr (org-entry-tags e)))"
        ),
        "((#true #false) (#true #true #false) (#false))"
    );
    // The title is without its keyword and tags.
    assert_eq!(
        entries(&mut s, &dir, "t.org", "cadddr"),
        r#"("Projects" "Write <2026-10-25 Sun 10:00-11:00>" "Other")"#
    );
}

#[test]
fn appointments_are_the_other_active_timestamps() {
    let dir = org_dir("org-agenda-appts", &[("t.org", TAGGED)]);
    let mut s = agenda_server(&dir);
    // The heading's, with its time range, then the text's range; not the
    // inactive one, nor SCHEDULED: and DEADLINE:.
    let apps = entries(
        &mut s,
        &dir,
        "t.org",
        "(lambda (e) (map (lambda (a) (list (cadr (car a)) (caddr (car a)) (and (cadr a) (cadr (cadr a))))) (org-entry-appointments e)))",
    );
    assert_eq!(
        apps,
        r#"(() (((2026 10 25) "10:00-11:00" #false) ((2026 10 26) #false (2026 10 28))) ())"#
    );
    // The planning line's dates are still the entry's.
    assert_eq!(
        entries(
            &mut s,
            &dir,
            "t.org",
            "(lambda (e) (and (list-ref e 5) (list-ref (list-ref e 5) 4)))"
        ),
        r#"(#false ("-" 3 "d") #false)"#
    );
}

#[test]
fn an_open_file_is_read_from_its_buffer() {
    let dir = org_dir("org-agenda-buffer", &[("b.org", "* TODO On disk\n")]);
    let mut s = agenda_server(&dir);
    type_keys(
        &mut s,
        &format!(
            ":e {}<ret>:s/On disk/Unsaved/<ret>",
            dir.join("b.org").display()
        ),
    );
    // Not saved: the agenda reads the buffer.
    type_keys(&mut s, ":OrgAgenda<ret>");
    let text = s.text();
    assert!(text.contains("Unsaved"), "{text}");
    assert!(!text.contains("On disk"), "{text}");
}

/// Wednesday 21 October 2026, in a week from Sunday 18 to Saturday 24.
/// The title's rule, 71 wide in a 72-column window.
const RULE: &str = "───────────────────────────────────────────────────────────────────────";

const TODAY: &str = "(define (calendar-today) (list 2026 10 21))";

const WEEK: &str = "#+CATEGORY: work
* TODO [#A] Send the invoice :money:
SCHEDULED: <2026-10-21 Wed>
* NEXT A title long enough that the agenda has to cut it short to fit :long:tags:
DEADLINE: <2026-10-22 Thu>
* Dentist :health:
SCHEDULED: <2026-10-24 Sat 10:00>
* TODO Undated
";

/// The agenda over WEEK, `width` columns wide.
fn week(name: &str, width: u16) -> (imp_server::Server, Vec<String>) {
    let dir = org_dir(name, &[("w.org", WEEK)]);
    let mut s = agenda_server(&dir);
    s.set_size(width, 40);
    s.eval(TODAY).unwrap();
    s.eval(r#"(set-option! 'org-todo-keywords '("TODO" "NEXT" "|" "DONE"))"#)
        .unwrap();
    type_keys(&mut s, ":OrgAgenda<ret>");
    let lines = s.text().lines().map(str::to_string).collect();
    (s, lines)
}

/// The column `part` starts at on the line holding `on`.
fn column(lines: &[String], on: &str, part: &str) -> usize {
    let line = lines
        .iter()
        .find(|l| l.contains(on))
        .unwrap_or_else(|| panic!("no {on} in {lines:#?}"));
    line[..line.find(part).unwrap()].chars().count()
}

#[test]
fn the_title_line_has_the_week_and_a_rule() {
    let (_, lines) = week("org-agenda-week-1", 100);
    assert_eq!(lines[0], " Agenda");
    assert_eq!(lines[1], " Week 43 · 18–24 Oct 2026");
    assert_eq!(lines[2], "─".repeat(99));
}

#[test]
fn days_and_sections_have_headers_with_rules() {
    let (_, lines) = week("org-agenda-week-2", 100);
    let at = |text: &str| {
        lines
            .iter()
            .position(|l| l == text)
            .unwrap_or_else(|| panic!("no {text:?} in {lines:#?}"))
    };
    // Today has the accent bar; each header has a rule as long as it.
    let today = at("▌ Wednesday 21 October · today");
    assert_eq!(lines[today + 1], format!("  {}", "─".repeat(28)));
    let sunday = at("  Sunday 18 October");
    assert_eq!(lines[sunday + 1], format!("  {}", "─".repeat(17)));
    let todo = at("  To do");
    assert_eq!(lines[todo + 1], "  ─────");
    // No Overdue or Later: nothing is in them.
    assert!(!lines
        .iter()
        .any(|l| l.contains("Overdue") || l.contains("Later")));
}

#[test]
fn entries_line_up_in_columns() {
    let (_, lines) = week("org-agenda-week-3", 100);
    // The keyword, title, tags' end and category line up down the agenda.
    let title = column(&lines, "Send the invoice", "[#A]");
    assert_eq!(column(&lines, "Dentist", "Dentist"), title);
    assert_eq!(column(&lines, "Undated", "Undated"), title);
    let kw = column(&lines, "Send the invoice", "TODO");
    assert_eq!(column(&lines, "A title long", "NEXT"), kw);
    let category = column(&lines, "Send the invoice", " work") + 1;
    for on in ["A title long", "Dentist", "Undated"] {
        assert_eq!(column(&lines, on, " work") + 1, category, "{on}");
    }
    let tags_end = |on: &str, tags: &str| column(&lines, on, tags) + tags.chars().count();
    assert_eq!(
        tags_end("Dentist", ":health:"),
        tags_end("Send the invoice", ":money:")
    );
    // The what and time columns.
    assert!(lines
        .iter()
        .any(|l| l.contains("Sched.") && l.contains("Send the invoice")));
    assert!(lines
        .iter()
        .any(|l| l.contains("Deadline") && l.contains("A title long")));
}

#[test]
fn a_long_title_is_cut_and_narrow_windows_drop_tags() {
    let (_, lines) = week("org-agenda-week-4", 100);
    let long = lines.iter().find(|l| l.contains("A title long")).unwrap();
    assert!(long.contains("…"), "{long}");
    assert!(long.contains(":long:tags:"), "{long}");
    assert_eq!(long.trim_end().chars().count(), 99, "{long}");
    let (_, lines) = week("org-agenda-week-5", 58);
    let text = lines.join("\n");
    assert!(
        !text.contains(":money:") && !text.contains(":health:"),
        "{text}"
    );
    assert!(lines.iter().all(|l| l.chars().count() < 58), "{text}");
}

#[test]
fn every_theme_colors_the_agenda() {
    let (mut s, _) = week("org-agenda-week-6", 100);
    let faces = [
        "title",
        "span",
        "rule",
        "section",
        "date",
        "weekend",
        "today",
        "time",
        "scheduled",
        "deadline",
        "overdue",
        "upcoming",
        "tag",
        "category",
    ];
    let themes = s.eval("(hash-keys->list *themes*)").unwrap();
    for theme in themes
        .trim_matches(|c| c == '(' || c == ')')
        .split_whitespace()
    {
        s.eval(&format!("(load-theme! '{theme})")).unwrap();
        for face in faces {
            let spec = s
                .eval(&format!("(face-spec \"org.agenda.{face}\")"))
                .unwrap();
            assert!(spec.contains("fg="), "{theme} org.agenda.{face}: {spec}");
        }
    }
    // Weekends are drawn apart from other days.
    s.eval("(load-theme! 'one-dark)").unwrap();
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
    assert_ne!(style("Saturday").fg, style("Monday").fg);
}

#[test]
fn the_window_client_draws_the_title_and_headers_larger() {
    let (mut s, lines) = week("org-agenda-week-7", 100);
    s.set_heights(true);
    let frame = s.frame();
    let height = |row: usize, word: &str| {
        frame.windows[0].rows[row]
            .spans
            .iter()
            .find(|sp| sp.text.contains(word))
            .unwrap_or_else(|| panic!("no {word} on row {row}"))
            .style
            .height
    };
    assert_eq!(height(0, "Agenda"), 140);
    let monday = lines.iter().position(|l| l.contains("Monday")).unwrap();
    assert_eq!(height(monday, "Monday"), 125);
}

/// The agenda over one file holding `text`, 72 columns wide, today
/// TODAY.
fn agenda(name: &str, text: &str) -> imp_server::Server {
    let dir = org_dir(name, &[("a.org", text)]);
    let mut s = agenda_server(&dir);
    s.set_size(72, 60);
    s.eval(TODAY).unwrap();
    type_keys(&mut s, ":OrgAgenda<ret>");
    s
}

fn lines(s: &imp_server::Server) -> Vec<String> {
    s.text().lines().map(|l| l.trim_end().to_string()).collect()
}

#[test]
fn the_agenda_is_a_week_with_repeats_on_each_day() {
    let mut s = agenda(
        "agenda-week",
        "* TODO Pay\nSCHEDULED: <2026-10-20 Tue>\n* TODO Water\nSCHEDULED: <2026-10-01 Thu +1w>\n* TODO Ship\nDEADLINE: <2026-10-23 Fri>\n* TODO Later\nDEADLINE: <2026-12-01 Tue>\n* TODO Someday\n* DONE Gone\nSCHEDULED: <2026-10-22 Thu>\n",
    );
    assert_eq!(
        lines(&s),
        [
            " Agenda",
            " Week 43 · 18–24 Oct 2026",
            RULE,
            "",
            "  Overdue",
            "  ───────",
            "    Thu 1 Oct   Sched.    TODO  Water                                 a",
            "    Tue 20 Oct  Sched.    TODO  Pay                                   a",
            "",
            "  Sunday 18 October",
            "  ─────────────────",
            "",
            "  Monday 19 October",
            "  ─────────────────",
            "",
            "  Tuesday 20 October",
            "  ──────────────────",
            "                Sched.    TODO  Pay                                   a",
            "",
            "▌ Wednesday 21 October · today",
            "  ────────────────────────────",
            "",
            "  Thursday 22 October",
            "  ───────────────────",
            "                Sched.    TODO  Water                                 a",
            "",
            "  Friday 23 October",
            "  ─────────────────",
            "                Deadline  TODO  Ship                                  a",
            "",
            "  Saturday 24 October",
            "  ───────────────────",
            "",
            "  Later",
            "  ─────",
            "    Thu 29 Oct  Sched.    TODO  Water                                 a",
            "    Tue 1 Dec   Deadline  TODO  Later                                 a",
            "",
            "  To do",
            "  ─────",
            "                          TODO  Someday                               a",
        ]
    );
    // f shows the next week, the repeat on its Thursday; . comes back.
    type_keys(&mut s, "f");
    let next = lines(&s);
    assert_eq!(next[1], " Week 44 · 25–31 Oct 2026");
    let thu = next.iter().position(|l| l.contains("Thursday")).unwrap();
    assert_eq!(next[thu], "  Thursday 29 October");
    assert!(next[thu + 2].contains("Sched.    TODO  Water"), "{next:#?}");
    type_keys(&mut s, "bb");
    assert_eq!(lines(&s)[1], " Week 42 · 11–17 Oct 2026");
    type_keys(&mut s, ".");
    assert_eq!(lines(&s)[1], " Week 43 · 18–24 Oct 2026");
    // A span of 3 days has no week number.
    s.eval("(set-option! 'org-agenda-span 3)").unwrap();
    type_keys(&mut s, "gr");
    assert_eq!(lines(&s)[1], " 18–20 Oct 2026");
}

#[test]
fn the_agenda_shows_each_entry_s_category() {
    let s = agenda(
        "agenda-category",
        "#+CATEGORY: home\n* TODO Plain\n* Work\n:PROPERTIES:\n:CATEGORY: job\n:END:\n** TODO Report\n",
    );
    let text = lines(&s);
    assert!(
        text.iter()
            .any(|l| l.contains("TODO  Plain") && l.ends_with("home")),
        "{text:?}"
    );
    assert!(
        text.iter()
            .any(|l| l.contains("TODO  Report") && l.ends_with(" job")),
        "{text:?}"
    );
}
