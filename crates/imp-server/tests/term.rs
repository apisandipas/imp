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
    // ANSI red is the theme's red (one-dark).
    assert_eq!(
        red.style.fg,
        Some(imp_core::Color::Rgb(0xe0, 0x6c, 0x75)),
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

/// Terminal ids, oldest first, and window ids top to bottom.
fn term_ids(s: &mut imp_server::Server) -> Vec<String> {
    let ids = s.eval("(sort (hash-keys->list *terminals*) <)").unwrap();
    ids.trim_matches(|c| c == '(' || c == ')')
        .split(' ')
        .map(str::to_string)
        .collect()
}

#[test]
fn every_terminal_fits_the_windows_showing_it() {
    let mut s = server("");
    s.set_size(80, 30);
    type_keys(&mut s, ":terminal cat<ret>");
    s.keys(&["C-\\", "C-n"]);
    type_keys(&mut s, ":split<ret>:terminal cat<ret>");
    s.keys(&["C-\\", "C-n"]);
    let ids = term_ids(&mut s);
    let (first, second) = (&ids[0], &ids[1]);
    let windows = s.eval("(window-list)").unwrap();
    let windows: Vec<&str> = windows
        .trim_matches(|c| c == '(' || c == ')')
        .split(' ')
        .collect();
    let size_of =
        |s: &mut imp_server::Server, w: &str| s.eval(&format!("(window-text-size {w})")).unwrap();
    let shown_in = |s: &mut imp_server::Server, t: &str| {
        s.eval(&format!(
            "(car (filter (lambda (w) (eqv? (if (= w (current-window)) (current-buffer) (window-buffer w)) (hash-ref *terminals* {t}))) (window-list)))"
        ))
        .unwrap()
    };
    // The first terminal, no longer in the current window, was refitted
    // when the split made its window smaller.
    let w1 = shown_in(&mut s, first);
    let w2 = shown_in(&mut s, second);
    assert_ne!(w1, w2);
    assert_eq!(
        s.eval(&format!("(term-size {first})")).unwrap(),
        size_of(&mut s, &w1)
    );
    assert_eq!(
        s.eval(&format!("(term-size {second})")).unwrap(),
        size_of(&mut s, &w2)
    );
    // Making one window taller resizes its terminal.
    s.keys(&["C-w", "+"]);
    s.keys(&["C-w", "+"]);
    assert_eq!(
        s.eval(&format!("(term-size {second})")).unwrap(),
        size_of(&mut s, &w2)
    );
    assert_eq!(
        s.eval(&format!("(term-size {first})")).unwrap(),
        size_of(&mut s, &w1)
    );
    // Shown in both windows, a terminal takes the smaller one.
    s.eval(&format!("(go-to-buffer! (hash-ref *terminals* {first}))"))
        .unwrap();
    type_keys(&mut s, "<esc>");
    let smaller = windows
        .iter()
        .map(|w| size_of(&mut s, w))
        .min_by_key(|r| {
            r.trim_matches(|c| c == '(' || c == ')')
                .split(' ')
                .next()
                .unwrap()
                .parse::<u32>()
                .unwrap()
        })
        .unwrap();
    assert_eq!(s.eval(&format!("(term-size {first})")).unwrap(), smaller);
}

fn mouse(s: &mut imp_server::Server, action: &str, button: &str, x: u16, y: u16) {
    s.handle(imp_core::protocol::ClientMsg::Mouse {
        action: action.into(),
        button: button.into(),
        x,
        y,
        fine: None,
    });
}

fn have_python() -> bool {
    std::process::Command::new("python3")
        .arg("--version")
        .output()
        .is_ok()
}

/// A program that turns on mouse reporting with `modes` (escape sequence
/// numbers, such as 1000 and 1006) and prints each read as Python bytes.
fn mouse_program(modes: &[u32]) -> String {
    let on: String = modes.iter().map(|m| format!("\\\\x1b[?{m}h")).collect();
    format!(
        ":terminal python3 -c \"import os,tty; tty.setraw(0); os.write(1, b'{on}ready\\\\r\\\\n'); [os.write(1, (repr(os.read(0, 64)) + '\\\\r\\\\n').encode()) for _ in range(9)]\"<ret>"
    )
}

#[test]
fn the_mouse_goes_to_programs_that_ask_for_it() {
    if !have_python() {
        return;
    }
    let mut s = server("");
    type_keys(&mut s, &mouse_program(&[1002, 1006]));
    wait_for(&mut s, "the program", |s| s.text().contains("ready"));
    assert_eq!(
        s.eval("(term-mouse-mode (term-id))").unwrap(),
        r#"("button-motion" "sgr")"#
    );
    // Cell (4, 0) is column 5, row 1 of the program's screen.
    mouse(&mut s, "press", "left", 4, 0);
    wait_for(&mut s, "the press", |s| s.text().contains(r"\x1b[<0;5;1M"));
    mouse(&mut s, "drag", "left", 6, 1);
    wait_for(&mut s, "the drag", |s| s.text().contains(r"\x1b[<32;7;2M"));
    mouse(&mut s, "release", "left", 6, 1);
    wait_for(&mut s, "the release", |s| {
        s.text().contains(r"\x1b[<0;7;2m")
    });
    mouse(&mut s, "scroll-down", "", 0, 2);
    wait_for(&mut s, "the wheel", |s| s.text().contains(r"\x1b[<65;1;3M"));
    // In normal state the mouse is the editor's again.
    s.keys(&["C-\\", "C-n"]);
    let before = s.text();
    mouse(&mut s, "press", "left", 0, 0);
    s.pump(Duration::from_millis(100));
    assert_eq!(s.text(), before);
}

#[test]
fn classic_mouse_encoding_and_press_only() {
    if !have_python() {
        return;
    }
    let mut s = server("");
    type_keys(&mut s, &mouse_program(&[9]));
    wait_for(&mut s, "the program", |s| s.text().contains("ready"));
    // X10 mode: presses only, as ESC [ M and three chars.
    mouse(&mut s, "release", "left", 4, 0);
    mouse(&mut s, "press", "right", 4, 0);
    wait_for(&mut s, "the press", |s| s.text().contains(r#"\x1b[M"%!"#));
    assert!(!s.text().contains(r"\x1b[M#"), "{}", s.text());
}
