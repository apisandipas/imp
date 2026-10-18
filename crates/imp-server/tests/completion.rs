//! Completion menus: M-x, find-file, switch-buffer.

mod common;

use common::*;

fn rows(s: &mut imp_server::Server) -> Vec<String> {
    s.frame()
        .text_rows()
        .into_iter()
        .map(|r| r.trim_end().to_string())
        .collect()
}

#[test]
fn menu_narrows_as_you_type() {
    let mut s = server("");
    s.eval(r#"(completing-read "Pick: " (list "apple" "banana" "cherry" "grape") (lambda (x) (message (string-append "got " x))))"#)
        .unwrap();
    assert!(rows(&mut s).contains(&"banana".to_string()));
    type_keys(&mut s, "ap");
    let r = rows(&mut s);
    assert!(r.contains(&"apple".to_string()) && r.contains(&"grape".to_string()));
    assert!(!r.contains(&"banana".to_string()));
    assert!(r.last().unwrap().starts_with("Pick: ap   [1/2]"));
    type_keys(&mut s, "<ret>");
    assert_eq!(s.status(), "got apple");
    // The menu is gone.
    assert!(!rows(&mut s).contains(&"apple".to_string()));
}

#[test]
fn moving_the_selection() {
    let mut s = server("");
    s.eval(r#"(completing-read "Pick: " (list "a1" "a2" "a3") (lambda (x) (message x)))"#)
        .unwrap();
    s.keys(&["C-n", "C-n"]);
    type_keys(&mut s, "<ret>");
    assert_eq!(s.status(), "a3");
    s.eval(r#"(completing-read "Pick: " (list "a1" "a2" "a3") (lambda (x) (message x)))"#)
        .unwrap();
    s.keys(&["C-p"]);
    type_keys(&mut s, "<ret>");
    assert_eq!(s.status(), "a3");
}

#[test]
fn no_match_submits_the_text_and_escape_cancels() {
    let mut s = server("");
    s.eval(
        r#"(completing-read "Pick: " (list "a") (lambda (x) (message (string-append "got " x))))"#,
    )
    .unwrap();
    type_keys(&mut s, "zz<ret>");
    assert_eq!(s.status(), "got zz");
    s.eval(r#"(completing-read "Pick: " (list "a") (lambda (x) (message "picked")))"#)
        .unwrap();
    type_keys(&mut s, "<esc>");
    assert_ne!(s.status(), "picked");
    assert!(!rows(&mut s).iter().any(|r| r == "a"));
}

#[test]
fn execute_command_runs_by_name() {
    let mut s = server("(+ 2 3)\n");
    s.eval("(run-command 'execute-command)").unwrap();
    type_keys(&mut s, "eval buf<ret>");
    assert_eq!(s.status(), "5");
}

#[test]
fn find_file_lists_project_files() {
    let dir = temp_path("project");
    std::fs::create_dir_all(dir.join("src")).unwrap();
    std::fs::create_dir_all(dir.join("ignored")).unwrap();
    std::fs::write(dir.join("src/main.rs"), "fn main() {}\n").unwrap();
    std::fs::write(dir.join("ignored/x.txt"), "x\n").unwrap();
    std::fs::write(dir.join(".gitignore"), "ignored/\n").unwrap();
    // .gitignore only applies inside a git repository.
    std::fs::create_dir_all(dir.join(".git")).unwrap();
    let mut s = server("");
    let files = s
        .eval(&format!("(list-files \"{}\" 100)", dir.display()))
        .unwrap();
    assert!(files.contains("src/main.rs"), "{files}");
    assert!(!files.contains("ignored"), "{files}");
}

#[test]
fn switch_buffer_by_name() {
    let a = temp_path("switch-a.txt");
    std::fs::write(&a, "aaa\n").unwrap();
    let mut s = server("scratch\n");
    type_keys(&mut s, &format!(":e {}<ret>", a.display()));
    s.eval("(run-command 'switch-buffer)").unwrap();
    // The alternate buffer is offered first.
    type_keys(&mut s, "<ret>");
    assert_eq!(s.text(), "scratch\n");
}
