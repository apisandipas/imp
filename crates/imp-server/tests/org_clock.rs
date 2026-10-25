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

#[test]
fn clocking_in_and_out_writes_the_logbook() {
    let mut s = org(
        "clock.org",
        "* TODO Write report\n:PROPERTIES:\n:Effort: 1:00\n:END:\nbody\n* Other\n",
    );
    type_keys(&mut s, "j<C-c><C-x><C-i>");
    assert_eq!(
        s.text(),
        "* TODO Write report\n:PROPERTIES:\n:Effort: 1:00\n:END:\n:LOGBOOK:\n\
         CLOCK: [2026-10-25 Sun 11:42]\n:END:\nbody\n* Other\n"
    );
    pin(&mut s, "12:05");
    s.eval("(org-clock-show!)").unwrap();
    assert!(status_row(&mut s).contains("[0:23/1:00] Write report"));
    pin(&mut s, "12:57");
    type_keys(&mut s, "<C-c><C-x><C-o>");
    assert!(s.text().contains(
        ":LOGBOOK:\nCLOCK: [2026-10-25 Sun 11:42]--[2026-10-25 Sun 12:57] =>  1:15\n:END:"
    ));
    assert!(!status_row(&mut s).contains("Write report"));
}

#[test]
fn one_clock_runs_at_a_time() {
    let mut s = org("clocks.org", "* A\n* B\n");
    type_keys(&mut s, " mci");
    pin(&mut s, "12:00");
    type_keys(&mut s, "G mci");
    assert_eq!(
        s.text(),
        "* A\n:LOGBOOK:\nCLOCK: [2026-10-25 Sun 11:42]--[2026-10-25 Sun 12:00] =>  0:18\n:END:\n\
         * B\n:LOGBOOK:\nCLOCK: [2026-10-25 Sun 12:00]\n:END:\n"
    );
    // Going to it, then cancelling it, which takes its empty drawer too.
    type_keys(&mut s, "gg mcg");
    assert_eq!(s.eval("(current-line)").unwrap(), "4");
    type_keys(&mut s, " mcc");
    assert_eq!(
        s.text(),
        "* A\n:LOGBOOK:\nCLOCK: [2026-10-25 Sun 11:42]--[2026-10-25 Sun 12:00] =>  0:18\n:END:\n* B\n"
    );
    type_keys(&mut s, " mco");
    let rows = s.frame().text_rows();
    assert!(rows[rows.len() - 1].contains("no clock is running"));
}

#[test]
fn a_running_clock_is_picked_up() {
    let dir = temp_path("clock-resume");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("work.org"),
        "* Done one\n:LOGBOOK:\nCLOCK: [2026-10-24 Sat 09:00]--[2026-10-24 Sat 10:00] =>  1:00\n:END:\n\
         * Still going\n:LOGBOOK:\nCLOCK: [2026-10-25 Sun 11:00]\n:END:\n",
    )
    .unwrap();
    let mut s = common::server("");
    pin(&mut s, "11:42");
    s.eval(&format!(
        "(set-option! 'org-directory {:?})",
        dir.display().to_string()
    ))
    .unwrap();
    s.eval("(org-clock-resume!)").unwrap();
    assert!(status_row(&mut s).contains("[0:42] Still going"));
    type_keys(&mut s, ":e x.txt<ret>");
    s.eval("(org-clock-out!)").unwrap();
    // Its file was clean, so clocking out from elsewhere saves it.
    let text = std::fs::read_to_string(dir.join("work.org")).unwrap();
    assert!(text.contains("CLOCK: [2026-10-25 Sun 11:00]--[2026-10-25 Sun 11:42] =>  0:42"));
}

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

