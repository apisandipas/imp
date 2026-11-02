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
    s.eval("(autosave-all!)").unwrap();
    // A crash: the copy is left by an imp that is gone (a pid that can't
    // run), and the buffer's changes are lost. (One server per thread:
    // the editor is thread-local; tests/crash_recovery.rs has the rest.)
    let name = |pid: String| format!("{}#{pid}", path.display().to_string().replace('/', "%"));
    let copies = state.join("autosave");
    std::fs::rename(
        copies.join(name(std::process::id().to_string())),
        copies.join(name("999999999".into())),
    )
    .unwrap();
    type_keys(&mut s, ":bd!<ret>");
    open(&mut s, &path);
    assert_eq!(s.text(), "saved\n");
    assert!(s.status().contains(":recover"), "{}", s.status());
    type_keys(&mut s, ":recover<ret>");
    assert_eq!(s.text(), "savedunsaved\n");
}

#[cfg(unix)]
#[test]
fn autosave_copies_are_private() {
    use std::os::unix::fs::PermissionsExt;
    let state = temp_path("private-state");
    let _ = std::fs::remove_dir_all(&state);
    // A state directory left too open by an older imp is tightened.
    std::fs::create_dir_all(state.join("autosave")).unwrap();
    std::fs::set_permissions(
        state.join("autosave"),
        std::fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    let path = temp_path("shared.txt");
    std::fs::write(&path, "public\n").unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
    let mut s = server("");
    s.eval(&format!(
        "(set-option! 'state-directory \"{}\")",
        state.display()
    ))
    .unwrap();
    open(&mut s, &path);
    type_keys(&mut s, "Asecret<esc>");
    s.eval("(autosave-all!)").unwrap();
    let mode = |p: &std::path::Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
    let copies: Vec<_> = std::fs::read_dir(state.join("autosave"))
        .unwrap()
        .map(|e| e.unwrap().path())
        .collect();
    assert_eq!(copies.len(), 1);
    assert_eq!(
        std::fs::read_to_string(&copies[0]).unwrap(),
        "publicsecret\n"
    );
    assert_eq!(mode(&copies[0]), 0o600);
    assert_eq!(mode(&state.join("autosave")), 0o700);
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

#[test]
fn file_errors_show_their_message() {
    let mut s = server("text\n");
    // A primitive's error raises with its message as written, unquoted.
    assert_eq!(
        s.eval("(error-text (lambda () (read-file \"/nonexistent/imp\")))")
            .unwrap(),
        "\"/nonexistent/imp: No such file or directory (os error 2)\""
    );
    assert_eq!(s.eval("(error-text (lambda () 1))").unwrap(), "#false");
    // A file that can't be read doesn't open, and says why.
    let dir = temp_path("unreadable-dir");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.display().to_string();
    assert_eq!(
        s.eval(&format!("(open-file-buffer! {path:?})")).unwrap(),
        "#false"
    );
    assert!(s.status().starts_with(&path), "{}", s.status());
    assert_eq!(s.text(), "text\n");
    // A save that fails says so, and the buffer stays modified.
    let file = temp_path("not-a-dir.txt");
    std::fs::write(&file, "").unwrap();
    s.eval(&format!(
        "(set-buffer-path! {:?})",
        file.join("x").display().to_string()
    ))
    .unwrap();
    type_keys(&mut s, "x:w<ret>");
    assert!(s.status().starts_with("save failed: "), "{}", s.status());
    assert_eq!(s.eval("(buffer-modified?)").unwrap(), "#true");
}
