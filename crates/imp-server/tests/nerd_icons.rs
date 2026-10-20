//! The nerd-icons package (packages/nerd-icons): icons in the status line
//! and the menus.

mod common;

use common::*;
use std::process::Command;

const RUST: &str = "\u{e7a8}";
const FOLDER: &str = "\u{f07b}";
const BOLT: &str = "\u{f0e7}";
const BRANCH: &str = "\u{e725}";

fn repo(name: &str) -> std::path::PathBuf {
    let dir = temp_path(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("src")).unwrap();
    std::fs::write(dir.join("main.rs"), "fn main() {}\n").unwrap();
    let git = |args: &[&str]| {
        assert!(Command::new("git")
            .arg("-C")
            .arg(&dir)
            .args(args)
            .output()
            .unwrap()
            .status
            .success());
    };
    git(&["init", "-q", "-b", "trunk"]);
    dir
}

#[test]
fn the_status_line_shows_the_file_icon_and_branch() {
    let dir = repo("nerd-status");
    let mut s = server("");
    s.set_size(100, 10);
    s.eval("(use-package! 'nerd-icons)").unwrap();
    type_keys(
        &mut s,
        &format!(":e {}<ret>", dir.join("main.rs").display()),
    );
    let status = s.frame().text_rows()[8].clone();
    assert!(status.contains(&format!("{RUST} ")), "{status}");
    assert!(status.contains(&format!("{BRANCH} trunk")), "{status}");
}

#[test]
fn pickers_and_the_completion_menu_get_icons() {
    let dir = repo("nerd-menus");
    let mut s = server("");
    s.set_size(100, 30);
    s.eval("(use-package! 'nerd-icons)").unwrap();
    type_keys(
        &mut s,
        &format!(":e {}<ret>", dir.join("main.rs").display()),
    );
    // M-x: each command after a bolt.
    s.keys(&["M-x"]);
    type_keys(&mut s, "find-file");
    let rows = s.frame().text_rows().join("\n");
    assert!(rows.contains(&format!("{BOLT} find-file")), "{rows}");
    type_keys(&mut s, "<esc>");
    // Find file: by type.
    s.eval(r#"(set! *completion-category* 'file) (completing-read "Find file: " (list "main.rs" "src/") (lambda (x) #t))"#)
        .unwrap();
    let rows = s.frame().text_rows().join("\n");
    assert!(rows.contains(&format!("{RUST} main.rs")), "{rows}");
    assert!(rows.contains(&format!("{FOLDER} src/")), "{rows}");
    type_keys(&mut s, "<esc>");
    // Completing a path in insert state.
    type_keys(&mut s, "o./s");
    s.keys(&["C-x", "C-f"]);
    let rows = s.frame().text_rows().join("\n");
    assert!(rows.contains(&format!("{FOLDER} src/")), "{rows}");
}