/// The agenda's week over `files` in a fresh directory, today and now
/// pinned, the grid off; returns the directory too.
fn agenda(name: &str, files: &[(&str, &str)]) -> (imp_server::Server, std::path::PathBuf) {
    let dir = org_dir(name, files);
    let mut s = common::server("");
    s.set_size(100, 50);
    pin(&mut s, "11:42");
    s.eval(&format!(
        "(set-option! 'org-directory {:?})",
        dir.display().to_string()
    ))
    .unwrap();
    s.eval("(set-option! 'org-agenda-use-time-grid #f)")
        .unwrap();
    type_keys(&mut s, ":OrgAgenda<ret>a");
    (s, dir)
}

fn lines(s: &imp_server::Server) -> Vec<String> {
    s.text().lines().map(|l| l.trim_end().to_string()).collect()
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
fn the_agenda_clocks_in_and_out() {
    let (mut s, dir) = agenda(
        "agenda-clock",
        &[(
            "a.org",
            "* TODO Write\nSCHEDULED: <2026-10-25 Sun>\n* TODO Read\nSCHEDULED: <2026-10-25 Sun>\n",
        )],
    );
    go_to(&mut s, "Write");
    type_keys(&mut s, "I");
    assert_eq!(s.eval("(major-mode)").unwrap(), "org-agenda-mode");
    assert_eq!(
        std::fs::read_to_string(dir.join("a.org")).unwrap(),
        "* TODO Write\nSCHEDULED: <2026-10-25 Sun>\n:LOGBOOK:\nCLOCK: [2026-10-25 Sun 11:42]\n:END:\n\
         * TODO Read\nSCHEDULED: <2026-10-25 Sun>\n"
    );
    assert!(status_row(&mut s).contains("[0:00] Write"));
    // I on another clocks out of the first.
    pin(&mut s, "12:10");
    go_to(&mut s, "Read");
    type_keys(&mut s, "I");
    let text = std::fs::read_to_string(dir.join("a.org")).unwrap();
    assert!(text.contains("--[2026-10-25 Sun 12:10] =>  0:28"), "{text}");
    assert!(text.contains(
        "* TODO Read\nSCHEDULED: <2026-10-25 Sun>\n:LOGBOOK:\nCLOCK: [2026-10-25 Sun 12:10]\n:END:"
    ));
    // cg goes there; back in the agenda, cc cancels it and O says none runs.
    type_keys(&mut s, "cg");
    assert_eq!(s.eval("(major-mode)").unwrap(), "org-mode");
    assert_eq!(s.eval("(current-line)").unwrap(), "5");
    type_keys(&mut s, ":OrgAgenda<ret>a");
    type_keys(&mut s, "cc");
    assert!(!std::fs::read_to_string(dir.join("a.org"))
        .unwrap()
        .contains("CLOCK: [2026-10-25 Sun 12:10]"));
    type_keys(&mut s, "O");
    let rows = s.frame().text_rows();
    assert!(rows[rows.len() - 1].contains("no clock is running"));
}

/// Whether some line of `lines` holds each of `parts`, in order.
fn has_line(lines: &[String], parts: &[&str]) -> bool {
    lines.iter().any(|l| {
        let mut from = 0;
        parts
            .iter()
            .all(|p| l[from..].find(p).map(|i| from += i + p.len()).is_some())
    })
}

const LOGGED: &str = "* DONE Write report\n\
CLOSED: [2026-10-23 Fri 16:00] SCHEDULED: <2026-10-22 Thu>\n\
:LOGBOOK:\n\
CLOCK: [2026-10-23 Fri 09:00]--[2026-10-23 Fri 10:15] =>  1:15\n\
:END:\n\
* TODO Water\n\
SCHEDULED: <2026-10-27 Tue +1w>\n\
:PROPERTIES:\n\
:LAST_REPEAT: [2026-10-20 Tue 08:30]\n\
:END:\n\
:LOGBOOK:\n\
- State \"DONE\"       from \"TODO\"       [2026-10-20 Tue 08:30]\n\
CLOCK: [2026-10-24 Sat 10:00]\n\
:END:\n";

#[test]
fn log_mode_shows_what_happened_each_day() {
    let (mut s, _dir) = agenda("agenda-log", &[("a.org", LOGGED)]);
    assert!(!lines(&s).iter().any(|l| l.contains("Clocked")));
    // The week before, which the log is of.
    type_keys(&mut s, "gDlb");
    let ls = lines(&s);
    let day = |name: &str| {
        ls.iter()
            .position(|l| l.contains(name))
            .unwrap_or_else(|| panic!("no {name} in {ls:#?}"))
    };
    let (tue, wed, fri, sat) = (
        day("Tuesday 20"),
        day("Wednesday 21"),
        day("Friday 23"),
        day("Saturday 24"),
    );
    let tuesday = &ls[tue..wed];
    assert!(
        has_line(tuesday, &["08:30", "State", "DONE", "from TODO", "Water"]),
        "{ls:#?}"
    );
    let friday = &ls[fri..sat];
    // At their times: the clock first, then closing it, done though it is.
    let clocked = friday.iter().position(|l| l.contains("Clocked")).unwrap();
    let closed = friday.iter().position(|l| l.contains("Closed")).unwrap();
    assert!(clocked < closed, "{ls:#?}");
    assert!(has_line(
        friday,
        &["09:00", "Clocked", "DONE", "(1:15)", "Write report"]
    ));
    assert!(has_line(
        friday,
        &["16:00", "Closed", "DONE", "Write report"]
    ));
    // A clock still running isn't logged yet.
    assert!(!ls[sat..].iter().any(|l| l.contains("Clocked")), "{ls:#?}");
    type_keys(&mut s, "gDl");
    assert!(!lines(&s).iter().any(|l| l.contains("Clocked")));
}

#[test]
fn the_clock_report_sums_the_span_s_clocks() {
    let (mut s, _dir) = agenda(
        "agenda-report",
        &[
            (
                "work.org",
                "* Project\n\
                 :LOGBOOK:\n\
                 CLOCK: [2026-10-26 Mon 09:00]--[2026-10-26 Mon 09:30] =>  0:30\n\
                 :END:\n\
                 ** Draft\n\
                 :LOGBOOK:\n\
                 CLOCK: [2026-10-27 Tue 10:00]--[2026-10-27 Tue 11:15] =>  1:15\n\
                 CLOCK: [2026-10-01 Thu 10:00]--[2026-10-01 Thu 12:00] =>  2:00\n\
                 :END:\n\
                 *** Deep\n\
                 :LOGBOOK:\n\
                 CLOCK: [2026-10-28 Wed 10:00]--[2026-10-28 Wed 10:10] =>  0:10\n\
                 :END:\n\
                 * Idle\n",
            ),
            (
                "home.org",
                "* Garden\n:LOGBOOK:\nCLOCK: [2026-10-25 Sun 08:00]--[2026-10-25 Sun 09:00] =>  1:00\n:END:\n",
            ),
        ],
    );
    assert!(!lines(&s).iter().any(|l| l.contains("Clock report")));
    type_keys(&mut s, "gDR");
    let ls = lines(&s);
    let at = ls
        .iter()
        .position(|l| l.contains("Clock report"))
        .unwrap_or_else(|| panic!("no report in {ls:#?}"));
    let report = &ls[at..];
    // Only this week's clocks; a heading's time holds those under it, and
    // a third level counts in its parent.
    assert!(
        has_line(report, &["home.org", "File time", "1:00"]),
        "{ls:#?}"
    );
    assert!(has_line(report, &["Garden", "1:00"]));
    assert!(has_line(report, &["work.org", "File time", "1:55"]));
    assert!(has_line(report, &["Project", "1:55"]));
    assert!(has_line(report, &["  Draft", "1:25"]));
    assert!(!report
        .iter()
        .any(|l| l.contains("Deep") || l.contains("Idle")));
    assert!(has_line(report, &["Total", "2:55"]));
    // cr hides it again.
    type_keys(&mut s, "cr");
    assert!(!lines(&s).iter().any(|l| l.contains("Clock report")));
}
