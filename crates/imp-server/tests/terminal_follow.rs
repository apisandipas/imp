//! Terminals following what the program reports (runtime/term.scm,
//! docs/specs/terminals.md): the shell's directory (OSC 7) and the
//! program's title (OSC 0 and 2). Scripts stand in for the shell.

mod common;

use common::*;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

fn wait_for(
    s: &mut imp_server::Server,
    what: &str,
    done: impl Fn(&mut imp_server::Server) -> bool,
) {
    let start = Instant::now();
    while !done(s) {
        assert!(
            start.elapsed() < Duration::from_secs(10),
            "waited for {what}; buffer:\n{}\nstatus: {}",
            s.text(),
            s.status()
        );
        s.pump(Duration::from_millis(30));
    }
}

/// A project with `sub/b.txt` in it and a file open, and `script` (sh)
/// written beside it.
fn project(name: &str, script: &str) -> (imp_server::Server, PathBuf, PathBuf) {
    let root = temp_path(name);
    std::fs::create_dir_all(root.join(".git")).unwrap();
    std::fs::create_dir_all(root.join("sub")).unwrap();
    std::fs::write(root.join("a.txt"), "a\n").unwrap();
    std::fs::write(root.join("sub/b.txt"), "b\n").unwrap();
    let path = root.join("stand-in.sh");
    std::fs::write(&path, script).unwrap();
    let mut s = server("");
    s.set_size(200, 30);
    type_keys(&mut s, &format!(":e {}<ret>", root.join("a.txt").display()));
    (s, root, path)
}

/// Runs `script` in a terminal here and waits for it to say "ready".
fn run(s: &mut imp_server::Server, script: &Path) {
    type_keys(s, &format!(":terminal sh {}<ret>", script.display()));
    wait_for(s, "ready", |s| s.text().contains("ready"));
}

fn term_dir(s: &mut imp_server::Server) -> String {
    s.eval("(buffer-local 'term-dir)").unwrap()
}

/// Reports `dir` with OSC 7 from `host`, ended by BEL, says ready, and
/// does `then`.
fn reporting(host: &str, dir: &str, then: &str) -> String {
    format!("cd {dir}; printf '\\033]7;file://{host}%s\\007' \"$PWD\"; echo ready; {then}\n")
}

/// The same, ended by ESC \ as the reference page's bash and zsh lines do.
fn reporting_st(host: &str, dir: &str, then: &str) -> String {
    reporting(host, dir, then).replace("\\007", "\\033\\\\")
}

#[test]
fn a_terminal_follows_the_shells_directory() {
    let (mut s, root, _) = project("follow-dir", "");
    let sub = root.join("sub");
    let script = root.join("cd.sh");
    std::fs::write(&script, reporting("localhost", "sub", "exec cat")).unwrap();
    run(&mut s, &script);
    assert_eq!(term_dir(&mut s), format!("{:?}", sub.display().to_string()));
    s.keys(&["C-\\", "C-n"]);
    // :e takes a relative name from there, and completes there.
    type_keys(&mut s, ":e b.t<tab>");
    assert_eq!(s.eval("*cmdline*").unwrap(), "\"e b.txt\"");
    type_keys(&mut s, "<ret>");
    assert_eq!(
        s.eval("(buffer-path)").unwrap(),
        format!("{:?}", sub.join("b.txt").display().to_string())
    );
    // find-file lists the files under it.
    type_keys(&mut s, "<C-o>");
    assert_eq!(s.eval("(major-mode)").unwrap(), "term-mode");
    s.keys(&["M-x"]);
    type_keys(&mut s, "find-file<ret>b.txt<ret>");
    assert_eq!(
        s.eval("(buffer-path)").unwrap(),
        format!("{:?}", sub.join("b.txt").display().to_string())
    );
}

#[test]
fn the_file_browser_and_new_terminals_start_there() {
    let (mut s, root, _) = project("follow-browse", "");
    let sub = root.join("sub");
    let script = root.join("cd.sh");
    std::fs::write(&script, reporting("", "sub", "exec cat")).unwrap();
    run(&mut s, &script);
    s.keys(&["C-\\", "C-n"]);
    let term = s.eval("(current-buffer)").unwrap();
    // A new terminal from it starts in its directory.
    s.eval("(terminal! \"pwd; cat\")").unwrap();
    wait_for(&mut s, "pwd", |s| {
        s.text().contains(&*sub.to_string_lossy())
    });
    s.eval(&format!("(go-to-buffer! {term})")).unwrap();
    s.keys(&["C-\\", "C-n"]);
    type_keys(&mut s, ":Ex<ret>");
    assert_eq!(
        s.eval("(dired-dir)").unwrap(),
        format!("{:?}", sub.display().to_string())
    );
}

