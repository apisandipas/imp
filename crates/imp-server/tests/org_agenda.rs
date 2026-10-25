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

const TODAY: &str =
    r#"(define (calendar-today) (list 2026 10 21)) (define (org-agenda-now) "11:42")"#;

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
        "grid",
        "now",
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
    // The grid has its own test.
    s.eval("(set-option! 'org-agenda-use-time-grid #f)")
        .unwrap();
    type_keys(&mut s, "gr");
    assert_eq!(
        lines(&s),
        [
            " Agenda",
            " Week 43 · 18–24 Oct 2026",
            RULE,
            "",
            "  Overdue",
            "  ───────",
            "                Sched. 20x  TODO  Water                               a",
            "                Sched. 1x   TODO  Pay                                 a",
            "",
            "  Sunday 18 October",
            "  ─────────────────",
            "",
            "  Monday 19 October",
            "  ─────────────────",
            "",
            "  Tuesday 20 October",
            "  ──────────────────",
            "                Sched.      TODO  Pay                                 a",
            "",
            "▌ Wednesday 21 October · today",
            "  ────────────────────────────",
            "                In 2 d.     TODO  Ship                                a",
            "",
            "  Thursday 22 October",
            "  ───────────────────",
            "                Sched.      TODO  Water                               a",
            "",
            "  Friday 23 October",
            "  ─────────────────",
            "                Deadline    TODO  Ship                                a",
            "",
            "  Saturday 24 October",
            "  ───────────────────",
            "",
            "  Later",
            "  ─────",
            "    Thu 29 Oct  Sched.      TODO  Water                               a",
            "    Tue 1 Dec   Deadline    TODO  Later                               a",
            "",
            "  To do",
            "  ─────",
            "                            TODO  Someday                             a",
        ]
    );
    // f shows the next week, the repeat on its Thursday; . comes back.
    type_keys(&mut s, "f");
    let next = lines(&s);
    assert_eq!(next[1], " Week 44 · 25–31 Oct 2026");
    let thu = next.iter().position(|l| l.contains("Thursday")).unwrap();
    assert_eq!(next[thu], "  Thursday 29 October");
    assert!(
        next[thu + 2].contains("Sched.") && next[thu + 2].contains("Water"),
        "{next:#?}"
    );
    // Overdue is only there when the span has today.
    assert!(!next.iter().any(|l| l.contains("Overdue")), "{next:#?}");
    type_keys(&mut s, "bb");
    assert_eq!(lines(&s)[1], " Week 42 · 11–17 Oct 2026");
    type_keys(&mut s, ".");
    assert_eq!(lines(&s)[1], " Week 43 · 18–24 Oct 2026");
    // A span of 3 days starts on today, and has no week number.
    s.eval("(set-option! 'org-agenda-span 3)").unwrap();
    type_keys(&mut s, ":OrgAgenda<ret>");
    assert_eq!(lines(&s)[1], " 21–23 Oct 2026");
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

/// The lines under `header` in `lines`, up to the next blank one.
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

#[test]
fn timed_entries_come_first_by_time() {
    let s = agenda(
        "agenda-times",
        "* TODO [#A] Untimed first\nSCHEDULED: <2026-10-21 Wed>\n* Lunch <2026-10-21 Wed 12:30>\n* TODO Late\nSCHEDULED: <2026-10-21 Wed 16:00>\n* Stand-up\n<2026-10-21 Wed 9:30-10:00>\n* TODO Untimed\nSCHEDULED: <2026-10-21 Wed>\n",
    );
    assert_eq!(
        under(&lines(&s), "Wednesday 21 October · today"),
        [
            "9:30-10:00 Stand-up a",
            "12:30 Lunch a",
            "16:00 Sched. TODO Late a",
            "Sched. TODO [#A] Untimed first a",
            "Sched. TODO Untimed a",
        ]
    );
}

