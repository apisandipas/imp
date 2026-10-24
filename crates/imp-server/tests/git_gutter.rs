//! The git-gutter package (packages/git-gutter), against a real
//! repository in a temp directory.

mod common;

use common::*;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

fn git(dir: &Path, args: &[&str]) {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .expect("git runs");
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// A repository with a.txt committed.
fn repo(name: &str) -> PathBuf {
    let dir = temp_path(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    git(&dir, &["init", "-q", "-b", "main"]);
    git(&dir, &["config", "user.name", "Ada Lovelace"]);
    git(&dir, &["config", "user.email", "ada@example.com"]);
    git(&dir, &["config", "commit.gpgsign", "false"]);
    std::fs::write(dir.join("a.txt"), "one\ntwo\nthree\n").unwrap();
    git(&dir, &["add", "a.txt"]);
    git(&dir, &["commit", "-q", "-m", "Add a"]);
    dir
}

/// A server with the package loaded, visiting `path`.
fn visiting(path: &Path) -> imp_server::Server {
    let mut s = server("");
    s.eval("(use-package! 'git-gutter)").unwrap();
    type_keys(&mut s, &format!(":e {}<ret>", path.display()));
    s
}

fn rows(s: &mut imp_server::Server) -> Vec<String> {
    s.frame()
        .text_rows()
        .iter()
        .map(|r| r.trim_end().to_string())
        .collect()
}

/// Waits for the first rows to be `want`, as timers and git run.
fn wait_for(s: &mut imp_server::Server, want: &[&str]) {
    let start = Instant::now();
    loop {
        s.pump(Duration::from_millis(50));
        let r = rows(s);
        if r[..want.len()] == *want {
            return;
        }
        assert!(
            start.elapsed() < Duration::from_secs(5),
            "wanted {want:?}, got {:?}",
            &r[..want.len()]
        );
    }
}

fn on(s: &mut imp_server::Server) -> bool {
    s.eval("(git-gutter-on?)").unwrap() == "#true"
}

#[test]
fn tracked_files_get_a_change_column() {
    let dir = repo("gutter-on");
    let mut s = visiting(&dir.join("a.txt"));
    assert!(on(&mut s));
    wait_for(&mut s, &[" one", " two", " three"]);
    // :GitGutter takes it away and brings it back.
    type_keys(&mut s, ":GitGutter<ret>");
    assert!(!on(&mut s));
    assert_eq!(rows(&mut s)[0], "one");
    type_keys(&mut s, ":GitGutter<ret>");
    wait_for(&mut s, &[" one"]);
    // Not for an untracked file, or one outside a repository.
    std::fs::write(dir.join("new.txt"), "x\n").unwrap();
    type_keys(
        &mut s,
        &format!(":e {}<ret>", dir.join("new.txt").display()),
    );
    assert!(!on(&mut s));
    assert_eq!(rows(&mut s)[0], "x");
    let outside = temp_path("gutter-outside.txt");
    std::fs::write(&outside, "y\n").unwrap();
    type_keys(&mut s, &format!(":e {}<ret>", outside.display()));
    assert!(!on(&mut s));
}

#[test]
fn edits_are_marked_as_you_type() {
    let dir = repo("gutter-edits");
    let mut s = visiting(&dir.join("a.txt"));
    wait_for(&mut s, &[" one"]);
    // Added, unsaved.
    type_keys(&mut s, "ggonew<esc>");
    wait_for(&mut s, &[" one", "┃new", " two", " three"]);
    // Changed.
    type_keys(&mut s, "j0cwTWO<esc>");
    wait_for(&mut s, &[" one", "┃new", "┃TWO", " three"]);
    assert_eq!(
        s.eval("(buffer-local 'git-gutter-hunks)").unwrap(),
        "((1 1 1 2))"
    );
    // Removed: the line above gets ▁, or the first line ▔.
    type_keys(&mut s, "ggjdd");
    wait_for(&mut s, &[" one", "┃TWO", " three"]);
    type_keys(&mut s, "Gdd");
    wait_for(&mut s, &[" one", "┃TWO"]);
    // A changed line's mark wins over the removal above it.
    type_keys(&mut s, "uggdd");
    wait_for(&mut s, &["┃TWO", " three"]);
}

#[test]
fn lines_removed_at_the_top_mark_the_first_line() {
    let dir = repo("gutter-top");
    let mut s = visiting(&dir.join("a.txt"));
    wait_for(&mut s, &[" one"]);
    type_keys(&mut s, "ggdd");
    wait_for(&mut s, &["▔two", " three"]);
}

#[test]
fn marks_have_their_faces() {
    let dir = repo("gutter-faces");
    let mut s = visiting(&dir.join("a.txt"));
    let marks = s
        .eval("(git-gutter-marks (list (list 0 1 0 0) (list 1 0 1 1) (list 2 1 3 1)))")
        .unwrap();
    assert_eq!(
        marks,
        "((0 \"▔\" \"git-gutter.removed\") (1 \"┃\" \"git-gutter.added\") (3 \"┃\" \"git-gutter.changed\"))"
    );
    // An added line's mark wins over the removal above it.
    assert_eq!(
        s.eval("(git-gutter-marks (list (list 1 1 1 0) (list 2 0 0 1)))")
            .unwrap(),
        "((0 \"┃\" \"git-gutter.added\"))"
    );
}

#[test]
fn staged_changes_are_not_marked() {
    let dir = repo("gutter-staged");
    let mut s = visiting(&dir.join("a.txt"));
    type_keys(&mut s, "ggcwONE<esc>:w<ret>");
    wait_for(&mut s, &["┃ONE"]);
    // Staged elsewhere; the marks follow when the buffer is shown again.
    git(&dir, &["add", "a.txt"]);
    s.eval("(run-hooks 'buffer-enter)").unwrap();
    wait_for(&mut s, &[" ONE"]);
}
