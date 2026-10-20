//! The org-babel package (packages/org-babel): running Org source blocks.

mod common;

use common::*;
use std::time::{Duration, Instant};

fn org(name: &str, text: &str) -> (imp_server::Server, std::path::PathBuf) {
    let path = temp_path(&format!("babel-{name}.org"));
    std::fs::write(&path, text).unwrap();
    let mut s = server("");
    s.eval("(use-package! 'org-babel)").unwrap();
    type_keys(&mut s, &format!(":e {}<ret>", path.display()));
    assert_eq!(s.eval("(major-mode)").unwrap(), "org-mode");
    (s, path)
}

fn wait_for(s: &mut imp_server::Server, what: &str, done: impl Fn(&str) -> bool) {
    let start = Instant::now();
    while !done(&s.text()) {
        assert!(
            start.elapsed() < Duration::from_secs(10),
            "waited for {what}:\n{}\n{}",
            s.text(),
            s.status()
        );
        s.pump(Duration::from_millis(30));
    }
}

#[test]
fn a_scheme_block_runs_in_imp_and_asks_first() {
    let (mut s, _) = org(
        "scheme",
        "* Try\n#+begin_src scheme\n(define x 6)\n(* x 7)\n#+end_src\n",
    );
    type_keys(&mut s, "3G");
    s.keys(&["C-c", "C-c"]);
    assert!(
        s.status().contains("Run this scheme block? (y or n)"),
        "{}",
        s.status()
    );
    type_keys(&mut s, "y");
    assert_eq!(
        s.text(),
        "* Try\n#+begin_src scheme\n(define x 6)\n(* x 7)\n#+end_src\n\n#+RESULTS:\n: 42\n"
    );
    // Again: the results are replaced, not added. n doesn't run it.
    s.eval("(set-option! 'org-babel-confirm #f)").unwrap();
    type_keys(&mut s, "4Gcc(+ x 1)<esc>");
    s.keys(&["C-c", "C-c"]);
    assert!(
        s.text().ends_with("#+end_src\n\n#+RESULTS:\n: 7\n"),
        "{}",
        s.text()
    );
    // A string is shown as it is; steel is the same language.
    type_keys(&mut s, "4Gcc\"two\\nlines\"<esc>");
    s.keys(&["C-c", "C-c"]);
    assert!(
        s.text().ends_with("#+RESULTS:\n: two\n: lines\n"),
        "{}",
        s.text()
    );
}

#[test]
fn a_shell_block_runs_in_the_background() {
    let (mut s, _) = org(
        "shell",
        "#+begin_src sh :dir /\npwd\necho\nprintf 'a\\nb\\n'\n#+end_src\n* After\n",
    );
    s.eval("(set-option! 'org-babel-confirm #f)").unwrap();
    type_keys(&mut s, "2G");
    s.keys(&["C-c", "C-c"]);
    wait_for(&mut s, "the results", |t| t.contains("#+RESULTS:"));
    assert_eq!(
        s.text(),
        "#+begin_src sh :dir /\npwd\necho\nprintf 'a\\nb\\n'\n#+end_src\n\n#+RESULTS:\n: /\n:\n: a\n: b\n* After\n"
    );
    // C-c C-v k removes them.
    type_keys(&mut s, "gg");
    s.keys(&["C-c", "C-v", "k"]);
    assert_eq!(
        s.text(),
        "#+begin_src sh :dir /\npwd\necho\nprintf 'a\\nb\\n'\n#+end_src\n* After\n"
    );
}

#[test]
fn long_output_goes_in_an_example_block_and_silent_shows_it() {
    let (mut s, _) = org("long", "#+begin_src sh\nseq 1 12\n#+end_src\n\n#+begin_src sh :results silent\necho quiet\n#+end_src\n");
    s.eval("(set-option! 'org-babel-confirm #f)").unwrap();
    s.keys(&["C-c", "C-c"]);
    wait_for(&mut s, "the results", |t| t.contains("#+end_example"));
    assert!(
        s.text().starts_with(
            "#+begin_src sh\nseq 1 12\n#+end_src\n\n#+RESULTS:\n#+begin_example\n1\n2\n"
        ),
        "{}",
        s.text()
    );
    let before = s.text();
    type_keys(&mut s, "G");
    s.keys(&["C-c", "C-c"]);
    let start = Instant::now();
    while s.status() != "quiet" && start.elapsed() < Duration::from_secs(10) {
        s.pump(Duration::from_millis(30));
    }
    assert_eq!(s.status().trim(), "quiet");
    assert_eq!(s.text(), before);
}

#[test]
fn the_whole_buffer_runs_in_order_and_errors_are_shown() {
    let (mut s, _) = org(
        "buffer",
        "#+begin_src scheme\n(define base 40)\n#+end_src\n\n#+begin_src scheme\n(+ base 2)\n#+end_src\n",
    );
    s.eval("(set-option! 'org-babel-confirm #f)").unwrap();
    s.keys(&["C-c", "C-v", "C-b"]);
    assert_eq!(
        s.text(),
        "#+begin_src scheme\n(define base 40)\n#+end_src\n\n#+RESULTS:\n: 40\n\n#+begin_src scheme\n(+ base 2)\n#+end_src\n\n#+RESULTS:\n: 42\n"
    );
    // An error is shown, and leaves no results.
    type_keys(&mut s, "Go#+begin_src scheme\n(car '())\n#+end_src<esc>k");
    s.keys(&["C-c", "C-c"]);
    assert!(s.status().starts_with("error"), "{}", s.status());
    assert!(s.text().ends_with("(car '())\n#+end_src\n"), "{}", s.text());
    // Outside a block, and an unknown language.
    type_keys(&mut s, "gg");
    s.eval("(run-command 'org-babel-execute)").unwrap();
    s.keys(&["C-c", "C-c"]);
    let (mut s, _) = org("cobol", "#+begin_src cobol\nDISPLAY 'HI'.\n#+end_src\n");
    s.eval("(set-option! 'org-babel-confirm #f)").unwrap();
    s.keys(&["C-c", "C-c"]);
    assert!(
        s.status().contains("no interpreter for cobol"),
        "{}",
        s.status()
    );
}
