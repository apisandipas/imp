//! The file-tree package (packages/file-tree): the project's folders as a
//! tree down the left.

mod common;

use common::*;
use std::path::{Path, PathBuf};

/// A project (it has .git) holding src/ (with main.rs), docs/, b.txt,
/// A.txt, .env, and debug.log and target/, which .gitignore ignores.
fn project(name: &str) -> PathBuf {
    let dir = temp_path(name);
    let _ = std::fs::remove_dir_all(&dir);
    for d in [".git", "src", "docs", "target"] {
        std::fs::create_dir_all(dir.join(d)).unwrap();
    }
    for f in [
        "src/main.rs",
        "b.txt",
        "A.txt",
        ".env",
        "debug.log",
        "target/x",
    ] {
        std::fs::write(dir.join(f), "").unwrap();
    }
    std::fs::write(dir.join(".gitignore"), "target/\n*.log\n").unwrap();
    dir
}

/// A server with the package loaded, visiting `file`.
fn visiting(file: &Path) -> imp_server::Server {
    let mut s = server("");
    s.eval("(use-package! 'file-tree)").unwrap();
    type_keys(&mut s, &format!(":e {}<ret>", file.display()));
    s
}

fn eval(s: &mut imp_server::Server, code: &str) -> String {
    s.eval(code).unwrap()
}

#[test]
fn toggles_down_the_left() {
    let dir = project("tree-toggle");
    let mut s = visiting(&dir.join("b.txt"));
    let file_window = eval(&mut s, "(current-window)");
    type_keys(&mut s, " te");
    assert_eq!(eval(&mut s, "(major-mode)"), "file-tree-mode");
    assert_eq!(eval(&mut s, "(length (window-list))"), "2");
    // On the left, file-tree-width columns wide.
    assert_eq!(
        eval(&mut s, "(car (window-list))"),
        eval(&mut s, "(current-window)")
    );
    assert_eq!(eval(&mut s, "(window-text-width)"), "30");
    // The root's name, then directories, then files, alphabetical; no
    // dotfiles, nothing git ignores.
    let root = dir.file_name().unwrap().to_str().unwrap();
    assert_eq!(
        s.text(),
        format!("{root}\n  docs/\n  src/\n  A.txt\n  b.txt\n")
    );
    assert_eq!(eval(&mut s, "(buffer-read-only?)"), "#true");
    // Toggling from the tree closes it, back in the file's window.
    type_keys(&mut s, " te");
    assert_eq!(eval(&mut s, "(length (window-list))"), "1");
    assert_eq!(eval(&mut s, "(current-window)"), file_window);
    assert_eq!(s.text(), "");
    // :FileTree opens it, and q closes it.
    type_keys(&mut s, ":FileTree<ret>");
    assert_eq!(eval(&mut s, "(major-mode)"), "file-tree-mode");
    type_keys(&mut s, "q");
    assert_eq!(eval(&mut s, "(length (window-list))"), "1");
    assert_eq!(eval(&mut s, "(current-window)"), file_window);
}

#[test]
fn toggling_from_another_window_closes_it() {
    let dir = project("tree-elsewhere");
    let mut s = visiting(&dir.join("b.txt"));
    let file_window = eval(&mut s, "(current-window)");
    type_keys(&mut s, " te");
    // Back to the file's window: the tree stays, one per frame.
    type_keys(&mut s, "<C-w>l");
    assert_eq!(eval(&mut s, "(current-window)"), file_window);
    type_keys(&mut s, " te");
    assert_eq!(eval(&mut s, "(length (window-list))"), "1");
    assert_eq!(eval(&mut s, "(current-window)"), file_window);
}

#[test]
fn with_no_file_it_shows_the_working_directorys_project() {
    let mut s = server("");
    s.eval("(use-package! 'file-tree)").unwrap();
    let root = eval(&mut s, "(file-name-of (or (project-root) (current-dir)))");
    type_keys(&mut s, " te");
    assert!(
        s.text()
            .starts_with(&format!("{}\n", root.trim_matches('"'))),
        "{}",
        s.text()
    );
}
