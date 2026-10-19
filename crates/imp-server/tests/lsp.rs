//! The LSP client (runtime/lsp.scm) against a scripted server,
//! tests/fake_lsp.py. Skipped when python3 isn't installed.

mod common;

use common::*;
use std::path::PathBuf;
use std::time::Duration;

fn have_python() -> bool {
    std::process::Command::new("python3")
        .arg("--version")
        .output()
        .is_ok()
}

/// Pumps events until `expr` is true, or fails after a few seconds.
fn wait_for(s: &mut imp_server::Server, expr: &str) {
    for _ in 0..100 {
        if s.eval(expr).unwrap() == "#true" {
            return;
        }
        s.pump(Duration::from_millis(30));
    }
    panic!("timed out waiting for {expr}; status: {}", s.status());
}

/// Lets timers and replies arrive.
fn settle(s: &mut imp_server::Server) {
    s.pump(Duration::from_millis(400));
}

/// A server with `text` in a fresh `name` (a .rs file, so rust-mode),
/// attached to the fake language server. The log file records every
/// message the server got.
fn attached(name: &str, text: &str) -> (imp_server::Server, PathBuf, PathBuf) {
    attached_with(name, text, "")
}

/// `attached`, with `env` (NAME=value ...) set for the fake server.
fn attached_with(name: &str, text: &str, env: &str) -> (imp_server::Server, PathBuf, PathBuf) {
    let path = temp_path(name);
    std::fs::write(&path, text).unwrap();
    let log = temp_path(&format!("{name}.log"));
    let _ = std::fs::remove_file(&log);
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_lsp.py");
    let mut s = server("");
    s.eval("(set-option! 'lsp #t)").unwrap();
    s.eval(&format!(
        r#"(define-language-server! 'rust-mode
             '("imp-no-such-server --stdio" "env FAKE_LSP_LOG={} {env} python3 {fake}") '() "rust")"#,
        log.display()
    ))
    .unwrap();
    s.eval(&format!("(open-file! {:?})", path.display().to_string()))
        .unwrap();
    wait_for(&mut s, "(and (lsp-key) (lsp-get (lsp-key) 'ready) #t)");
    (s, path, log)
}

fn text(s: &mut imp_server::Server) -> String {
    s.text()
}

#[test]
fn diagnostics_are_shown_and_follow_edits() {
    if !have_python() {
        return;
    }
    let (mut s, _, _) = attached("diag.rs", "let bad = 1;\nfine\n");
    wait_for(&mut s, "(= (length (buffer-diagnostics)) 1)");
    // A sign in the gutter, and the message on the status line.
    let rows = s.frame().text_rows();
    assert!(rows[0].starts_with("E let bad"), "{:?}", rows[0]);
    assert!(rows[1].starts_with("  fine"), "{:?}", rows[1]);
    type_keys(&mut s, "0");
    assert_eq!(s.status(), "E: bad word (fake)");
    type_keys(&mut s, "j");
    assert_eq!(s.status(), "");

    // Typing another one is sent to the server after a pause.
    type_keys(&mut s, "obad<esc>");
    wait_for(&mut s, "(= (length (buffer-diagnostics)) 2)");
    // ]d and [d go between them, wrapping.
    type_keys(&mut s, "gg]d");
    assert_eq!(s.cursor(), 4);
    type_keys(&mut s, "]d");
    assert_eq!(s.eval("(current-line)").unwrap(), "2");
    type_keys(&mut s, "]d");
    assert_eq!(s.cursor(), 4);
    type_keys(&mut s, "[d");
    assert_eq!(s.eval("(current-line)").unwrap(), "2");
}

#[test]
fn diagnostics_are_pulled_from_a_server_that_does_not_push() {
    if !have_python() {
        return;
    }
    let (mut s, _, _) = attached_with("pull.rs", "let bad = 1;\nmeh\n", "FAKE_LSP_PULL=1");
    wait_for(&mut s, "(= (length (buffer-diagnostics)) 1)");
    type_keys(&mut s, "0");
    assert_eq!(s.status(), "E: bad word (fake)");
    // Asked again after a change; the status line follows without a key.
    type_keys(&mut s, "obad<esc>");
    wait_for(&mut s, "(= (length (buffer-diagnostics)) 2)");
    assert_eq!(s.status(), "E: bad word (fake)");
    type_keys(&mut s, "0cwgood<esc>");
    wait_for(&mut s, "(= (length (buffer-diagnostics)) 1)");
    assert_eq!(s.status(), "");
    type_keys(&mut s, "obad<esc>");
    wait_for(&mut s, "(= (length (buffer-diagnostics)) 2)");
    // After a save the server also flags "meh" and asks imp to pull again.
    type_keys(&mut s, ":w<ret>");
    wait_for(&mut s, "(= (length (buffer-diagnostics)) 3)");
    type_keys(&mut s, "G");
    assert_eq!(s.eval("(current-line)").unwrap(), "3");
    assert_eq!(s.status(), "E: meh word (fake)");
}

