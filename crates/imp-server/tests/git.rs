//! The git interface (runtime/git.scm), against real repositories in a
//! temp directory.

mod common;

use common::*;
use std::path::{Path, PathBuf};
use std::process::Command;

fn git(dir: &Path, args: &[&str]) -> String {
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
    String::from_utf8_lossy(&out.stdout).into_owned()
}

/// A repository with a.txt committed then changed, b.txt untracked and
/// c.txt staged.
fn repo(name: &str) -> PathBuf {
    let dir = temp_path(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    git(&dir, &["init", "-q", "-b", "main"]);
    git(&dir, &["config", "user.name", "Test"]);
    git(&dir, &["config", "user.email", "test@example.com"]);
    git(&dir, &["config", "commit.gpgsign", "false"]);
    std::fs::write(
        dir.join("a.txt"),
        "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n",
    )
    .unwrap();
    git(&dir, &["add", "a.txt"]);
    git(&dir, &["commit", "-q", "-m", "Add a"]);
    // Two separate hunks.
    std::fs::write(
        dir.join("a.txt"),
        "ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nTEN\n",
    )
    .unwrap();
    std::fs::write(dir.join("b.txt"), "new\n").unwrap();
    std::fs::write(dir.join("c.txt"), "staged\n").unwrap();
    git(&dir, &["add", "c.txt"]);
    dir
}

fn status(dir: &Path) -> imp_server::Server {
    let mut s = server("");
    type_keys(&mut s, &format!(":e {}<ret>", dir.join("a.txt").display()));
    type_keys(&mut s, ":Git<ret>");
    s
}

/// Puts the cursor on the first line containing `text`.
fn go_to(s: &mut imp_server::Server, text: &str) {
    let line = s
        .text()
        .lines()
        .position(|l| l.contains(text))
        .unwrap_or_else(|| panic!("no line with {text:?} in\n{}", s.text()));
    s.eval(&format!("(set-cursor! (line-start {line}))"))
        .unwrap();
}

#[test]
fn status_shows_the_repository() {
    let dir = repo("git-status");
    let mut s = status(&dir);
    let text = s.text();
    assert!(text.starts_with("Head:     main  Add a\n"), "{text}");
    for want in [
        "Untracked files (1)",
        "untracked  b.txt",
        "Unstaged changes (1)",
        "modified   a.txt",
        "Staged changes (1)",
        "new file   c.txt",
        "Recent commits",
    ] {
        assert!(text.contains(want), "{want:?} in\n{text}");
    }
    assert_eq!(s.eval("(major-mode)").unwrap(), "git-status-mode");
    // The section titles are drawn in their face.
    let rows = s.frame().text_rows();
    assert!(rows.iter().any(|r| r.starts_with("Untracked files")));
    // It can't be edited by accident.
    feed(&mut s, "ihello<esc>");
    assert_eq!(s.text(), text);
    // dd is the unstaged diff (d for the diff menu, then d).
    type_keys(&mut s, "dd");
    assert!(s.text().contains("+ONE"), "{}", s.text());
    type_keys(&mut s, "q");
    assert_eq!(s.eval("(major-mode)").unwrap(), "git-status-mode");
    // q goes back to the file.
    type_keys(&mut s, "q");
    assert!(s.eval("(buffer-name)").unwrap().contains("a.txt"));
}

#[test]
fn stage_and_unstage_files_and_hunks() {
    let dir = repo("git-stage");
    let mut s = status(&dir);
    // A whole untracked file.
    go_to(&mut s, "untracked  b.txt");
    type_keys(&mut s, "s");
    assert!(git(&dir, &["diff", "--cached", "--name-only"]).contains("b.txt"));
    assert!(!s.text().contains("Untracked files"));
    // One hunk of a.txt: open its diff, stage the second hunk only.
    go_to(&mut s, "modified   a.txt");
    type_keys(&mut s, "<tab>");
    assert!(s.text().contains("-one\n+ONE"), "{}", s.text());
    go_to(&mut s, "+TEN");
    type_keys(&mut s, "s");
    let cached = git(&dir, &["diff", "--cached", "a.txt"]);
    assert!(
        cached.contains("+TEN") && !cached.contains("+ONE"),
        "{cached}"
    );
    let unstaged = git(&dir, &["diff", "a.txt"]);
    assert!(
        unstaged.contains("+ONE") && !unstaged.contains("+TEN"),
        "{unstaged}"
    );
    // And unstage it again from the staged section.
    go_to(&mut s, "Staged changes");
    let staged_a = s
        .text()
        .lines()
        .skip_while(|l| !l.starts_with("Staged"))
        .any(|l| l.ends_with("a.txt"));
    assert!(staged_a, "{}", s.text());
    s.eval("(set-cursor! (line-start (+ 1 (current-line))))")
        .unwrap();
    while !s
        .eval("(buffer-substring (line-start (current-line)) (line-end (current-line)))")
        .unwrap()
        .contains("a.txt")
    {
        type_keys(&mut s, "j");
    }
    type_keys(&mut s, "u");
    assert!(!git(&dir, &["diff", "--cached", "--name-only"]).contains("a.txt"));
    // U unstages everything; S stages everything.
    type_keys(&mut s, "U");
    assert_eq!(git(&dir, &["diff", "--cached", "--name-only"]), "");
    type_keys(&mut s, "S");
    assert_eq!(
        git(&dir, &["diff", "--cached", "--name-only"]),
        "a.txt\nb.txt\nc.txt\n"
    );
}

#[test]
fn commit_from_a_message_buffer() {
    let dir = repo("git-commit");
    let mut s = status(&dir);
    type_keys(&mut s, "cc");
    assert_eq!(s.eval("(major-mode)").unwrap(), "git-commit-mode");
    assert!(s.text().contains("# Write the message above."));
    assert!(
        s.text().contains("c.txt"),
        "the staged files are listed: {}",
        s.text()
    );
    type_keys(&mut s, "OAdd c<esc>ZZ");
    assert_eq!(git(&dir, &["log", "-1", "--format=%s"]), "Add c\n");
    assert_eq!(s.eval("(major-mode)").unwrap(), "git-status-mode");
    assert!(!s.text().contains("Staged changes"), "{}", s.text());
    assert!(s.text().contains("Add c"));
    // Cancelling leaves no commit.
    go_to(&mut s, "untracked  b.txt");
    type_keys(&mut s, "scc");
    type_keys(&mut s, "ZQ");
    assert_eq!(git(&dir, &["log", "-1", "--format=%s"]), "Add c\n");
    assert_eq!(s.eval("(major-mode)").unwrap(), "git-status-mode");
}

#[test]
fn discard_asks_first() {
    let dir = repo("git-discard");
    let mut s = status(&dir);
    go_to(&mut s, "untracked  b.txt");
    type_keys(&mut s, "xn");
    assert!(dir.join("b.txt").exists());
    type_keys(&mut s, "xy");
    assert!(!dir.join("b.txt").exists());
    go_to(&mut s, "modified   a.txt");
    type_keys(&mut s, "xy");
    assert!(std::fs::read_to_string(dir.join("a.txt"))
        .unwrap()
        .starts_with("one\n"));
}

#[test]
fn visit_log_and_show() {
    let dir = repo("git-visit");
    let mut s = status(&dir);
    // <ret> on a diff line opens the file there.
    go_to(&mut s, "modified   a.txt");
    type_keys(&mut s, "<tab>");
    go_to(&mut s, "+TEN");
    type_keys(&mut s, "<ret>");
    assert!(s.eval("(buffer-name)").unwrap().contains("a.txt"));
    assert_eq!(s.eval("(current-line)").unwrap(), "9");
    // The log, and a commit from it.
    type_keys(&mut s, ":Git<ret>l");
    assert_eq!(s.eval("(major-mode)").unwrap(), "git-log-mode");
    assert!(s.text().contains("Add a"), "{}", s.text());
    type_keys(&mut s, "<ret>");
    assert_eq!(s.eval("(major-mode)").unwrap(), "git-diff-mode");
    assert!(s.text().starts_with("commit "), "{}", s.text());
    assert!(s.text().contains("+one"));
    // :Git with arguments runs them.
    type_keys(&mut s, ":Git rev-parse --abbrev-ref HEAD<ret>");
    assert!(s.frame().text_rows().join("\n").contains("main"));
}

#[test]
fn branches_and_stashes() {
    let dir = repo("git-branch");
    let mut s = status(&dir);
    type_keys(&mut s, "bcfeature<ret>");
    assert_eq!(git(&dir, &["branch", "--show-current"]), "feature\n");
    assert!(s.text().starts_with("Head:     feature"), "{}", s.text());
    type_keys(&mut s, "zz");
    assert!(s.text().contains("Stashes (1)"), "{}", s.text());
    assert!(!s.text().contains("Unstaged changes"));
    go_to(&mut s, "stash@{0}");
    type_keys(&mut s, "zp");
    assert!(!s.text().contains("Stashes"));
    assert!(s.text().contains("Unstaged changes"));
}

#[test]
fn outside_a_repository() {
    let dir = temp_path("git-none");
    std::fs::create_dir_all(&dir).unwrap();
    let mut s = server("");
    // A file whose directory isn't in a repository (temp dirs aren't).
    type_keys(&mut s, &format!(":e {}<ret>", dir.join("x.txt").display()));
    if git_root_exists(&dir) {
        return;
    }
    type_keys(&mut s, ":Git<ret>");
    assert!(
        s.status().contains("not in a git repository"),
        "{}",
        s.status()
    );
}

fn git_root_exists(dir: &Path) -> bool {
    Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}
