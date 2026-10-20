//! Org capture (runtime/org.scm): templates, the capture buffer, filing.

mod common;

use common::*;
use std::path::PathBuf;

/// A server whose org-directory is a fresh `name`, with the clock fixed
/// at 2026-10-19 14:02.
fn setup(name: &str) -> (imp_server::Server, PathBuf) {
    let dir = temp_path(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let mut s = server("");
    s.set_size(120, 30);
    s.eval(&format!(
        r#"(set-option! 'org-directory {:?})
           (define (capture-clock) (list "2026-10-19" "Mon" "14:02" "Monday" "October"))"#,
        dir.display().to_string()
    ))
    .unwrap();
    (s, dir)
}

fn read(dir: &std::path::Path, name: &str) -> String {
    std::fs::read_to_string(dir.join(name)).unwrap_or_else(|e| panic!("{name}: {e}"))
}

fn windows(s: &mut imp_server::Server) -> String {
    s.eval("(length (window-list))").unwrap()
}

#[test]
fn a_todo_goes_under_its_heading_from_a_buffer_down_the_right() {
    let (mut s, dir) = setup("capture-todo");
    std::fs::write(
        dir.join("inbox.org"),
        "#+title: Inbox\n\n* Tasks\n** TODO Older\n* Notes\n** Something\n",
    )
    .unwrap();
    type_keys(&mut s, " oc");
    // The templates, by key.
    let screen = s.frame().text_rows().join("\n");
    assert!(
        screen.contains("Todo") && screen.contains("Journal"),
        "{screen}"
    );
    type_keys(&mut s, "t");
    assert_eq!(windows(&mut s), "2");
    assert_eq!(s.eval("(buffer-name)").unwrap(), "\"*capture*\"");
    assert_eq!(s.eval("(major-mode)").unwrap(), "org-mode");
    assert_eq!(s.eval("*mode*").unwrap(), "insert");
    assert_eq!(s.text(), "* TODO \n/Entered on/ [2026-10-19 Mon 14:02]");
    assert!(s.status().contains("C-c C-c"), "{}", s.status());
    type_keys(&mut s, "Call the bank<C-c><C-c>");
    assert_eq!(windows(&mut s), "1");
    assert_eq!(
        read(&dir, "inbox.org"),
        "#+title: Inbox\n\n* Tasks\n** TODO Older\n** TODO Call the bank\n/Entered on/ [2026-10-19 Mon 14:02]\n* Notes\n** Something\n"
    );
    assert!(s.status().starts_with("captured to "), "{}", s.status());
    // The capture buffer is gone.
    assert_eq!(
        s.eval(
            "(filter (lambda (id) (equal? (car (buffer-info id)) \"*capture*\")) (buffer-list))"
        )
        .unwrap(),
        "()"
    );
}

#[test]
fn a_missing_heading_and_file_are_made() {
    let (mut s, dir) = setup("capture-new");
    type_keys(&mut s, " ocnIdea<esc><C-c><C-c>");
    assert_eq!(
        read(&dir, "inbox.org"),
        "* Notes\n** Idea \n/Entered on/ [2026-10-19 Mon 14:02]\n"
    );
}

#[test]
fn a_note_links_to_where_you_were() {
    let (mut s, dir) = setup("capture-link");
    let src = dir.join("code.txt");
    std::fs::write(&src, "one\ntwo\nthree\n").unwrap();
    type_keys(&mut s, &format!(":e {}<ret>jj", src.display()));
    type_keys(&mut s, " ocnLook<C-c><C-c>");
    let inbox = read(&dir, "inbox.org");
    assert!(
        inbox.contains("** Look [[file:") && inbox.contains("code.txt::3]]"),
        "{inbox}"
    );
    // Back in the file, where capture started.
    assert_eq!(s.text(), "one\ntwo\nthree\n");
}

#[test]
fn nothing_typed_files_nothing_and_cancel_throws_away() {
    let (mut s, dir) = setup("capture-empty");
    type_keys(&mut s, " oct<C-c><C-c>");
    assert_eq!(s.status(), "nothing captured");
    assert!(!dir.join("inbox.org").exists());
    type_keys(&mut s, " octHalf a thought<C-c><C-k>");
    assert_eq!(s.status(), "capture cancelled");
    assert!(!dir.join("inbox.org").exists());
    assert_eq!(windows(&mut s), "1");
}

#[test]
fn saving_files_it_too() {
    let (mut s, dir) = setup("capture-save");
    type_keys(&mut s, " octFrom normal<esc>:w<ret>");
    assert!(read(&dir, "inbox.org").contains("** TODO From normal\n"));
}

#[test]
fn journal_entries_go_into_a_date_tree() {
    let (mut s, dir) = setup("capture-journal");
    std::fs::write(
        dir.join("journal.org"),
        "* 2026\n** 2026-09 September\n*** 2026-09-30 Wednesday\n**** 09:00 Old\n* 2027\n",
    )
    .unwrap();
    s.eval(
        r#"(define-capture-template! "j" "Journal" '(file+datetree "journal.org") "* 14:02 %?")"#,
    )
    .unwrap();
    type_keys(&mut s, " ocjFirst<C-c><C-c>");
    type_keys(&mut s, " ocjSecond<C-c><C-c>");
    assert_eq!(
        read(&dir, "journal.org"),
        "* 2026\n** 2026-09 September\n*** 2026-09-30 Wednesday\n**** 09:00 Old\n\
         ** 2026-10 October\n*** 2026-10-19 Monday\n**** 14:02 First\n**** 14:02 Second\n* 2027\n"
    );
}

#[test]
fn an_open_buffer_gets_the_entry_and_is_saved() {
    let (mut s, dir) = setup("capture-open");
    let inbox = dir.join("inbox.org");
    std::fs::write(&inbox, "* Tasks\n").unwrap();
    type_keys(&mut s, &format!(":e {}<ret>", inbox.display()));
    type_keys(&mut s, " octOpen one<C-c><C-c>");
    assert_eq!(
        s.text(),
        "* Tasks\n** TODO Open one\n/Entered on/ [2026-10-19 Mon 14:02]\n"
    );
    assert_eq!(read(&dir, "inbox.org"), s.text());
    assert_eq!(s.eval("(buffer-modified?)").unwrap(), "#false");
}

#[test]
fn prompts_selection_and_a_single_template() {
    let (mut s, dir) = setup("capture-prompts");
    s.eval(
        r#"(set! *capture-templates* '())
           (define-capture-template! "c" "Contact" '(file "people.org")
             "* %^{Name}\n:PHONE: %^{Phone}\n%i%?")"#,
    )
    .unwrap();
    s.eval("(buffer-insert! 0 \"selected words\")").unwrap();
    // One template: no menu. Visual selection becomes %i.
    type_keys(&mut s, "ve oc");
    type_keys(&mut s, "Ada<ret>555<ret>");
    assert_eq!(s.text(), "* Ada\n:PHONE: 555\nselected");
    type_keys(&mut s, "<C-c><C-c>");
    // Was it changed? Only the template, so nothing is filed...
    assert_eq!(s.status(), "nothing captured");
    type_keys(&mut s, " ocBob<ret>1<ret> more<C-c><C-c>");
    assert_eq!(read(&dir, "people.org"), "* Bob\n:PHONE: 1\n more\n");
}

#[test]
fn refile_puts_it_under_a_heading_you_pick() {
    let (mut s, dir) = setup("capture-refile");
    std::fs::write(
        dir.join("projects.org"),
        "* Garden\n** TODO Water\n* House\n",
    )
    .unwrap();
    type_keys(&mut s, " octPrune roses<C-c><C-w>");
    type_keys(&mut s, "garden<ret>");
    assert_eq!(
        read(&dir, "projects.org"),
        "* Garden\n** TODO Water\n** TODO Prune roses\n/Entered on/ [2026-10-19 Mon 14:02]\n* House\n"
    );
    assert!(!dir.join("inbox.org").exists());
}

#[test]
fn templates_expand() {
    let (mut s, _) = setup("capture-expand");
    let got = s
        .eval(r#"(capture-expand "%t %T %u 100%% %f [%?]" (capture-context) '())"#)
        .unwrap();
    assert_eq!(
        got,
        r#"("<2026-10-19 Mon> <2026-10-19 Mon 14:02> [2026-10-19 Mon] 100%  []" 64)"#
    );
}
