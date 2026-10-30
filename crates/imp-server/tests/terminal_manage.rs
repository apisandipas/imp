//! Managing terminals (runtime/term.scm, docs/specs/terminals.md):
//! killing or quitting with a program running asks first.

mod common;

use common::*;
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

/// A file open, and a terminal running `command` in normal state.
fn with_terminal(command: &str) -> (imp_server::Server, String, String) {
    let mut s = server("");
    s.set_size(120, 30);
    let file = temp_path("manage.txt");
    std::fs::write(&file, "text\n").unwrap();
    type_keys(&mut s, &format!(":e {}<ret>", file.display()));
    let file = s.eval("(current-buffer)").unwrap();
    s.eval(&format!("(terminal! {command:?})")).unwrap();
    let term = s.eval("(current-buffer)").unwrap();
    s.keys(&["C-\\", "C-n"]);
    (s, file, term)
}

fn alive(s: &mut imp_server::Server, buf: &str) -> bool {
    s.eval(&format!("(and (memv {buf} (buffer-list)) #t)"))
        .unwrap()
        == "#true"
}

#[test]
fn bd_refuses_a_running_terminal_and_bd_bang_kills_it() {
    let (mut s, _, term) = with_terminal("cat");
    type_keys(&mut s, ":bd<ret>");
    assert_eq!(s.status(), "a program is running in it (add ! to kill it)");
    assert!(alive(&mut s, &term));
    type_keys(&mut s, ":bd!<ret>");
    assert!(!alive(&mut s, &term));
}

#[test]
fn kill_buffer_asks_first() {
    let (mut s, _, term) = with_terminal("cat");
    let name = s.eval("(buffer-name-of (current-buffer))").unwrap();
    let name = name.trim_matches('"').to_string();
    type_keys(&mut s, " bk");
    assert_eq!(
        s.status(),
        format!("kill the program running in {name}? (y or n)")
    );
    type_keys(&mut s, "n");
    assert!(alive(&mut s, &term));
    type_keys(&mut s, " bk");
    type_keys(&mut s, "y");
    assert!(!alive(&mut s, &term));
}

#[test]
fn an_exited_terminal_goes_without_asking() {
    let (mut s, _, term) = with_terminal("true");
    wait_for(&mut s, "the exit", |s| {
        s.text().contains("[process exited 0]")
    });
    type_keys(&mut s, " bk");
    assert!(!alive(&mut s, &term), "{}", s.status());
}

#[test]
fn quitting_refuses_while_a_program_runs() {
    let (mut s, file, term) = with_terminal("cat");
    s.eval(&format!("(go-to-buffer! {file})")).unwrap();
    for quit in [":qa<ret>", ":q<ret>", ":x<ret>"] {
        type_keys(&mut s, quit);
        assert!(!s.should_quit(), "{quit}");
        assert!(
            s.status().starts_with("a program is running in *terminal"),
            "{}",
            s.status()
        );
        // It goes to the terminal, as for unsaved changes.
        assert_eq!(s.eval("(current-buffer)").unwrap(), term);
        s.keys(&["C-\\", "C-n"]);
    }
    type_keys(&mut s, ":qa!<ret>");
    assert!(s.should_quit());
}

#[test]
fn terminal_confirm_kill_off_doesnt_ask() {
    let (mut s, _, term) = with_terminal("cat");
    // Off for this terminal only.
    s.eval("(set-local-option! 'terminal-confirm-kill #f)")
        .unwrap();
    s.eval("(terminal! \"cat\")").unwrap();
    s.keys(&["C-\\", "C-n"]);
    let second = s.eval("(current-buffer)").unwrap();
    type_keys(&mut s, ":bd<ret>");
    assert!(alive(&mut s, &second), "the second still asks");
    s.eval(&format!("(go-to-buffer! {term})")).unwrap();
    s.keys(&["C-\\", "C-n"]);
    type_keys(&mut s, ":bd<ret>");
    assert!(!alive(&mut s, &term));
    // Off everywhere.
    s.eval("(set-option! 'terminal-confirm-kill #f)").unwrap();
    type_keys(&mut s, ":qa<ret>");
    assert!(s.should_quit());
}

#[test]
fn in_a_daemon_q_detaches_and_kill_server_asks() {
    let (mut s, file, _) = with_terminal("cat");
    s.eval(&format!("(go-to-buffer! {file})")).unwrap();
    s.eval("(set! daemon? (lambda () #t))").unwrap();
    type_keys(&mut s, ":q<ret>");
    assert!(s.should_quit(), "{}", s.status());
    s.clear_quit();
    s.keys(&["M-x"]);
    type_keys(&mut s, "kill-server<ret>");
    assert_eq!(
        s.status(),
        "stop the programs running in 1 terminal? (y or n)"
    );
    assert!(!s.should_quit());
    type_keys(&mut s, "y");
    assert!(s.should_quit() && s.kill_requested());
}

fn rows(s: &mut imp_server::Server) -> Vec<String> {
    s.frame()
        .text_rows()
        .into_iter()
        .map(|r| r.trim().to_string())
        .collect()
}

#[test]
fn space_o_l_picks_a_terminal() {
    let (mut s, file, first) = with_terminal("cat");
    s.eval("(terminal! \"true\")").unwrap();
    wait_for(&mut s, "the exit", |s| {
        s.text().contains("[process exited 0]")
    });
    let dir = s
        .eval("(abbreviate-path (buffer-local 'term-dir))")
        .unwrap();
    let dir = dir.trim_matches('"').to_string();
    s.eval(&format!("(go-to-buffer! {file})")).unwrap();
    s.keys(&["<esc>"]);
    type_keys(&mut s, " ol");
    let menu = rows(&mut s);
    // Each with its command and directory; the one that exited says so.
    let cat = menu.iter().find(|r| r.starts_with("*terminal 1: cat*"));
    assert!(
        cat.is_some_and(|r| r.contains("cat") && r.contains(&dir) && !r.contains("exited")),
        "{menu:?}"
    );
    let done = menu.iter().find(|r| r.starts_with("*terminal 2: true*"));
    assert!(done.is_some_and(|r| r.ends_with("exited")), "{menu:?}");
    // The file isn't listed.
    assert!(!menu.iter().any(|r| r.contains("manage.txt")), "{menu:?}");
    type_keys(&mut s, "cat<ret>");
    assert_eq!(s.eval("(current-buffer)").unwrap(), first);
    assert!(status_row(&mut s).contains("TERMINAL"));
}

#[test]
fn a_toggled_terminal_is_picked_into_its_window() {
    let (mut s, file, _) = with_terminal("cat");
    s.eval(r#"(define-toggled-terminal! 'toggle-terminal "cat" "*terminal")"#)
        .unwrap();
    s.eval(&format!("(go-to-buffer! {file})")).unwrap();
    s.keys(&["M-`"]);
    let toggled = s.eval("(current-buffer)").unwrap();
    s.keys(&["M-`"]);
    assert_eq!(s.eval("(length (window-list))").unwrap(), "1");
    type_keys(&mut s, " ol");
    type_keys(&mut s, "*terminal:<ret>");
    assert_eq!(s.eval("(current-buffer)").unwrap(), toggled);
    assert_eq!(s.eval("(length (window-list))").unwrap(), "2");
}
