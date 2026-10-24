//! The date picker (runtime/calendar.scm) and Org's dates: scheduling,
//! deadlines, timestamps and dates asked for by capture templates.

mod common;

use common::*;

/// A server for `text` in org-mode, today fixed at Wednesday 2026-10-21.
fn setup(text: &str) -> imp_server::Server {
    let mut s = server(text);
    s.set_size(100, 30);
    s.eval("(define (calendar-today) (list 2026 10 21)) (set-major-mode! 'org-mode)")
        .unwrap();
    s
}

fn parse(s: &mut imp_server::Server, text: &str) -> String {
    s.eval(&format!(
        "(parse-date-input {text:?} (list 2026 10 21) (list 2026 10 21))"
    ))
    .unwrap()
}

#[test]
fn typed_dates() {
    let mut s = setup("");
    assert_eq!(parse(&mut s, ""), "((2026 10 21) #false)");
    assert_eq!(parse(&mut s, "fri"), "((2026 10 23) #false)");
    assert_eq!(parse(&mut s, "wed"), "((2026 10 21) #false)");
    assert_eq!(parse(&mut s, "+2w"), "((2026 11 4) #false)");
    assert_eq!(parse(&mut s, "-1d"), "((2026 10 20) #false)");
    assert_eq!(parse(&mut s, "+3"), "((2026 10 24) #false)");
    assert_eq!(parse(&mut s, "11-03"), "((2026 11 3) #false)");
    assert_eq!(parse(&mut s, "10-01"), "((2027 10 1) #false)");
    assert_eq!(parse(&mut s, "3"), "((2026 11 3) #false)");
    assert_eq!(parse(&mut s, "2026-12-25"), "((2026 12 25) #false)");
    assert_eq!(parse(&mut s, "tom 3pm"), "((2026 10 22) \"15:00\")");
    assert_eq!(parse(&mut s, "9:30"), "((2026 10 21) \"09:30\")");
    assert_eq!(parse(&mut s, "2026-02-30"), "#false");
    assert_eq!(parse(&mut s, "soon"), "#false");
    // A month on from the 31st is the end of the next month.
    assert_eq!(
        s.eval("(date-add-months (list 2026 1 31) 1)").unwrap(),
        "(2026 2 28)"
    );
    assert_eq!(
        s.eval("(date-timestamp (list 2026 10 23) \"09:00\" #t)")
            .unwrap(),
        "\"<2026-10-23 Fri 09:00>\""
    );
}

#[test]
fn schedule_and_deadline_from_the_calendar() {
    let mut s = setup("* TODO Task\nSome text\n");
    type_keys(&mut s, "<C-c><C-s>");
    let screen = s.frame().text_rows().join("\n");
    for month in ["September 2026", "October 2026", "November 2026"] {
        assert!(screen.contains(month), "{screen}");
    }
    assert!(screen.contains("Schedule:    <2026-10-21 Wed>"), "{screen}");
    // A day on, a week on.
    type_keys(&mut s, "<right><down>");
    let screen = s.frame().text_rows().join("\n");
    assert!(screen.contains("<2026-10-29 Thu>"), "{screen}");
    type_keys(&mut s, "<ret>");
    assert_eq!(
        s.text(),
        "* TODO Task\nSCHEDULED: <2026-10-29 Thu>\nSome text\n"
    );
    // A typed deadline joins the same line.
    type_keys(&mut s, "<C-c><C-d>fri 9:00<ret>");
    assert_eq!(
        s.text(),
        "* TODO Task\nSCHEDULED: <2026-10-29 Thu> DEADLINE: <2026-10-23 Fri 09:00>\nSome text\n"
    );
    // Scheduling again replaces the date, starting from it.
    type_keys(&mut s, "<C-c><C-s><pagedown><ret>");
    assert_eq!(
        s.text(),
        "* TODO Task\nSCHEDULED: <2026-11-29 Sun> DEADLINE: <2026-10-23 Fri 09:00>\nSome text\n"
    );
    // <esc> leaves it alone, and the calendar goes.
    type_keys(&mut s, "<C-c><C-s>+1d<esc>");
    assert!(s.text().contains("<2026-11-29 Sun>"));
    assert!(!s.frame().text_rows().join("\n").contains("November 2026"));
    assert_eq!(s.eval("*mode*").unwrap(), "normal");
}

