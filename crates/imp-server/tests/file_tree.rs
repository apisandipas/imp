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
        "(window-buffer (cadr (assv (current-window) *file-tree-origins*)))",
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

fn screen(s: &mut imp_server::Server) -> String {
    s.frame().text_rows().join("\n")
}

#[test]
fn question_mark_shows_and_hides_the_keys() {
    let dir = project("tree-help");
    let mut s = visiting(&dir.join("b.txt"));
    type_keys(&mut s, " te");
    assert!(!screen(&mut s).contains("show or hide dotfiles"));
    type_keys(&mut s, "?");
    let shown = screen(&mut s);
    for label in [
        "add a file, or a folder/",
        "rename or move",
        "show or hide dotfiles",
        "close the tree",
    ] {
        assert!(shown.contains(label), "{label}: {shown}");
    }
    // It stays up as you move, until ? again.
    type_keys(&mut s, "k");
    assert!(screen(&mut s).contains("rename or move"));
    type_keys(&mut s, "?");
    assert!(!screen(&mut s).contains("rename or move"));
    // Closing the tree takes it down too.
    type_keys(&mut s, "?q");
    assert!(!screen(&mut s).contains("rename or move"));
}

#[test]
fn it_can_open_at_start() {
    let dir = project("tree-start");
    std::fs::write(dir.join("b.txt"), "bee\n").unwrap();
    let config = temp_path("tree-start-init.scm");
    std::fs::write(
        &config,
        "(use-package! 'file-tree)\n(set-option! 'file-tree-open-at-start #t)\n",
    )
    .unwrap();
    let mut s = imp_server::Server::new(
        imp_core::Buffer::open(&dir.join("b.txt")).unwrap(),
        imp_server::Options {
            user_config: Some(config),
        },
    )
    .expect("runtime loads");
    // The tree is open on the left, the cursor still in the file.
    assert_eq!(eval(&mut s, "(length (window-list))"), "2");
    assert_eq!(s.text(), "bee\n");
    assert_eq!(
        eval(&mut s, "(window-buffer (car (window-list)))"),
        eval(&mut s, "(file-tree-buffer)")
    );
    let root = dir.file_name().unwrap().to_str().unwrap().to_string();
    assert!(
        s.frame().text_rows()[0].starts_with(&root),
        "{:?}",
        s.frame().text_rows()[0]
    );
}

#[test]
fn it_starts_closed_by_default() {
    let config = temp_path("tree-closed-init.scm");
    std::fs::write(&config, "(use-package! 'file-tree)\n").unwrap();
    let mut s = imp_server::Server::new(
        imp_core::Buffer::from_text(""),
        imp_server::Options {
            user_config: Some(config),
        },
    )
    .expect("runtime loads");
    assert_eq!(eval(&mut s, "(length (window-list))"), "1");
}

#[test]
fn the_cursor_sits_on_the_name() {
    let dir = project("tree-cursor");
    let mut s = visiting(&dir.join("src/main.rs"));
    type_keys(&mut s, " te");
    // main.rs, two levels in.
    assert_eq!(eval(&mut s, "(current-line)"), "3");
    assert_eq!(eval(&mut s, "(current-col)"), "4");
}

#[test]
fn the_tree_never_shows_line_numbers() {
    let dir = project("tree-numbers");
    let mut s = visiting(&dir.join("b.txt"));
    s.eval("(set-option! 'number #t)").unwrap();
    type_keys(&mut s, " te");
    let root = dir.file_name().unwrap().to_str().unwrap().to_string();
    assert!(s.frame().text_rows()[0].starts_with(&root));
    // Opening a file moves the cursor out of the tree; still no numbers.
    type_keys(&mut s, "ggjjj<ret>");
    let rows = s.frame().text_rows();
    assert!(rows[0].starts_with(&root), "{rows:?}");
    assert!(rows[1].starts_with("  docs/"), "{rows:?}");
}

/// A server like `visiting`'s, with a state directory of its own, so
/// roots it adds don't reach other tests.
fn with_own_state(file: &Path, name: &str) -> imp_server::Server {
    let mut s = visiting(file);
    let state = temp_path(&format!("{name}-state"));
    let _ = std::fs::remove_dir_all(&state);
    std::fs::create_dir_all(&state).unwrap();
    s.eval(&format!(
        "(set-option! 'state-directory {:?})",
        state.display().to_string()
    ))
    .unwrap();
    s
}

