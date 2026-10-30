//! Completion menus: M-x, find-file, switch-buffer.

mod common;

use common::*;

fn rows(s: &mut imp_server::Server) -> Vec<String> {
    s.frame()
        .text_rows()
        .into_iter()
        .map(|r| r.trim().to_string())
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

#[test]
fn m_x_works_in_normal_mode() {
    let mut s = server("(+ 1 1)\n");
    s.keys(&["M-x"]);
    type_keys(&mut s, "eval buf<ret>");
    assert_eq!(s.status(), "2");
}

#[test]
fn m_x_describes_each_command() {
    let mut s = server("");
    s.set_size(200, 24);
    s.keys(&["M-x"]);
    type_keys(&mut s, "find-file");
    let menu = rows(&mut s).join("\n");
    // The first line of its doc comment, after its keys.
    let row = menu
        .lines()
        .find(|r| r.starts_with("find-file "))
        .expect(&menu);
    assert!(row.contains("SPC f f"), "{row}");
    assert!(
        row.contains(
            "Open a file in this buffer's project (or its directory), skipping what .gitignore does."
        ),
        "{row}"
    );
    // With no docstring, its which-key label.
    type_keys(&mut s, "<esc>");
    s.eval("(define-command! 'undocumented-thing (lambda (count) #t)) (define-leader! \"zq\" 'undocumented-thing \"do the thing\")")
        .unwrap();
    s.keys(&["M-x"]);
    type_keys(&mut s, "undocumented-thing");
    let menu = rows(&mut s).join("\n");
    let row = menu
        .lines()
        .find(|r| r.starts_with("undocumented-thing "))
        .expect(&menu);
    assert!(
        row.contains("SPC z q") && row.contains("Do the thing"),
        "{row}"
    );
    // A command from a table, documented with document-command!.
    type_keys(&mut s, "<esc>");
    s.keys(&["M-x"]);
    type_keys(&mut s, "kill-line");
    let menu = rows(&mut s).join("\n");
    assert!(
        menu.contains("Kill to the end of the line; at the end, kill the line break."),
        "{menu}"
    );
}

#[test]
fn every_command_has_a_description() {
    let mut s = server("");
    let missing = s
        .eval(
            "(filter (lambda (c) (not (or (command-doc (symbol->string c) (doc-lines))
                                          (assoc c (*command-labels*)))))
                     (command-names))",
        )
        .unwrap();
    assert_eq!(missing, "()", "commands M-x can't describe");
}

#[test]
fn tab_completes_a_file_path_then_moves() {
    let mut s = server("");
    s.eval(
        r#"(set! *completion-category* 'file)
           (completing-read "Find file: " (list "src/main.rs" "src/lib.rs" "scripts/build.sh" "README")
                            (lambda (x) (message (string-append "got " x))))"#,
    )
    .unwrap();
    // "s" could be src/ or scripts/: nothing to add, so <tab> moves down.
    type_keys(&mut s, "s<tab>");
    assert!(rows(&mut s).last().unwrap().starts_with("Find file: s "));
    type_keys(&mut s, "r<tab>");
    assert!(rows(&mut s).last().unwrap().starts_with("Find file: src/ "));
    type_keys(&mut s, "m<tab><ret>");
    assert_eq!(s.status(), "got src/main.rs");
    // Not choosing a file, <tab> only moves.
    s.eval(r#"(completing-read "Pick: " (list "ab1" "ab2") (lambda (x) (message x)))"#)
        .unwrap();
    type_keys(&mut s, "a<tab><ret>");
    assert_eq!(s.status(), "ab2");
}

#[test]
fn a_path_outside_lists_that_directory() {
    let dir = temp_path("elsewhere");
    std::fs::create_dir_all(dir.join("notes")).unwrap();
    std::fs::write(dir.join("notes/todo.org"), "x\n").unwrap();
    std::fs::write(dir.join("readme.md"), "x\n").unwrap();
    std::fs::write(dir.join(".hidden"), "x\n").unwrap();
    let mut s = server("");
    // Wide enough for CI's long temporary paths.
    s.set_size(200, 24);
    s.eval(r#"(run-command 'find-file)"#).unwrap();
    let base = dir.to_str().unwrap();
    type_keys(&mut s, &format!("{base}/"));
    let r = rows(&mut s);
    assert!(r.iter().any(|l| l.ends_with("/notes/")), "{r:?}");
    assert!(r.iter().any(|l| l.ends_with("/readme.md")), "{r:?}");
    assert!(!r.iter().any(|l| l.ends_with("/.hidden")), "{r:?}");
    // <tab> goes into the only match, which lists its files.
    type_keys(&mut s, "n<tab>");
    let r = rows(&mut s);
    assert!(r.iter().any(|l| l.ends_with("/notes/todo.org")), "{r:?}");
    type_keys(&mut s, "<ret>");
    assert!(s.eval("(buffer-path)").unwrap().contains("todo.org"));
}

#[test]
fn find_file_lists_the_buffers_project_or_directory() {
    let mut s = server("");
    s.set_size(200, 24);
    // In a project: its files, from wherever imp was started.
    let project = temp_path("ff-project");
    std::fs::create_dir_all(project.join(".git")).unwrap();
    std::fs::create_dir_all(project.join("src")).unwrap();
    std::fs::write(project.join("src/a.rs"), "a\n").unwrap();
    std::fs::write(project.join("notes.md"), "n\n").unwrap();
    type_keys(
        &mut s,
        &format!(":e {}<ret>", project.join("src/a.rs").display()),
    );
    s.eval("(run-command 'find-file)").unwrap();
    let r = rows(&mut s);
    assert!(
        r.last().unwrap().starts_with("Find file in ff-project"),
        "{r:?}"
    );
    assert!(r.iter().any(|l| l == "notes.md"), "{r:?}");
    type_keys(&mut s, "notes<ret>");
    assert_eq!(
        s.eval("(buffer-path)").unwrap(),
        format!("{:?}", project.join("notes.md").display().to_string())
    );
    // Outside any project: the file's own directory.
    let loose = temp_path("ff-loose");
    std::fs::create_dir_all(&loose).unwrap();
    std::fs::write(loose.join("init.scm"), "x\n").unwrap();
    std::fs::write(loose.join("other.scm"), "y\n").unwrap();
    type_keys(
        &mut s,
        &format!(":e {}<ret>", loose.join("init.scm").display()),
    );
    s.eval("(run-command 'find-file)").unwrap();
    let r = rows(&mut s);
    assert!(
        r.last().unwrap().starts_with("Find file in ff-loose"),
        "{r:?}"
    );
    assert!(r.iter().any(|l| l == "other.scm"), "{r:?}");
}
