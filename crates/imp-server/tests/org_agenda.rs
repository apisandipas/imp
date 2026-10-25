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
    let report = text.find("Scheduled:  TODO Write report").expect(&text);
    let trip = text.find("TODO Plan trip").expect(&text);
    assert!(overdue < report && report < todo && todo < trip, "{text}");
    // A date after the week is under Later, before To do.
    let later = text.find("Later").expect(&text);
    let future = text
        .find("2999-01-01  Deadline:   TODO Future")
        .expect(&text);
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
    assert!(
        text.contains("TODO Write") && text.contains("NEXT Plan"),
        "{text}"
    );
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