#[test]
fn p_adds_roots_and_x_removes_them() {
    let dir = project("tree-roots");
    let other = project("tree-roots-other");
    let mut s = with_own_state(&dir.join("b.txt"), "tree-roots");
    let (root, second) = (
        dir.file_name().unwrap().to_str().unwrap().to_string(),
        other.file_name().unwrap().to_str().unwrap().to_string(),
    );
    type_keys(&mut s, " te");
    type_keys(&mut s, "P");
    type_keys(&mut s, &format!("{}<ret>", other.display()));
    let both = format!(
        "{root}\n  docs/\n  src/\n  A.txt\n  b.txt\n{second}\n  docs/\n  src/\n  A.txt\n  b.txt\n"
    );
    assert_eq!(s.text(), both);
    // The cursor is on the new root's line.
    assert_eq!(eval(&mut s, "(current-line)"), "5");
    // Adding it again shows it once.
    type_keys(&mut s, "P");
    type_keys(&mut s, &format!("{}/<ret>", other.display()));
    assert_eq!(s.text(), both);
    // r works relative to the entry's own root.
    std::fs::write(other.join("b.txt"), "bee\n").unwrap();
    type_keys(&mut s, "Gr");
    type_keys(&mut s, "<C-u>c.txt<ret>");
    assert_eq!(
        std::fs::read_to_string(other.join("c.txt")).unwrap(),
        "bee\n"
    );
    assert!(dir.join("b.txt").exists());
    // Remembered: a new tree shows it too.
    type_keys(&mut s, "q te");
    assert!(s.text().contains(&format!("{second}\n")), "{}", s.text());
    // X on the first root does nothing; on the added one, it goes.
    type_keys(&mut s, "ggX");
    assert!(
        s.status().contains("the first root stays"),
        "{}",
        s.status()
    );
    type_keys(&mut s, "6GX");
    assert_eq!(
        s.text(),
        format!("{root}\n  docs/\n  src/\n  A.txt\n  b.txt\n")
    );
    assert!(other.exists());
}

#[test]
fn p_offers_the_remembered_projects() {
    let dir = project("tree-offer");
    let other = project("tree-offer-other");
    let mut s = with_own_state(&dir.join("b.txt"), "tree-offer");
    s.eval(&format!(
        "(remember-project! {:?})",
        other.display().to_string()
    ))
    .unwrap();
    type_keys(&mut s, " teP");
    let shown = s.frame().text_rows().join("\n");
    assert!(shown.contains(&other.display().to_string()), "{shown}");
    type_keys(&mut s, "<ret>");
    let second = other.file_name().unwrap().to_str().unwrap();
    assert!(s.text().contains(&format!("\n{second}\n")), "{}", s.text());
}

#[test]
fn it_follows_the_current_buffer() {
    let dir = project("tree-follow");
    std::fs::create_dir_all(dir.join("docs/guide")).unwrap();
    std::fs::write(dir.join("docs/guide/intro.md"), "intro\n").unwrap();
    let mut s = visiting(&dir.join("b.txt"));
    let root = dir.file_name().unwrap().to_str().unwrap().to_string();
    let file_window = eval(&mut s, "(current-window)");
    type_keys(&mut s, " te<C-w>l");
    type_keys(
        &mut s,
        &format!(":e {}<ret>", dir.join("docs/guide/intro.md").display()),
    );
    // Focus stays in the file's window; the tree opened down to it.
    assert_eq!(eval(&mut s, "(current-window)"), file_window);
    assert_eq!(s.text(), "intro\n");
    let rows = s.frame().text_rows();
    assert!(rows[2].starts_with("    guide/"), "{rows:?}");
    assert!(rows[3].starts_with("      intro.md"), "{rows:?}");
    // The tree's cursor is on it.
    type_keys(&mut s, "<C-w>h");
    assert_eq!(eval(&mut s, "(current-line)"), "3");
    assert!(s.text().starts_with(&root));
}

