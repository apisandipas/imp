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
