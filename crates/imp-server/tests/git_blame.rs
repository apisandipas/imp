//! The git-blame package (packages/git-blame), against a real repository
//! in a temp directory.

mod common;

use common::*;
use std::path::{Path, PathBuf};
use std::process::Command;

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

/// A repository with a.txt committed by Ada Lovelace.
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
    s.eval("(use-package! 'git-blame)").unwrap();
    type_keys(&mut s, &format!(":e {}<ret>", path.display()));
    s
}

fn on(s: &mut imp_server::Server) -> bool {
    s.eval("(and (memq 'git-blame-mode (minor-modes)) #t)")
        .unwrap()
        == "#true"
}

#[test]
fn it_turns_on_for_files_in_a_repository() {
    let dir = repo("blame-on");
    let mut s = visiting(&dir.join("a.txt"));
    assert!(on(&mut s));
    // SPC g b and git-blame-mode toggle it.
    type_keys(&mut s, " gb");
    assert!(!on(&mut s));
    type_keys(&mut s, ":git-blame-mode<ret>");
    assert!(on(&mut s));
    // Not for a file outside one.
    let outside = temp_path("blame-outside.txt");
    std::fs::write(&outside, "x\n").unwrap();
    type_keys(&mut s, &format!(":e {}<ret>", outside.display()));
    assert!(!on(&mut s));
}

/// The screen's rows once timers and git have had `ms` to run.
fn rows_after(s: &mut imp_server::Server, ms: u64) -> Vec<String> {
    s.pump(std::time::Duration::from_millis(ms));
    s.frame()
        .text_rows()
        .iter()
        .map(|r| r.trim_end().to_string())
        .collect()
}

/// Waits for row `row` to contain `text`.
fn wait_for_row(s: &mut imp_server::Server, row: usize, text: &str) -> String {
    for _ in 0..50 {
        let rows = rows_after(s, 50);
        if rows[row].contains(text) {
            return rows[row].clone();
        }
    }
    panic!("row {row} never showed {text:?}: {:?}", rows_after(s, 0));
}

#[test]
fn the_cursor_line_shows_its_commit_after_a_pause() {
    let dir = repo("blame-show");
    let mut s = visiting(&dir.join("a.txt"));
    // Not at once.
    assert_eq!(rows_after(&mut s, 0)[0], "one");
    let row = wait_for_row(&mut s, 0, "Ada Lovelace, ");
    assert!(row.starts_with("one  Ada Lovelace, "), "{row}");
    assert!(row.ends_with("ago • Add a"), "{row}");
    // Moving off the line hides it there; the new line gets its own.
    type_keys(&mut s, "j");
    assert_eq!(rows_after(&mut s, 0)[0], "one");
    wait_for_row(&mut s, 1, "• Add a");
    // Moving along the line keeps it.
    type_keys(&mut s, "l");
    assert!(rows_after(&mut s, 0)[1].contains("• Add a"));
    // Insert state hides it.
    type_keys(&mut s, "i");
    assert_eq!(rows_after(&mut s, 700)[1], "two");
}

#[test]
fn an_edited_line_is_not_committed_yet() {
    let dir = repo("blame-edit");
    let mut s = visiting(&dir.join("a.txt"));
    // Unsaved: blamed as the buffer has it.
    type_keys(&mut s, "Onew<esc>");
    wait_for_row(&mut s, 0, "Not committed yet");
    type_keys(&mut s, "j");
    wait_for_row(&mut s, 1, "• Add a");
}

#[test]
fn an_untracked_file_shows_nothing() {
    let dir = repo("blame-untracked");
    std::fs::write(dir.join("new.txt"), "fresh\n").unwrap();
    let mut s = visiting(&dir.join("new.txt"));
    assert_eq!(rows_after(&mut s, 1200)[0], "fresh");
}

#[test]
fn a_file_on_the_command_line_shows_it_before_any_key() {
    let dir = repo("blame-startup");
    let config = temp_path("blame-startup-init.scm");
    std::fs::write(&config, "(use-package! 'git-blame)").unwrap();
    let mut s = imp_server::Server::new(
        imp_core::Buffer::open(&dir.join("a.txt")).unwrap(),
        imp_server::Options {
            user_config: Some(config),
        },
    )
    .expect("runtime loads");
    wait_for_row(&mut s, 0, "• Add a");
}
