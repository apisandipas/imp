//! Packages: loading from the packages directory and cloning with git.

mod common;

use common::*;
use std::process::Command;

fn packages_dir(name: &str) -> std::path::PathBuf {
    let dir = temp_path(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn use_dir(s: &mut imp_server::Server, dir: &std::path::Path) {
    s.eval(&format!(
        "(set-option! 'packages-dir \"{}\")",
        dir.display()
    ))
    .unwrap();
}

#[test]
fn loads_a_local_package_and_runs_its_config() {
    let dir = packages_dir("pkgs-local");
    std::fs::create_dir_all(dir.join("shout")).unwrap();
    std::fs::write(
        dir.join("shout/shout.scm"),
        ";; A package.\n(define (shout-text) \"HEY\")\n(define-key! 'normal \"Q\" (lambda (n) (buffer-insert! 0 (shout-text))))\n",
    )
    .unwrap();
    let mut s = server("x\n");
    use_dir(&mut s, &dir);
    s.eval("(use-package! 'shout 'config (lambda () (set! shout-text (lambda () \"hi\"))))")
        .unwrap();
    type_keys(&mut s, "Q");
    assert_eq!(s.text(), "hix\n");
    type_keys(&mut s, ":packages<ret>");
    let rows = s.frame().text_rows().join("\n");
    assert!(rows.contains("shout") && rows.contains("loaded"), "{rows}");
    // Its source is known to describe-function.
    type_keys(&mut s, "<esc>:help shout-text<ret>");
    assert!(s.frame().text_rows().join("\n").contains("A package."));
}

#[test]
fn missing_and_broken_packages_are_reported() {
    let dir = packages_dir("pkgs-broken");
    std::fs::create_dir_all(dir.join("bad")).unwrap();
    std::fs::write(dir.join("bad/bad.scm"), "(car 1)").unwrap();
    let mut s = server("");
    use_dir(&mut s, &dir);
    s.eval("(use-package! 'nope)").unwrap();
    assert!(s.status().contains("not in"));
    s.eval("(use-package! 'bad)").unwrap();
    assert!(s.status().contains("package bad"));
    type_keys(&mut s, ":packages<ret>");
    let rows = s.frame().text_rows().join("\n");
    assert!(rows.contains("missing") && rows.contains("error"), "{rows}");
}

fn git(dir: &std::path::Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@t")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@t")
        .output()
        .expect("git runs");
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

#[test]
fn clones_a_git_package_at_a_revision() {
    if Command::new("git").arg("--version").output().is_err() {
        eprintln!("git not available; skipping");
        return;
    }
    let repo = packages_dir("pkg-repo");
    git(&repo, &["init", "--quiet"]);
    std::fs::write(repo.join("init.scm"), "(define (pkg-version) 1)").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "--quiet", "-m", "one"]);
    let first = git(&repo, &["rev-parse", "HEAD"]);
    std::fs::write(repo.join("init.scm"), "(define (pkg-version) 2)").unwrap();
    git(&repo, &["commit", "--quiet", "-am", "two"]);

    let dir = packages_dir("pkgs-git");
    let mut s = server("");
    use_dir(&mut s, &dir);
    s.eval(&format!(
        "(use-package! 'versioned 'git \"{}\" 'rev \"{first}\")",
        repo.display()
    ))
    .unwrap();
    assert_eq!(s.eval("(pkg-version)").unwrap(), "1");
    assert!(dir.join("versioned/init.scm").exists());
}
