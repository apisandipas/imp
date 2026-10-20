//! The file browser (runtime/dired.scm): a directory as editable text.

mod common;

use common::*;
use std::path::{Path, PathBuf};

/// A directory with sub/ (holding inner.txt), a.txt, b.txt and .hidden.
fn tree(name: &str) -> PathBuf {
    let dir = temp_path(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("sub")).unwrap();
    std::fs::write(dir.join("sub/inner.txt"), "inner\n").unwrap();
    std::fs::write(dir.join("a.txt"), "aaa\n").unwrap();
    std::fs::write(dir.join("b.txt"), "bbb\n").unwrap();
    std::fs::write(dir.join(".hidden"), "").unwrap();
    dir
}

fn browse(dir: &Path) -> imp_server::Server {
    let mut s = server("");
    type_keys(&mut s, &format!(":Explore {}<ret>", dir.display()));
    s
}

fn read(dir: &Path, name: &str) -> String {
    std::fs::read_to_string(dir.join(name)).unwrap_or_else(|e| panic!("{name}: {e}"))
}

#[test]
fn lists_and_navigates() {
    let dir = tree("dired-list");
    let mut s = browse(&dir);
    assert_eq!(s.text(), "sub/\na.txt\nb.txt\n");
    assert_eq!(s.eval("(major-mode)").unwrap(), "dired-mode");
    type_keys(&mut s, "g.");
    assert_eq!(s.text(), "sub/\n.hidden\na.txt\nb.txt\n");
    type_keys(&mut s, "g.");
    // Into sub/ and back up, landing on it.
    type_keys(&mut s, "<ret>");
    assert_eq!(s.text(), "inner.txt\n");
    type_keys(&mut s, "-");
    assert_eq!(s.text(), "sub/\na.txt\nb.txt\n");
    assert_eq!(s.eval("(current-line)").unwrap(), "0");
    // A file opens.
    type_keys(&mut s, "j<ret>");
    assert_eq!(s.text(), "aaa\n");
    // :e on a directory browses it.
    type_keys(&mut s, &format!(":e {}<ret>", dir.join("sub").display()));
    assert_eq!(s.text(), "inner.txt\n");
}

#[test]
fn rename_delete_and_create() {
    let dir = tree("dired-edit");
    let mut s = browse(&dir);
    // a.txt -> c.txt, delete b.txt, add new.txt and dir2/ and deep/x.txt.
    type_keys(
        &mut s,
        "jcwc<esc>jddonew.txt<esc>odir2/<esc>odeep/x.txt<esc>",
    );
    type_keys(&mut s, ":w<ret>");
    let popup = s.frame().text_rows().join("\n");
    for want in [
        "rename  a.txt → c.txt",
        "delete  b.txt",
        "create  new.txt",
        "create  dir2/",
        "create  deep/x.txt",
    ] {
        assert!(popup.contains(want), "{want:?} in\n{popup}");
    }
    assert!(
        s.status().contains("Make these 5 changes?"),
        "{}",
        s.status()
    );
    type_keys(&mut s, "y");
    assert_eq!(read(&dir, "c.txt"), "aaa\n");
    assert!(!dir.join("a.txt").exists() && !dir.join("b.txt").exists());
    assert_eq!(read(&dir, "new.txt"), "");
    assert!(dir.join("dir2").is_dir());
    assert_eq!(read(&dir, "deep/x.txt"), "");
    assert_eq!(s.text(), "deep/\ndir2/\nsub/\nc.txt\nnew.txt\n");
    assert_eq!(s.eval("(buffer-modified?)").unwrap(), "#false");
}

#[test]
fn saying_no_changes_nothing() {
    let dir = tree("dired-no");
    let mut s = browse(&dir);
    type_keys(&mut s, "jdd:w<ret>n");
    assert!(dir.join("a.txt").exists());
    assert_eq!(s.eval("(buffer-modified?)").unwrap(), "#true");
    // :e! puts the listing back.
    type_keys(&mut s, ":e!<ret>");
    assert_eq!(s.text(), "sub/\na.txt\nb.txt\n");
}

