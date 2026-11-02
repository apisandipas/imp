//! Generated buffers (runtime/special.scm): read-only buffers, per-buffer
//! highlights, special-mode.

mod common;

use common::*;

#[test]
fn read_only_buffers_refuse_changes() {
    let mut s = server("one\ntwo\n");
    type_keys(&mut s, ":set nomodifiable<ret>");
    assert_eq!(s.eval("(buffer-read-only?)").unwrap(), "#true");
    for keys in ["dd", "x", "ifoo<esc>", ":s/one/1/<ret>", "p"] {
        feed(&mut s, keys);
        assert_eq!(s.text(), "one\ntwo\n", "after {keys}");
    }
    assert!(s.status().contains("E21"), "{}", s.status());
    // with-writable lifts it for a package's own change.
    s.eval("(with-writable (lambda () (buffer-insert! 0 \"zero\\n\")))")
        .unwrap();
    assert_eq!(s.text(), "zero\none\ntwo\n");
    assert_eq!(s.eval("(buffer-read-only?)").unwrap(), "#true");
    type_keys(&mut s, ":set ma<ret>dd");
    assert_eq!(s.text(), "one\ntwo\n");
}

#[test]
fn special_buffers() {
    let mut s = server("file\n");
    s.eval("(define-major-mode! 'thing-mode 'special-mode '() #f)")
        .unwrap();
    s.eval("(go-to-buffer! (special-buffer \"*thing*\" 'thing-mode))")
        .unwrap();
    s.eval("(set-buffer-contents! \"a\\nb\\nc\\n\")").unwrap();
    assert_eq!(s.text(), "a\nb\nc\n");
    assert_eq!(s.eval("(major-mode)").unwrap(), "thing-mode");
    assert_eq!(
        s.eval("(caddr (buffer-info (current-buffer)))").unwrap(),
        "#false"
    );
    // The same name finds the same buffer; new contents keep the line.
    type_keys(&mut s, "jj");
    let id = s.eval("(current-buffer)").unwrap();
    assert_eq!(
        s.eval("(special-buffer \"*thing*\" 'thing-mode)").unwrap(),
        id
    );
    s.eval("(set-buffer-contents! \"x\\ny\\nz\\nw\\n\")")
        .unwrap();
    assert_eq!(s.eval("(current-line)").unwrap(), "2");
    feed(&mut s, "dd");
    assert_eq!(s.text(), "x\ny\nz\nw\n");
    // q goes back.
    type_keys(&mut s, "q");
    assert_eq!(s.text(), "file\n");
}

#[test]
fn a_buffer_pattern_paints_its_groups() {
    let mut s = server("** Two\nhalf\n");
    s.eval(r#"(set-face! "thing" "fg=red")"#).unwrap();
    // All of the stars but the last: its group, not the whole match.
    s.eval(r#"(buffer-highlight-pattern! "p" "^\\(\\*\\+\\)\\* " "thing")"#)
        .unwrap();
    assert_eq!(s.eval("(faces-at 0)").unwrap(), "(\"thing\")");
    assert_eq!(s.eval("(faces-at 1)").unwrap(), "()");
    let rows = s.frame().rows;
    let red: Vec<_> = rows[0]
        .iter()
        .filter(|sp| sp.style.fg.is_some())
        .map(|sp| sp.text.as_str())
        .collect();
    assert_eq!(red, ["*"], "{:?}", rows[0]);
    // Without groups, the whole match; a global pattern, the whole match
    // whatever its groups, as Vim's hlsearch.
    s.eval(r#"(buffer-highlight-pattern! "p" "ha" "thing")"#)
        .unwrap();
    assert_eq!(s.eval("(faces-at 8)").unwrap(), "(\"thing\")");
    s.eval(r#"(buffer-highlight-clear! "p") (highlight-pattern! "g" "h\\(a\\)" "thing")"#)
        .unwrap();
    assert_eq!(s.eval("(faces-at 7)").unwrap(), "(\"thing\")");
}

#[test]
fn buffer_highlights_follow_their_buffer() {
    let mut s = server("alpha\n");
    s.eval(r#"(set-face! "thing" "fg=red")"#).unwrap();
    s.eval("(buffer-highlight-add! \"x\" 0 5 \"thing\")")
        .unwrap();
    let styled = |s: &mut imp_server::Server| {
        s.frame().rows[0]
            .iter()
            .any(|sp| sp.text.contains("alpha") && sp.style.fg.is_some())
    };
    assert!(styled(&mut s));
    // Another buffer in a split doesn't get them; the first still does.
    type_keys(&mut s, ":vnew<ret>ialpha<esc>");
    let rows = s.frame().rows;
    let red: Vec<_> = rows[0]
        .iter()
        .filter(|sp| sp.text.contains("alpha") && sp.style.fg.is_some())
        .collect();
    assert_eq!(red.len(), 1, "{:?}", rows[0]);
    // Patterns follow edits.
    s.eval("(buffer-highlight-pattern! \"p\" \"al\" \"thing\")")
        .unwrap();
    type_keys(&mut s, "0iZZ<esc>");
    assert!(s.frame().rows[0]
        .iter()
        .any(|sp| sp.text == "al" && sp.style.fg.is_some()));
}
