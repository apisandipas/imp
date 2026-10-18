//! Projects (runtime/project.scm): roots, finding files, searching, and
//! the quickfix list.

mod common;

use common::*;
use std::path::PathBuf;

/// A project marked by .git with src/main.rs, src/lib.rs and README.
fn project(name: &str) -> PathBuf {
    let dir = temp_path(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join(".git")).unwrap();
    std::fs::create_dir_all(dir.join("src")).unwrap();
    std::fs::write(dir.join("src/main.rs"), "fn main() {\n    helper();\n}\n").unwrap();
    std::fs::write(
        dir.join("src/lib.rs"),
        "pub fn helper() {}\n// helper again\n",
    )
    .unwrap();
    std::fs::write(dir.join("README"), "about\n").unwrap();
    dir
}

fn open(dir: &std::path::Path, file: &str) -> imp_server::Server {
    let mut s = server("");
    // Remembered projects go to a state directory of the test's own.
    s.eval(&format!(
        "(set-option! 'state-directory {:?})",
        temp_path(&format!(
            "{}-state",
            dir.file_name().unwrap().to_string_lossy()
        ))
        .display()
        .to_string()
    ))
    .unwrap();
    type_keys(&mut s, &format!(":e {}<ret>", dir.join(file).display()));
    s
}

#[test]
fn the_root_comes_from_a_marker() {
    let dir = project("proj-root");
    let mut s = open(&dir, "src/main.rs");
    assert_eq!(
        s.eval("(project-root)").unwrap(),
        format!("{:?}", dir.display().to_string())
    );
    // Remembered.
    assert!(s.eval("(known-projects)").unwrap().contains("proj-root"));
    // Outside any project.
    let lone = temp_path("proj-none");
    std::fs::create_dir_all(&lone).unwrap();
    std::fs::write(lone.join("x.txt"), "x\n").unwrap();
    s.eval("(set-option! 'project-markers '(\".no-such-marker\"))")
        .unwrap();
    assert_eq!(s.eval("(project-root)").unwrap(), "#false");
}

#[test]
fn find_a_file_and_a_buffer() {
    let dir = project("proj-find");
    let mut s = open(&dir, "README");
    type_keys(&mut s, " pf");
    type_keys(&mut s, "lib<ret>");
    assert!(s.eval("(buffer-name)").unwrap().contains("lib.rs"));
    type_keys(&mut s, " pb");
    type_keys(&mut s, "READ<ret>");
    assert!(s.eval("(buffer-name)").unwrap().contains("README"));
}

#[test]
fn grep_fills_the_quickfix_list() {
    let dir = project("proj-grep");
    let mut s = open(&dir, "README");
    type_keys(&mut s, ":grep helper<ret>");
    // Vim jumps to the first match.
    let first = s.eval("(buffer-name)").unwrap();
    assert!(first.contains(".rs"), "{first}");
    assert!(s.status().contains("of 3)"), "{}", s.status());
    type_keys(&mut s, ":cn<ret>");
    assert!(s.status().starts_with("(2 of 3)"), "{}", s.status());
    type_keys(&mut s, "]q");
    assert!(s.status().starts_with("(3 of 3)"), "{}", s.status());
    type_keys(&mut s, "]q");
    assert!(s.status().contains("E553"), "{}", s.status());
    type_keys(&mut s, "[q[q");
    assert!(s.status().starts_with("(1 of 3)"), "{}", s.status());
    // The list, and <ret> on an entry.
    type_keys(&mut s, ":copen<ret>");
    assert_eq!(s.eval("(major-mode)").unwrap(), "grep-mode");
    let text = s.text();
    assert!(text.starts_with("grep helper (3 matches)\n"), "{text}");
    assert!(text.contains("src/main.rs:2: helper();"), "{text}");
    let line = text.lines().position(|l| l.contains("main.rs")).unwrap();
    s.eval(&format!("(set-cursor! (line-start {line}))"))
        .unwrap();
    type_keys(&mut s, "<ret>");
    assert!(s.eval("(buffer-name)").unwrap().contains("main.rs"));
    assert_eq!(s.eval("(current-line)").unwrap(), "1");
    assert_eq!(s.eval("(current-col)").unwrap(), "4");
}

#[test]
fn grep_without_rg() {
    let dir = project("proj-plain-grep");
    let mut s = open(&dir, "README");
    s.eval("(set-option! 'grepprg \"grep -rn\")").unwrap();
    type_keys(&mut s, ":grep! about<ret>");
    assert!(s.status().contains("1 matches"), "{}", s.status());
    type_keys(&mut s, ":cfirst<ret>");
    assert!(s.eval("(buffer-name)").unwrap().contains("README"));
}

#[test]
fn search_project_shows_the_list() {
    let dir = project("proj-search");
    let mut s = open(&dir, "src/lib.rs");
    // The word at the cursor is offered.
    type_keys(&mut s, "w sp");
    assert!(s
        .frame()
        .text_rows()
        .join("\n")
        .contains("Search project: fn"));
    type_keys(&mut s, "<C-u>helper<ret>");
    assert_eq!(s.eval("(major-mode)").unwrap(), "grep-mode");
    assert!(s.text().contains("(3 matches)"));
}
