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
    let (mut s, _) = project(
        "complete-scheme",
        "init.scm",
        "(define-leader-group! \"x\")\n",
    );
    type_keys(&mut s, "Go(define-leader-gr");
    s.keys(&["C-n"]);
    assert_eq!(menu(&mut s)[0], "define-leader-group!");
    // Once, though it's in imp's names and a word in the buffer too.
    assert_eq!(
        menu(&mut s)
            .iter()
            .filter(|w| *w == "define-leader-group!")
            .count(),
        1
    );
    let detail = s.eval("(cadr (car *menu-matches*))").unwrap();
    assert!(detail.contains("leader"), "{detail}");
    type_keys(&mut s, "<C-y>");
    assert_eq!(
        s.text(),
        "(define-leader-group! \"x\")\n(define-leader-group!\n"
    );
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
    // As you type, only the words starting with what's typed stay.
    type_keys(&mut s, "o// frotz fro");
    assert!(
        pump_until(&mut s, |s| menu(s).len() == 2),
        "{:?}",
        menu(&mut s)
    );
    type_keys(&mut s, "b");
    assert_eq!(menu(&mut s), ["frobnicate"]);
    type_keys(&mut s, "<C-e><esc>");
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

#[test]
fn words_nearest_the_cursor_come_first() {
    let mut s = server("alpha_far\n\n\n\nalpha_near\n\n");
    type_keys(&mut s, "5jialp");
    s.keys(&["C-n"]);
    assert_eq!(menu(&mut s), ["alpha_near", "alpha_far"]);
    // Smartcase: an uppercase letter matches case-sensitively.
    let mut s = server("Alpha alpha\n");
    type_keys(&mut s, "oal");
    s.keys(&["C-n"]);
    assert_eq!(menu(&mut s).len(), 2);
    type_keys(&mut s, "<C-e><esc>oAl");
    s.keys(&["C-n"]);
    assert_eq!(menu(&mut s), ["Alpha"]);
}

