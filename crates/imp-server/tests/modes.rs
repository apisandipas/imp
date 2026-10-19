//! Major and minor modes, buffer-local options, commenting.

mod common;

use common::*;

/// A server whose which-key popup shows at once instead of after a delay.
fn server(text: &str) -> imp_server::Server {
    let mut s = common::server(text);
    s.eval("(set-option! 'which-key-delay 0)").unwrap();
    s
}

fn open(s: &mut imp_server::Server, name: &str, text: &str) {
    let path = temp_path(name);
    std::fs::write(&path, text).unwrap();
    type_keys(s, &format!(":e {}<ret>", path.display()));
}

#[test]
fn mode_from_file_extension() {
    let mut s = server("");
    open(&mut s, "m.rs", "fn main() {}\n");
    assert_eq!(s.eval("(major-mode)").unwrap(), "rust-mode");
    let status = status_row(&mut s);
    assert!(status.contains("rust  1:1"), "status line: {status:?}");
    open(&mut s, "m.scm", "(+ 1 2)\n");
    assert_eq!(s.eval("(major-mode)").unwrap(), "scheme-mode");
    open(&mut s, "Makefile", "all:\n");
    assert_eq!(s.eval("(major-mode)").unwrap(), "makefile-mode");
}

#[test]
fn a_long_path_is_shortened_from_its_start() {
    let mut s = server("");
    s.set_size(50, 10);
    let dir = temp_path("a-directory-name-long-enough-to-crowd-the-status-line");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("m.rs");
    std::fs::write(&path, "fn main() {}\n").unwrap();
    type_keys(&mut s, &format!(":e {}<ret>", path.display()));
    let status = status_row(&mut s);
    // The file name, the mode and the position all still show.
    assert!(status.contains(" <"), "status line: {status:?}");
    assert!(status.contains("/m.rs"), "status line: {status:?}");
    assert!(status.contains("rust  1:1"), "status line: {status:?}");
    assert_eq!(status.chars().count(), 50);
}

#[test]
fn modes_set_local_options() {
    let mut s = server("");
    open(&mut s, "o.go", "x\n");
    assert_eq!(s.eval("(option 'expandtab)").unwrap(), "#false");
    open(&mut s, "o.ts", "x\n");
    assert_eq!(s.eval("(option 'shiftwidth)").unwrap(), "2");
    type_keys(&mut s, ">>");
    assert_eq!(s.text(), "  x\n");
    // Back in the Go buffer its own values come back.
    s.keys(&["C-^"]);
    assert_eq!(s.eval("(option 'expandtab)").unwrap(), "#false");
}

#[test]
fn setlocal_only_affects_this_buffer() {
    let mut s = server("");
    open(&mut s, "l1.txt", "a\n");
    type_keys(&mut s, ":setlocal sw=8<ret>");
    open(&mut s, "l2.txt", "b\n");
    assert_eq!(s.eval("(option 'shiftwidth)").unwrap(), "4");
    s.keys(&["C-^"]);
    assert_eq!(s.eval("(option 'shiftwidth)").unwrap(), "8");
}

#[test]
fn mode_keys_override_global_ones() {
    let mut s = server("");
    open(&mut s, "k.scm", "(define (f) 1)\n");
    // K in a Scheme buffer describes the symbol under the cursor.
    type_keys(&mut s, "9lK");
    assert!(
        s.frame()
            .text_rows()
            .join("\n")
            .contains("no definition of f")
            || s.status().contains("no definition of f"),
        "{}",
        s.status()
    );
    open(&mut s, "k.txt", "x\n");
    s.eval("(define-key! 'normal \"K\" (lambda (n) (message \"global K\")))")
        .unwrap();
    type_keys(&mut s, "K");
    assert_eq!(s.status(), "global K");
}

#[test]
fn user_defined_major_mode() {
    let mut s = server("");
    s.eval(
        r#"(define-major-mode! 'zz-mode 'prog-mode '("zz")
             (lambda () (set-local-option! 'commentstring "%% %s")))
           (define-mode-key! 'zz-mode 'normal "Q" (lambda (n) (message "zz Q")))"#,
    )
    .unwrap();
    open(&mut s, "u.zz", "line\n");
    type_keys(&mut s, "Q");
    assert_eq!(s.status(), "zz Q");
    type_keys(&mut s, "gcc");
    assert_eq!(s.text(), "%% line\n");
}

#[test]
fn minor_modes_toggle_keymaps() {
    let mut s = server("x\n");
    s.eval(
        r#"(define-minor-mode! 'shouty-mode #f #f)
           (define-mode-key! 'shouty-mode 'normal "x" (lambda (n) (message "shouted")))"#,
    )
    .unwrap();
    s.eval("(minor-mode-on! 'shouty-mode)").unwrap();
    type_keys(&mut s, "x");
    assert_eq!(s.status(), "shouted");
    assert_eq!(s.text(), "x\n");
    s.eval("(minor-mode-off! 'shouty-mode)").unwrap();
    type_keys(&mut s, "x");
    assert_eq!(s.text(), "\n");
}

#[test]
fn comment_and_uncomment() {
    let mut s = server("");
    open(&mut s, "c.rs", "fn a() {\n    b();\n    c();\n}\n");
    type_keys(&mut s, "jgcj");
    assert_eq!(s.text(), "fn a() {\n    // b();\n    // c();\n}\n");
    type_keys(&mut s, "gcj");
    assert_eq!(s.text(), "fn a() {\n    b();\n    c();\n}\n");
    type_keys(&mut s, "ggVGgc");
    assert_eq!(s.text(), "// fn a() {\n//     b();\n//     c();\n// }\n");
    type_keys(&mut s, "u");
    open(&mut s, "c.css", "a {}\n");
    type_keys(&mut s, "gcc");
    assert_eq!(s.text(), "/* a {} */\n");
    type_keys(&mut s, "gcc");
    assert_eq!(s.text(), "a {}\n");
    // gc is dot-repeatable.
    open(&mut s, "c.py", "a\nb\n");
    type_keys(&mut s, "gccj.");
    assert_eq!(s.text(), "# a\n# b\n");
}

#[test]
fn local_leader_shows_mode_bindings() {
    let mut s = server("");
    open(&mut s, "ll.scm", "(* 3 3)\n");
    type_keys(&mut s, " m");
    assert!(s
        .frame()
        .text_rows()
        .join("\n")
        .contains("e → eval top-level form"));
    type_keys(&mut s, "b");
    assert_eq!(s.status(), "9");
}

#[test]
fn mode_command_switches() {
    let mut s = server("x\n");
    type_keys(&mut s, ":mode rust<ret>");
    assert_eq!(s.eval("(major-mode)").unwrap(), "rust-mode");
}