#[test]
fn deadlines_warn_on_today() {
    let mut s = agenda(
        "agenda-warnings",
        "* TODO Soon\nDEADLINE: <2026-10-31 Sat>\n* TODO Too far\nDEADLINE: <2026-11-10 Tue>\n* TODO Own warning\nDEADLINE: <2026-10-25 Sun -3d>\n* TODO Own warning, close\nDEADLINE: <2026-10-23 Fri -3d>\n",
    );
    let shown = lines(&s);
    // 14 days by default; an entry's -3d wins. Each also shows on its day
    // when that is in the span.
    assert_eq!(
        under(&shown, "Wednesday 21 October · today"),
        ["In 10 d. TODO Soon a", "In 2 d. TODO Own warning, close a"]
    );
    assert_eq!(
        under(&shown, "Friday 23 October"),
        ["Deadline TODO Own warning, close a"]
    );
    s.eval("(set-option! 'org-deadline-warning-days 30)")
        .unwrap();
    type_keys(&mut s, "gr");
    assert!(under(&lines(&s), "Wednesday 21 October · today")
        .contains(&"In 20 d. TODO Too far a".to_string()));
}

#[test]
fn appointments_and_ranges_show_on_their_days() {
    let s = agenda(
        "agenda-ranges",
        "* Trip\n<2026-10-20 Tue>--<2026-10-22 Thu>\n* Past meeting <2026-10-19 Mon 15:00>\n* Party <2026-11-07 Sat 20:00>\n* TODO Done is out\n* DONE Gone <2026-10-21 Wed>\n",
    );
    let lines = lines(&s);
    assert_eq!(under(&lines, "Tuesday 20 October"), ["(1/3) Trip a"]);
    assert_eq!(
        under(&lines, "Wednesday 21 October · today"),
        ["(2/3) Trip a"]
    );
    assert_eq!(under(&lines, "Thursday 22 October"), ["(3/3) Trip a"]);
    assert_eq!(under(&lines, "Monday 19 October"), ["15:00 Past meeting a"]);
    // A past appointment isn't overdue; a later one is under Later.
    assert!(!lines.iter().any(|l| l.contains("Overdue")), "{lines:#?}");
    assert_eq!(under(&lines, "Later"), ["Sat 7 Nov 20:00 Party a"]);
    // A TODO with an appointment isn't undated.
    assert_eq!(under(&lines, "To do"), ["TODO Done is out a"]);
}

#[test]
fn today_has_a_time_grid_and_a_now_line() {
    let mut s = agenda(
        "agenda-grid",
        "* Stand-up\n<2026-10-21 Wed 9:30-10:00>\n* Lunch <2026-10-21 Wed 12:00>\n* TODO Untimed\nSCHEDULED: <2026-10-21 Wed>\n* Call <2026-10-23 Fri 15:00>\n* TODO Plain\nSCHEDULED: <2026-10-22 Thu>\n",
    );
    let shown = lines(&s);
    let today = shown.iter().position(|l| l.contains("Wednesday")).unwrap();
    let day: Vec<String> = shown[today + 2..]
        .iter()
        .take_while(|l| !l.is_empty())
        .map(|l| l.trim_end_matches(['┄', '━']).trim_end().to_string())
        .collect();
    // In time order; no 12:00 line, as Lunch is at 12:00; now after the
    // entries before it. Grid times line up with the entries' times.
    assert_eq!(
        day,
        [
            "    08:00",
            "    9:30-10:00                Stand-up                                a",
            "    10:00",
            "    11:42       ━━━━━━━━━━━━━━━━ now",
            "    12:00                     Lunch                                   a",
            "    14:00",
            "    16:00",
            "    18:00",
            "    20:00",
            "                Sched.  TODO  Untimed                                 a",
        ],
        "{shown:#?}"
    );
    assert!(shown[today + 2].ends_with('┄'), "{}", shown[today + 2]);
    // Another day has the grid only with something timed.
    let after = |day: &str| {
        let at = shown.iter().position(|l| l.contains(day)).unwrap();
        shown[at + 2].clone()
    };
    assert!(after("Friday").contains("08:00"), "{shown:#?}");
    assert!(after("Thursday").contains("Plain"), "{shown:#?}");
    // Off, and the timed entries still sort by time.
    s.eval("(set-option! 'org-agenda-use-time-grid #f)")
        .unwrap();
    type_keys(&mut s, "gr");
    assert_eq!(
        under(&lines(&s), "Wednesday 21 October · today"),
        [
            "9:30-10:00 Stand-up a",
            "12:00 Lunch a",
            "Sched. TODO Untimed a"
        ]
    );
    assert!(!lines(&s).iter().any(|l| l.contains('┄')));
}

