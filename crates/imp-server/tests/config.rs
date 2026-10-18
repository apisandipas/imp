//! The user's init.scm can rebind keys and redefine runtime functions.

use std::path::PathBuf;

use imp_core::Buffer;
use imp_server::{Options, Server};

fn server_with_config(name: &str, config: &str) -> Server {
    let path: PathBuf =
        std::env::temp_dir().join(format!("imp-test-{name}-{}.scm", std::process::id()));
    std::fs::write(&path, config).unwrap();
    let server = Server::new(
        Buffer::from_text("one two three\n"),
        Options {
            user_config: Some(path.clone()),
        },
    )
    .expect("runtime loads");
    let _ = std::fs::remove_file(path);
    server
}

#[test]
fn init_can_bind_a_new_motion_that_works_with_operators() {
    let mut s = server_with_config(
        "motion",
        // A motion to the end of the buffer, defined by the user. `d` and `.`
        // pick it up with no further code.
        r#"(define-motion! "Q" 'exclusive (lambda (from n) (buffer-length)))"#,
    );
    s.keys(&["w", "d", "Q"]);
    assert_eq!(s.text(), "one \n");
}

#[test]
fn init_can_rebind_a_normal_key() {
    let mut s = server_with_config(
        "rebind",
        r#"(define-key! 'normal "U" (lambda (count) (buffer-insert! 0 "!")))"#,
    );
    s.keys(&["U"]);
    assert_eq!(s.text(), "!one two three\n");
}

#[test]
fn a_broken_init_still_starts_the_editor() {
    let mut s = server_with_config("broken", "(this is not defined");
    assert!(
        !s.status().is_empty(),
        "the error should be on the status line"
    );
    s.keys(&["d", "w"]);
    assert_eq!(s.text(), "two three\n");
}

#[test]
fn init_redefines_a_runtime_function_for_its_callers() {
    // `line-first-nonblank` (core.scm) is what ^ calls. Redefining it must
    // change ^: that only works if the runtime's callers see the new
    // definition, not just a new binding beside the old one.
    let mut s = server_with_config(
        "redefine",
        r#"(define (line-first-nonblank line) (line-end line))"#,
    );
    s.keys(&["^"]);
    assert_eq!(s.cursor(), 12);
}

#[test]
fn init_can_change_what_a_word_is() {
    // Words are char-class's business; w, e and iw all follow it.
    let mut s = server_with_config("words", r#"(define (char-class c) (if c 1 0))"#);
    s.keys(&["d", "w"]);
    assert_eq!(s.text(), "\n");
}

#[test]
fn init_can_define_new_functions_and_macros() {
    let mut s = server_with_config(
        "new",
        r#"(define-syntax twice (syntax-rules () [(_ e) (begin e e)]))
           (define (bang! count) (twice (buffer-insert! 0 "!")))
           (define-key! 'normal "Q" bang!)"#,
    );
    s.keys(&["Q"]);
    assert_eq!(s.text(), "!!one two three\n");
}

/// examples/init.scm, the starter config, loads cleanly and does what it
/// says.
#[test]
fn the_example_config_works() {
    let config = concat!(env!("CARGO_MANIFEST_DIR"), "/../../examples/init.scm");
    let file = std::env::temp_dir().join(format!("imp-test-example-{}.ts", std::process::id()));
    std::fs::write(&file, "let a = 1;   \nlet b = 2;\n").unwrap();
    let mut s = Server::new(
        Buffer::open(&file).unwrap(),
        Options {
            user_config: Some(config.into()),
        },
    )
    .expect("runtime loads");
    assert!(!s.status().starts_with("error"), "{}", s.status());
    assert_eq!(s.eval("*theme*").unwrap(), "gruvbox-dark");
    assert_eq!(s.eval("(option 'number)").unwrap(), "#true");
    // TypeScript gets two-space indents.
    s.eval("(set-major-mode! 'typescript-mode)").unwrap();
    assert_eq!(s.eval("(option 'shiftwidth)").unwrap(), "2");
    // SPC i d inserts the date; C-s saves, trimming trailing spaces.
    s.keys(&["j", " ", "i", "d"]);
    let today = std::process::Command::new("date")
        .arg("+%F")
        .output()
        .unwrap();
    let today = String::from_utf8(today.stdout).unwrap();
    assert!(s.text().contains(today.trim()), "{}", s.text());
    s.keys(&["C-s"]);
    let saved = std::fs::read_to_string(&file).unwrap();
    assert!(saved.starts_with("let a = 1;\n"), "{saved:?}");
    let _ = std::fs::remove_file(file);
}
