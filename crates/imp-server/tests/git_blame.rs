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
    // SPC g b and :GitBlame toggle it.
    type_keys(&mut s, " gb");
    assert!(!on(&mut s));
    type_keys(&mut s, ":GitBlame<ret>");
    assert!(on(&mut s));
    // Not for a file outside one.
    let outside = temp_path("blame-outside.txt");
    std::fs::write(&outside, "x\n").unwrap();
    type_keys(&mut s, &format!(":e {}<ret>", outside.display()));
    assert!(!on(&mut s));
}
