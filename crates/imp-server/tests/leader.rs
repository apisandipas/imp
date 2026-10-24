//! The leader key and which-key.

mod common;

use common::*;

/// A server whose which-key popup shows at once instead of after a delay.
fn server(text: &str) -> imp_server::Server {
    let mut s = common::server(text);
    s.eval("(set-option! 'which-key-delay 0)").unwrap();
    s
}

fn rows(s: &mut imp_server::Server) -> String {
    s.frame().text_rows().join("\n")
}

#[test]
fn which_key_shows_the_next_keys() {
    let mut s = server("");
    type_keys(&mut s, " ");
    let r = rows(&mut s);
    assert!(r.contains("b → +buffer"), "{r}");
    assert!(r.contains("SPC → find file"), "{r}");
    // Titled with the keys so far.
    assert!(r.contains("─ SPC ─"), "{r}");
    type_keys(&mut s, "h");
    let r = rows(&mut s);
    assert!(r.contains("k → describe key"), "{r}");
    assert!(!r.contains("+buffer"));
    assert!(s.status().starts_with("SPC h"));
    type_keys(&mut s, "<esc>");
    assert!(!rows(&mut s).contains("describe key"));
}

#[test]
fn leader_runs_commands() {
    let mut s = server("(* 6 7)\n");
    type_keys(&mut s, " eb");
    assert_eq!(s.status(), "42");
    type_keys(&mut s, " hk");
    type_keys(&mut s, "w");
    assert!(rows(&mut s).contains("runs the motion w"));
}

#[test]
fn undefined_sequences_say_so() {
    let mut s = server("x\n");
    feed(&mut s, " bz");
    assert!(s.status().contains("is undefined"), "{}", s.status());
    // Back to normal: x deletes.
    type_keys(&mut s, "x");
    assert_eq!(s.text(), "\n");
}

#[test]
fn user_leader_bindings() {
    let mut s = server("");
    s.eval(
        r#"(define-leader-group! "o" "open")
           (define-leader! "ox" (lambda (n) (buffer-insert! 0 "hi")) "say hi")"#,
    )
    .unwrap();
    type_keys(&mut s, " ");
    assert!(rows(&mut s).contains("o → +open"));
    type_keys(&mut s, "o");
    assert!(rows(&mut s).contains("x → say hi"));
    type_keys(&mut s, "x");
    assert_eq!(s.text(), "hi");
}

#[test]
fn leader_in_visual_mode() {
    let mut s = server("(+ 1 1)\n(+ 2 2)\n");
    type_keys(&mut s, "V er");
    assert_eq!(s.status(), "2");
}

#[test]
fn which_key_waits_for_its_delay() {
    let mut s = common::server("");
    s.eval("(set-option! 'which-key-delay 30)").unwrap();
    type_keys(&mut s, " ");
    assert!(!s.frame().text_rows().join("\n").contains("+buffer"));
    s.pump(std::time::Duration::from_millis(200));
    assert!(s.frame().text_rows().join("\n").contains("+buffer"));
    // Typing on before the delay never shows it.
    type_keys(&mut s, "<esc> b");
    s.pump(std::time::Duration::from_millis(200));
    assert!(s.frame().text_rows().join("\n").contains("switch buffer"));
}

#[test]
fn keys_have_which_key_labels() {
    let mut s = server("");
    let label = |s: &mut imp_server::Server, state: &str, key: &str| {
        s.eval(&format!("(binding-label '{state} \"{key}\")"))
            .unwrap()
    };
    s.eval(
        r#"(define-key! 'normal "gb" 'switch-buffer "switch buffer")
           (define-key! 'normal "gB" 'switch-buffer)
           (define-key! 'normal "gL" (lambda (n) 1))
           (define-motion! "gX" 'exclusive (lambda (from n) from) "nowhere")
           (define-operator! "gO" (lambda (s e l) 1) "do nothing")
           (define-major-mode! 'label-mode #f '() #f)
           (define-mode-key! 'label-mode 'normal "gb" (lambda (n) 1) "mode's own")"#,
    )
    .unwrap();
    assert_eq!(label(&mut s, "normal", "gb"), "\"switch buffer\"");
    // No label: the command's name, or nothing for a procedure.
    assert_eq!(label(&mut s, "normal", "gB"), "\"switch-buffer\"");
    assert_eq!(label(&mut s, "normal", "gL"), "#false");
    assert_eq!(label(&mut s, "normal", "gX"), "\"nowhere\"");
    assert_eq!(label(&mut s, "visual", "gO"), "\"do nothing\"");
    assert_eq!(label(&mut s, "normal", "gq"), "#false");
    // Binding again without a label forgets the old one.
    s.eval(r#"(define-key! 'normal "gb" (lambda (n) 1))"#)
        .unwrap();
    assert_eq!(label(&mut s, "normal", "gb"), "#false");
    // A mode's key and label win.
    s.eval("(set-major-mode! 'label-mode)").unwrap();
    assert_eq!(label(&mut s, "normal", "gb"), "\"mode's own\"");
}
