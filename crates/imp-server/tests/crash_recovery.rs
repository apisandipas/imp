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

/// A pid no process can have (Linux's highest is 2^22): the imp that
/// wrote a copy under it has crashed.
const DEAD: u32 = 999_999_999;

/// Leaves a copy of `path` holding `text` as a crashed imp (pid `pid`)
/// would have, in `state`.
fn leave_copy(state: &std::path::Path, path: &std::path::Path, pid: u32, text: &str) {
    let dir = state.join("autosave");
    std::fs::create_dir_all(&dir).unwrap();
    let name = path.display().to_string().replace('/', "%");
    std::fs::write(dir.join(format!("{name}#{pid}")), text).unwrap();
}

#[test]
fn opening_a_file_offers_its_crash_copy() {
    let (mut s, state) = server_with_state("offer-state");
    let path = temp_path("offered.txt");
    std::fs::write(&path, "one\ntwo\n").unwrap();
    leave_copy(&state, &path, DEAD, "one\ntwo\nthree\n");
    open(&mut s, &path);
    // Asked, not yet changed.
    assert_eq!(s.text(), "one\ntwo\n");
    let status = s.status();
    assert!(
        status.contains("offered.txt has unsaved changes from a crash, saved ")
            && status.ends_with("(1 line differs)"),
        "{status}"
    );
    let rows = s.frame().text_rows().join("\n");
    assert!(
        rows.contains("r recover   d delete the copy   k keep it for later"),
        "{rows}"
    );
    type_keys(&mut s, "r");
    assert_eq!(s.text(), "one\ntwo\nthree\n");
    assert!(
        s.status().contains("recovered offered.txt; :w to keep it"),
        "{}",
        s.status()
    );
    assert_eq!(s.eval("(buffer-modified?)").unwrap(), "#true");
    // The copy is this imp's now, so a second crash still has it.
    assert_eq!(copies(&state), vec![copy_name(&path)]);
    // One change: u takes it back.
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "one\ntwo\n");
}

#[test]
fn d_deletes_the_copy_and_k_keeps_it() {
    let (mut s, state) = server_with_state("dk-state");
    let path = temp_path("dk.txt");
    std::fs::write(&path, "file\n").unwrap();
    leave_copy(&state, &path, DEAD, "copy\n");
    open(&mut s, &path);
    type_keys(&mut s, "k");
    assert_eq!(s.text(), "file\n");
    assert_eq!(copies(&state).len(), 1);
    // Kept for later: :recover takes it now.
    type_keys(&mut s, ":recover<ret>");
    assert_eq!(s.text(), "copy\n");
    // Another file, its copy deleted.
    let other = temp_path("dk2.txt");
    std::fs::write(&other, "file\n").unwrap();
    leave_copy(&state, &other, DEAD, "copy\n");
    open(&mut s, &other);
    type_keys(&mut s, "d");
    assert_eq!(s.text(), "file\n");
    assert_eq!(copies(&state), vec![copy_name(&path)]);
}

#[test]
fn a_copy_that_matches_the_file_goes_quietly() {
    let (mut s, state) = server_with_state("same-state");
    let path = temp_path("same.txt");
    std::fs::write(&path, "same\n").unwrap();
    leave_copy(&state, &path, DEAD, "same\n");
    open(&mut s, &path);
    assert!(!s.status().contains("crash"), "{}", s.status());
    assert!(copies(&state).is_empty());
}

#[test]
fn an_older_imps_copy_without_a_pid_is_orphaned() {
    let (mut s, state) = server_with_state("old-state");
    let path = temp_path("old.txt");
    std::fs::write(&path, "file\n").unwrap();
    let dir = state.join("autosave");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join(path.display().to_string().replace('/', "%")),
        "copy\n",
    )
    .unwrap();
    open(&mut s, &path);
    assert!(s.status().contains("from a crash"), "{}", s.status());
}