#[test]
fn sources_in_a_group_merge_by_priority() {
    let mut s = server("hello_word\n");
    s.eval(
        r#"(define-completion-source! 'greeting
             (lambda (manual? done)
               (done (word-start-before (cursor)) (list (completion-candidate "hello_there"))) #t)
             'priority 10)"#,
    )
    .unwrap();
    type_keys(&mut s, "ohel");
    s.keys(&["C-n"]);
    // Equally good matches: the higher priority first.
    assert_eq!(menu(&mut s), ["hello_there", "hello_word"]);
    type_keys(&mut s, "<C-e><esc>");
    // A mode's own groups: greeting alone, words only if it has nothing.
    s.eval("(set-completion-sources! 'fundamental-mode '(greeting words))")
        .unwrap();
    type_keys(&mut s, "ohel");
    s.keys(&["C-n"]);
    assert_eq!(menu(&mut s), ["hello_there"]);
    type_keys(&mut s, "<C-e><esc>");
    s.eval("(set-completion-sources! 'fundamental-mode '((file) words))")
        .unwrap();
    type_keys(&mut s, "ohel");
    s.keys(&["C-n"]);
    assert_eq!(menu(&mut s), ["hello_word"]);
}

#[test]
fn key_presets() {
    let mut s = server("alphabet alpine\n");
    s.eval("(set-option! 'completion-keys 'tab)").unwrap();
    type_keys(&mut s, "oalp");
    s.keys(&["C-n"]);
    // alpine is nearer, so first; C-n moves on and <tab> accepts.
    assert_eq!(menu(&mut s), ["alpine", "alphabet"]);
    type_keys(&mut s, "<C-n><tab>");
    assert_eq!(s.text(), "alphabet alpine\nalphabet\n");
    // enter: <ret> accepts the selected candidate.
    s.eval("(set-option! 'completion-keys 'enter)").unwrap();
    type_keys(&mut s, " alp");
    s.keys(&["C-n"]);
    type_keys(&mut s, "<ret>");
    assert_eq!(s.text(), "alphabet alpine\nalphabet alphabet\n");
    // vim: <ret> in a menu that opened by itself, nothing selected, is a
    // new line.
    s.eval("(set-option! 'completion-keys 'vim)").unwrap();
    s.eval("(set-option! 'completion-auto-modes '(fundamental-mode))")
        .unwrap();
    type_keys(&mut s, " alp");
    s.eval("(complete-at-point! #f)").unwrap();
    assert_eq!(menu(&mut s), ["alphabet", "alpine"]);
    type_keys(&mut s, "<ret>");
    assert_eq!(s.text(), "alphabet alpine\nalphabet alphabet alp\n\n");
}

#[test]
fn menu_columns() {
    let mut s = server("alphabet\n");
    s.set_size(80, 20);
    s.eval("(set-option! 'completion-menu-columns '(label source))")
        .unwrap();
    type_keys(&mut s, "oalp");
    s.keys(&["C-n"]);
    let rows = s.frame().text_rows().join("\n");
    assert!(rows.contains("alphabet  [words]"), "{rows}");
}

fn cmd_menu(s: &mut imp_server::Server) -> Vec<String> {
    s.eval("(map (lambda (k) (vector-ref *cmd-labels* k)) *cmd-hits*)")
        .unwrap()
        .trim_matches(|c| c == '(' || c == ')')
        .split_whitespace()
        .map(|w| w.trim_matches('"').to_string())
        .collect()
}

#[test]
fn the_command_line_menu() {
    let mut s = server("needle haystack needles\n");
    s.set_size(100, 20);
    // It opens as you type a command's argument, docs beside options.
    type_keys(&mut s, ":set completion-auto-mo");
    let rows = s.frame().text_rows().join("\n");
    assert!(
        rows.contains("completion-auto-modes  Major modes"),
        "{rows}"
    );
    type_keys(&mut s, "<esc>:set relativen");
    assert_eq!(cmd_menu(&mut s), ["relativenumber"]);
    type_keys(&mut s, "<tab>");
    assert_eq!(s.eval("*cmdline*").unwrap(), "\"set relativenumber\"");
    // Typing narrows it; <ret> runs the line.
    type_keys(&mut s, "<ret>");
    assert_eq!(s.eval("(option 'relativenumber)").unwrap(), "#true");
    // A command's name, once begun.
    type_keys(&mut s, ":nohl");
    assert_eq!(cmd_menu(&mut s), ["nohlsearch"]);
    type_keys(&mut s, "<esc>");
    assert!(cmd_menu(&mut s).is_empty());
    // Searching: the buffer's words, after 3 characters, nearest the
    // match incsearch went to first.
    type_keys(&mut s, "/nee");
    assert_eq!(cmd_menu(&mut s), ["needles", "needle"]);
    type_keys(&mut s, "<tab><ret>");
    assert_eq!(s.cursor(), "needle haystack ".len());
}

#[test]
fn the_menu_keeps_its_side_and_width_as_it_narrows() {
    let filler = "x\n".repeat(14);
    let mut s = server(&format!(
        "alpha_short1 alpha_short2 alpha3 alpha4 alpha5 alpha6 alpha7 alphabetically_long\n{filler}"
    ));
    s.set_size(60, 24);
    s.eval("(set-option! 'completion-auto-modes '(fundamental-mode))")
        .unwrap();
    type_keys(&mut s, "Goalp");
    s.eval("(complete-at-point! #f)").unwrap();
    // The box (its top corner's row and its width) for the open menu.
    let a_box = |s: &mut imp_server::Server| {
        let f = s.frame();
        let rows = f.text_rows();
        let top = rows.iter().position(|r| r.contains('╭')).expect("a menu");
        let r: Vec<char> = rows[top].chars().collect();
        let left = r.iter().position(|&c| c == '╭').unwrap();
        let right = r.iter().position(|&c| c == '╮').unwrap();
        (top < f.cursor.1 as usize, right - left)
    };
    assert_eq!(menu(&mut s).len(), 8);
    let full = a_box(&mut s);
    // Too long to go under the cursor, so over it.
    assert!(full.0);
    type_keys(&mut s, "ha_s");
    assert_eq!(menu(&mut s).len(), 2);
    // Two would fit under, but it stays where it was, as wide.
    assert_eq!(a_box(&mut s), full);
    // Opened again, it starts afresh.
    type_keys(&mut s, "<C-e><esc>oalpha_s");
    s.eval("(complete-at-point! #f)").unwrap();
    assert!(!a_box(&mut s).0);
}
