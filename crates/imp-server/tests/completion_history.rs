//! Completion by use (runtime/history.scm, docs/specs/completion-by-use.md):
//! menus put what you pick often and lately first.

mod common;

use common::*;

fn rows(s: &mut imp_server::Server) -> Vec<String> {
    s.frame()
        .text_rows()
        .into_iter()
        .map(|r| r.trim().to_string())
        .collect()
}

/// Opens a fruit menu; picks go to `*picked*`.
fn fruit(s: &mut imp_server::Server) {
    s.eval(
        r#"(set! *completion-category* 'fruit)
           (completing-read "Fruit: " (list "apple" "banana" "cherry" "cherimoya")
                            (lambda (x) (set! *picked* x)))"#,
    )
    .unwrap();
}

/// The menu's candidates, top to bottom.
fn menu(s: &mut imp_server::Server) -> Vec<String> {
    let names = ["apple", "banana", "cherry", "cherimoya"];
    rows(s)
        .into_iter()
        .filter(|r| names.contains(&r.as_str()))
        .collect()
}

fn pick(s: &mut imp_server::Server, typed: &str) {
    fruit(s);
    type_keys(s, &format!("{typed}<ret>"));
}

fn server_with_state(state: &std::path::Path) -> imp_server::Server {
    let mut s = server("");
    s.set_size(100, 30);
    s.eval(&format!(
        "(define *picked* #f) (set-option! 'state-directory {:?})",
        state.display().to_string()
    ))
    .unwrap();
    s
}

#[test]
fn what_you_pick_comes_first_and_is_kept() {
    let state = temp_path("history-state");
    let mut s = server_with_state(&state);
    fruit(&mut s);
    assert_eq!(menu(&mut s), ["apple", "banana", "cherry", "cherimoya"]);
    type_keys(&mut s, "<esc>");
    pick(&mut s, "cherry");
    pick(&mut s, "cherry");
    pick(&mut s, "banana");
    assert_eq!(s.eval("*picked*").unwrap(), "\"banana\"");
    // Nothing typed: by score, then the rest in order.
    fruit(&mut s);
    assert_eq!(menu(&mut s), ["cherry", "banana", "apple", "cherimoya"]);
    // Typed: equally good matches by use ("cher" starts both).
    type_keys(&mut s, "cher");
    assert_eq!(menu(&mut s), ["cherry", "cherimoya"]);
    type_keys(&mut s, "<esc>");
    // Kept for the next imp.
    let mut s = server_with_state(&state);
    fruit(&mut s);
    assert_eq!(menu(&mut s), ["cherry", "banana", "apple", "cherimoya"]);
}

#[test]
fn a_better_match_still_wins_over_use() {
    let state = temp_path("history-match");
    let mut s = server_with_state(&state);
    pick(&mut s, "cherimoya");
    pick(&mut s, "cherimoya");
    fruit(&mut s);
    // "ry" is a substring of cherry, only a fuzzy match in cherimoya: the
    // better match wins, used or not.
    type_keys(&mut s, "ry");
    assert_eq!(menu(&mut s)[0], "cherry");
}

#[test]
fn each_kind_of_menu_has_its_own() {
    let state = temp_path("history-kinds");
    let mut s = server_with_state(&state);
    pick(&mut s, "cherry");
    s.eval(
        r#"(set! *completion-category* 'tree)
           (completing-read "Tree: " (list "apple" "cherry") (lambda (x) #t))"#,
    )
    .unwrap();
    let r = rows(&mut s);
    let apple = r.iter().position(|l| l == "apple").unwrap();
    let cherry = r.iter().position(|l| l == "cherry").unwrap();
    assert!(apple < cherry, "{r:?}");
}

#[test]
fn the_score_weighs_count_by_age() {
    let s = &mut server("");
    let score = |s: &mut imp_server::Server, count: u32, ago: u32| {
        s.eval(&format!(
            "(history-score (list {count} (- (unix-time) {ago})) (unix-time))"
        ))
        .unwrap()
    };
    assert_eq!(score(s, 2, 60), "8");
    assert_eq!(score(s, 2, 7200), "4");
    assert_eq!(score(s, 2, 200_000), "2");
    assert_eq!(score(s, 2, 2_000_000), "1.0");
}

#[test]
fn turned_off_or_cleared_menus_keep_their_order() {
    let state = temp_path("history-off");
    let mut s = server_with_state(&state);
    pick(&mut s, "cherry");
    s.keys(&["M-x"]);
    type_keys(&mut s, "clear-completion-history<ret>");
    fruit(&mut s);
    assert_eq!(menu(&mut s)[0], "apple");
    type_keys(&mut s, "<esc>");
    s.eval("(set-option! 'completion-history #f)").unwrap();
    pick(&mut s, "cherry");
    s.eval("(set-option! 'completion-history #t)").unwrap();
    fruit(&mut s);
    assert_eq!(menu(&mut s)[0], "apple");
}

#[test]
fn find_file_remembers_full_paths() {
    let state = temp_path("history-files");
    let mut s = server_with_state(&state);
    let project = temp_path("history-project");
    std::fs::create_dir_all(project.join(".git")).unwrap();
    for f in ["a.txt", "b.txt", "c.txt"] {
        std::fs::write(project.join(f), "x\n").unwrap();
    }
    s.eval(&format!(
        "(project-find-file-in {:?})",
        project.display().to_string()
    ))
    .unwrap();
    type_keys(&mut s, "c.txt<ret>");
    let file = std::fs::read_to_string(state.join("completion-history")).unwrap();
    assert!(
        file.contains("file\t1\t") && file.contains(&*project.join("c.txt").to_string_lossy()),
        "{file}"
    );
    // And it comes first next time.
    s.eval(&format!(
        "(project-find-file-in {:?})",
        project.display().to_string()
    ))
    .unwrap();
    let r = rows(&mut s);
    let first = r.iter().position(|l| l.ends_with(".txt")).unwrap();
    assert_eq!(r[first], "c.txt", "{r:?}");
}
