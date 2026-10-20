//! Claude Code in a window (runtime/claude.scm). A small script stands in
//! for claude: it turns on bracketed paste, as Claude Code does once it
//! takes input, and echoes what it gets with escapes made visible.

mod common;

use common::*;
use std::time::{Duration, Instant};

fn wait_for(
    s: &mut imp_server::Server,
    what: &str,
    done: impl Fn(&mut imp_server::Server) -> bool,
) {
    let start = Instant::now();
    while !done(s) {
        assert!(
            start.elapsed() < Duration::from_secs(10),
            "waited for {what}; buffer:\n{}\nstatus: {}",
            s.text(),
            s.status()
        );
        s.pump(Duration::from_millis(30));
    }
}

/// A project with a file in it, open, and the stand-in for claude.
fn project(name: &str, delay: &str) -> (imp_server::Server, std::path::PathBuf) {
    let root = temp_path(name);
    std::fs::create_dir_all(root.join(".git")).unwrap();
    std::fs::create_dir_all(root.join("src")).unwrap();
    std::fs::write(root.join("src/a.txt"), "one\ntwo\nthree\n").unwrap();
    let mut s = server("");
    s.set_size(200, 30);
    s.eval(&format!(
        r#"(set-option! 'claude-command "sleep {delay}; printf 'ready\\033[?2004h\\n'; stty -echo -icanon; cat -v")"#
    ))
    .unwrap();
    type_keys(
        &mut s,
        &format!(":e {}<ret>", root.join("src/a.txt").display()),
    );
    (s, root)
}

fn windows(s: &mut imp_server::Server) -> usize {
    s.eval("(length (window-list))").unwrap().parse().unwrap()
}

#[test]
fn toggles_a_window_down_the_right_that_keeps_running() {
    let (mut s, root) = project("claude-toggle", "0");
    s.keys(&["M-a"]);
    assert_eq!(windows(&mut s), 2);
    let status = status_row(&mut s);
    assert!(
        status.contains("TERMINAL") && status.contains(" claude "),
        "{status}"
    );
    assert_eq!(
        s.eval("(buffer-local 'claude-root)").unwrap(),
        format!("{:?}", root.display().to_string())
    );
    // 40% of the width, on the right.
    let width: usize = s.eval("(window-text-width)").unwrap().parse().unwrap();
    assert!((76..=82).contains(&width), "{width}");
    assert_eq!(s.eval("(window-in-direction \"right\")").unwrap(), "#false");
    wait_for(&mut s, "it to start", |s| s.text().contains("ready"));
    let buf = s.eval("(current-buffer)").unwrap();
    s.keys(&["x"]);
    wait_for(&mut s, "the echo", |s| {
        s.text().contains("readyx") || s.text().contains("\nx")
    });

    // M-a inside it hides it; the file is current again, in normal state.
    s.keys(&["M-a"]);
    assert_eq!(windows(&mut s), 1);
    assert!(status_row(&mut s).contains("NORMAL"));
    assert!(s.text().starts_with("one\n"));
    assert_eq!(s.eval("(hash-length *terminals*)").unwrap(), "1");

    // And back: the same instance, with what it had.
    type_keys(&mut s, " aa");
    assert_eq!(windows(&mut s), 2);
    assert_eq!(s.eval("(current-buffer)").unwrap(), buf);
    assert!(s.text().contains('x'), "{}", s.text());
    s.keys(&["M-a"]);

    // SPC a k stops it.
    type_keys(&mut s, " ak");
    assert_eq!(s.eval("(hash-length *terminals*)").unwrap(), "0");
}

#[test]
fn sends_a_selection_labelled_with_its_file_and_lines_once_it_takes_input() {
    let (mut s, _root) = project("claude-wait", "0.5");
    type_keys(&mut s, "jVj as");
    assert!(status_row(&mut s).contains("TERMINAL"));
    wait_for(&mut s, "the paste", |s| s.text().contains("[201~"));
    let text = s.text();
    let at = text.find("^[[200~").expect(&text);
    assert!(
        text[at..].starts_with("^[[200~src/a.txt:2-3\n```\ntwo\nthree\n```\n^[[201~"),
        "{text}"
    );
}

#[test]
fn sends_a_line_the_buffer_or_a_file_reference() {
    let (mut s, _root) = project("claude-buffer", "0");
    type_keys(&mut s, " as");
    wait_for(&mut s, "the line", |s| s.text().contains("[201~"));
    assert!(
        s.text()
            .contains("^[[200~src/a.txt:1\n```\none\n```\n^[[201~"),
        "{}",
        s.text()
    );
    s.keys(&["M-a"]);
    type_keys(&mut s, " ab");
    wait_for(&mut s, "the buffer", |s| {
        s.text().matches("[201~").count() == 2
    });
    assert!(
        s.text().contains("src/a.txt\n```\none\ntwo\nthree\n```\n"),
        "{}",
        s.text()
    );
    s.keys(&["M-a"]);
    type_keys(&mut s, " af");
    wait_for(&mut s, "the reference", |s| {
        s.text().matches("[201~").count() == 3
    });
    assert!(
        s.text().contains("^[[200~@src/a.txt ^[[201~"),
        "{}",
        s.text()
    );
    // Only one instance for all of that.
    assert_eq!(s.eval("(hash-length *terminals*)").unwrap(), "1");
}

#[test]
fn each_project_has_its_own() {
    let (mut s, _a) = project("claude-one", "0");
    s.keys(&["M-a"]);
    let first = s.eval("(current-buffer)").unwrap();
    s.keys(&["M-a"]);
    let other = temp_path("claude-two");
    std::fs::create_dir_all(other.join(".git")).unwrap();
    std::fs::write(other.join("b.txt"), "b\n").unwrap();
    type_keys(
        &mut s,
        &format!(":e {}<ret>", other.join("b.txt").display()),
    );
    s.keys(&["M-a"]);
    assert_ne!(s.eval("(current-buffer)").unwrap(), first);
    assert_eq!(s.eval("(hash-length *terminals*)").unwrap(), "2");
    // The window down the right is reused, not split again.
    assert_eq!(windows(&mut s), 2);
}
