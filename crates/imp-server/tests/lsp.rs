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

/// The server has sent one diagnostic for the buffer, shown or not.
const ARRIVED_ONE: &str = "(= (length (or (hash-try-get *lsp-diagnostics* (lsp-uri)) '())) 1)";

/// Diagnostics move with the text until the server sends new ones: while
/// typing (new ones held back), and for held ones that arrive before more
/// typing.
#[test]
fn diagnostics_move_with_edits_before_the_server_answers() {
    if !have_python() {
        return;
    }
    let (mut s, _, _) = attached("follow.rs", "let bad = 1;\nfine\n");
    wait_for(&mut s, "(= (length (buffer-diagnostics)) 1)");
    // The server won't answer the edits below.
    s.eval("(set-option! 'lsp-change-delay 100000)").unwrap();
    type_keys(&mut s, "ggOnew");
    let rows = s.frame().text_rows();
    assert!(rows[0].starts_with("  new"), "{rows:?}");
    assert!(rows[1].starts_with("E let bad"), "{rows:?}");
    assert_eq!(s.eval("(car (car (buffer-diagnostics)))").unwrap(), "8");
    type_keys(&mut s, "<esc>");

    // One that arrives while typing lands where its text has gone since.
    let (mut s, _, _) = attached("follow-held.rs", "fine\n");
    settle(&mut s);
    type_keys(&mut s, "Obad");
    wait_for(&mut s, ARRIVED_ONE);
    s.eval("(set-option! 'lsp-change-delay 100000)").unwrap();
    type_keys(&mut s, "<left><left><left>xx<esc>");
    assert_eq!(s.text(), "xxbad\nfine\n");
    assert_eq!(
        s.eval("(car (buffer-diagnostics))")
            .unwrap()
            .split(' ')
            .take(2)
            .collect::<Vec<_>>(),
        ["(2", "5"]
    );
}

