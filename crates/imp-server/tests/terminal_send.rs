//! Sending text to the project's terminal (runtime/term.scm,
//! docs/specs/terminals.md). A script stands in for the shell: it prints a
//! prompt, maybe turning on bracketed paste as shells do, and echoes what
//! it gets with escapes and returns made visible.

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

/// The stand-in: after `delay` seconds, a prompt, with bracketed paste
/// turned on if `bracketed`; then what it gets, made visible.
fn shell(delay: &str, bracketed: bool) -> String {
    let on = if bracketed { "\\\\033[?2004h" } else { "" };
    format!("sleep {delay}; stty -echo -icanon -icrnl; printf '{on}$ '; cat -v")
}

/// A project with a file in it, open, its terminal the stand-in.
fn project(name: &str, shell: &str) -> imp_server::Server {
    let root = temp_path(name);
    std::fs::create_dir_all(root.join(".git")).unwrap();
    std::fs::write(root.join("a.sh"), "echo one\necho two\necho three\n").unwrap();
    let mut s = server("");
    s.set_size(200, 30);
    s.eval(&format!(
        r#"(define-toggled-terminal! 'toggle-terminal "{shell}" "*terminal")"#
    ))
    .unwrap();
    type_keys(&mut s, &format!(":e {}<ret>", root.join("a.sh").display()));
    s
}

/// The project's terminal's text, read from its buffer and back.
fn terminal(s: &mut imp_server::Server) -> String {
    let here = s.eval("(current-buffer)").unwrap();
    let buf = s
        .eval("(toggled-terminal-buffer 'toggle-terminal (toggled-terminal-root))")
        .unwrap();
    if buf == "#false" {
        return String::new();
    }
    s.eval(&format!("(switch-to-buffer! {buf})")).unwrap();
    let text = s.text();
    s.eval(&format!("(switch-to-buffer! {here})")).unwrap();
    text
}

fn windows(s: &mut imp_server::Server) -> usize {
    s.eval("(length (window-list))").unwrap().parse().unwrap()
}

#[test]
fn space_o_s_sends_the_line_and_moves_down() {
    let mut s = project("send-line", &shell("0", true));
    type_keys(&mut s, " os");
    // The terminal came up; you're still in the file, in normal state.
    assert_eq!(windows(&mut s), 2);
    assert!(s.text().starts_with("echo one\n"));
    assert!(status_row(&mut s).contains("NORMAL"));
    assert_eq!(s.eval("(current-line)").unwrap(), "1");
    wait_for(&mut s, "the line", |s| {
        terminal(s).contains("$ ^[[200~echo one^[[201~^M")
    });
    // Again: the next line, into the same terminal.
    type_keys(&mut s, " os");
    assert_eq!(s.eval("(current-line)").unwrap(), "2");
    wait_for(&mut s, "the second line", |s| {
        terminal(s).contains("^[[201~^M^[[200~echo two^[[201~^M")
    });
    assert_eq!(s.eval("(hash-length *terminals*)").unwrap(), "1");
}

#[test]
fn space_o_s_in_visual_sends_the_selection() {
    let mut s = project("send-visual", &shell("0", true));
    type_keys(&mut s, "jVj os");
    assert!(status_row(&mut s).contains("NORMAL"));
    assert_eq!(s.eval("(current-line)").unwrap(), "2");
    // Its line breaks inside the paste, the last one dropped.
    wait_for(&mut s, "the selection", |s| {
        terminal(s).contains("^[[200~echo two\necho three^[[201~^M")
    });
}

#[test]
fn space_o_b_sends_the_buffer() {
    let mut s = project("send-buffer", &shell("0", true));
    type_keys(&mut s, " ob");
    wait_for(&mut s, "the buffer", |s| {
        terminal(s).contains("^[[200~echo one\necho two\necho three^[[201~^M")
    });
}

#[test]
fn without_bracketed_paste_it_is_typed() {
    let mut s = project("send-typed", &shell("0", false));
    type_keys(&mut s, "Vj os");
    wait_for(&mut s, "the typing", |s| {
        terminal(s).contains("$ echo one^Mecho two^M")
    });
    assert!(!terminal(&mut s).contains("200~"));
}

#[test]
fn terminal_send_enter_off_sends_no_return() {
    let mut s = project("send-no-enter", &shell("0", true));
    s.eval("(set-option! 'terminal-send-enter #f)").unwrap();
    type_keys(&mut s, " os");
    wait_for(&mut s, "the line", |s| {
        terminal(s).contains("^[[200~echo one^[[201~")
    });
    s.pump(Duration::from_millis(300));
    assert!(!terminal(&mut s).contains("^M"), "{}", terminal(&mut s));
}

#[test]
fn a_starting_shell_gets_the_text_once_it_has_a_prompt() {
    // Sent at once, the text would arrive before bracketed paste was on.
    let mut s = project("send-starting", &shell("1", true));
    type_keys(&mut s, " os");
    wait_for(&mut s, "the line", |s| {
        terminal(s).contains("$ ^[[200~echo one^[[201~^M")
    });
}

#[test]
fn a_hidden_terminal_is_shown_again_and_its_own_lines_are_not_sent() {
    let mut s = project("send-hidden", &shell("0", true));
    s.keys(&["M-`"]);
    wait_for(&mut s, "the prompt", |s| s.text().contains("$ "));
    s.keys(&["M-`"]);
    assert_eq!(windows(&mut s), 1);
    type_keys(&mut s, " os");
    assert_eq!(windows(&mut s), 2);
    assert!(s.text().starts_with("echo one\n"));
    wait_for(&mut s, "the line", |s| {
        terminal(s).contains("^[[200~echo one^[[201~^M")
    });
    // From the terminal itself, in normal state: nothing is sent.
    s.keys(&["M-`"]);
    s.keys(&["C-\\", "C-n"]);
    type_keys(&mut s, " os");
    assert!(
        s.status().contains("terminal's own window"),
        "{}",
        s.status()
    );
}
