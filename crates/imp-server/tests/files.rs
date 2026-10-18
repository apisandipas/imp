//! Files on disk: line endings, encodings, outside changes, backups and
//! autosave.

mod common;

use common::*;

fn open(s: &mut imp_server::Server, path: &std::path::Path) {
    type_keys(s, &format!(":e {}<ret>", path.display()));
}

#[test]
fn crlf_files_keep_their_line_endings() {
    let path = temp_path("crlf.txt");
    std::fs::write(&path, "one\r\ntwo\r\n").unwrap();
    let mut s = server("");
    open(&mut s, &path);
    assert_eq!(s.text(), "one\ntwo\n");
    assert_eq!(s.eval("(option 'fileformat)").unwrap(), "\"dos\"");
    type_keys(&mut s, "Athree<esc>:w<ret>");
    assert_eq!(std::fs::read(&path).unwrap(), b"onethree\r\ntwo\r\n");
    type_keys(&mut s, ":set ff=unix<ret>:w<ret>");
    assert_eq!(std::fs::read(&path).unwrap(), b"onethree\ntwo\n");
}

#[test]
fn latin1_files_round_trip() {
    let path = temp_path("latin1.txt");
    std::fs::write(&path, b"caf\xE9\n").unwrap();
    let mut s = server("");
    open(&mut s, &path);
    assert_eq!(s.text(), "café\n");
    assert_eq!(s.eval("(option 'fileencoding)").unwrap(), "\"latin1\"");
    type_keys(&mut s, "A!<esc>:w<ret>");
    assert_eq!(std::fs::read(&path).unwrap(), b"caf\xE9!\n");
}

#[test]
fn write_refuses_over_outside_changes() {
    let path = temp_path("outside.txt");
    std::fs::write(&path, "mine\n").unwrap();
    let mut s = server("");
    open(&mut s, &path);
    type_keys(&mut s, "x");
    // Someone else writes the file (a different size, so the change is
    // seen even within the same second).
    std::fs::write(&path, "theirs!\n").unwrap();
    type_keys(&mut s, ":w<ret>");
    assert!(s.status().contains("changed on disk"), "{}", s.status());
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "theirs!\n");
    type_keys(&mut s, ":w!<ret>");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "ine\n");
}

#[test]
fn unmodified_buffers_reload_outside_changes() {
    let path = temp_path("autoread.txt");
    std::fs::write(&path, "old\n").unwrap();
    let mut s = server("");
    open(&mut s, &path);
    std::fs::write(&path, "newer\n").unwrap();
    s.eval("(check-all-buffers!)").unwrap();
    assert_eq!(s.text(), "newer\n");
    assert!(s.status().contains("reloaded"));
    // With changes of its own, the buffer is kept and you are told.
    type_keys(&mut s, "x");
    std::fs::write(&path, "newest!\n").unwrap();
    s.eval("(check-all-buffers!)").unwrap();
    assert_eq!(s.text(), "ewer\n");
    assert!(s.status().contains("changed on disk"));
}

#[test]
fn backup_keeps_the_previous_version() {
    let path = temp_path("backup.txt");
    std::fs::write(&path, "v1\n").unwrap();
    let mut s = server("");
    open(&mut s, &path);
    type_keys(&mut s, ":set backup<ret>xx:w<ret>");
    let backup = path.with_file_name("backup.txt~");
    assert_eq!(std::fs::read_to_string(backup).unwrap(), "v1\n");
}

#[test]
fn autosave_and_recover() {
    let state = temp_path("state");
    let path = temp_path("precious.txt");
    std::fs::write(&path, "saved\n").unwrap();
    let mut s = server("");
    s.eval(&format!(
        "(set-option! 'state-directory \"{}\")",
        state.display()
    ))
    .unwrap();
    open(&mut s, &path);
    type_keys(&mut s, "Aunsaved<esc>");
    // File times are in whole seconds: make the copy clearly newer.
    std::thread::sleep(std::time::Duration::from_millis(1100));
    s.eval("(autosave-all!)").unwrap();
    // Losing the changes (as a crash would), then opening the file again,
    // finds the copy. (One server per thread: the editor is thread-local.)
    type_keys(&mut s, ":bd!<ret>");
    open(&mut s, &path);
    assert_eq!(s.text(), "saved\n");
    assert!(s.status().contains(":recover"), "{}", s.status());
    type_keys(&mut s, ":recover<ret>");
    assert_eq!(s.text(), "savedunsaved\n");
    // Saving removes the copy.
    type_keys(&mut s, ":w<ret>");
    assert_eq!(s.eval("(recoverable?)").unwrap(), "#false");
}

#[test]
fn saves_are_atomic_and_keep_symlinks() {
    let real = temp_path("real.txt");
    let link = temp_path("link.txt");
    std::fs::write(&real, "a\n").unwrap();
    let _ = std::fs::remove_file(&link);
    #[cfg(unix)]
    std::os::unix::fs::symlink(&real, &link).unwrap();
    let mut s = server("");
    open(&mut s, &link);
    type_keys(&mut s, "x:w<ret>");
    assert_eq!(std::fs::read_to_string(&real).unwrap(), "\n");
    assert!(std::fs::symlink_metadata(&link)
        .unwrap()
        .file_type()
        .is_symlink());
}