#[test]
fn the_week_starts_on_org_agenda_start_on_weekday() {
    let mut s = agenda("agenda-weekday", "* TODO Thing\n");
    assert_eq!(lines(&s)[1], " Week 43 · 18–24 Oct 2026");
    s.eval("(set-option! 'org-agenda-start-on-weekday 1)")
        .unwrap();
    type_keys(&mut s, ":OrgAgenda<ret>");
    assert_eq!(lines(&s)[1], " Week 43 · 19–25 Oct 2026");
    s.eval("(set-option! 'org-agenda-start-on-weekday #f)")
        .unwrap();
    type_keys(&mut s, ":OrgAgenda<ret>");
    assert_eq!(lines(&s)[1], " Week 43 · 21–27 Oct 2026");
}

#[test]
fn the_cursor_starts_on_today() {
    let mut s = agenda("agenda-cursor", "* TODO Thing\n");
    let today = lines(&s).iter().position(|l| l.starts_with('▌')).unwrap();
    assert_eq!(s.eval("(current-line)").unwrap(), today.to_string());
    // A week without today starts at the top; . comes back to today.
    type_keys(&mut s, "f");
    assert_eq!(s.eval("(current-line)").unwrap(), "0");
    type_keys(&mut s, ".");
    assert_eq!(s.eval("(current-line)").unwrap(), today.to_string());
}

const MOVES: &str = "* TODO First\nSCHEDULED: <2026-10-19 Mon>\n* TODO Second\nSCHEDULED: <2026-10-21 Wed>\n* TODO Third\nDEADLINE: <2026-10-23 Fri>\n* TODO Far\nSCHEDULED: <2026-11-12 Thu>\n";

fn line_text(s: &mut imp_server::Server) -> String {
    let n: usize = s.eval("(current-line)").unwrap().parse().unwrap();
    lines(s)[n].clone()
}

#[test]
fn gj_and_gk_move_between_entries() {
    let mut s = agenda("agenda-gj", MOVES);
    s.eval("(set-option! 'org-agenda-use-time-grid #f)")
        .unwrap();
    type_keys(&mut s, ":OrgAgenda<ret>");
    // From today's header, past the rule and the next day's header.
    type_keys(&mut s, "gj");
    assert!(
        line_text(&mut s).contains("Second"),
        "{}",
        line_text(&mut s)
    );
    type_keys(&mut s, "gj");
    assert!(line_text(&mut s).contains("Third"));
    type_keys(&mut s, "<C-k><C-k>");
    assert!(line_text(&mut s).contains("First"));
    type_keys(&mut s, "2gj");
    assert!(line_text(&mut s).contains("Third"));
    // ]] and [[ move by the span.
    type_keys(&mut s, "]]");
    assert_eq!(lines(&s)[1], " Week 44 · 25–31 Oct 2026");
    type_keys(&mut s, "[[[[");
    assert_eq!(lines(&s)[1], " Week 42 · 11–17 Oct 2026");
}

#[test]
fn gd_goes_to_a_date() {
    let mut s = agenda("agenda-gd", MOVES);
    type_keys(&mut s, "gd11-12<ret>");
    assert_eq!(lines(&s)[1], " Week 46 · 8–14 Nov 2026");
    assert_eq!(line_text(&mut s), "  Thursday 12 November");
}

#[test]
fn tab_shows_the_entry_in_another_window() {
    let dir = org_dir("agenda-tab", &[("a.org", MOVES)]);
    let mut s = agenda_server(&dir);
    s.set_size(100, 40);
    s.eval(TODAY).unwrap();
    type_keys(&mut s, ":OrgAgenda<ret>gj");
    type_keys(&mut s, "<tab>");
    // The cursor stays in the agenda; the other window has the file, on
    // the entry's heading.
    assert_eq!(s.eval("(major-mode)").unwrap(), "org-agenda-mode");
    let windows = s.eval("(length (window-list))").unwrap();
    assert_eq!(windows, "2");
    let other = s
        .eval("(with-buffer (window-buffer (list-find (lambda (w) (not (= w (current-window)))) (window-list))) (lambda () (list (buffer-name) (current-line))))")
        .unwrap();
    assert!(other.contains("a.org") && other.ends_with(" 2)"), "{other}");
    // Follow mode shows each entry the cursor moves to.
    type_keys(&mut s, "Fgj");
    let other = s
        .eval("(with-buffer (window-buffer (list-find (lambda (w) (not (= w (current-window)))) (window-list))) current-line)")
        .unwrap();
    assert_eq!(other, "4");
    // ZQ closes the agenda and the file it opened.
    type_keys(&mut s, "ZQ");
    let names = s.eval("(map buffer-name-of (buffer-list))").unwrap();
    assert!(
        !names.contains("a.org") && !names.contains("agenda*\" "),
        "{names}"
    );
}

