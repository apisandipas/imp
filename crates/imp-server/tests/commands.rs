//! Commands at the `:` line (docs/specs/commands.md): `:NAME` runs the
//! command NAME when no ex command has that name.

mod common;

use common::*;

/// The message line.
fn said(s: &mut imp_server::Server) -> String {
    s.frame().text_rows().last().unwrap().trim_end().to_string()
}

/// A server with a command `hello-world` that records its counts in
/// `*hellos*`.
fn with_hello() -> imp_server::Server {
    let mut s = server("one\ntwo\n");
    s.eval(
        "(define *hellos* '())
         (define-command! 'hello-world
           (lambda (count) \"Say hello.\" (set! *hellos* (cons count *hellos*))))",
    )
    .unwrap();
    s
}

#[test]
fn the_command_line_runs_a_command() {
    let mut s = with_hello();
    type_keys(&mut s, ":hello-world<ret>");
    assert_eq!(s.eval("*hellos*").unwrap(), "(1)");
    // A number before it is the count, even past the buffer's last line.
    type_keys(&mut s, ":3hello-world<ret>");
    type_keys(&mut s, ":12hello-world<ret>");
    assert_eq!(s.eval("*hellos*").unwrap(), "(12 3 1)");
}

#[test]
fn a_command_takes_no_other_range() {
    let mut s = with_hello();
    for keys in [":%", ":.,$", ":.", "Vj:"] {
        type_keys(&mut s, &format!("{keys}hello-world<ret>"));
        assert!(
            said(&mut s).contains("hello-world takes no range"),
            "{keys}: {}",
            said(&mut s)
        );
    }
    assert_eq!(s.eval("*hellos*").unwrap(), "()");
}

#[test]
fn an_ex_command_of_the_same_name_wins() {
    let mut s = server("one\n");
    s.eval(
        "(define *ran* #f)
         (define-command! 'noh (lambda (count) \"Not Vim's.\" (set! *ran* #t)))",
    )
    .unwrap();
    type_keys(&mut s, ":noh<ret>");
    assert_eq!(s.eval("*ran*").unwrap(), "#false");
}

#[test]
fn only_the_full_name_runs_a_command() {
    let mut s = with_hello();
    type_keys(&mut s, ":hello-wor<ret>");
    assert!(said(&mut s).contains("not an editor command: hello-wor"));
    type_keys(&mut s, ":nope<ret>");
    assert!(said(&mut s).contains("not an editor command: nope"));
    assert_eq!(s.eval("*hellos*").unwrap(), "()");
}

#[test]
fn an_error_in_a_command_shows_on_the_status_line() {
    let mut s = server("one\n");
    s.eval("(define-command! 'broken (lambda (count) \"Fail.\" (error \"it broke\")))")
        .unwrap();
    type_keys(&mut s, ":broken<ret>");
    assert!(said(&mut s).contains("it broke"), "{}", said(&mut s));
}

/// A server with `pick-fruit`, which asks for a fruit from a menu, and
/// `greet`, which asks for a name in a free-text prompt that starts with
/// one filled in. What they got is in `*got*`.
fn with_questions() -> imp_server::Server {
    let mut s = with_hello();
    s.eval(
        "(define *got* '())
         (define-command! 'pick-fruit
           (lambda (count)
             \"Pick a fruit.\"
             (completing-read \"Fruit: \" '(\"apple\" \"banana\" \"cherry\")
                              (lambda (f) (set! *got* (cons f *got*))))))
         (define-command! 'greet
           (lambda (count)
             \"Greet someone.\"
             (open-cmdline! \"Name: \" \"Grace\"
                            (lambda (n) (set! *got* (cons n *got*))) #f #f)))",
    )
    .unwrap();
    s
}

#[test]
fn text_after_the_name_answers_a_menu() {
    let mut s = with_questions();
    // Narrowed as if typed, then the first match taken.
    type_keys(&mut s, ":pick-fruit ban<ret>");
    type_keys(&mut s, ":pick-fruit cherry<ret>");
    assert_eq!(s.eval("*got*").unwrap(), "(\"cherry\" \"banana\")");
    assert_eq!(s.eval("(eq? *mode* 'normal)").unwrap(), "#true");
    // A real one, narrowed from part of its name.
    assert_ne!(s.eval("*theme*").unwrap(), "gruvbox-dark");
    type_keys(&mut s, ":load-theme gruvbox<ret>");
    assert_eq!(s.eval("*theme*").unwrap(), "gruvbox-dark");
}

#[test]
fn text_after_the_name_answers_a_prompt() {
    let mut s = with_questions();
    // It replaces what the prompt started with.
    type_keys(&mut s, ":greet Ada Lovelace<ret>");
    assert_eq!(s.eval("*got*").unwrap(), "(\"Ada Lovelace\")");
}

#[test]
fn without_text_the_command_asks() {
    let mut s = with_questions();
    type_keys(&mut s, ":pick-fruit<ret>");
    assert_eq!(s.eval("(eq? *mode* 'cmdline)").unwrap(), "#true");
    assert_eq!(s.eval("*got*").unwrap(), "()");
    type_keys(&mut s, "app<ret>");
    assert_eq!(s.eval("*got*").unwrap(), "(\"apple\")");
}

#[test]
fn text_for_a_command_that_asks_nothing_is_reported() {
    let mut s = with_questions();
    type_keys(&mut s, ":hello-world there<ret>");
    // It has run by then: only a prompt shows that a command asks.
    assert_eq!(s.eval("*hellos*").unwrap(), "(1)");
    assert!(
        said(&mut s).contains("hello-world takes no argument"),
        "{}",
        said(&mut s)
    );
}

/// The `:` line menu's candidates, best first.
fn cmd_menu(s: &mut imp_server::Server) -> Vec<String> {
    s.eval("(map (lambda (k) (vector-ref *cmd-labels* k)) *cmd-hits*)")
        .unwrap()
        .trim_matches(|c| c == '(' || c == ')')
        .split_whitespace()
        .map(|w| w.trim_matches('"').to_string())
        .collect()
}

#[test]
fn the_command_line_offers_commands() {
    let mut s = with_hello();
    s.set_size(120, 20);
    // As you type, with what each does: its docstring's first line, read
    // from its source as M-x does.
    type_keys(&mut s, ":hello-w");
    assert_eq!(cmd_menu(&mut s), ["hello-world"]);
    type_keys(&mut s, "<esc>:install-gram");
    assert_eq!(cmd_menu(&mut s), ["install-grammar", "install-grammars"]);
    let rows = s.frame().text_rows().join("\n");
    assert!(
        rows.contains("install-grammars  Install every declared tree-sitter grammar"),
        "{rows}"
    );
    // <tab> completes one, and <ret> runs it.
    type_keys(&mut s, "<esc>:hello-w<tab>");
    assert_eq!(s.eval("*cmdline*").unwrap(), "\"hello-world\"");
    type_keys(&mut s, "<ret>");
    assert_eq!(s.eval("*hellos*").unwrap(), "(1)");
    // A name that is both an ex command and a command shows once, and
    // Vim's names are still full ones only.
    type_keys(&mut s, ":termina");
    assert_eq!(cmd_menu(&mut s), ["terminal"]);
    type_keys(&mut s, "<esc>:nohl");
    assert_eq!(cmd_menu(&mut s), ["nohlsearch"]);
}
