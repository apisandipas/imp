//! The debugger (runtime/dap.scm) against a scripted adapter,
//! tests/fake_dap.py. Session tests are skipped without python3.

mod common;

use common::*;
use std::time::Duration;

fn have_python() -> bool {
    std::process::Command::new("python3")
        .arg("--version")
        .output()
        .is_ok()
}

fn wait_for(s: &mut imp_server::Server, expr: &str) {
    for _ in 0..100 {
        if s.eval(expr).unwrap() == "#true" {
            return;
        }
        s.pump(Duration::from_millis(30));
    }
    panic!("timed out waiting for {expr}; status: {}", s.status());
}

fn settle(s: &mut imp_server::Server) {
    s.pump(Duration::from_millis(300));
}

const PROGRAM: &str = "fn main() {\n    let a = 1;\n    let b = 2;\n    let c = 3;\n}\n";

fn rows(s: &mut imp_server::Server) -> Vec<String> {
    s.frame().text_rows()
}

#[test]
fn breakpoints_toggle_and_follow_edits() {
    let mut s = server(PROGRAM);
    type_keys(&mut s, "2G<f9>");
    assert!(rows(&mut s)[1].starts_with("● "), "{:?}", rows(&mut s));
    // An inserted line above moves it down.
    type_keys(&mut s, "ggOuse x;<esc>");
    assert!(rows(&mut s)[2].starts_with("● "), "{:?}", rows(&mut s));
    type_keys(&mut s, "3G<f9>");
    assert!(!rows(&mut s).join("\n").contains('●'));
}

#[test]
fn the_highest_sign_wins_a_line() {
    let mut s = server("one\ntwo\n");
    s.eval("(set-sign-source! 'low 1 (list (list 0 \"L\" \"x\") (list 1 \"L\" \"x\")))")
        .unwrap();
    s.eval("(set-sign-source! 'high 5 (list (list 1 \"H\" \"x\")))")
        .unwrap();
    let r = rows(&mut s);
    assert!(r[0].starts_with("L one"), "{r:?}");
    assert!(r[1].starts_with("H two"), "{r:?}");
    s.eval("(set-sign-source! 'high 5 '())").unwrap();
    assert!(rows(&mut s)[1].starts_with("L two"));
}

#[test]
fn a_debug_session() {
    if !have_python() {
        return;
    }
    let path = temp_path("debugged.rs");
    std::fs::write(&path, PROGRAM).unwrap();
    let log = temp_path("debugged.log");
    let _ = std::fs::remove_file(&log);
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_dap.py");
    let mut s = server("");
    s.eval(&format!(
        r#"(define-debug-adapter! 'rust-mode "env FAKE_DAP_LOG={} python3 {fake}" "fake"
             (lambda (done) (done (hash "source" {:?}))))"#,
        log.display(),
        path.display().to_string()
    ))
    .unwrap();
    s.eval(&format!("(open-file! {:?})", path.display().to_string()))
        .unwrap();
    type_keys(&mut s, "2G<f9>4G<f9>gg");

    // Start: it stops at the first breakpoint, marked and highlighted.
    type_keys(&mut s, " dd");
    wait_for(&mut s, "(and *dap-stopped-at* #t)");
    assert_eq!(s.eval("(current-line)").unwrap(), "1");
    let r = rows(&mut s);
    assert!(r[1].starts_with("→ "), "{r:?}");
    assert!(r[3].starts_with("● "), "{r:?}");
    assert!(s.status().starts_with("stopped (breakpoint) in inner"));

    // Variables, and evaluating.
    type_keys(&mut s, " dv");
    settle(&mut s);
    let r = rows(&mut s).join("\n");
    assert!(r.contains("Locals:"), "{r}");
    assert!(r.contains("  x = 20"), "{r}");
    assert!(r.contains("  items = list(2) ▸"), "{r}");
    type_keys(&mut s, "<esc> de<bs><bs><bs>x<ret>");
    settle(&mut s);
    assert_eq!(s.status(), "value of x");

    // Step over, then pick the outer frame.
    type_keys(&mut s, "<f10>");
    wait_for(&mut s, "(equal? (current-line) 2)");
    type_keys(&mut s, " dsmain<ret>");
    assert_eq!(s.eval("(current-line)").unwrap(), "0");

    // Continue to the next breakpoint, then to the end.
    type_keys(&mut s, " dc");
    wait_for(&mut s, "(equal? (current-line) 3)");
    type_keys(&mut s, " dc");
    wait_for(&mut s, "(not *dap-job*)");
    assert!(!rows(&mut s).join("\n").contains('→'));
    type_keys(&mut s, " dO");
    assert!(rows(&mut s).join("\n").contains("program done"));

    let log = std::fs::read_to_string(log).unwrap();
    assert!(log.contains(r#""lines": [2, 4]"#), "{log}");
    assert!(log.contains("configurationDone"));
}

#[test]
fn without_an_adapter_it_says_so() {
    let mut s = server("text\n");
    type_keys(&mut s, " dd");
    assert_eq!(s.status(), "no debug adapter for fundamental-mode");
    type_keys(&mut s, " dn");
    assert_eq!(s.status(), "not stopped in a debug session");
}
