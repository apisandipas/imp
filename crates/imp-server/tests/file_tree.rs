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

#[test]
fn h_and_i_show_dotfiles_and_ignored_files() {
    let dir = project("tree-hidden");
    let mut s = visiting(&dir.join("b.txt"));
    let root = dir.file_name().unwrap().to_str().unwrap().to_string();
    type_keys(&mut s, " te");
    type_keys(&mut s, "H");
    assert_eq!(
        s.text(),
        format!("{root}\n  .git/\n  docs/\n  src/\n  .env\n  .gitignore\n  A.txt\n  b.txt\n")
    );
    // The cursor stays on b.txt.
    assert_eq!(eval(&mut s, "(current-line)"), "7");
    type_keys(&mut s, "HI");
    assert_eq!(
        s.text(),
        format!("{root}\n  docs/\n  src/\n  target/\n  A.txt\n  b.txt\n  debug.log\n")
    );
    type_keys(&mut s, "I");
    assert_eq!(
        s.text(),
        format!("{root}\n  docs/\n  src/\n  A.txt\n  b.txt\n")
    );
}

#[test]
fn the_options_set_what_it_starts_with() {
    let dir = project("tree-options");
    let mut s = visiting(&dir.join("b.txt"));
    s.eval("(set-option! 'file-tree-show-hidden #t)").unwrap();
    s.eval("(set-option! 'file-tree-show-ignored #t)").unwrap();
    type_keys(&mut s, " te");
    assert!(s.text().contains("  .env\n"), "{}", s.text());
    assert!(s.text().contains("  debug.log\n"), "{}", s.text());
}

#[test]
fn r_and_reopening_read_the_folders_again() {
    let dir = project("tree-refresh");
    let mut s = visiting(&dir.join("b.txt"));
    let root = dir.file_name().unwrap().to_str().unwrap().to_string();
    type_keys(&mut s, " te");
    std::fs::write(dir.join("c.txt"), "").unwrap();
    type_keys(&mut s, "R");
    assert_eq!(
        s.text(),
        format!("{root}\n  docs/\n  src/\n  A.txt\n  b.txt\n  c.txt\n")
    );
    // The cursor is still on b.txt.
    assert_eq!(eval(&mut s, "(current-line)"), "4");
    std::fs::remove_file(dir.join("c.txt")).unwrap();
    type_keys(&mut s, "q te");
    assert_eq!(
        s.text(),
        format!("{root}\n  docs/\n  src/\n  A.txt\n  b.txt\n")
    );
}

#[test]
fn a_adds_files_and_folders() {
    let dir = project("tree-add");
    let mut s = visiting(&dir.join("b.txt"));
    let root = dir.file_name().unwrap().to_str().unwrap().to_string();
    type_keys(&mut s, " te");
    // On src/, a adds inside it, making the folders on the way.
    type_keys(&mut s, "ggjja");
    type_keys(&mut s, "lib/mod.rs<ret>");
    assert!(dir.join("src/lib/mod.rs").is_file());
    assert_eq!(
        s.text(),
        format!("{root}\n  docs/\n  src/\n    lib/\n      mod.rs\n    main.rs\n  A.txt\n  b.txt\n")
    );
    assert_eq!(eval(&mut s, "(current-line)"), "4");
    // On a file, a adds beside it; a name ending in / is a folder.
    type_keys(&mut s, "anotes/<ret>");
    assert!(dir.join("src/lib/notes").is_dir());
    assert_eq!(eval(&mut s, "(current-line)"), "4");
    assert!(
        s.text().contains("      notes/\n      mod.rs\n"),
        "{}",
        s.text()
    );
    // On the root line, a adds at the top; an existing name says so.
    type_keys(&mut s, "gga");
    type_keys(&mut s, "b.txt<ret>");
    assert!(s.status().contains("b.txt already exists"));
}

#[test]
fn r_renames_and_moves_and_buffers_follow() {
    let dir = project("tree-rename");
    std::fs::write(dir.join("b.txt"), "bee\n").unwrap();
    let mut s = visiting(&dir.join("b.txt"));
    let root = dir.file_name().unwrap().to_str().unwrap().to_string();
    type_keys(&mut s, " te");
    // The cursor starts on b.txt; the prompt holds its path.
    type_keys(&mut s, "r");
    type_keys(&mut s, "<C-u>docs/bee.txt<ret>");
    assert!(!dir.join("b.txt").exists());
    assert_eq!(read(&dir, "docs/bee.txt"), "bee\n");
    assert_eq!(
        s.text(),
        format!("{root}\n  docs/\n    bee.txt\n  src/\n  A.txt\n")
    );
    assert_eq!(eval(&mut s, "(current-line)"), "2");
    // The buffer visiting it now visits the new path.
    let file_buffer = eval(
        &mut s,
        "(window-buffer (cdr (assv (current-window) *file-tree-origins*)))",
    );
    let path = eval(&mut s, &format!("(with-buffer {file_buffer} buffer-path)"));
    assert!(path.ends_with("docs/bee.txt\""), "{path}");
    // A folder's files follow it too.
    type_keys(&mut s, "kr");
    type_keys(&mut s, "<C-u>guide<ret>");
    assert_eq!(read(&dir, "guide/bee.txt"), "bee\n");
    let path = eval(&mut s, &format!("(with-buffer {file_buffer} buffer-path)"));
    assert!(path.ends_with("guide/bee.txt\""), "{path}");
}

#[test]
fn d_deletes_after_asking() {
    let dir = project("tree-delete");
    std::fs::write(dir.join("docs/a.md"), "").unwrap();
    let mut s = visiting(&dir.join("b.txt"));
    let root = dir.file_name().unwrap().to_str().unwrap().to_string();
    type_keys(&mut s, " te");
    // n keeps it.
    type_keys(&mut s, "ggjDn");
    assert!(dir.join("docs/a.md").exists());
    // y deletes the folder and what's in it.
    type_keys(&mut s, "D");
    assert!(s
        .status()
        .contains("Delete docs/ and everything in it? (y or n)"));
    type_keys(&mut s, "y");
    assert!(!dir.join("docs").exists());
    assert_eq!(s.text(), format!("{root}\n  src/\n  A.txt\n  b.txt\n"));
    type_keys(&mut s, "GDy");
    assert!(!dir.join("b.txt").exists());
    assert_eq!(s.text(), format!("{root}\n  src/\n  A.txt\n"));
}

fn read(dir: &Path, name: &str) -> String {
    std::fs::read_to_string(dir.join(name)).unwrap_or_else(|e| panic!("{name}: {e}"))
}