#[test]
fn a_timestamp_at_the_cursor() {
    let mut s = setup("Meet ");
    type_keys(&mut s, "A<C-c>.tom<ret>");
    assert_eq!(s.text(), "Meet <2026-10-22 Thu>");
    assert_eq!(s.eval("*mode*").unwrap(), "insert");
    // On a timestamp, C-c . changes it.
    type_keys(&mut s, "<esc>0fT<C-c>.fri<ret>");
    assert_eq!(s.text(), "Meet <2026-10-23 Fri>");
}

#[test]
fn capture_asks_for_a_date_and_can_schedule() {
    let dir = temp_path("calendar-capture");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let mut s = setup("");
    s.eval(&format!(
        r#"(set-option! 'org-directory {:?})
           (define-capture-template! "d" "Due" '(file "") "* TODO %?\nDEADLINE: %^t")"#,
        dir.display().to_string()
    ))
    .unwrap();
    type_keys(&mut s, " ocd");
    assert!(s.frame().text_rows().join("\n").contains("October 2026"));
    type_keys(&mut s, "+2d<ret>");
    assert_eq!(s.text(), "* TODO \nDEADLINE: <2026-10-23 Fri>");
    // In the capture buffer C-c C-s schedules the entry too.
    type_keys(&mut s, "Pay rent<C-c><C-s>11-01<ret>");
    assert_eq!(
        s.text(),
        "* TODO Pay rent\nDEADLINE: <2026-10-23 Fri> SCHEDULED: <2026-11-01 Sun>"
    );
    type_keys(&mut s, "<C-c><C-c>");
    let filed = std::fs::read_to_string(dir.join("inbox.org")).unwrap();
    assert!(filed.contains("SCHEDULED: <2026-11-01 Sun>"), "{filed}");
}

#[test]
fn timestamps_parse_into_their_parts() {
    let mut s = setup("");
    let mut parse = |text: &str| s.eval(&format!("(org-parse-stamp {text:?})")).unwrap();
    assert_eq!(
        parse("<2026-10-24 Sat>"),
        "(#true (2026 10 24) #false #false #false)"
    );
    assert_eq!(
        parse("<2026-10-24 Sat 09:00-10:30 .+2w -3d>"),
        "(#true (2026 10 24) \"09:00-10:30\" (\".+\" 2 \"w\") (\"-\" 3 \"d\"))"
    );
    assert_eq!(
        parse("[2026-10-24 ++1m]"),
        "(#false (2026 10 24) #false (\"++\" 1 \"m\") #false)"
    );
    assert_eq!(parse("<2026-10-24 Sat +1x>"), "#false");
    assert_eq!(parse("<2026-10-24 Sat"), "#false");
    assert_eq!(parse("<soon>"), "#false");
    // Written back with the day name the date has.
    assert_eq!(
        s.eval("(org-stamp->string (list #t (list 2026 10 31) \"09:00\" (list \"+\" 1 \"w\") #f))")
            .unwrap(),
        "\"<2026-10-31 Sat 09:00 +1w>\""
    );
}

/// Marks the heading on the first line done, with <ret>.
fn mark_done(text: &str) -> String {
    let mut s = setup(text);
    type_keys(&mut s, "<ret>");
    s.text()
}

#[test]
fn marking_a_repeating_heading_done_moves_its_dates_on() {
    // + moves one interval, even if that is still in the past.
    assert_eq!(
        mark_done("* TODO Water\nSCHEDULED: <2026-10-01 Thu +1w>\n"),
        "* TODO Water\nSCHEDULED: <2026-10-08 Thu +1w>\n"
    );
    // ++ moves whole intervals until after today (2026-10-21).
    assert_eq!(
        mark_done("* TODO Call\nDEADLINE: <2026-10-01 Thu 09:00 ++1w -2d>\n"),
        "* TODO Call\nDEADLINE: <2026-10-22 Thu 09:00 ++1w -2d>\n"
    );
    // .+ moves to one interval after today; a body timestamp moves too.
    assert_eq!(
        mark_done("* TODO Cut hair\nSCHEDULED: <2026-01-31 Sat .+1m>\nAt <2026-01-31 Sat +1m>.\n* Next\n<2026-01-01 Thu +1d>\n"),
        "* TODO Cut hair\nSCHEDULED: <2026-11-21 Sat .+1m>\nAt <2026-02-28 Sat +1m>.\n* Next\n<2026-01-01 Thu +1d>\n"
    );
    // Without a repeater, or only an inactive one, done is done.
    assert_eq!(
        mark_done("* TODO Once\nSCHEDULED: <2026-10-01 Thu>\n[2026-10-01 Thu +1d]\n"),
        "* DONE Once\nSCHEDULED: <2026-10-01 Thu>\n[2026-10-01 Thu +1d]\n"
    );
}

#[test]
fn repeating_back_to_the_first_keyword_is_one_undo() {
    let mut s = setup("* NEXT Review\nSCHEDULED: <2026-10-19 Mon +1y>\n");
    s.eval("(set-option! 'org-todo-keywords '(\"TODO\" \"NEXT\" \"|\" \"DONE\"))")
        .unwrap();
    type_keys(&mut s, "<ret>");
    assert_eq!(s.text(), "* TODO Review\nSCHEDULED: <2027-10-19 Tue +1y>\n");
    let status = s.frame().text_rows().last().unwrap().clone();
    assert!(status.contains("repeats: <2027-10-19 Tue +1y>"), "{status}");
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "* NEXT Review\nSCHEDULED: <2026-10-19 Mon +1y>\n");
}