#[test]
fn a_file_newer_than_its_copy_says_so() {
    let (mut s, state) = server_with_state("newer-state");
    let path = temp_path("newer.txt");
    leave_copy(&state, &path, DEAD, "copy\n");
    std::thread::sleep(std::time::Duration::from_millis(20));
    std::fs::write(&path, "file\n").unwrap();
    open(&mut s, &path);
    let rows = s.frame().text_rows().join("\n");
    assert!(
        rows.contains("the file was changed after this copy"),
        "{rows}"
    );
}

#[test]
fn a_copy_held_by_a_running_imp_is_only_warned_about() {
    let (mut s, state) = server_with_state("live-state");
    let path = temp_path("live.txt");
    std::fs::write(&path, "file\n").unwrap();
    leave_copy(&state, &path, 4242, "theirs\n");
    // Pretend imp 4242 runs.
    s.eval("(define (copy-owner-alive? pid) (and pid (or (= pid 4242) (= pid (process-id)))))")
        .unwrap();
    open(&mut s, &path);
    assert!(
        s.status()
            .contains("live.txt is also being edited in imp 4242"),
        "{}",
        s.status()
    );
    type_keys(&mut s, "x");
    assert_eq!(s.text(), "ile\n");
    assert_eq!(copies(&state).len(), 1);
}

#[test]
fn recover_file_opens_and_recovers_it() {
    let (mut s, state) = server_with_state("recover-file-state");
    let path = temp_path("recover-file.txt");
    std::fs::write(&path, "file\n").unwrap();
    // Nothing to recover in the empty buffer.
    type_keys(&mut s, ":recover<ret>");
    assert_eq!(s.status(), "no autosaved copy of this buffer");
    leave_copy(&state, &path, DEAD, "copy\n");
    type_keys(&mut s, &format!(":recover {}<ret>", path.display()));
    assert_eq!(
        s.eval("(buffer-path)").unwrap(),
        format!("{:?}", path.display().to_string())
    );
    assert_eq!(s.text(), "copy\n");
    assert!(s.status().contains("recovered"), "{}", s.status());
    assert_eq!(copies(&state), vec![copy_name(&path)]);
}

#[test]
fn recover_session_lists_every_orphaned_copy() {
    let (mut s, state) = server_with_state("session-state");
    s.set_size(200, 24);
    type_keys(&mut s, ":recover-session<ret>");
    assert_eq!(s.status(), "nothing to recover");
    let path = temp_path("session.txt");
    std::fs::write(&path, "file\n").unwrap();
    leave_copy(&state, &path, DEAD, "copy\ntwo\n");
    std::thread::sleep(std::time::Duration::from_millis(20));
    // An unnamed buffer's, newer.
    let dir = state.join("autosave");
    std::fs::write(dir.join(format!("unnamed-3#{DEAD}")), "a note\n").unwrap();
    // This imp's own copies are in use, not listed.
    std::fs::write(
        dir.join(format!("unnamed-9#{}", std::process::id())),
        "mine\n",
    )
    .unwrap();
    type_keys(&mut s, ":recover-session<ret>");
    let rows = s.frame().text_rows().join("\n");
    assert!(rows.contains("1 unnamed"), "{rows}");
    assert!(rows.contains("2 "), "{rows}");
    assert!(rows.contains("session.txt"), "{rows}");
    assert!(rows.contains("2 lines"), "{rows}");
    assert!(!rows.contains("mine"), "{rows}");
    // The first is newest: the unnamed copy, into a new buffer.
    type_keys(&mut s, "<ret>");
    assert_eq!(s.text(), "a note\n");
    assert_eq!(s.eval("(buffer-path)").unwrap(), "#false");
    assert_eq!(s.eval("(buffer-modified?)").unwrap(), "#true");
    // Then the file's.
    type_keys(&mut s, ":recover-session<ret><ret>");
    assert_eq!(s.text(), "copy\ntwo\n");
    assert_eq!(
        s.eval("(buffer-path)").unwrap(),
        format!("{:?}", path.display().to_string())
    );
}