#[test]
fn moving_or_swapping_lines_is_safe() {
    let dir = tree("dired-move");
    let mut s = browse(&dir);
    // dd then p moves a line: no change at all.
    type_keys(&mut s, "jddp:w<ret>");
    assert!(s.status().contains("no changes"), "{}", s.status());
    assert_eq!(read(&dir, "a.txt"), "aaa\n");
    // O opens a line above an entry without stealing its identity.
    type_keys(&mut s, "ggjOfresh.txt<esc>:w<ret>");
    assert!(s
        .frame()
        .text_rows()
        .join("\n")
        .contains("create  fresh.txt"));
    assert!(!s.frame().text_rows().join("\n").contains("rename"));
    type_keys(&mut s, "y");
    assert_eq!(read(&dir, "a.txt"), "aaa\n");
    assert_eq!(read(&dir, "fresh.txt"), "");
    // Swapping two names reads as no change (both lines read as entries).
    type_keys(&mut s, ":e!<ret>/a.txt<ret>ccb.txt<esc>jcca.txt<esc>");
    assert_eq!(s.text(), "sub/\nb.txt\na.txt\nfresh.txt\n");
    type_keys(&mut s, ":w<ret>");
    assert!(s.status().contains("no changes"), "{}", s.status());
    // cc on a name keeps its identity: a rename, typed from the start.
    type_keys(&mut s, "/b.txt<ret>ccbee.txt<esc>Inew-<esc>:w<ret>");
    assert!(s
        .frame()
        .text_rows()
        .join("\n")
        .contains("rename  b.txt → new-bee.txt"));
    type_keys(&mut s, "y");
    assert_eq!(read(&dir, "new-bee.txt"), "bbb\n");
}

#[test]
fn deleting_the_last_lines() {
    let dir = tree("dired-last");
    let mut s = browse(&dir);
    // dG from a.txt deletes a.txt and b.txt, not sub.
    type_keys(&mut s, "jdG:w<ret>");
    let popup = s.frame().text_rows().join("\n");
    assert!(
        popup.contains("delete  a.txt") && popup.contains("delete  b.txt"),
        "{popup}"
    );
    assert!(!popup.contains("delete  sub"), "{popup}");
    type_keys(&mut s, "y");
    assert!(dir.join("sub").is_dir());
    assert!(!dir.join("a.txt").exists() && !dir.join("b.txt").exists());
    // Deleting a directory line deletes it and what's in it.
    type_keys(&mut s, "ggdd:w<ret>");
    assert!(s
        .frame()
        .text_rows()
        .join("\n")
        .contains("delete  sub/ and everything in it"));
    type_keys(&mut s, "y");
    assert!(!dir.join("sub").exists());
}

#[test]
fn a_rename_onto_an_existing_file_fails() {
    let dir = tree("dired-clash");
    let mut s = browse(&dir);
    type_keys(&mut s, "jccb.txt<esc>:w<ret>y");
    // b.txt is still there (renamed through a temporary name, then refused).
    assert_eq!(read(&dir, "b.txt"), "bbb\n");
    assert!(s.status().contains("already exists"), "{}", s.status());
}

#[test]
fn a_failed_rename_reports_one_problem() {
    let dir = tree("dired-gone");
    let mut s = browse(&dir);
    // a.txt goes behind the browser's back, so renaming it fails at once.
    std::fs::remove_file(dir.join("a.txt")).unwrap();
    type_keys(&mut s, "jccc.txt<esc>:w<ret>y");
    let status = s.status();
    assert!(!status.contains(';'), "one problem, not three: {status}");
    assert!(!status.contains(".imp-rename"), "{status}");
    assert!(!dir.join("c.txt").exists());
}

/// The screen row showing `name`, trimmed.
fn row_with(s: &mut imp_server::Server, name: &str) -> String {
    let rows = s.frame().text_rows();
    rows.iter()
        .find(|r| r.trim_end().ends_with(name))
        .unwrap_or_else(|| panic!("{name} in {rows:#?}"))
        .trim()
        .to_string()
}