#[test]
fn picking_a_new_date_keeps_the_repeater() {
    let mut s = setup("* TODO Water\nSCHEDULED: <2026-10-01 Thu 08:00 .+1w -1d>\n");
    type_keys(&mut s, "<C-c><C-s>fri<ret>");
    assert_eq!(
        s.text(),
        "* TODO Water\nSCHEDULED: <2026-10-23 Fri .+1w -1d>\n"
    );
    // And C-c . on one.
    type_keys(&mut s, "gg0jf<<C-c>.tom 9am<ret>");
    assert_eq!(
        s.text(),
        "* TODO Water\nSCHEDULED: <2026-10-22 Thu 09:00 .+1w -1d>\n"
    );
}

/// The agenda over one file holding `text`, as its buffer's lines.
fn agenda(name: &str, text: &str) -> imp_server::Server {
    let dir = temp_path(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("a.org"), text).unwrap();
    let mut s = setup("");
    s.eval(&format!(
        "(set-option! 'org-directory {:?})",
        dir.display().to_string()
    ))
    .unwrap();
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
            "Agenda: 2026-10-18 to 2026-10-24",
            "",
            "Overdue",
            "  2026-10-01  Scheduled:  TODO Water  a",
            "  2026-10-20  Scheduled:  TODO Pay  a",
            "",
            "Sunday    18 October 2026",
            "Monday    19 October 2026",
            "Tuesday   20 October 2026",
            "  Scheduled:  TODO Pay  a",
            "Wednesday 21 October 2026  today",
            "Thursday  22 October 2026",
            "  Scheduled:  TODO Water  a",
            "Friday    23 October 2026",
            "  Deadline:   TODO Ship  a",
            "Saturday  24 October 2026",
            "",
            "Later",
            "  2026-10-29  Scheduled:  TODO Water  a",
            "  2026-12-01  Deadline:   TODO Later  a",
            "",
            "To do",
            "  TODO Someday  a",
        ]
    );
    // f shows the next week, the repeat on its Thursday; . comes back.
    type_keys(&mut s, "f");
    let next = lines(&s);
    assert_eq!(next[0], "Agenda: 2026-10-25 to 2026-10-31");
    let thu = next.iter().position(|l| l.starts_with("Thursday")).unwrap();
    assert_eq!(next[thu], "Thursday  29 October 2026");
    assert_eq!(next[thu + 1], "  Scheduled:  TODO Water  a");
    type_keys(&mut s, "bb");
    assert_eq!(lines(&s)[0], "Agenda: 2026-10-11 to 2026-10-17");
    type_keys(&mut s, ".");
    assert_eq!(lines(&s)[0], "Agenda: 2026-10-18 to 2026-10-24");
    // A span of 3 days.
    s.eval("(set-option! 'org-agenda-span 3)").unwrap();
    type_keys(&mut s, "gr");
    assert_eq!(lines(&s)[0], "Agenda: 2026-10-18 to 2026-10-20");
}

#[test]
fn the_agenda_shows_each_entry_s_category() {
    let s = agenda(
        "agenda-category",
        "#+CATEGORY: home\n* TODO Plain\n* Work\n:PROPERTIES:\n:CATEGORY: job\n:END:\n** TODO Report\n",
    );
    let text = lines(&s);
    assert!(text.contains(&"  TODO Plain  home".to_string()), "{text:?}");
    assert!(text.contains(&"  TODO Report  job".to_string()), "{text:?}");
}