#[test]
fn diagnostics_wait_for_insert_to_end() {
    if !have_python() {
        return;
    }
    let (mut s, _, _) = attached("hold.rs", "fine\n");
    settle(&mut s);
    // They arrive while typing but don't show: no sign comes and goes.
    type_keys(&mut s, "obad");
    wait_for(&mut s, ARRIVED_ONE);
    s.pump(Duration::from_millis(100));
    assert!(
        s.frame().text_rows()[1].starts_with("bad"),
        "{:?}",
        s.frame().text_rows()
    );
    type_keys(&mut s, "<esc>");
    assert!(
        s.frame().text_rows()[1].starts_with("E bad"),
        "{:?}",
        s.frame().text_rows()
    );
    // With lsp-diagnostics-in-insert they show at once.
    s.eval("(set-option! 'lsp-diagnostics-in-insert #t)")
        .unwrap();
    type_keys(&mut s, "obad");
    wait_for(&mut s, "(= (length (buffer-diagnostics)) 2)");
    s.pump(Duration::from_millis(100));
    assert!(
        s.frame().text_rows()[2].starts_with("E bad"),
        "{:?}",
        s.frame().text_rows()
    );
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
    // Snippets expand: the placeholder is selected, <tab> moves on.
    type_keys(&mut s, " sn<C-x><C-o>");
    settle(&mut s);
    type_keys(&mut s, "<C-y>y<tab>z<tab>!<esc>");
    assert_eq!(text(&mut s), "alphabet snip(y, z)!\n");
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
fn a_trigger_character_is_named_in_the_request() {
    if !have_python() {
        return;
    }
    let (mut s, _, log) = attached("trigger.rs", "\n");
    let contexts = |log: &PathBuf| -> Vec<String> {
        std::fs::read_to_string(log)
            .unwrap()
            .lines()
            .filter(|l| l.contains("textDocument/completion"))
            .map(|l| {
                let at = l.find("\"context\"").unwrap();
                l[at..l[at..].find('}').unwrap() + at + 1].to_string()
            })
            .collect()
    };
    // Typed: the fake server's trigger character is ".", so a server
    // like TypeScript's can answer nothing where it means nothing.
    type_keys(&mut s, "ix.");
    settle(&mut s);
    let last = contexts(&log).pop().unwrap();
    assert!(last.contains(r#""triggerKind": 2"#), "{last}");
    assert!(last.contains(r#""triggerCharacter": ".""#), "{last}");
    // After a word character, or asked by a key, it was invoked.
    type_keys(&mut s, "<esc>obe");
    settle(&mut s);
    assert_eq!(
        contexts(&log).last().unwrap(),
        r#""context": {"triggerKind": 1}"#
    );
    type_keys(&mut s, "<esc>o.<C-x><C-o>");
    settle(&mut s);
    assert_eq!(
        contexts(&log).last().unwrap(),
        r#""context": {"triggerKind": 1}"#
    );
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
fn renaming_the_file_reopens_it_under_the_new_name() {
    if !have_python() {
        return;
    }
    let (mut s, path, log) = attached("rename-old.rs", "x\n");
    let new = temp_path("rename-new.rs");
    let _ = std::fs::remove_file(&new);
    s.keys(&["M-x"]);
    type_keys(&mut s, "rename-file<ret><ret>");
    type_keys(&mut s, &format!("<C-u>{}<ret>", new.display()));
    settle(&mut s);
    let log = std::fs::read_to_string(log).unwrap();
    let close = log.find("textDocument/didClose").expect(&log);
    // The new name opens after the old one closes.
    assert!(log[close..].contains("rename-new.rs"), "{log}");
    assert!(!path.exists());
    assert_eq!(
        s.eval("(and (memq 'lsp-mode (minor-modes)) #t)").unwrap(),
        "#true"
    );
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

#[test]
fn request_now_returns_the_request_id() {
    if !have_python() {
        return;
    }
    let (mut s, _, _) = attached("now.rs", "x\n");
    let id = s
        .eval("(lsp-request-now! (lsp-key) \"fake/nothing\" (hash) (lambda (r) #f))")
        .unwrap();
    assert!(id.parse::<i64>().is_ok(), "{id}");
    assert_eq!(
        s.eval(&format!(
            "(and (hash-try-get (lsp-get (lsp-key) 'pending) {id}) #t)"
        ))
        .unwrap(),
        "#true"
    );
}

#[test]
fn a_server_that_exits_leaves_its_buffers_detached_until_restarted() {
    if !have_python() {
        return;
    }
    let (mut s, _, _) = attached("exit.rs", "let bad = 1;\n");
    wait_for(&mut s, "(= (length (buffer-diagnostics)) 1)");
    // The server goes away (here asked to; a crash looks the same).
    s.eval("(lsp-stop! (lsp-key))").unwrap();
    wait_for(&mut s, "(not (lsp-state (buffer-local 'lsp-server)))");
    // Not restarted by itself (a crashing server would only crash again),
    // but the buffer no longer acts as if it had one, and says how.
    assert_eq!(
        s.eval("(and (memq 'lsp-mode (minor-modes)) #t)").unwrap(),
        "#false"
    );
    assert_eq!(s.eval("(length (buffer-diagnostics))").unwrap(), "0");
    assert!(s.status().contains(":lsp-restart"), "{}", s.status());
    type_keys(&mut s, "obad<esc>");
    settle(&mut s);
    assert_eq!(s.eval("(lsp-key)").unwrap(), "#false");
    // :lsp-restart starts it again.
    type_keys(&mut s, ":lsp-restart<ret>");
    wait_for(&mut s, "(and (lsp-key) (lsp-get (lsp-key) 'ready) #t)");
    assert_eq!(
        s.eval("(and (memq 'lsp-mode (minor-modes)) #t)").unwrap(),
        "#true"
    );
    wait_for(&mut s, "(= (length (buffer-diagnostics)) 2)");
}

#[test]
fn restarting_keeps_the_new_server_when_the_old_one_exits() {
    if !have_python() {
        return;
    }
    let (mut s, _, _) = attached("restart.rs", "x\n");
    type_keys(&mut s, ":lsp-restart<ret>");
    wait_for(&mut s, "(and (lsp-key) (lsp-get (lsp-key) 'ready) #t)");
    // The old server's exit (within a second) must not forget the new one.
    s.pump(Duration::from_millis(1500));
    assert_eq!(
        s.eval("(and (lsp-key) (lsp-get (lsp-key) 'ready) #t)")
            .unwrap(),
        "#true"
    );
    assert_eq!(
        s.eval("(and (memq 'lsp-mode (minor-modes)) #t)").unwrap(),
        "#true"
    );
}

/// The fake server's copy of the current buffer, once it has the latest
/// changes.
fn server_text(s: &mut imp_server::Server) -> String {
    s.eval(
        r#"(begin (lsp-sync!)
                  (set! *fake-text* #f)
                  (lsp-request! (lsp-key) "fake/text" (hash "uri" (lsp-uri))
                                (lambda (r) (set! *fake-text* r))))"#,
    )
    .unwrap();
    wait_for(s, "(string? *fake-text*)");
    s.eval("*fake-text*").unwrap()
}

#[test]
fn changes_are_sent_as_ranges() {
    if !have_python() {
        return;
    }
    let (mut s, _, log) = attached("ranges.rs", "let a = 1;\nfine\n");
    s.eval("(define *fake-text* #f)").unwrap();
    type_keys(&mut s, "ggOnew line<esc>jddAé!<esc>");
    assert_eq!(server_text(&mut s), format!("{:?}", s.text()));
    assert!(std::fs::read_to_string(&log)
        .unwrap()
        .contains(r#""contentChanges": [{"range""#));
    // After an undo the whole text goes.
    type_keys(&mut s, "u");
    type_keys(&mut s, "ggix<esc>");
    assert_eq!(server_text(&mut s), format!("{:?}", s.text()));
}

#[test]
fn whole_text_for_a_server_that_wants_it() {
    if !have_python() {
        return;
    }
    let (mut s, _, log) = attached_with("whole.rs", "let a = 1;\n", "FAKE_LSP_FULL=1");
    s.eval("(define *fake-text* #f)").unwrap();
    type_keys(&mut s, "Ax<esc>");
    assert_eq!(server_text(&mut s), format!("{:?}", s.text()));
    let sent = std::fs::read_to_string(&log).unwrap();
    assert!(sent.contains(r#""contentChanges": [{"text""#));
    assert!(!sent.contains(r#""contentChanges": [{"range""#));
}