#[test]
fn it_scrolls_to_follow_and_leaves_other_files_alone() {
    let dir = project("tree-follow-scroll");
    for i in 0..60 {
        std::fs::write(dir.join(format!("f{i:02}.txt")), "").unwrap();
    }
    std::fs::write(dir.join("f59.txt"), "last\n").unwrap();
    let mut s = visiting(&dir.join("b.txt"));
    type_keys(&mut s, " te<C-w>l");
    type_keys(
        &mut s,
        &format!(":e {}<ret>", dir.join("f59.txt").display()),
    );
    let rows = s.frame().text_rows();
    assert!(rows.iter().any(|r| r.starts_with("  f59.txt")), "{rows:?}");
    // A file outside the root changes nothing.
    let outside = temp_path("tree-follow-outside.txt");
    std::fs::write(&outside, "out\n").unwrap();
    type_keys(&mut s, &format!(":e {}<ret>", outside.display()));
    type_keys(&mut s, "<C-w>h");
    assert!(eval(&mut s, "(line-text (current-line))").contains("f59.txt"));
}

#[test]
fn with_follow_off_it_stays_put() {
    let dir = project("tree-follow-off");
    let mut s = visiting(&dir.join("b.txt"));
    s.eval("(set-option! 'file-tree-follow #f)").unwrap();
    type_keys(&mut s, " te<C-w>l");
    type_keys(
        &mut s,
        &format!(":e {}<ret>", dir.join("src/main.rs").display()),
    );
    let rows = s.frame().text_rows();
    assert!(
        !rows
            .iter()
            .any(|r| r.contains("main.rs") && r.starts_with("    ")),
        "{rows:?}"
    );
}

