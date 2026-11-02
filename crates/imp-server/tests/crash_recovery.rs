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

/// A server whose state (and so its crash copies) is in a directory of
/// its own, `name`, emptied first.
fn server_with_state(name: &str) -> (imp_server::Server, std::path::PathBuf) {
    let state = temp_path(name);
    let _ = std::fs::remove_dir_all(&state);
    let mut s = server("");
    s.eval(&format!(
        "(set-option! 'state-directory \"{}\")",
        state.display()
    ))
    .unwrap();
    (s, state)
}

/// The names in `state`'s autosave directory, sorted.
fn copies(state: &std::path::Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(state.join("autosave"))
        .map(|d| {
            d.map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names
}

/// What a file's copy written by this process is called.
fn copy_name(path: &std::path::Path) -> String {
    format!(
        "{}#{}",
        path.display().to_string().replace('/', "%"),
        std::process::id()
    )
}

fn open(s: &mut imp_server::Server, path: &std::path::Path) {
    type_keys(s, &format!(":e {}<ret>", path.display()));
}

#[test]
fn a_copy_is_named_for_its_file_and_this_imp() {
    let (mut s, state) = server_with_state("named-state");
    let path = temp_path("named.txt");
    std::fs::write(&path, "saved\n").unwrap();
    open(&mut s, &path);
    type_keys(&mut s, "Aunsaved<esc>");
    s.eval("(autosave-all!)").unwrap();
    assert_eq!(copies(&state), vec![copy_name(&path)]);
    let copy = state.join("autosave").join(copy_name(&path));
    assert_eq!(std::fs::read_to_string(copy).unwrap(), "savedunsaved\n");
}

#[test]
fn copies_wait_for_typing_to_stop() {
    let (mut s, state) = server_with_state("idle-state");
    let path = temp_path("idle.txt");
    std::fs::write(&path, "saved\n").unwrap();
    open(&mut s, &path);
    s.eval("(set-option! 'autosave-idle 1)").unwrap();
    type_keys(&mut s, "x");
    // Just typed: not yet.
    s.eval("(autosave-check!)").unwrap();
    assert!(copies(&state).is_empty());
    // A second without a key: copied.
    std::thread::sleep(std::time::Duration::from_millis(1100));
    s.eval("(autosave-check!)").unwrap();
    assert_eq!(copies(&state), vec![copy_name(&path)]);
    // Nothing changed since: not written again.
    let copy = state.join("autosave").join(copy_name(&path));
    std::fs::remove_file(&copy).unwrap();
    s.eval("(autosave-check!)").unwrap();
    assert!(copies(&state).is_empty());
}

#[test]
fn steady_typing_is_copied_on_the_interval() {
    let (mut s, state) = server_with_state("interval-state");
    let path = temp_path("interval.txt");
    std::fs::write(&path, "saved\n").unwrap();
    open(&mut s, &path);
    // No idle copies: only the interval, a second.
    s.eval("(set-option! 'autosave-idle 0)").unwrap();
    s.eval("(set-option! 'autosave-interval 1)").unwrap();
    type_keys(&mut s, "x");
    s.eval("(autosave-check!)").unwrap();
    assert!(copies(&state).is_empty());
    std::thread::sleep(std::time::Duration::from_millis(1100));
    type_keys(&mut s, "x");
    s.eval("(autosave-check!)").unwrap();
    assert_eq!(copies(&state), vec![copy_name(&path)]);
    // 0 turns autosave off.
    s.eval("(set-option! 'autosave-interval 0)").unwrap();
    type_keys(&mut s, "x");
    std::fs::remove_dir_all(state.join("autosave")).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(1100));
    s.eval("(autosave-check!)").unwrap();
    assert!(copies(&state).is_empty());
}

#[test]
fn unnamed_text_buffers_are_copied_but_not_special_ones() {
    let (mut s, state) = server_with_state("unnamed-state");
    type_keys(&mut s, ":enew<ret>ia note<esc>");
    let id = s.eval("(current-buffer)").unwrap();
    // A buffer named *...* (a package's, the REPL) isn't.
    s.eval("(go-to-buffer! (buffer-new! \"*scratch-output*\"))")
        .unwrap();
    type_keys(&mut s, "ilog<esc>");
    // Nor an empty one.
    type_keys(&mut s, ":enew<ret>");
    s.eval("(autosave-all!)").unwrap();
    assert_eq!(
        copies(&state),
        vec![format!("unnamed-{id}#{}", std::process::id())]
    );
}

#[test]
fn a_path_too_long_to_name_a_copy_is_said_once() {
    let (mut s, state) = server_with_state("long-state");
    let path = temp_path(&"l".repeat(250));
    std::fs::write(&path, "saved\n").unwrap();
    open(&mut s, &path);
    type_keys(&mut s, "x");
    s.eval("(autosave-all!)").unwrap();
    assert!(
        s.status().contains("too long to autosave"),
        "{}",
        s.status()
    );
    assert!(copies(&state).is_empty());
}
