//! Crash recovery (spec/crash-recovery): private autosave copies named
//! for the imp that wrote them, offered back once that imp is gone.

mod common;

use common::*;

#[test]
fn copies_know_which_imp_wrote_them() {
    let mut s = server("");
    assert_eq!(
        s.eval("(process-id)").unwrap(),
        std::process::id().to_string()
    );
    // A process that has ended is not a running imp.
    let mut done = std::process::Command::new("true").spawn().unwrap();
    let pid = done.id();
    done.wait().unwrap();
    assert_eq!(s.eval(&format!("(imp-running? {pid})")).unwrap(), "#false");
    assert_eq!(s.eval("(imp-running? 0)").unwrap(), "#false");
    assert_eq!(s.eval("(imp-running? -1)").unwrap(), "#false");
}

#[cfg(target_os = "linux")]
#[test]
fn a_running_process_counts_only_if_it_is_imp() {
    let mut s = server("");
    // This test binary runs, but isn't imp.
    assert_eq!(
        s.eval(&format!("(imp-running? {})", std::process::id()))
            .unwrap(),
        "#false"
    );
    // A program called imp is.
    let imp = temp_path("bin/imp");
    std::fs::create_dir_all(imp.parent().unwrap()).unwrap();
    std::fs::copy("/bin/sh", &imp).unwrap();
    let mut child = std::process::Command::new(&imp)
        .args(["-c", "read x"])
        .stdin(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let pid = child.id();
    let running = s.eval(&format!("(imp-running? {pid})")).unwrap();
    drop(child.stdin.take());
    child.wait().unwrap();
    assert_eq!(running, "#true");
}

#[test]
fn idle_time_counts_from_the_last_key() {
    let mut s = server("text\n");
    // Before any input, imp has been idle a long time.
    let before: i64 = s.eval("(input-idle-ms)").unwrap().parse().unwrap();
    assert!(before > 1_000_000, "{before}");
    type_keys(&mut s, "l");
    let after: i64 = s.eval("(input-idle-ms)").unwrap().parse().unwrap();
    assert!((0..1000).contains(&after), "{after}");
}
