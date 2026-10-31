//! Key resolution: which binding a key runs in normal and visual state.

mod common;

/// What `(resolve-key ARGS)` gives, as "kind label command" ("-" for a
/// field that is #f), or "#f".
fn resolve(s: &mut imp_server::Server, args: &str) -> String {
    s.eval(&format!(
        r##"(let ([b (resolve-key {args})]
                 [text (lambda (x) (cond [(not x) "-"] [(symbol? x) (symbol->string x)] [else x]))])
             (if b
                 (string-append (text (binding-record-kind b)) " " (text (binding-record-label b))
                                " " (text (binding-record-command b)))
                 "#f"))"##
    ))
    .unwrap()
    .trim_matches('"')
    .to_string()
}

#[test]
fn normal_state_order() {
    let mut s = common::server("one two\n");
    // An operator before a motion or a normal key.
    assert_eq!(resolve(&mut s, "'normal \"d\""), "operator - -");
    assert_eq!(resolve(&mut s, "'normal \"w\""), "motion - -");
    assert_eq!(resolve(&mut s, "'normal \"x\""), "normal-key - -");
    assert!(resolve(&mut s, "'normal \"rx\"").starts_with("char-command"));
    assert!(resolve(&mut s, "'normal \"fx\"").starts_with("motion"));
    // Keys that wait for another.
    assert_eq!(resolve(&mut s, "'normal \"g\""), "prefix - -");
    assert_eq!(resolve(&mut s, "'normal \"r\""), "prefix - -");
    assert_eq!(resolve(&mut s, "'normal \"f\""), "prefix - -");
    // Nothing bound.
    assert_eq!(resolve(&mut s, "'normal \"C-F12\""), "#f");
    assert_eq!(resolve(&mut s, "'normal \"gQZ\""), "#f");
}

#[test]
fn a_named_command_has_its_name() {
    let mut s = common::server("");
    s.eval(r#"(define-key! 'normal "C-F11" 'describe-key)"#)
        .unwrap();
    assert_eq!(
        resolve(&mut s, "'normal \"C-F11\""),
        "normal-key describe-key describe-key"
    );
    s.eval(r#"(define-key! 'normal "C-F11" 'describe-key "what a key does")"#)
        .unwrap();
    assert_eq!(
        resolve(&mut s, "'normal \"C-F11\""),
        "normal-key what a key does describe-key"
    );
}

#[test]
fn a_mode_key_comes_first() {
    let mut s = common::server("");
    s.eval("(set-major-mode! 'git-status-mode)").unwrap();
    // git status binds d, x and the prefix z itself.
    assert_eq!(resolve(&mut s, "'normal \"d\""), "mode-key diff menu -");
    assert_eq!(resolve(&mut s, "'normal \"x\""), "mode-key discard -");
    assert_eq!(resolve(&mut s, "'normal \"z\""), "mode-key stash -");
    // Not with an operator pending: dd is still the operator again.
    assert_eq!(resolve(&mut s, "'normal \"d\" \"d\""), "operator-again - -");
    // Vim's keys it doesn't bind are still Vim's.
    assert_eq!(resolve(&mut s, "'normal \"w\""), "motion - -");
}

#[test]
fn visual_state_order() {
    let mut s = common::server("one two\n");
    // A visual key before an operator: o is the other end, not a motion.
    assert!(resolve(&mut s, "'visual \"o\"").starts_with("visual-key"));
    assert_eq!(resolve(&mut s, "'visual \"d\""), "operator - -");
    assert!(resolve(&mut s, "'visual \"iw\"").starts_with("text-object"));
    assert!(resolve(&mut s, "'visual \"rx\"").starts_with("char-command"));
    assert_eq!(resolve(&mut s, "'visual \"w\""), "motion - -");
    // i and a wait for a text object.
    assert_eq!(resolve(&mut s, "'visual \"i\""), "prefix - -");
    // Normal keys aren't visual's.
    assert_eq!(resolve(&mut s, "'visual \"C-F12\""), "#f");
}

#[test]
fn operator_pending() {
    let mut s = common::server("one two\n");
    assert_eq!(resolve(&mut s, "'normal \"w\" \"d\""), "motion - -");
    assert!(resolve(&mut s, "'normal \"iw\" \"d\"").starts_with("text-object"));
    assert_eq!(resolve(&mut s, "'normal \"d\" \"d\""), "operator-again - -");
    assert!(resolve(&mut s, "'normal \"U\" \"gU\"").starts_with("operator-again"));
    assert!(resolve(&mut s, "'normal \"gU\" \"gU\"").starts_with("operator-again"));
    assert_eq!(resolve(&mut s, "'normal \"i\" \"d\""), "prefix - -");
    assert_eq!(resolve(&mut s, "'normal \"g\" \"d\""), "prefix - -");
    // Only a motion, a text object or the operator again: not x or r.
    assert_eq!(resolve(&mut s, "'normal \"x\" \"d\""), "#f");
    assert_eq!(resolve(&mut s, "'normal \"r\" \"d\""), "#f");
}
