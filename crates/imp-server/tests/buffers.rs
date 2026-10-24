//! Several buffers: opening files, switching, closing, saving and quitting.

mod common;

use common::*;

fn name(s: &mut imp_server::Server) -> String {
    s.eval("(buffer-name)")
        .unwrap()
        .trim_matches('"')
        .to_string()
}

fn file(name: &str, text: &str) -> String {
    let path = temp_path(name);
    std::fs::write(&path, text).unwrap();
    path.display().to_string()
}

#[test]
fn edit_opens_and_switches() {
    let a = file("buf-a.txt", "alpha\n");
    let b = file("buf-b.txt", "beta\n");
    let mut s = server("scratch\n");
    type_keys(&mut s, &format!(":e {a}<ret>"));
    assert_eq!(s.text(), "alpha\n");
    type_keys(&mut s, &format!(":e {b}<ret>"));
    assert_eq!(s.text(), "beta\n");
    // Opening a file again goes to its buffer rather than a second copy.
    type_keys(&mut s, &format!("x:e {a}<ret>:e {b}<ret>"));
    assert_eq!(s.text(), "eta\n");
    assert_eq!(s.eval("(length (buffer-list))").unwrap(), "3");
}

#[test]
fn each_buffer_keeps_its_cursor() {
    let a = file("cur-a.txt", "one\ntwo\nthree\n");
    let mut s = server("x\ny\n");
    type_keys(&mut s, "j");
    type_keys(&mut s, &format!(":e {a}<ret>G"));
    s.keys(&["C-^"]);
    assert_eq!(s.cursor(), 2);
    s.keys(&["C-^"]);
    assert_eq!(s.cursor(), 8);
}

#[test]
fn buffer_list_and_navigation() {
    let a = file("nav-a.txt", "a\n");
    let b = file("nav-b.txt", "b\n");
    let mut s = server("s\n");
    type_keys(&mut s, &format!(":e {a}<ret>:e {b}<ret>:bn<ret>"));
    assert_eq!(s.text(), "s\n");
    type_keys(&mut s, ":bp<ret>");
    assert_eq!(s.text(), "b\n");
    type_keys(&mut s, ":b nav-a<ret>");
    assert_eq!(s.text(), "a\n");
    type_keys(&mut s, ":b 0<ret>");
    assert_eq!(s.text(), "s\n");
    // :ls lists whole paths, cut at the screen's edge; $TMPDIR can be long
    // (on CI, /home/runner/work/_temp/...).
    s.set_size(200, 24);
    type_keys(&mut s, ":ls<ret>");
    let rows = s.frame().text_rows();
    assert!(
        rows.iter()
            .any(|r| r.contains("%a") && r.contains("[No Name]")),
        "{rows:?}"
    );
    assert!(rows.iter().any(|r| r.contains("nav-b.txt")));
}

/// A path too long for :ls or a menu is shortened from the start,
/// keeping the file name, as the status line does.
#[test]
fn long_paths_shorten_from_the_start() {
    let long = file("a-rather-long-file-name.txt", "x\n");
    let mut s = server("");
    type_keys(&mut s, &format!(":e {long}<ret>"));
    s.set_size(40, 24);
    type_keys(&mut s, ":ls<ret>");
    let rows = s.frame().text_rows();
    assert!(
        rows.iter()
            .any(|r| r.contains("%a + \"<") || r.contains("%a   \"<")),
        "{rows:?}"
    );
    assert!(
        rows.iter()
            .any(|r| r.trim_end().ends_with("a-rather-long-file-name.txt\"")),
        "{rows:?}"
    );
    type_keys(&mut s, "<esc>");
    s.eval(r#"(completing-read "Pick: " (list "some/deeply/nested/directory/tree/target.txt" "plain") (lambda (x) x))"#)
        .unwrap();
    let rows = s.frame().text_rows();
    assert!(
        rows.iter()
            .any(|r| r.contains("<") && r.contains("target.txt")),
        "{rows:?}"
    );
    // Rows that fit, and candidates that aren't paths, are left alone.
    assert!(rows.iter().any(|r| r.contains(" plain")), "{rows:?}");
}

#[test]
fn delete_buffer() {
    let a = file("del-a.txt", "a\n");
    let mut s = server("s\n");
    type_keys(&mut s, &format!(":e {a}<ret>x:bd<ret>"));
    assert!(s.status().contains("unsaved"));
    type_keys(&mut s, ":bd!<ret>");
    assert_eq!(s.text(), "s\n");
    assert_eq!(s.eval("(length (buffer-list))").unwrap(), "1");
    // Deleting the last buffer leaves an empty one.
    type_keys(&mut s, ":bd!<ret>");
    assert_eq!(s.text(), "");
}

#[test]
fn quit_checks_every_buffer() {
    let a = file("quit-a.txt", "a\n");
    let mut s = server("s\n");
    type_keys(&mut s, "x");
    type_keys(&mut s, &format!(":e {a}<ret>:q<ret>"));
    assert!(!s.should_quit());
    // It shows the buffer with the changes.
    assert_eq!(s.text(), "\n");
    type_keys(&mut s, ":qa!<ret>");
    assert!(s.should_quit());
}

#[test]
fn write_all() {
    let a = file("wa-a.txt", "a\n");
    let b = file("wa-b.txt", "b\n");
    let mut s = server("");
    type_keys(&mut s, &format!(":e {a}<ret>x:e {b}<ret>x:wa<ret>"));
    assert_eq!(std::fs::read_to_string(&a).unwrap(), "\n");
    assert_eq!(std::fs::read_to_string(&b).unwrap(), "\n");
}

#[test]
fn reload_from_disk() {
    let a = file("re-a.txt", "old\n");
    let mut s = server("");
    type_keys(&mut s, &format!(":e {a}<ret>"));
    std::fs::write(&a, "new\n").unwrap();
    type_keys(&mut s, ":e<ret>");
    assert_eq!(s.text(), "new\n");
    type_keys(&mut s, "x:e<ret>");
    assert!(s.status().contains("unsaved"));
    type_keys(&mut s, ":e!<ret>");
    assert_eq!(s.text(), "new\n");
    // The reload can be undone.
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "ew\n");
}

#[test]
fn jumps_cross_buffers() {
    let a = file("jump-a.txt", "a\n");
    let mut s = server("s\n");
    type_keys(&mut s, &format!(":e {a}<ret>"));
    s.keys(&["C-o"]);
    assert_eq!(s.text(), "s\n");
    s.keys(&["<tab>"]);
    assert_eq!(s.text(), "a\n");
}

#[test]
fn new_and_named_buffers() {
    let mut s = server("s\n");
    type_keys(&mut s, ":enew<ret>");
    assert_eq!(name(&mut s), "[No Name]");
    assert_eq!(s.text(), "");
    s.eval("(set-buffer-name! \"*notes*\")").unwrap();
    assert_eq!(name(&mut s), "*notes*");
}

#[test]
fn hooks_run_on_save_and_buffer_open() {
    let a = file("hook-a.txt", "a\n");
    let mut s = server("");
    s.eval(
        r#"(define opened 0)
           (add-hook! 'buffer-open (lambda () (set! opened (+ opened 1))))
           (add-hook! 'before-save (lambda () (buffer-insert! 0 "!")))"#,
    )
    .unwrap();
    type_keys(&mut s, &format!(":e {a}<ret>:bn<ret>:e {a}<ret>"));
    assert_eq!(s.eval("opened").unwrap(), "1");
    type_keys(&mut s, ":w<ret>");
    assert_eq!(std::fs::read_to_string(&a).unwrap(), "!a\n");
}
