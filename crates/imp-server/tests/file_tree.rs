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

#[test]
fn folders_open_and_shut_in_place() {
    let dir = project("tree-expand");
    std::fs::create_dir_all(dir.join("src/deep")).unwrap();
    std::fs::write(dir.join("src/deep/inner.rs"), "").unwrap();
    let mut s = visiting(&dir.join("b.txt"));
    let root = dir.file_name().unwrap().to_str().unwrap().to_string();
    type_keys(&mut s, " te");
    // src/ is the third line (the cursor starts on b.txt, the current
    // file): <ret> opens it, its entries indented a
    // level more, and the cursor stays on it.
    type_keys(&mut s, "ggjj<ret>");
    assert_eq!(
        s.text(),
        format!("{root}\n  docs/\n  src/\n    deep/\n    main.rs\n  A.txt\n  b.txt\n")
    );
    assert_eq!(eval(&mut s, "(current-line)"), "2");
    type_keys(&mut s, "j<tab>");
    assert_eq!(
        s.text(),
        format!(
            "{root}\n  docs/\n  src/\n    deep/\n      inner.rs\n    main.rs\n  A.txt\n  b.txt\n"
        )
    );
    // <tab> shuts src/ again; reopened, deep/ is still open.
    type_keys(&mut s, "k<tab>");
    assert_eq!(
        s.text(),
        format!("{root}\n  docs/\n  src/\n  A.txt\n  b.txt\n")
    );
    type_keys(&mut s, "<ret>");
    assert!(s.text().contains("      inner.rs\n"), "{}", s.text());
    // Closed and opened again, the tree looks the same.
    type_keys(&mut s, "q te");
    assert!(s.text().contains("      inner.rs\n"), "{}", s.text());
}

#[test]
fn ret_on_a_file_opens_it_in_the_window_it_came_from() {
    let dir = project("tree-open");
    std::fs::write(dir.join("src/main.rs"), "fn main() {}\n").unwrap();
    let mut s = visiting(&dir.join("b.txt"));
    let file_window = eval(&mut s, "(current-window)");
    type_keys(&mut s, " te");
    let tree_window = eval(&mut s, "(current-window)");
    type_keys(&mut s, "ggjj<ret>j<ret>");
    assert_eq!(eval(&mut s, "(current-window)"), file_window);
    assert_eq!(s.text(), "fn main() {}\n");
    // The tree stays open beside it.
    assert_eq!(eval(&mut s, "(length (window-list))"), "2");
    assert_eq!(
        eval(&mut s, &format!("(window-buffer {tree_window})")),
        eval(&mut s, "(file-tree-buffer)")
    );
}

#[test]
fn opening_reveals_the_current_file() {
    let dir = project("tree-reveal");
    std::fs::create_dir_all(dir.join("docs/guide")).unwrap();
    std::fs::write(dir.join("docs/guide/intro.md"), "").unwrap();
    let mut s = visiting(&dir.join("docs/guide/intro.md"));
    type_keys(&mut s, " te");
    let root = dir.file_name().unwrap().to_str().unwrap().to_string();
    assert_eq!(
        s.text(),
        format!("{root}\n  docs/\n    guide/\n      intro.md\n  src/\n  A.txt\n  b.txt\n")
    );
    assert_eq!(eval(&mut s, "(current-line)"), "3");
}