fn git(dir: &Path, args: &[&str]) {
    let out = std::process::Command::new("git")
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

/// A real repository: a.txt and src/lib.rs committed, then a.txt
/// changed, src/new.rs added to the index, notes.txt untracked, and a
/// committed debug.log that .gitignore now ignores.
fn repo(name: &str) -> PathBuf {
    let dir = temp_path(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("src")).unwrap();
    git(&dir, &["init", "-q", "-b", "main"]);
    git(&dir, &["config", "user.name", "Ada"]);
    git(&dir, &["config", "user.email", "ada@example.com"]);
    git(&dir, &["config", "commit.gpgsign", "false"]);
    std::fs::write(dir.join("a.txt"), "one\n").unwrap();
    std::fs::write(dir.join("src/lib.rs"), "").unwrap();
    std::fs::write(dir.join(".gitignore"), "*.log\n").unwrap();
    git(&dir, &["add", "."]);
    git(&dir, &["commit", "-q", "-m", "start"]);
    std::fs::write(dir.join("a.txt"), "two\n").unwrap();
    std::fs::write(dir.join("src/new.rs"), "").unwrap();
    git(&dir, &["add", "src/new.rs"]);
    std::fs::write(dir.join("notes.txt"), "").unwrap();
    std::fs::write(dir.join("debug.log"), "").unwrap();
    dir
}

/// The tree's rows once its git status has come in.
fn wait_for(s: &mut imp_server::Server, what: impl Fn(&[String]) -> bool) -> Vec<String> {
    for _ in 0..60 {
        s.pump(std::time::Duration::from_millis(50));
        let rows: Vec<String> = s
            .frame()
            .text_rows()
            .iter()
            .map(|r| r.trim_end().to_string())
            .collect();
        if what(&rows) {
            return rows;
        }
    }
    panic!("never: {:?}", s.frame().text_rows());
}

fn face(s: &mut imp_server::Server, path: &Path) -> String {
    eval(
        s,
        &format!("(file-tree-face-of {:?})", path.display().to_string()),
    )
}

#[test]
fn changed_entries_show_their_git_status() {
    let dir = repo("tree-git");
    let mut s = visiting(&dir.join("a.txt"));
    s.set_size(100, 24);
    type_keys(&mut s, " te");
    type_keys(&mut s, "ggj<ret>");
    let rows = wait_for(&mut s, |r| r.iter().any(|l| l.starts_with("  a.txt  M")));
    assert!(
        rows.iter().any(|l| l.starts_with("  notes.txt  U")),
        "{rows:?}"
    );
    assert!(
        rows.iter().any(|l| l.starts_with("    new.rs  A")),
        "{rows:?}"
    );
    // Unchanged files and folders get no letter.
    assert!(
        rows.iter()
            .any(|l| l.split('│').next().unwrap().trim_end() == "    lib.rs"),
        "{rows:?}"
    );
    assert!(
        rows.iter()
            .any(|l| l.split('│').next().unwrap().trim_end() == "  src/"),
        "{rows:?}"
    );
    assert_eq!(face(&mut s, &dir.join("a.txt")), "\"file-tree.modified\"");
    assert_eq!(
        face(&mut s, &dir.join("notes.txt")),
        "\"file-tree.untracked\""
    );
    assert_eq!(face(&mut s, &dir.join("src/new.rs")), "\"file-tree.added\"");
    // A folder takes its most serious change's face.
    assert_eq!(face(&mut s, &dir.join("src")), "\"file-tree.added\"");
    assert_eq!(face(&mut s, &dir.join("src/lib.rs")), "#false");
    // Shown, an ignored file is dimmed.
    type_keys(&mut s, "I");
    assert_eq!(
        face(&mut s, &dir.join("debug.log")),
        "\"file-tree.ignored\""
    );
}

#[test]
fn saving_a_file_refreshes_the_status() {
    let dir = repo("tree-git-save");
    std::fs::write(dir.join("a.txt"), "one\n").unwrap();
    let mut s = visiting(&dir.join("a.txt"));
    s.set_size(100, 24);
    type_keys(&mut s, " te");
    wait_for(&mut s, |r| {
        r.iter().any(|l| l.starts_with("  notes.txt  U"))
    });
    assert_eq!(face(&mut s, &dir.join("a.txt")), "#false");
    type_keys(&mut s, "<C-w>lccthree<esc>:w<ret>");
    wait_for(&mut s, |r| r.iter().any(|l| l.starts_with("  a.txt  M")));
}

#[test]
fn outside_a_repository_nothing_has_a_status() {
    let dir = project("tree-no-git");
    std::fs::remove_dir_all(dir.join(".git")).unwrap();
    std::fs::write(dir.join(".project"), "").unwrap();
    let mut s = visiting(&dir.join("b.txt"));
    type_keys(&mut s, " te");
    s.pump(std::time::Duration::from_millis(300));
    assert_eq!(face(&mut s, &dir.join("b.txt")), "#false");
}

#[test]
fn entries_show_icons_before_their_names() {
    let dir = project("tree-icons");
    let mut s = visiting(&dir.join("b.txt"));
    let root = dir.file_name().unwrap().to_str().unwrap().to_string();
    s.eval(r#"(set! *dired-icon* (lambda (name) (if (ends-with? name "/") "D" "F")))"#)
        .unwrap();
    s.eval(r#"(set! *open-folder-icon* "O")"#).unwrap();
    type_keys(&mut s, " te");
    assert_eq!(
        s.text(),
        format!("{root}\n  D docs/\n  D src/\n  F A.txt\n  F b.txt\n")
    );
    // The cursor is on the name, past the icon.
    assert_eq!(eval(&mut s, "(current-col)"), "4");
    // An open folder has the open icon.
    type_keys(&mut s, "ggjj<ret>");
    assert_eq!(
        s.text(),
        format!("{root}\n  D docs/\n  O src/\n    F main.rs\n  F A.txt\n  F b.txt\n")
    );
    // r still starts from the path, without the icon.
    type_keys(&mut s, "jr");
    assert!(s
        .frame()
        .text_rows()
        .last()
        .unwrap()
        .contains("src/main.rs"));
}

#[test]
fn nerd_icons_gives_the_tree_its_icons() {
    let dir = project("tree-nerd");
    let mut s = visiting(&dir.join("b.txt"));
    s.eval("(use-package! 'nerd-icons)").unwrap();
    type_keys(&mut s, " teggjj<ret>");
    let text = s.text();
    // Nerd Font's shut (U+F07B) and open (U+F07C) folders.
    assert!(text.contains("  \u{f07b} docs/\n"), "{text}");
    assert!(text.contains("  \u{f07c} src/\n"), "{text}");
}

#[test]
fn git_statuses_map_to_letters() {
    let mut s = server("");
    s.eval("(use-package! 'file-tree)").unwrap();
    for (xy, letter) in [
        ("UU", "\"!\""),
        ("AA", "\"!\""),
        ("DU", "\"!\""),
        ("??", "\"U\""),
        ("A ", "\"A\""),
        ("AM", "\"A\""),
        ("R ", "\"A\""),
        (" M", "\"M\""),
        ("M ", "\"M\""),
        ("MM", "\"M\""),
        ("!!", "#false"),
    ] {
        assert_eq!(
            eval(&mut s, &format!("(file-tree-status-letter {xy:?})")),
            letter,
            "{xy}"
        );
    }
}