#[test]
fn a_copy_goes_when_its_changes_are_safe() {
    let (mut s, state) = server_with_state("cleanup-state");
    let path = temp_path("cleanup.txt");
    std::fs::write(&path, "saved\n").unwrap();
    open(&mut s, &path);
    // Saved.
    type_keys(&mut s, "x");
    s.eval("(autosave-all!)").unwrap();
    assert_eq!(copies(&state).len(), 1);
    type_keys(&mut s, ":w<ret>");
    assert!(copies(&state).is_empty());
    // Undone back to the saved text, when the next copy would be made.
    type_keys(&mut s, "x");
    s.eval("(autosave-all!)").unwrap();
    type_keys(&mut s, "u");
    s.eval("(autosave-all!)").unwrap();
    assert!(copies(&state).is_empty());
    // Thrown away with :e!.
    type_keys(&mut s, "x");
    s.eval("(autosave-all!)").unwrap();
    type_keys(&mut s, ":e!<ret>");
    s.eval("(autosave-check!)").unwrap();
    assert!(copies(&state).is_empty());
    // Killed.
    type_keys(&mut s, "x");
    s.eval("(autosave-all!)").unwrap();
    type_keys(&mut s, ":bd!<ret>");
    assert!(copies(&state).is_empty());
}

#[test]
fn an_emptied_unnamed_buffer_loses_its_copy() {
    let (mut s, state) = server_with_state("emptied-state");
    type_keys(&mut s, ":enew<ret>ia note<esc>");
    s.eval("(autosave-all!)").unwrap();
    assert_eq!(copies(&state).len(), 1);
    type_keys(&mut s, "dd");
    s.eval("(autosave-check!)").unwrap();
    assert!(copies(&state).is_empty());
}

#[test]
fn qa_bang_throws_the_copies_away_but_kill_server_keeps_them() {
    let (mut s, state) = server_with_state("quit-state");
    let path = temp_path("quit.txt");
    std::fs::write(&path, "saved\n").unwrap();
    open(&mut s, &path);
    type_keys(&mut s, "x");
    s.eval("(autosave-all!)").unwrap();
    // :kill-server doesn't ask about unsaved changes; the copy stays, to
    // be offered once this imp is gone.
    type_keys(&mut s, ":kill-server<ret>");
    assert!(s.should_quit());
    assert_eq!(copies(&state), vec![copy_name(&path)]);
    s.clear_quit();
    // :qa (no !) refuses and keeps it.
    type_keys(&mut s, ":qa<ret>");
    assert!(!s.should_quit());
    assert_eq!(copies(&state).len(), 1);
    type_keys(&mut s, ":qa!<ret>");
    assert!(s.should_quit());
    assert!(copies(&state).is_empty());
}

#[test]
fn a_renamed_buffers_copy_follows_it() {
    let (mut s, state) = server_with_state("rename-state");
    let from = temp_path("before.txt");
    let to = temp_path("after.txt");
    let _ = std::fs::remove_file(&to);
    std::fs::write(&from, "saved\n").unwrap();
    open(&mut s, &from);
    type_keys(&mut s, "x");
    s.eval("(autosave-all!)").unwrap();
    assert_eq!(copies(&state), vec![copy_name(&from)]);
    s.eval(&format!(
        "(begin (rename-file! {f:?} {t:?}) (buffer-renamed! {f:?} {t:?}))",
        f = from.display().to_string(),
        t = to.display().to_string()
    ))
    .unwrap();
    assert!(copies(&state).is_empty());
    s.eval("(autosave-all!)").unwrap();
    assert_eq!(copies(&state), vec![copy_name(&to)]);
}

#[test]
fn a_daemon_clients_qa_bang_keeps_the_copies() {
    let (mut s, state) = server_with_state("daemon-quit-state");
    let path = temp_path("daemon-quit.txt");
    std::fs::write(&path, "saved\n").unwrap();
    open(&mut s, &path);
    type_keys(&mut s, "x");
    s.eval("(autosave-all!)").unwrap();
    // In a daemon :qa! only detaches the client: the buffers live on, and
    // their copies stay in use.
    s.eval("(define (daemon?) #t)").unwrap();
    type_keys(&mut s, ":qa!<ret>");
    assert!(s.should_quit());
    assert_eq!(copies(&state), vec![copy_name(&path)]);
}