#[test]
fn zq_keeps_files_that_were_open_already() {
    let dir = org_dir("agenda-zq", &[("a.org", MOVES)]);
    let mut s = agenda_server(&dir);
    s.eval(TODAY).unwrap();
    type_keys(&mut s, &format!(":e {}<ret>", dir.join("a.org").display()));
    type_keys(&mut s, ":OrgAgenda<ret>gj<ret>:OrgAgenda<ret>ZQ");
    let names = s.eval("(map buffer-name-of (buffer-list))").unwrap();
    assert!(names.contains("a.org"), "{names}");
}

#[test]
fn gh_gm_gl_go_to_the_window_s_top_middle_and_bottom() {
    let mut s = agenda("agenda-hml", MOVES);
    let line = |s: &mut imp_server::Server, keys: &str| -> usize {
        type_keys(s, keys);
        s.eval("(current-line)").unwrap().parse().unwrap()
    };
    let top = line(&mut s, "gH");
    let middle = line(&mut s, "gM");
    let bottom = line(&mut s, "gL");
    assert_eq!(top, 0);
    assert!(top < middle && middle < bottom, "{top} {middle} {bottom}");
}

#[test]
fn which_key_names_the_agenda_s_keys() {
    let mut s = agenda("agenda-which-key", MOVES);
    s.eval("(set-option! 'which-key-delay 0)").unwrap();
    type_keys(&mut s, "g");
    let shown = s.frame().text_rows().join("\n");
    for label in ["next entry", "go to date", "refresh all", "window top"] {
        assert!(shown.contains(label), "{label} in\n{shown}");
    }
}