#[test]
fn details_show_beside_each_entry_and_cannot_be_edited() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tree("dired-details");
    std::fs::write(dir.join("b.txt"), vec![b'x'; 3000]).unwrap();
    std::fs::set_permissions(dir.join("a.txt"), std::fs::Permissions::from_mode(0o600)).unwrap();
    let mut s = browse(&dir);
    s.set_size(100, 20);
    let a = row_with(&mut s, "a.txt");
    assert!(a.starts_with("-rw-------     4 "), "{a}");
    let b = row_with(&mut s, "b.txt");
    assert!(b.contains(" 2.9K "), "{b}");
    assert!(row_with(&mut s, "sub/").starts_with("drwx"));
    // Not text: the buffer holds only the names, and the cursor starts on
    // the name.
    assert_eq!(s.text(), "sub/\na.txt\nb.txt\n");
    // They follow their entry: delete sub/'s line, and a.txt keeps its own.
    type_keys(&mut s, "dd");
    assert!(row_with(&mut s, "a.txt").starts_with("-rw-------"));
    // A renamed line keeps its details; a new one has none.
    type_keys(&mut s, "ciwrenamed<esc>");
    assert!(row_with(&mut s, "renamed.txt").starts_with("-rw-------"));
    type_keys(&mut s, "Gonew.txt<esc>");
    assert_eq!(row_with(&mut s, "new.txt"), "new.txt");
    // ( hides them.
    type_keys(&mut s, "uuu(");
    assert_eq!(row_with(&mut s, "a.txt"), "a.txt");
    type_keys(&mut s, "(");
    assert!(row_with(&mut s, "a.txt").starts_with("-rw-------"));
}

#[test]
fn file_times_and_sizes_read_as_ls_shows_them() {
    let mut s = server("");
    let now = 1_760_000_000; // 2025-10-09
    for (expr, want) in [
        (
            format!("(format-file-time {now} {now} 0)"),
            "\"Oct  9 08:53\"",
        ),
        (
            format!("(format-file-time {now} {now} 7200)"),
            "\"Oct  9 10:53\"",
        ),
        (format!("(format-file-time 0 {now} 0)"), "\"Jan  1  1970\""),
        (
            format!("(format-file-time 951782400 {now} 0)"),
            "\"Feb 29  2000\"",
        ),
        ("(format-file-size 512)".into(), "\"512\""),
        ("(format-file-size 4096)".into(), "\"4.0K\""),
        ("(format-file-size 12000)".into(), "\"12K\""),
        ("(format-file-size 1572864)".into(), "\"1.5M\""),
    ] {
        assert_eq!(s.eval(&expr).unwrap(), want, "{expr}");
    }
}

fn dired_buffers(s: &mut imp_server::Server) -> usize {
    s.eval("(length (filter (lambda (id) (with-buffer id (lambda () (eq? (major-mode) 'dired-mode)))) (buffer-list)))")
        .unwrap()
        .parse()
        .unwrap()
}

#[test]
fn going_between_directories_reuses_the_buffer_and_q_closes_it() {
    let dir = tree("dired-reuse");
    let mut s = server("");
    type_keys(&mut s, &format!(":e {}<ret>", dir.join("a.txt").display()));
    type_keys(&mut s, ":Explore<ret>");
    type_keys(&mut s, "gg<ret>");
    assert_eq!(s.text(), "inner.txt\n");
    type_keys(&mut s, "-");
    assert_eq!(s.text(), "sub/\na.txt\nb.txt\n");
    assert_eq!(dired_buffers(&mut s), 1);
    // A browser with unsaved edits stays.
    type_keys(&mut s, "Gonew.txt<esc>gg<ret>");
    assert_eq!(dired_buffers(&mut s), 2);
    // q goes back to the file the browser was opened from.
    type_keys(&mut s, "q");
    assert_eq!(dired_buffers(&mut s), 1);
    assert_eq!(s.text(), "aaa\n");
    type_keys(&mut s, ":Explore<ret>");
    assert_eq!(s.text(), "sub/\na.txt\nb.txt\nnew.txt\n");
    type_keys(&mut s, "q");
    assert_eq!(dired_buffers(&mut s), 1);
    assert!(s.status().contains("unsaved"), "{}", s.status());
    type_keys(&mut s, ":e!<ret>q");
    assert_eq!(dired_buffers(&mut s), 0);
    assert_eq!(s.text(), "aaa\n");
    // With the option off, each directory keeps its buffer.
    s.eval("(set-option! 'dired-reuse-buffer #f)").unwrap();
    type_keys(&mut s, ":Explore<ret>gg<ret>");
    assert_eq!(dired_buffers(&mut s), 2);
}
