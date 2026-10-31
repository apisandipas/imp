//! Overlays: one owner for the popup and the keys it takes
//! (runtime/overlay.scm).

mod common;

use common::*;

fn rows(s: &mut imp_server::Server) -> String {
    s.frame().text_rows().join("\n")
}

/// `n` one-run lines, "line 0" to "line n-1".
fn lines(n: usize) -> String {
    format!("(map (lambda (i) (list (list (string-append \"line \" (number->string i)) \"\"))) (range 0 {n}))")
}

#[test]
fn opening_one_closes_the_other() {
    let mut s = server("");
    s.eval(&format!(
        "(define closed '())
         (overlay-open! 'one {} 'on-close (lambda () (set! closed (cons 'one closed))))",
        lines(2)
    ))
    .unwrap();
    assert_eq!(s.eval("(overlay-open? 'one)").unwrap(), "#true");
    s.eval(&format!(
        "(overlay-open! 'two {} 'on-close (lambda () (set! closed (cons 'two closed))))",
        lines(3)
    ))
    .unwrap();
    // one was told, once.
    assert_eq!(s.eval("closed").unwrap(), "(one)");
    assert_eq!(s.eval("(overlay-open? 'two)").unwrap(), "#true");
    assert_eq!(s.eval("(overlay-open? 'one)").unwrap(), "#false");
    // Closing one, which isn't open, leaves two alone.
    s.eval("(overlay-close! 'one)").unwrap();
    assert!(rows(&mut s).contains("line 2"));
    s.eval("(overlay-close! 'two)").unwrap();
    assert_eq!(s.eval("closed").unwrap(), "(two one)");
    assert_eq!(s.eval("(overlay-open?)").unwrap(), "#false");
    assert!(!rows(&mut s).contains("line 0"));
}

#[test]
fn nothing_is_kept_from_the_overlay_before() {
    let mut s = server("");
    s.eval(&format!(
        "(overlay-open! 'one {} 'title \"Titled\" 'selected 1)",
        lines(2)
    ))
    .unwrap();
    assert!(rows(&mut s).contains("Titled"));
    s.eval(&format!("(overlay-open! 'two {})", lines(2)))
        .unwrap();
    assert!(!rows(&mut s).contains("Titled"), "{}", rows(&mut s));
    assert_eq!(s.eval("(hash-ref *overlay* 'selected)").unwrap(), "#false");
}

#[test]
fn the_open_overlay_sees_keys_first() {
    let mut s = server("abc\n");
    s.eval(
        "(define seen '())
         (overlay-open! 'reader '()
                        'keys (lambda (key) (set! seen (cons key seen)) (equal? key \"x\")))",
    )
    .unwrap();
    // x is used up; l goes on and moves the cursor.
    type_keys(&mut s, "xl");
    assert_eq!(s.text(), "abc\n");
    assert_eq!(s.cursor(), 1);
    assert_eq!(s.eval("seen").unwrap(), "(\"l\" \"x\")");
    s.eval("(overlay-close! 'reader)").unwrap();
    type_keys(&mut s, "x");
    assert_eq!(s.text(), "ac\n");
}

#[test]
fn a_late_popup_waits_for_an_overlay_that_takes_keys() {
    let mut s = server("");
    s.eval(&format!(
        "(overlay-open! 'menu {} 'keys (lambda (key) #t))",
        lines(1)
    ))
    .unwrap();
    s.eval("(show-popup! (list (list (list \"late output\" \"\"))))")
        .unwrap();
    let r = rows(&mut s);
    assert!(r.contains("line 0") && !r.contains("late output"), "{r}");
    s.eval("(overlay-close! 'menu)").unwrap();
    assert!(rows(&mut s).contains("late output"));
    // A popup replaces a popup, and the next key closes it.
    s.eval("(show-popup! (list (list (list \"newer\" \"\"))))")
        .unwrap();
    assert!(!rows(&mut s).contains("late output"));
    type_keys(&mut s, "<esc>");
    assert!(!rows(&mut s).contains("newer"));
}

#[test]
fn scrolling_keeps_the_selection_in_view() {
    let mut s = server("");
    s.eval(&format!("(overlay-open! 'list {} 'selected 15)", lines(30)))
        .unwrap();
    // Ten rows, the selected one last.
    assert_eq!(s.eval("(overlay-top)").unwrap(), "6");
    let r = rows(&mut s);
    assert!(r.contains("line 15") && !r.contains("line 16") && !r.contains("line 5\n"));
    // Up within the rows shown: they stay.
    s.eval(&format!(
        "(overlay-update! 'list {} 'selected 10)",
        lines(30)
    ))
    .unwrap();
    assert_eq!(s.eval("(overlay-top)").unwrap(), "6");
    // Above them: they move only that far.
    s.eval(&format!(
        "(overlay-update! 'list {} 'selected 3)",
        lines(30)
    ))
    .unwrap();
    assert_eq!(s.eval("(overlay-top)").unwrap(), "3");
}

#[test]
fn rows_fit_the_window() {
    let mut s = server("");
    s.handle(imp_core::ClientMsg::Resize {
        width: 80,
        height: 8,
    });
    s.eval(&format!("(overlay-open! 'list {} 'selected 0)", lines(30)))
        .unwrap();
    let shown = rows(&mut s).matches("line ").count();
    assert!(shown <= 4, "{shown} rows shown");
}

#[test]
fn lines_from_a_procedure() {
    let mut s = server("");
    // Only the rows shown are made: a long list costs no more than ten.
    s.eval(
        "(define asked #f)
         (overlay-open! 'many
                        (lambda (top rows)
                          (set! asked (list top rows))
                          (map (lambda (i) (list (list (string-append \"item \" (number->string i)) \"\")))
                               (range top (+ top rows))))
                        'count 100000 'selected 500)",
    )
    .unwrap();
    assert_eq!(s.eval("asked").unwrap(), "(491 10)");
    assert!(rows(&mut s).contains("item 500"));
}

#[test]
fn a_page_with_no_selection_shows_every_line() {
    let mut s = server("");
    s.eval(&format!("(show-popup! {})", lines(15))).unwrap();
    let r = rows(&mut s);
    assert!(r.contains("line 0") && r.contains("line 14"), "{r}");
}

#[test]
fn a_late_popup_does_not_take_the_leaders_popup() {
    let mut s = server("");
    s.eval("(set-option! 'which-key-delay 0)").unwrap();
    type_keys(&mut s, " ");
    let leader = rows(&mut s);
    assert!(leader.contains("+file"), "{leader}");
    // Hover or git output arriving now waits for the leader.
    s.eval("(show-popup! (list (list (list \"late output\" \"\"))))")
        .unwrap();
    let r = rows(&mut s);
    assert!(r.contains("+file") && !r.contains("late output"), "{r}");
    // The leader still has its keys, and when it ends the popup shows.
    type_keys(&mut s, "<esc>");
    assert!(rows(&mut s).contains("late output"));
}

#[test]
fn the_file_trees_help_comes_back_after_another_overlay_closed_it() {
    let dir = temp_path("overlay-tree-help");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join(".git")).unwrap();
    std::fs::write(dir.join("a.txt"), "").unwrap();
    let mut s = server("");
    s.eval("(use-package! 'file-tree)").unwrap();
    type_keys(
        &mut s,
        &format!(":e {}<ret> te?", dir.join("a.txt").display()),
    );
    assert!(rows(&mut s).contains("show or hide these keys"));
    // Another overlay takes the popup, and closes.
    s.eval("(show-popup! (list (list (list \"other\" \"\"))))")
        .unwrap();
    type_keys(&mut s, "<esc>");
    assert!(!rows(&mut s).contains("show or hide these keys"));
    // One ? shows the help again.
    type_keys(&mut s, "?");
    assert!(rows(&mut s).contains("show or hide these keys"));
}