/// The agenda over `files` in a fresh directory, today TODAY, the grid
/// off; returns the directory too.
fn agenda_files(name: &str, files: &[(&str, &str)]) -> (imp_server::Server, std::path::PathBuf) {
    let dir = org_dir(name, files);
    let mut s = agenda_server(&dir);
    s.set_size(100, 50);
    s.eval(TODAY).unwrap();
    s.eval(r#"(set-option! 'org-todo-keywords '("TODO" "NEXT" "|" "DONE"))"#)
        .unwrap();
    s.eval("(set-option! 'org-agenda-use-time-grid #f)")
        .unwrap();
    type_keys(&mut s, ":OrgAgenda<ret>");
    (s, dir)
}

/// Puts the cursor on the agenda line holding `text`.
fn go_to(s: &mut imp_server::Server, text: &str) {
    let at = lines(s)
        .iter()
        .position(|l| l.contains(text))
        .unwrap_or_else(|| panic!("no {text} in {:#?}", lines(s)));
    s.eval(&format!("(set-cursor! (line-start {at}))")).unwrap();
}

#[test]
fn t_changes_the_entry_s_keyword_in_its_file() {
    let (mut s, dir) = agenda_files(
        "agenda-t",
        &[(
            "a.org",
            "* TODO Write\nSCHEDULED: <2026-10-21 Wed>\n* TODO Other\n",
        )],
    );
    go_to(&mut s, "Write");
    type_keys(&mut s, "t");
    // Not open before: opened in the background, changed and saved.
    assert_eq!(
        std::fs::read_to_string(dir.join("a.org")).unwrap(),
        "* NEXT Write\nSCHEDULED: <2026-10-21 Wed>\n* TODO Other\n"
    );
    assert_eq!(s.eval("(major-mode)").unwrap(), "org-agenda-mode");
    assert!(line_text(&mut s).contains("NEXT") && line_text(&mut s).contains("Write"));
    // Done: it leaves the view, the cursor staying where it was.
    type_keys(&mut s, "t");
    assert!(
        !lines(&s).iter().any(|l| l.contains("Write")),
        "{:#?}",
        lines(&s)
    );
    // SPC m t picks one.
    go_to(&mut s, "Other");
    type_keys(&mut s, " mtNEXT<ret>");
    assert!(std::fs::read_to_string(dir.join("a.org"))
        .unwrap()
        .contains("* NEXT Other"));
}

#[test]
fn a_buffer_with_unsaved_changes_is_changed_but_not_saved() {
    let (mut s, dir) = agenda_files(
        "agenda-unsaved",
        &[("a.org", "* TODO Write\n* TODO Keep\n")],
    );
    let path = dir.join("a.org");
    type_keys(
        &mut s,
        &format!(
            ":e {}<ret>Gcc* TODO Kept<esc>:OrgAgenda<ret>",
            path.display()
        ),
    );
    go_to(&mut s, "Write");
    type_keys(&mut s, "t");
    // The file is as it was; the buffer has both changes.
    assert_eq!(
        std::fs::read_to_string(&path).unwrap(),
        "* TODO Write\n* TODO Keep\n"
    );
    let id = s
        .eval(&format!(
            "(buffer-for-path {:?})",
            path.display().to_string()
        ))
        .unwrap();
    assert_eq!(
        s.eval(&format!(
            "(with-buffer {id} (lambda () (buffer-substring 0 (buffer-length))))"
        ))
        .unwrap(),
        "\"* NEXT Write\\n* TODO Kept\\n\""
    );
}

fn file(dir: &std::path::Path, name: &str) -> String {
    std::fs::read_to_string(dir.join(name)).unwrap()
}

#[test]
fn schedule_and_deadline_from_the_agenda() {
    let (mut s, dir) = agenda_files("agenda-plan", &[("a.org", "* TODO Write\n")]);
    go_to(&mut s, "Write");
    type_keys(&mut s, " mdsfri<ret>");
    assert_eq!(
        file(&dir, "a.org"),
        "* TODO Write\nSCHEDULED: <2026-10-23 Fri>\n"
    );
    // It moved from To do to Friday, and the cursor went with it.
    assert!(
        lines(&s).iter().all(|l| !l.contains("To do")),
        "{:#?}",
        lines(&s)
    );
    assert!(line_text(&mut s).contains("Write"), "{}", line_text(&mut s));
    type_keys(&mut s, " mdd+3<ret>");
    assert_eq!(
        file(&dir, "a.org"),
        "* TODO Write\nSCHEDULED: <2026-10-23 Fri> DEADLINE: <2026-10-24 Sat>\n"
    );
}

#[test]
fn h_and_l_move_the_line_s_date() {
    let (mut s, dir) = agenda_files(
        "agenda-hl",
        &[(
            "a.org",
            "* TODO Write\nSCHEDULED: <2026-10-21 Wed 10:00 +1w> DEADLINE: <2026-10-23 Fri>\n* Lunch\nwith Ann <2026-10-22 Thu 12:30>\n",
        )],
    );
    // The scheduled line: its date, keeping time and repeater.
    go_to(&mut s, "Sched.");
    type_keys(&mut s, "L");
    assert_eq!(
        file(&dir, "a.org"),
        "* TODO Write\nSCHEDULED: <2026-10-22 Thu 10:00 +1w> DEADLINE: <2026-10-23 Fri>\n* Lunch\nwith Ann <2026-10-22 Thu 12:30>\n"
    );
    // The deadline's line moves the deadline; 2H is two days.
    go_to(&mut s, "Deadline");
    type_keys(&mut s, "2H");
    assert!(
        file(&dir, "a.org").contains("DEADLINE: <2026-10-21 Wed>"),
        "{}",
        file(&dir, "a.org")
    );
    // An appointment.
    go_to(&mut s, "Lunch");
    type_keys(&mut s, "L");
    assert!(
        file(&dir, "a.org").ends_with("with Ann <2026-10-23 Fri 12:30>\n"),
        "{}",
        file(&dir, "a.org")
    );
    assert!(line_text(&mut s).contains("Lunch"));
}

#[test]
fn priority_tags_and_effort_from_the_agenda() {
    let (mut s, dir) = agenda_files(
        "agenda-prio",
        &[("a.org", "* Area :home:\n** TODO Write :work:\n")],
    );
    go_to(&mut s, "Write");
    // None counts as B: up is A, and A is the top.
    type_keys(&mut s, "++");
    assert_eq!(
        file(&dir, "a.org"),
        "* Area :home:\n** TODO [#A] Write :work:\n"
    );
    type_keys(&mut s, "---");
    assert!(file(&dir, "a.org").contains("[#C] Write"));
    type_keys(&mut s, " mp ");
    assert!(
        file(&dir, "a.org").contains("** TODO Write"),
        "{}",
        file(&dir, "a.org")
    );
    // Tags: own ones toggle, inherited ones aren't the entry's to remove.
    type_keys(&mut s, "ctwork<ret>urgent<ret><esc>");
    let heading = file(&dir, "a.org").lines().nth(1).unwrap().to_string();
    assert!(
        heading.starts_with("** TODO Write ") && heading.ends_with(" :urgent:"),
        "{heading}"
    );
    // Effort.
    type_keys(&mut s, "ce1:30<ret>");
    assert!(
        file(&dir, "a.org").contains(":Effort: 1:30"),
        "{}",
        file(&dir, "a.org")
    );
}

#[test]
fn refile_archive_and_delete_from_the_agenda() {
    let (mut s, dir) = agenda_files(
        "agenda-move",
        &[
            ("a.org", "* TODO Move\n** sub\n* TODO Archive\n* TODO Archive too\n* TODO Delete\nbody\n* TODO Keep\n"),
            ("b.org", "* Target\n"),
        ],
    );
    go_to(&mut s, "Move");
    type_keys(&mut s, " mrb.org › Target<ret>");
    assert_eq!(file(&dir, "b.org"), "* Target\n** TODO Move\n*** sub\n");
    assert!(!file(&dir, "a.org").contains("Move"));
    // da asks; n keeps it, y archives.
    go_to(&mut s, "Archive too");
    type_keys(&mut s, "dan");
    assert!(file(&dir, "a.org").contains("Archive too"));
    type_keys(&mut s, "day");
    assert!(!file(&dir, "a.org").contains("Archive too"));
    assert!(file(&dir, "a.org_archive").contains("* TODO Archive too"));
    // dA doesn't ask.
    go_to(&mut s, "Archive");
    type_keys(&mut s, "dA");
    assert!(file(&dir, "a.org_archive").contains("* TODO Archive\n"));
    // dd asks, then deletes the subtree.
    go_to(&mut s, "Delete");
    type_keys(&mut s, "ddy");
    assert_eq!(file(&dir, "a.org"), "* TODO Keep\n");
    assert!(lines(&s).iter().all(|l| !l.contains("Delete")));
}

#[test]
fn u_undoes_the_last_change_from_the_agenda() {
    let (mut s, dir) = agenda_files(
        "agenda-undo",
        &[
            ("a.org", "* TODO Write\nSCHEDULED: <2026-10-21 Wed>\n"),
            ("b.org", "* Target\n"),
        ],
    );
    go_to(&mut s, "Write");
    type_keys(&mut s, "Ltt");
    // The last change only, saved again.
    type_keys(&mut s, "u");
    assert_eq!(
        file(&dir, "a.org"),
        "* NEXT Write\nSCHEDULED: <2026-10-22 Thu>\n"
    );
    assert!(s.status().contains("undone"), "{}", s.status());
    type_keys(&mut s, "u");
    assert!(s.status().contains("no change"), "{}", s.status());
    // A refile into another file can't be undone.
    go_to(&mut s, "Write");
    type_keys(&mut s, " mrb.org › Target<ret>u");
    assert!(s.status().contains("no change"), "{}", s.status());
    assert!(file(&dir, "b.org").contains("Write") && !file(&dir, "a.org").contains("Write"));
}

#[test]
fn c_captures_for_the_line_s_day() {
    let (mut s, dir) = agenda_files(
        "agenda-capture",
        &[("a.org", "* TODO Thing\nSCHEDULED: <2026-10-23 Fri>\n")],
    );
    s.eval(
        r#"(define (capture-clock) (list "2026-10-21" "Wed" "09:15" "Wednesday" "October"))
           (set! *capture-templates* '())
           (define-capture-template! "t" "Todo" '(file "inbox.org") "* TODO %?\nSCHEDULED: %t")"#,
    )
    .unwrap();
    go_to(&mut s, "Thing");
    type_keys(&mut s, "CCall Ann<C-c><C-c>");
    assert_eq!(
        file(&dir, "inbox.org"),
        "* TODO Call Ann\nSCHEDULED: <2026-10-23 Fri>\n"
    );
    // A capture from anywhere else is for today again.
    type_keys(&mut s, ":OrgCapture<ret>Later<C-c><C-c>");
    assert!(
        file(&dir, "inbox.org").ends_with("* TODO Later\nSCHEDULED: <2026-10-21 Wed>\n"),
        "{}",
        file(&dir, "inbox.org")
    );
}

#[test]
fn spc_m_names_the_agenda_s_groups() {
    let (mut s, _) = agenda_files("agenda-wk-groups", &[("a.org", "* TODO X\n")]);
    s.eval("(set-option! 'which-key-delay 0)").unwrap();
    type_keys(&mut s, " m");
    let shown = s.frame().text_rows().join("\n");
    assert!(
        shown.contains("d → +dates") && shown.contains("t → set TODO"),
        "{shown}"
    );
    // An Org buffer's SPC m d is its own: the agenda's group name goes.
    type_keys(&mut s, "<esc>");
    let dir = temp_path("agenda-wk-groups");
    type_keys(
        &mut s,
        &format!(":e {}<ret> m", dir.join("a.org").display()),
    );
    let shown = s.frame().text_rows().join("\n");
    assert!(
        shown.contains("d → deadline") && shown.contains("c → +clock"),
        "{shown}"
    );
}

#[test]
fn spc_o_a_a_opens_the_agenda() {
    let dir = org_dir("agenda-spc", &[("a.org", "* TODO Thing\n")]);
    let mut s = agenda_server(&dir);
    s.eval("(set-option! 'which-key-delay 0)").unwrap();
    type_keys(&mut s, " oa");
    assert!(s.frame().text_rows().join("\n").contains("a → agenda"));
    type_keys(&mut s, "a");
    assert_eq!(s.eval("(major-mode)").unwrap(), "org-agenda-mode");
    type_keys(&mut s, "q");
    s.eval("(run-command 'org-agenda-list)").unwrap();
    assert_eq!(s.eval("(major-mode)").unwrap(), "org-agenda-mode");
}

#[test]
fn gd_changes_the_span() {
    let (mut s, _) = agenda_files(
        "agenda-gD",
        &[("a.org", "* TODO Thing\nSCHEDULED: <2026-10-23 Fri 10:00>\n")],
    );
    // A day: the one the cursor is on (today).
    type_keys(&mut s, "gDd");
    assert_eq!(lines(&s)[1], " 21 Oct 2026");
    type_keys(&mut s, "f");
    assert_eq!(lines(&s)[1], " 22 Oct 2026");
    // A fortnight, a month from its first, a year from 1 January; f moves
    // a month or a year.
    type_keys(&mut s, ".gDt");
    assert_eq!(lines(&s)[1], " 18–31 Oct 2026");
    type_keys(&mut s, "gDm");
    assert_eq!(lines(&s)[1], " 1–31 Oct 2026");
    type_keys(&mut s, "f");
    assert_eq!(lines(&s)[1], " 1–30 Nov 2026");
    type_keys(&mut s, "gDy");
    assert_eq!(lines(&s)[1], " 1 Jan – 31 Dec 2026");
    type_keys(&mut s, "b");
    assert_eq!(lines(&s)[1], " 1 Jan – 31 Dec 2025");
    type_keys(&mut s, ".gDw");
    assert_eq!(lines(&s)[1], " Week 43 · 18–24 Oct 2026");
    // The grid: off in these tests, on with gD g; opening again resets both.
    assert!(!lines(&s).iter().any(|l| l.contains('┄')));
    type_keys(&mut s, "gDg");
    assert!(lines(&s).iter().any(|l| l.contains('┄')));
    type_keys(&mut s, "gDm:OrgAgenda<ret>");
    assert_eq!(lines(&s)[1], " Week 43 · 18–24 Oct 2026");
    assert!(!lines(&s).iter().any(|l| l.contains('┄')));
}

#[test]
fn the_todo_list_has_every_undone_todo() {
    let (mut s, _) = agenda_files(
        "agenda-todo-list",
        &[(
            "a.org",
            "* TODO [#C] Low\nSCHEDULED: <2026-10-21 Wed>\n* NEXT Next one\n* Notes\n* TODO [#A] High\n* DONE Done\n* TODO Plain\n",
        )],
    );
    s.eval("(set-option! 'which-key-delay 0)").unwrap();
    type_keys(&mut s, " oat");
    let shown = lines(&s);
    assert_eq!(shown[0], " To do");
    assert_eq!(shown[1], " Every keyword · 4 entries");
    // By priority, none as B, then file order; dated ones too; no plain
    // headings or done ones.
    let rest: Vec<String> = shown[3..]
        .iter()
        .filter(|l| !l.is_empty())
        .map(|l| l.split_whitespace().collect::<Vec<_>>().join(" "))
        .collect();
    assert_eq!(
        rest,
        [
            "TODO [#A] High a",
            "NEXT Next one a",
            "TODO Plain a",
            "TODO [#C] Low a"
        ]
    );
    // One keyword.
    s.eval("(org-todo-list! \"NEXT\")").unwrap();
    assert_eq!(lines(&s)[0], " To do: NEXT");
    assert_eq!(lines(&s)[1], " NEXT · 1 entry");
    // t on it still acts, and the list redraws.
    go_to(&mut s, "Next one");
    type_keys(&mut s, "t");
    assert_eq!(lines(&s)[1], " NEXT · 0 entries");
}

const MATCHING: &str = "#+FILETAGS: :org:
* Work :work:
** TODO [#A] Urgent report :urgent:
:PROPERTIES:
:Effort: 0:30
:END:
** NEXT Plan
:PROPERTIES:
:Effort: 2:00
:END:
** DONE Shipped
* Home :home:
** TODO Garden
";

/// The titles a tags match `text` shows, in order.
fn matched(s: &mut imp_server::Server, text: &str, todo_only: bool) -> Vec<String> {
    s.eval(&format!(
        "(org-tags-view! {text:?} {})",
        if todo_only { "#t" } else { "#f" }
    ))
    .unwrap();
    lines(s)[3..]
        .iter()
        .filter(|l| !l.is_empty())
        .map(|l| {
            let words: Vec<&str> = l.split_whitespace().collect();
            words[..words.len() - 1]
                .iter()
                .filter(|w| !w.starts_with(':') && !["TODO", "NEXT", "DONE"].contains(w))
                .cloned()
                .collect::<Vec<_>>()
                .join(" ")
        })
        .collect()
}

#[test]
fn tags_matches_in_org_s_syntax() {
    let (mut s, _) = agenda_files("agenda-match", &[("m.org", MATCHING)]);
    // Inherited tags count; - excludes; | is or.
    assert_eq!(
        matched(&mut s, "work", false),
        ["Work", "[#A] Urgent report", "Plan", "Shipped"]
    );
    assert_eq!(
        matched(&mut s, "+work-urgent", false),
        ["Work", "Plan", "Shipped"]
    );
    assert_eq!(
        matched(&mut s, "urgent|home", false),
        ["[#A] Urgent report", "Home", "Garden"]
    );
    assert_eq!(matched(&mut s, "org&home", false), ["Home", "Garden"]);
    assert_eq!(matched(&mut s, "{^ho}", false), ["Home", "Garden"]);
    // Special properties and the drawer's.
    assert_eq!(matched(&mut s, "TODO=\"NEXT\"", false), ["Plan"]);
    assert_eq!(matched(&mut s, "LEVEL>1+home", false), ["Garden"]);
    assert_eq!(
        matched(&mut s, "PRIORITY=\"A\"", false),
        ["[#A] Urgent report"]
    );
    assert_eq!(
        matched(&mut s, "work+Effort<\"1:00\"", false),
        ["[#A] Urgent report"]
    );
    assert_eq!(matched(&mut s, "Effort={^2}", false), ["Plan"]);
    assert_eq!(
        matched(&mut s, "CATEGORY=\"m\"-LEVEL>1", false),
        ["Work", "Home"]
    );
    // M: undone TODOs only.
    assert_eq!(
        matched(&mut s, "work", true),
        ["[#A] Urgent report", "Plan"]
    );
    assert_eq!(lines(&s)[0], " Tags: work");
    assert_eq!(lines(&s)[1], " TODOs · 2 entries");
}

#[test]
fn spc_o_a_m_asks_for_a_match() {
    let (mut s, _) = agenda_files("agenda-match-key", &[("m.org", MATCHING)]);
    type_keys(&mut s, " oamhome<ret>");
    assert_eq!(lines(&s)[0], " Tags: home");
    assert_eq!(lines(&s)[1], " 2 entries");
}
