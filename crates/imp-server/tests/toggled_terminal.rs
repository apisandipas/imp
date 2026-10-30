//! The project's terminal and toggled terminals (runtime/term.scm,
//! docs/specs/terminals.md): one program per project in a window down the
//! right, hidden again from inside while it keeps running.

mod common;

use common::*;
use std::time::{Duration, Instant};

/// Handles events until `done` holds, or fails after a few seconds.
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

/// A project named `name` with a file in it, open. The project's terminal
/// runs a stand-in that says where it started and echoes what it gets,
/// rather than your shell.
fn project(name: &str) -> (imp_server::Server, std::path::PathBuf) {
    let root = temp_path(name);
    std::fs::create_dir_all(root.join(".git")).unwrap();
    std::fs::write(root.join("a.txt"), "one\ntwo\n").unwrap();
    let mut s = server("");
    s.set_size(200, 30);
    s.eval(r#"(define-toggled-terminal! 'toggle-terminal "pwd; cat" "*terminal")"#)
        .unwrap();
    type_keys(&mut s, &format!(":e {}<ret>", root.join("a.txt").display()));
    (s, root)
}

fn windows(s: &mut imp_server::Server) -> usize {
    s.eval("(length (window-list))").unwrap().parse().unwrap()
}

fn terminals(s: &mut imp_server::Server) -> usize {
    s.eval("(hash-length *terminals*)")
        .unwrap()
        .parse()
        .unwrap()
}

#[test]
fn space_o_t_toggles_the_projects_terminal_down_the_right() {
    let (mut s, root) = project("toggle-shell");
    type_keys(&mut s, " ot");
    assert_eq!(windows(&mut s), 2);
    assert!(status_row(&mut s).contains("TERMINAL"));
    let name = root.file_name().unwrap().to_str().unwrap();
    assert_eq!(
        s.eval("(buffer-name-of (current-buffer))").unwrap(),
        format!("\"*terminal: {name}*\"")
    );
    // 40% of the width, on the right, started in the project root.
    let width: usize = s.eval("(window-text-width)").unwrap().parse().unwrap();
    assert!((76..=82).contains(&width), "{width}");
    assert_eq!(s.eval("(window-in-direction \"right\")").unwrap(), "#false");
    wait_for(&mut s, "pwd", |s| {
        s.text().contains(&*root.to_string_lossy())
    });
    let buf = s.eval("(current-buffer)").unwrap();
    s.keys(&["x", "<ret>"]);
    wait_for(&mut s, "the echo", |s| s.text().contains("x\nx"));

    // M-` inside hides it, and it keeps running.
    s.keys(&["M-`"]);
    assert_eq!(windows(&mut s), 1);
    assert!(status_row(&mut s).contains("NORMAL"));
    assert!(s.text().starts_with("one\n"));
    assert_eq!(terminals(&mut s), 1);

    // M-` from the file brings back the same one, with what it had.
    s.keys(&["M-`"]);
    assert_eq!(windows(&mut s), 2);
    assert_eq!(s.eval("(current-buffer)").unwrap(), buf);
    assert!(s.text().contains("x\nx"), "{}", s.text());
    // SPC o t from normal state in it hides it too.
    s.keys(&["C-\\", "C-n"]);
    type_keys(&mut s, " ot");
    assert_eq!(windows(&mut s), 1);
    assert_eq!(terminals(&mut s), 1);
}

#[test]
fn each_project_has_its_own_and_outside_one_there_is_one() {
    let (mut s, a) = project("toggle-a");
    let b = temp_path("toggle-b");
    std::fs::create_dir_all(b.join(".git")).unwrap();
    std::fs::write(b.join("b.txt"), "b\n").unwrap();
    s.keys(&["M-`"]);
    let in_a = s.eval("(current-buffer)").unwrap();
    s.keys(&["M-`"]);
    type_keys(&mut s, &format!(":e {}<ret>", b.join("b.txt").display()));
    s.keys(&["M-`"]);
    assert_ne!(s.eval("(current-buffer)").unwrap(), in_a);
    wait_for(&mut s, "pwd in b", |s| {
        s.text().contains(&*b.to_string_lossy())
    });
    s.keys(&["M-`"]);
    // Outside a project: imp's current directory's, one for them all.
    let outside = temp_path("toggle-none");
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(outside.join("c.txt"), "c\n").unwrap();
    type_keys(
        &mut s,
        &format!(":e {}<ret>", outside.join("c.txt").display()),
    );
    s.keys(&["M-`"]);
    let cwd = s.eval("(current-dir)").unwrap();
    assert_eq!(s.eval("(buffer-local 'toggled-root)").unwrap(), cwd);
    assert_eq!(terminals(&mut s), 3);
    let _ = a;
}

#[test]
fn after_the_program_exits_the_toggle_starts_a_new_one() {
    let (mut s, _) = project("toggle-exit");
    s.eval(r#"(define-toggled-terminal! 'toggle-terminal "echo started; exit 0" "*terminal")"#)
        .unwrap();
    s.keys(&["M-`"]);
    wait_for(&mut s, "the exit", |s| {
        s.text().contains("[process exited 0]")
    });
    let first = s.eval("(current-buffer)").unwrap();
    // Leave it, then toggle again: a fresh one, the old buffer gone.
    s.keys(&["C-w", "w"]);
    s.keys(&["M-`"]);
    assert_ne!(s.eval("(current-buffer)").unwrap(), first);
    assert_eq!(
        s.eval(&format!("(and (memv {first} (buffer-list)) #t)"))
            .unwrap(),
        "#false"
    );
}

#[test]
fn space_o_capital_t_is_a_terminal_buffer_here() {
    let (mut s, _) = project("toggle-here");
    type_keys(&mut s, " oT");
    assert_eq!(windows(&mut s), 1);
    assert_eq!(s.eval("(major-mode)").unwrap(), "term-mode");
    assert!(s
        .eval("(buffer-name-of (current-buffer))")
        .unwrap()
        .starts_with("\"*terminal 1"));
}

#[test]
fn a_toggle_of_your_own() {
    let (mut s, root) = project("toggle-own");
    // Its command from an option, and its window where its rule says.
    s.eval(
        r#"(define-option! 'echo-command "pwd; cat" '())
           (define-toggled-terminal! 'echoer 'echo-command "*echoer")
           (define-popup-rule! "*echoer" 'side 'bottom 'size 0.3)"#,
    )
    .unwrap();
    s.keys(&["M-x"]);
    type_keys(&mut s, "echoer<ret>");
    assert_eq!(windows(&mut s), 2);
    assert_eq!(s.eval("(window-in-direction \"down\")").unwrap(), "#false");
    assert!(
        status_row(&mut s).contains("echoer"),
        "{}",
        status_row(&mut s)
    );
    wait_for(&mut s, "pwd", |s| {
        s.text().contains(&*root.to_string_lossy())
    });
    // M-` is the shell's, not this one's: from inside, run it by name.
    s.keys(&["C-\\", "C-n"]);
    s.keys(&["M-x"]);
    type_keys(&mut s, "echoer<ret>");
    assert_eq!(windows(&mut s), 1);
    assert_eq!(terminals(&mut s), 1);
}

#[test]
fn the_projects_terminal_runs_your_shell() {
    // "" is your shell, as :terminal with no command runs; the stand-in in
    // project() replaces it, so check what the runtime defines. (Running
    // your real shell here depends on the machine: CI's printed nothing.)
    let mut s = server("");
    assert_eq!(
        s.eval("(hash-ref *toggles* 'toggle-terminal)").unwrap(),
        "(\"\" \"*terminal\")"
    );
}

#[test]
fn a_count_picks_which_of_the_projects_terminals() {
    let (mut s, root) = project("toggle-count");
    let name = root.file_name().unwrap().to_str().unwrap().to_string();
    let buffer = |s: &mut imp_server::Server| s.eval("(buffer-name-of (current-buffer))").unwrap();
    type_keys(&mut s, " ot");
    let first = s.eval("(current-buffer)").unwrap();
    s.keys(&["M-`"]);
    // 2 SPC o t: the second, started.
    type_keys(&mut s, "2 ot");
    assert_eq!(buffer(&mut s), format!("\"*terminal: {name}<2>*\""));
    assert_eq!(terminals(&mut s), 2);
    // Without a count, the one last shown: the second, for M-` too.
    s.keys(&["M-`"]);
    s.keys(&["M-`"]);
    assert_eq!(buffer(&mut s), format!("\"*terminal: {name}<2>*\""));
    s.keys(&["M-`"]);
    // And sending goes to it.
    type_keys(&mut s, " os");
    wait_for(&mut s, "the line", |s| {
        let here = s.eval("(current-buffer)").unwrap();
        let second = s
            .eval("(toggled-terminal-buffer 'toggle-terminal (toggled-terminal-root) 2)")
            .unwrap();
        s.eval(&format!("(switch-to-buffer! {second})")).unwrap();
        let got = s.text().contains("one\none");
        s.eval(&format!("(switch-to-buffer! {here})")).unwrap();
        got
    });
    // 1 SPC o t: back to the first.
    s.keys(&["<esc>"]);
    type_keys(&mut s, "1 ot");
    assert_eq!(s.eval("(current-buffer)").unwrap(), first);
    assert_eq!(terminals(&mut s), 2);
}