#[test]
fn another_hosts_directory_is_ignored() {
    let (mut s, root, _) = project("follow-host", "");
    let script = root.join("cd.sh");
    std::fs::write(&script, reporting("elsewhere.invalid", "sub", "exec cat")).unwrap();
    run(&mut s, &script);
    // Still where it started.
    assert_eq!(
        term_dir(&mut s),
        format!("{:?}", root.display().to_string())
    );
}

#[test]
fn the_directory_stays_after_the_program_exits() {
    let (mut s, root, _) = project("follow-exit", "");
    let script = root.join("cd.sh");
    std::fs::write(&script, reporting_st("localhost", "sub", "exit 0")).unwrap();
    run(&mut s, &script);
    wait_for(&mut s, "the exit", |s| {
        s.text().contains("[process exited 0]")
    });
    type_keys(&mut s, ":e b.txt<ret>");
    assert_eq!(
        s.eval("(buffer-path)").unwrap(),
        format!("{:?}", root.join("sub/b.txt").display().to_string())
    );
}

#[test]
fn a_toggled_terminal_stays_its_projects() {
    let (mut s, root, _) = project("follow-toggle", "");
    let script = root.join("cd.sh");
    std::fs::write(&script, reporting("localhost", "/tmp", "exec cat")).unwrap();
    s.eval(&format!(
        r#"(define-toggled-terminal! 'toggle-terminal "sh {}" "*terminal")"#,
        script.display()
    ))
    .unwrap();
    s.keys(&["M-`"]);
    wait_for(&mut s, "ready", |s| s.text().contains("ready"));
    assert_eq!(term_dir(&mut s), "\"/tmp\"");
    assert_eq!(
        s.eval("(project-root)").unwrap(),
        format!("{:?}", root.display().to_string())
    );
    s.keys(&["M-`"]);
    assert_eq!(s.eval("(length (window-list))").unwrap(), "1");
}

/// Sets the title to `title` (OSC 2, or OSC 0 if `zero`), then says
/// `said` and waits for a line.
fn titling(title: &str, zero: bool, said: &str) -> String {
    let n = if zero { 0 } else { 2 };
    format!("printf '\\033]{n};{title}\\007'; echo {said}; read line; ")
}

fn rows(s: &mut imp_server::Server) -> Vec<String> {
    s.frame()
        .text_rows()
        .into_iter()
        .map(|r| r.trim().to_string())
        .collect()
}

#[test]
fn the_title_shows_after_the_name() {
    let (mut s, root, _) = project("follow-title", "");
    let script = root.join("title.sh");
    std::fs::write(
        &script,
        format!(
            "{}{}{}exec cat\n",
            titling("vim 50%% done; ok", false, "ready"),
            titling("htop", true, "second"),
            titling("", false, "cleared")
        ),
    )
    .unwrap();
    run(&mut s, &script);
    // In the status line, and the buffer's name is the same.
    let status = status_row(&mut s);
    assert!(status.contains("*terminal 1: sh "), "{status}");
    assert!(status.contains("  vim 50% done; ok"), "{status}");
    // OSC 0 too.
    s.keys(&["<ret>"]);
    wait_for(&mut s, "second", |s| s.text().contains("second"));
    assert!(status_row(&mut s).contains("  htop"));
    // Beside the name in switch-buffer.
    s.keys(&["C-\\", "C-n"]);
    s.eval("(run-command 'switch-buffer)").unwrap();
    type_keys(&mut s, "a.txt");
    type_keys(&mut s, "<ret>");
    s.eval("(run-command 'switch-buffer)").unwrap();
    let menu = rows(&mut s);
    assert!(
        menu.iter()
            .any(|r| r.contains("*terminal 1") && r.contains("htop")),
        "{menu:?}"
    );
    type_keys(&mut s, "terminal<ret>");
    // An empty title clears it.
    s.keys(&["i", "<ret>"]);
    wait_for(&mut s, "cleared", |s| s.text().contains("cleared"));
    assert!(
        !status_row(&mut s).contains("htop"),
        "{}",
        status_row(&mut s)
    );
}

#[test]
fn the_last_title_stays_after_the_program_exits() {
    let (mut s, root, _) = project("follow-title-exit", "");
    let script = root.join("title.sh");
    std::fs::write(
        &script,
        "printf '\\033]2;building\\007'; echo ready; exit 3\n",
    )
    .unwrap();
    run(&mut s, &script);
    wait_for(&mut s, "the exit", |s| {
        s.text().contains("[process exited 3]")
    });
    assert!(
        status_row(&mut s).contains("  building"),
        "{}",
        status_row(&mut s)
    );
}
