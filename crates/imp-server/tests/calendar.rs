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
