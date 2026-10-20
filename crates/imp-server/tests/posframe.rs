//! The posframe package (packages/posframe): completion in a centred box.

mod common;

use common::*;

fn rows(s: &mut imp_server::Server) -> Vec<String> {
    s.frame().text_rows()
}

#[test]
fn completion_opens_in_a_centred_box_with_its_prompt() {
    let mut s = server("");
    s.set_size(100, 30);
    s.eval("(use-package! 'posframe)").unwrap();
    s.eval(r#"(completing-read "Pick: " (list "apple" "banana" "cherry") (lambda (x) (message (string-append "got " x))))"#)
        .unwrap();
    let screen = rows(&mut s);
    // 60% of 100 columns inside the borders, centred: x = (100 - 62) / 2.
    let top = screen.iter().position(|r| r.contains('╭')).expect("a box");
    assert_eq!(top, 5, "{screen:#?}");
    assert_eq!(screen[top].find('╭'), Some(19), "{:?}", screen[top]);
    assert!(screen[top].contains(" Pick "), "{:?}", screen[top]);
    assert!(
        screen[top + 1].contains("│ Pick:    [1/3]"),
        "{:?}",
        screen[top + 1]
    );
    assert!(screen[top + 2].contains('├'));
    assert!(screen[top + 3].contains("apple") && screen[top + 5].contains("cherry"));
    assert!(screen[top + 6].contains('╰'));
    // The bottom line is left empty; the cursor is in the box.
    assert_eq!(screen[29].trim(), "");
    assert_eq!(s.frame().cursor, (19 + 2 + 6, (top + 1) as u16));
    type_keys(&mut s, "ch");
    let screen = rows(&mut s);
    assert!(
        screen[top + 1].contains("│ Pick: ch   [1/1]"),
        "{:?}",
        screen[top + 1]
    );
    assert_eq!(s.frame().cursor, (19 + 2 + 8, (top + 1) as u16));
    type_keys(&mut s, "<ret>");
    assert_eq!(s.status(), "got cherry");
    assert!(!rows(&mut s).iter().any(|r| r.contains('╭')));
}

#[test]
fn other_prompts_and_popups_stay_where_they_were() {
    let mut s = server("");
    s.set_size(100, 30);
    s.eval("(use-package! 'posframe)").unwrap();
    type_keys(&mut s, ":");
    let screen = rows(&mut s);
    assert_eq!(screen[29], ":");
    assert!(!screen.iter().any(|r| r.contains('╭')));
    type_keys(&mut s, "<esc>");
    // M-x in the box, then the leader's which-key popup at the bottom.
    s.keys(&["M-x"]);
    assert!(
        rows(&mut s).iter().any(|r| r.contains("╭─ M-x")),
        "{:#?}",
        rows(&mut s)
    );
    type_keys(&mut s, "<esc> ");
    let screen = rows(&mut s);
    assert!(!screen.iter().any(|r| r.contains('╭')), "{screen:#?}");
}

#[test]
fn it_turns_off_and_takes_a_width() {
    let mut s = server("");
    s.set_size(100, 30);
    s.eval("(use-package! 'posframe 'config (lambda () (set-option! 'posframe-width 80)))")
        .unwrap();
    s.keys(&["M-x"]);
    let screen = rows(&mut s);
    let top = screen.iter().position(|r| r.contains('╭')).expect("a box");
    assert_eq!(screen[top].find('╭'), Some(9), "{:?}", screen[top]);
    type_keys(&mut s, "<esc>");
    s.eval("(run-command 'posframe-mode)").unwrap();
    s.keys(&["M-x"]);
    assert!(!rows(&mut s).iter().any(|r| r.contains('╭')));
}