#[test]
fn hover_definition_and_references() {
    if !have_python() {
        return;
    }
    let (mut s, _, _) = attached("nav.rs", "foo here\nbar foo\nfoo end\n");
    type_keys(&mut s, "jw");
    type_keys(&mut s, "K");
    settle(&mut s);
    let rows = s.frame().text_rows().join("\n");
    assert!(rows.contains("fn foo()"), "{rows}");
    assert!(rows.contains("The foo function."), "{rows}");

    type_keys(&mut s, "<esc>gd");
    settle(&mut s);
    assert_eq!(s.cursor(), 0);
    // The jump can be undone with C-o.
    type_keys(&mut s, "<C-o>");
    assert_eq!(s.cursor(), 13);

    // References: three, picked from a menu. Its entries hold whole paths,
    // cut at the screen's edge, and $TMPDIR can be long (on CI).
    s.set_size(200, 24);
    type_keys(&mut s, "gr");
    settle(&mut s);
    let rows = s.frame().text_rows().join("\n");
    assert!(rows.contains("nav.rs:3: foo end"), "{rows}");
    type_keys(&mut s, "foo end<ret>");
    assert_eq!(s.eval("(current-line)").unwrap(), "2");
}

#[test]
fn rename_and_format_change_the_buffer() {
    if !have_python() {
        return;
    }
    let (mut s, _, _) = attached("rename.rs", "foo  \nbar foo \n");
    type_keys(&mut s, " cr");
    assert!(s.frame().text_rows().join("\n").contains("Rename to: foo"));
    type_keys(&mut s, "<bs><bs><bs>baz<ret>");
    settle(&mut s);
    assert_eq!(text(&mut s), "baz  \nbar baz \n");
    // One undo step takes it all back.
    type_keys(&mut s, "u");
    assert_eq!(text(&mut s), "foo  \nbar foo \n");
    type_keys(&mut s, "<C-r>");

    type_keys(&mut s, " cf");
    settle(&mut s);
    assert_eq!(text(&mut s), "baz\nbar baz\n");
}

#[test]
fn code_actions_apply_edits_and_run_commands() {
    if !have_python() {
        return;
    }
    let (mut s, _, _) = attached("action.rs", "let bad = 1;\n");
    type_keys(&mut s, " ca");
    settle(&mut s);
    let rows = s.frame().text_rows().join("\n");
    assert!(rows.contains("Replace bad with good"), "{rows}");
    type_keys(&mut s, "<ret>");
    assert_eq!(text(&mut s), "let good = 1;\n");

    // A command: the server answers with workspace/applyEdit.
    type_keys(&mut s, " ca");
    settle(&mut s);
    type_keys(&mut s, "Insert hi<ret>");
    settle(&mut s);
    assert_eq!(text(&mut s), "hi\nlet good = 1;\n");
}

#[test]
fn completion_from_the_server() {
    if !have_python() {
        return;
    }
    let (mut s, _, _) = attached("complete.rs", "\n");
    s.eval("(set-option! 'lsp-auto-complete #f)").unwrap();
    type_keys(&mut s, "ial<C-x><C-o>");
    settle(&mut s);
    let rows = s.frame().text_rows().join("\n");
    assert!(rows.contains("alpha"), "{rows}");
    assert!(rows.contains("alphabet"), "{rows}");
    assert!(!rows.contains("beta"), "{rows}");
    // Typing narrows it; C-n moves; <ret> accepts.
    type_keys(&mut s, "ph<C-n><ret>");
    assert_eq!(text(&mut s), "alphabet\n");
    assert_eq!(s.eval("*menu-open*").unwrap(), "#false");
    // Snippets lose their placeholders.
    type_keys(&mut s, " sn<C-x><C-o>");
    settle(&mut s);
    type_keys(&mut s, "<C-y><esc>");
    assert_eq!(text(&mut s), "alphabet snip(x, )\n");
}

#[test]
fn completion_opens_by_itself_while_typing() {
    if !have_python() {
        return;
    }
    let (mut s, _, _) = attached("auto.rs", "\n");
    type_keys(&mut s, "ibe");
    settle(&mut s);
    assert_eq!(s.eval("*menu-open*").unwrap(), "#true");
    // Nothing is selected in a menu that opened by itself, so <ret> is
    // just a new line.
    type_keys(&mut s, "<ret>");
    assert_eq!(text(&mut s), "be\n\n");
    type_keys(&mut s, "be");
    settle(&mut s);
    type_keys(&mut s, "<tab><ret><esc>");
    assert_eq!(text(&mut s), "be\nbeta\n");
}

#[test]
fn buffer_words_complete_without_a_server() {
    let mut s = server("hello help\nhe\n");
    type_keys(&mut s, "jA<C-n>");
    let rows = s.frame().text_rows().join("\n");
    assert!(rows.contains("hello"), "{rows}");
    assert!(rows.contains("help"), "{rows}");
    // The best match comes first ("help", shorter); C-n moves on.
    type_keys(&mut s, "<C-n><C-y><esc>");
    assert_eq!(s.text(), "hello help\nhello\n");
}

#[test]
fn closing_a_buffer_tells_the_server() {
    if !have_python() {
        return;
    }
    let (mut s, path, log) = attached("close.rs", "x\n");
    s.eval("(open-file! (string-append (current-dir) \"/Cargo.toml\"))")
        .unwrap();
    type_keys(
        &mut s,
        &format!(":bd {}<ret>", path.file_name().unwrap().to_str().unwrap()),
    );
    settle(&mut s);
    let log = std::fs::read_to_string(log).unwrap();
    assert!(log.contains("textDocument/didOpen"));
    assert!(log.contains("textDocument/didClose"));
}

#[test]
fn utf16_positions_count_astral_chars_twice() {
    let mut s = server("a😀b\n");
    assert_eq!(s.eval("(lsp-character 0 2 \"utf-16\")").unwrap(), "3");
    assert_eq!(s.eval("(lsp-character 0 2 \"utf-32\")").unwrap(), "2");
    assert_eq!(
        s.eval("(lsp-offset (hash \"line\" 0 \"character\" 3) \"utf-16\")")
            .unwrap(),
        "2"
    );
}
