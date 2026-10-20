//! M-x delete-file, rename-file and copy-file (runtime/files.scm).

mod common;

use common::*;
use std::path::{Path, PathBuf};

/// A fresh directory `name` holding a.txt.
fn dir(name: &str) -> PathBuf {
    let dir = temp_path(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("a.txt"), "aaa\n").unwrap();
    dir
}

fn open(path: &Path) -> imp_server::Server {
    let mut s = server("scratch\n");
    type_keys(&mut s, &format!(":e {}<ret>", path.display()));
    s
}

fn m_x(s: &mut imp_server::Server, command: &str) {
    s.keys(&["M-x"]);
    type_keys(s, &format!("{command}<ret>"));
}

/// Replaces the prompt's text with `answer` and submits it.
fn answer(s: &mut imp_server::Server, answer: &str) {
    type_keys(s, &format!("<C-u>{answer}<ret>"));
}

fn last_row(s: &mut imp_server::Server) -> String {
    s.frame().text_rows().last().unwrap().trim_end().to_string()
}

#[test]
fn delete_file_offers_the_current_buffer_and_asks_first() {
    let d = dir("files-delete");
    let a = d.join("a.txt");
    let mut s = open(&a);
    m_x(&mut s, "delete-file");
    let prompt = last_row(&mut s);
    assert!(
        prompt.starts_with("Delete file: ") && prompt.ends_with("files-delete/a.txt"),
        "{prompt}"
    );
    type_keys(&mut s, "<ret>");
    assert!(s.status().contains("a.txt? (y or n)"), "{}", s.status());
    // n keeps it.
    type_keys(&mut s, "n");
    assert!(a.exists());
    m_x(&mut s, "delete-file");
    type_keys(&mut s, "<ret>y");
    assert!(!a.exists());
    // Its buffer went with it.
    assert_eq!(s.text(), "scratch\n");
    assert!(s.status().starts_with("deleted "), "{}", s.status());
}

#[test]
fn delete_file_keeps_a_buffer_with_unsaved_changes() {
    let d = dir("files-delete-modified");
    let a = d.join("a.txt");
    let mut s = open(&a);
    type_keys(&mut s, "ix<esc>");
    m_x(&mut s, "delete-file");
    type_keys(&mut s, "<ret>y");
    assert!(!a.exists());
    assert_eq!(s.text(), "xaaa\n");
    assert!(s.status().contains("unsaved changes"), "{}", s.status());
}

#[test]
fn delete_file_by_name_and_refusing_directories() {
    let d = dir("files-delete-other");
    std::fs::write(d.join("b.txt"), "b\n").unwrap();
    let mut s = open(&d.join("a.txt"));
    m_x(&mut s, "delete-file");
    answer(&mut s, &d.join("b.txt").display().to_string());
    type_keys(&mut s, "y");
    assert!(!d.join("b.txt").exists());
    assert_eq!(s.text(), "aaa\n");
    m_x(&mut s, "delete-file");
    answer(&mut s, &d.display().to_string());
    assert!(s.status().contains("is a directory"), "{}", s.status());
    assert!(d.exists());
}

#[test]
fn rename_file_moves_the_buffer_with_it() {
    let d = dir("files-rename");
    let a = d.join("a.txt");
    let mut s = open(&a);
    m_x(&mut s, "rename-file");
    type_keys(&mut s, "<ret>");
    assert!(last_row(&mut s).contains("to: "), "{}", last_row(&mut s));
    answer(&mut s, &d.join("b.rs").display().to_string());
    assert!(!a.exists());
    assert_eq!(std::fs::read_to_string(d.join("b.rs")).unwrap(), "aaa\n");
    assert!(s.eval("(buffer-path)").unwrap().ends_with("b.rs\""));
    // The new extension's major mode.
    assert_eq!(s.eval("(major-mode)").unwrap(), "rust-mode");
    // Saving writes the new file.
    type_keys(&mut s, "ix<esc>:w<ret>");
    assert_eq!(std::fs::read_to_string(d.join("b.rs")).unwrap(), "xaaa\n");
    assert!(!a.exists());
}

#[test]
fn rename_file_into_a_directory_and_not_over_a_file() {
    let d = dir("files-rename-dir");
    std::fs::create_dir_all(d.join("sub")).unwrap();
    std::fs::write(d.join("taken.txt"), "taken\n").unwrap();
    let a = d.join("a.txt");
    let mut s = open(&a);
    m_x(&mut s, "rename-file");
    type_keys(&mut s, "<ret>");
    answer(&mut s, &d.join("taken.txt").display().to_string());
    assert!(s.status().contains("already exists"), "{}", s.status());
    assert!(a.exists());
    m_x(&mut s, "rename-file");
    type_keys(&mut s, "<ret>");
    answer(&mut s, &d.join("sub").display().to_string());
    assert!(d.join("sub/a.txt").exists());
    assert!(s.eval("(buffer-path)").unwrap().ends_with("sub/a.txt\""));
}

#[test]
fn copy_file_leaves_the_buffer_on_the_original() {
    let d = dir("files-copy");
    let a = d.join("a.txt");
    let mut s = open(&a);
    m_x(&mut s, "copy-file");
    type_keys(&mut s, "<ret>");
    answer(&mut s, &d.join("c.txt").display().to_string());
    assert_eq!(std::fs::read_to_string(d.join("c.txt")).unwrap(), "aaa\n");
    assert!(a.exists());
    assert!(s.eval("(buffer-path)").unwrap().ends_with("a.txt\""));
    // Not over an existing file.
    m_x(&mut s, "copy-file");
    type_keys(&mut s, "<ret>");
    answer(&mut s, &d.join("c.txt").display().to_string());
    assert!(s.status().contains("already exists"), "{}", s.status());
}
