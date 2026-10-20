//! Completion at point (runtime/complete.scm): the menu and its sources.
//! The language server's source is tested in lsp.rs.

mod common;

use common::*;
use std::time::{Duration, Instant};

fn menu(s: &mut imp_server::Server) -> Vec<String> {
    s.eval("(map car *menu-matches*)")
        .unwrap()
        .trim_matches(|c| c == '(' || c == ')')
        .split_whitespace()
        .map(|w| w.trim_matches('"').to_string())
        .collect()
}

/// A directory with a few files, and a file in it opened in `s`.
fn project(name: &str, file: &str, text: &str) -> (imp_server::Server, std::path::PathBuf) {
    let dir = temp_path(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("src/nested")).unwrap();
    std::fs::write(dir.join("src/main.rs"), "").unwrap();
    std::fs::write(dir.join("src/lib.rs"), "").unwrap();
    std::fs::write(dir.join("src/.hidden"), "").unwrap();
    std::fs::write(dir.join(file), text).unwrap();
    let mut s = server("");
    s.set_size(100, 30);
    type_keys(&mut s, &format!(":e {}<ret>", dir.join(file).display()));
    (s, dir)
}

fn pump_until(s: &mut imp_server::Server, done: impl Fn(&mut imp_server::Server) -> bool) -> bool {
    let start = Instant::now();
    while start.elapsed() < Duration::from_millis(1500) {
        if done(s) {
            return true;
        }
        s.pump(Duration::from_millis(30));
    }
    done(s)
}

#[test]
fn file_names_complete_from_the_buffers_directory() {
    let (mut s, _) = project("complete-files", "notes.txt", "");
    type_keys(&mut s, "isee ./src/");
    s.keys(&["C-x", "C-f"]);
    assert_eq!(menu(&mut s), ["lib.rs", "main.rs", "nested/"]);
    // Dotfiles only when asked for with a dot.
    type_keys(&mut s, "ma<C-y>");
    assert_eq!(s.text(), "see ./src/main.rs");
    // C-n on a path uses the file source too; a directory asks again.
    type_keys(&mut s, " ./src/ne");
    s.keys(&["C-n"]);
    assert_eq!(menu(&mut s), ["nested/"]);
    type_keys(&mut s, "<C-y>");
    assert_eq!(s.text(), "see ./src/main.rs ./src/nested/");
    assert!(s.eval("*menu-open*").unwrap() == "#false" || menu(&mut s).is_empty());
    type_keys(&mut s, " ./src/.");
    s.keys(&["C-x", "C-f"]);
    // (Fuzzy matching lets lib.rs and main.rs in too, after it.)
    assert_eq!(menu(&mut s)[0], ".hidden");
}

#[test]
fn scheme_buffers_complete_imps_names_with_their_docs() {
    let (mut s, _) = project("complete-scheme", "init.scm", "");
    type_keys(&mut s, "i(define-leader-gr");
    s.keys(&["C-n"]);
    assert_eq!(menu(&mut s)[0], "define-leader-group!");
    let detail = s.eval("(cadr (car *menu-matches*))").unwrap();
    assert!(detail.contains("leader"), "{detail}");
    type_keys(&mut s, "<C-y>");
    assert_eq!(s.text(), "(define-leader-group!");
}

#[test]
fn words_come_from_other_buffers_when_asked() {
    let (mut s, dir) = project("complete-words", "a.txt", "");
    std::fs::write(dir.join("b.txt"), "elephantine\n").unwrap();
    type_keys(&mut s, &format!(":e {}<ret>", dir.join("b.txt").display()));
    type_keys(&mut s, &format!(":e {}<ret>", dir.join("a.txt").display()));
    type_keys(&mut s, "iele");
    s.keys(&["C-n"]);
    assert_eq!(menu(&mut s), ["elephantine"]);
}

#[test]
fn completion_opens_as_you_type_in_code_but_not_prose() {
    let (mut s, _) = project("complete-auto", "main.rs", "fn frobnicate() {}\n");
    type_keys(&mut s, "Gofro");
    assert!(
        pump_until(&mut s, |s| menu(s) == ["frobnicate"]),
        "{:?}",
        menu(&mut s)
    );
    type_keys(&mut s, "<C-y><esc>");
    // Typing a comment's // doesn't list the root directory.
    type_keys(&mut s, "o// ");
    assert!(!pump_until(&mut s, |s| s.eval("*menu-open*").unwrap() == "#true"));
    type_keys(&mut s, "<esc>");
    let (mut s, _) = project("complete-prose", "notes.md", "frobnicate\n");
    type_keys(&mut s, "Gofro");
    assert!(!pump_until(&mut s, |s| s.eval("*menu-open*").unwrap() == "#true"));
    // C-n still works there.
    s.keys(&["C-n"]);
    assert_eq!(menu(&mut s), ["frobnicate"]);
}

#[test]
fn a_source_of_your_own() {
    let mut s = server("");
    s.eval(
        r#"(define-completion-source! 'greeting
             (lambda (manual? done)
               (and (equal? (buffer-substring (max 0 (- (cursor) 1)) (cursor)) "@")
                    (begin (done (cursor) (list (completion-candidate "hello" "a greeting"))) #t)))
             'before 'file)"#,
    )
    .unwrap();
    type_keys(&mut s, "i@");
    s.keys(&["C-n"]);
    assert_eq!(menu(&mut s), ["hello"]);
    type_keys(&mut s, "<C-y>");
    assert_eq!(s.text(), "@hello");
}
