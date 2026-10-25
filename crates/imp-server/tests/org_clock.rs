//! Org's logging and clocking (runtime/org.scm), and the agenda's clock
//! keys, log mode and clock report (runtime/org-agenda.scm).

mod common;

use common::*;

/// A server on Org file `name` holding `text`, with today pinned to
/// Sunday 25 October 2026 at 11:42 and no fold column.
fn org(name: &str, text: &str) -> imp_server::Server {
    let path = temp_path(name);
    std::fs::write(&path, text).unwrap();
    let mut s = common::server("");
    s.eval("(set-option! 'foldcolumn \"no\")").unwrap();
    pin(&mut s, "11:42");
    type_keys(&mut s, &format!(":e {}<ret>", path.display()));
    assert_eq!(s.eval("(major-mode)").unwrap(), "org-mode");
    s
}

/// Pins today to 25 October 2026 and the time to `time`.
fn pin(s: &mut imp_server::Server, time: &str) {
    s.eval("(define (calendar-today) (list 2026 10 25))")
        .unwrap();
    s.eval(&format!("(define (org-now) \"{time}\")")).unwrap();
    s.eval(&format!("(define (org-agenda-now) \"{time}\")"))
        .unwrap();
}

#[test]
fn marking_done_adds_closed_and_leaving_done_removes_it() {
    let mut s = org("closed.org", "* TODO Write it\nbody\n");
    type_keys(&mut s, "<ret>");
    assert_eq!(
        s.text(),
        "* DONE Write it\nCLOSED: [2026-10-25 Sun 11:42]\nbody\n"
    );
    type_keys(&mut s, "<ret>");
    assert_eq!(s.text(), "* Write it\nbody\n");
    // It goes first on an existing planning line, and u takes it away.
    let mut s = org(
        "closed-planning.org",
        "* TODO Pay\nSCHEDULED: <2026-10-24 Sat>\n",
    );
    type_keys(&mut s, "<ret>");
    assert_eq!(
        s.text(),
        "* DONE Pay\nCLOSED: [2026-10-25 Sun 11:42] SCHEDULED: <2026-10-24 Sat>\n"
    );
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "* TODO Pay\nSCHEDULED: <2026-10-24 Sat>\n");
    type_keys(&mut s, "<ret><ret>");
    assert_eq!(s.text(), "* Pay\nSCHEDULED: <2026-10-24 Sat>\n");
}

#[test]
fn org_log_done_off_adds_nothing() {
    let mut s = org("nolog.org", "* TODO Write it\n");
    s.eval("(set-option! 'org-log-done #f)").unwrap();
    type_keys(&mut s, "<ret>");
    assert_eq!(s.text(), "* DONE Write it\n");
}

#[test]
fn a_repeat_logs_last_repeat_and_its_state_change() {
    let mut s = org(
        "repeat-log.org",
        "* TODO Water plants\nSCHEDULED: <2026-10-25 Sun +1w>\n",
    );
    type_keys(&mut s, "<ret>");
    assert_eq!(
        s.text(),
        "* TODO Water plants\nSCHEDULED: <2026-11-01 Sun +1w>\n:PROPERTIES:\n\
         :LAST_REPEAT: [2026-10-25 Sun 11:42]\n:END:\n:LOGBOOK:\n\
         - State \"DONE\"       from \"TODO\"       [2026-10-25 Sun 11:42]\n:END:\n"
    );
    // The next goes on top, and one u undoes it all.
    pin(&mut s, "12:00");
    type_keys(&mut s, "gg<ret>");
    let text = s.text();
    assert!(text.contains(
        ":LOGBOOK:\n- State \"DONE\"       from \"TODO\"       [2026-10-25 Sun 12:00]\n\
         - State \"DONE\"       from \"TODO\"       [2026-10-25 Sun 11:42]\n:END:"
    ));
    assert!(text.contains(":LAST_REPEAT: [2026-10-25 Sun 12:00]"));
    assert!(text.contains("<2026-11-08 Sun +1w>"));
    type_keys(&mut s, "u");
    assert!(s.text().contains("<2026-11-01 Sun +1w>"));
    assert!(!s.text().contains("12:00"));
}

