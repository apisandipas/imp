//! Terminal buffers (runtime/term.scm, src/term.rs), with real programs on
//! a pseudo-terminal.

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

#[test]
fn runs_a_command_and_reports_its_exit() {
    let mut s = server("");
    type_keys(&mut s, ":terminal printf 'hello\\nworld\\n'; exit 3<ret>");
    assert_eq!(s.eval("(major-mode)").unwrap(), "term-mode");
    wait_for(&mut s, "the exit", |s| {
        s.text().contains("[process exited 3]")
    });
    let text = s.text();
    assert!(text.starts_with("hello\nworld\n"), "{text}");
    assert_eq!(s.eval("(buffer-modified?)").unwrap(), "#false");
    // The buffer stays, in normal state, and can't be typed into.
    assert!(status_row(&mut s).contains("NORMAL"));
    feed(&mut s, "ix<esc>");
    assert_eq!(s.text(), text);
}

#[test]
fn keys_go_to_the_program_until_ctrl_backslash_ctrl_n() {
    let mut s = server("");
    type_keys(&mut s, ":terminal cat<ret>");
    assert!(status_row(&mut s).contains("TERMINAL"));
    // Even keys that mean something to imp, like : and <esc>.
    s.keys(&["a", "b", ":", "<ret>"]);
    wait_for(&mut s, "cat's echo", |s| s.text().starts_with("ab:\nab:\n"));
    // The cursor follows the program's.
    assert_eq!(s.eval("(current-line)").unwrap(), "2");
    s.keys(&["C-\\", "C-n"]);
    assert!(status_row(&mut s).contains("NORMAL"));
    // Normal state: ordinary motions and yanks.
    type_keys(&mut s, "ggyiw");
    assert_eq!(s.eval("(car (register-get #\\\"))").unwrap(), "\"ab\"");
    // i goes back; C-d ends cat.
    type_keys(&mut s, "i");
    assert!(status_row(&mut s).contains("TERMINAL"));
    s.keys(&["C-d"]);
    wait_for(&mut s, "cat to exit", |s| {
        s.text().contains("[process exited 0]")
    });
}

#[test]
fn colors_become_faces() {
    let mut s = server("");
    type_keys(
        &mut s,
        ":terminal printf '\\033[31mred\\033[0m plain\\n'<ret>",
    );
    wait_for(&mut s, "output", |s| s.text().contains("exited"));
    let frame = s.frame();
    let red = frame.rows[0]
        .iter()
        .find(|sp| sp.text.contains("red"))
        .expect("a span with red");
    assert_eq!(
        red.style.fg,
        Some(imp_core::Color::Indexed(1)),
        "{:?}",
        frame.rows[0]
    );
    assert!(frame.rows[0]
        .iter()
        .any(|sp| sp.text.contains("plain") && sp.style.fg.is_none()));
}

#[test]
fn long_output_scrolls_into_the_buffer() {
    let mut s = server("");
    type_keys(&mut s, ":terminal seq 1 500<ret>");
    wait_for(&mut s, "the exit", |s| s.text().contains("exited"));
    let text = s.text();
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines[0], "1");
    assert_eq!(lines[499], "500");
}

#[test]
fn killing_the_buffer_ends_the_program() {
    let mut s = server("");
    type_keys(&mut s, ":terminal sleep 100<ret>");
    s.keys(&["C-\\", "C-n"]);
    type_keys(&mut s, ":bd!<ret>");
    assert_eq!(s.eval("(hash-length *terminals*)").unwrap(), "0");
}
