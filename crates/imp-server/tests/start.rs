//! The start screen and recent files (runtime/start.scm), and Tab
//! completion on the command line (vim.scm).

mod common;

use common::*;

fn last_row(s: &mut imp_server::Server) -> String {
    s.frame().text_rows().last().unwrap().trim_end().to_string()
}

#[test]
fn the_start_screen_lists_recent_files_and_opens_them() {
    let dir = temp_path("start-files");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("one.txt"), "one\n").unwrap();
    std::fs::write(dir.join("two.txt"), "two\n").unwrap();
    let mut s = server("");
    s.eval(&format!(
        "(set-option! 'state-directory {:?})",
        temp_path("start-state").display().to_string()
    ))
    .unwrap();
    type_keys(
        &mut s,
        &format!(":e {}<ret>", dir.join("one.txt").display()),
    );
    type_keys(
        &mut s,
        &format!(":e {}<ret>", dir.join("two.txt").display()),
    );
    // Newest first.
    let recent = s.eval("(recent-files)").unwrap();
    assert!(
        recent.find("two.txt").unwrap() < recent.find("one.txt").unwrap(),
        "{recent}"
    );

    s.eval("(imp-start-screen)").unwrap();
    let text = s.text();
    assert!(text.contains("Recent files"), "{text}");
    assert!(text.contains("Find file"));
    assert!(s.eval("(buffer-read-only?)").unwrap() == "#true");
    // 2 is the second most recent.
    type_keys(&mut s, "2");
    assert_eq!(s.text(), "one\n");
    // The start screen isn't a recent file.
    assert!(!s.eval("(recent-files)").unwrap().contains("*start*"));
}

#[test]
fn typing_on_the_start_screen_goes_to_an_empty_buffer() {
    let mut s = server("");
    s.eval("(imp-start-screen)").unwrap();
    type_keys(&mut s, "ihello<esc>");
    assert_eq!(s.text(), "hello");
    type_keys(&mut s, ":start<ret>A!<esc>");
    assert_eq!(s.text(), "hello!");
    type_keys(&mut s, ":start<ret>n");
    assert_eq!(s.text(), "");
    // Turned off, nothing shows.
    let mut s = server("");
    s.eval("(set-option! 'start-screen #f)").unwrap();
    s.eval("(imp-start-screen)").unwrap();
    assert_eq!(s.text(), "");
}

#[test]
fn tab_completes_files_and_steps_through_them() {
    let dir = temp_path("wild");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("sub")).unwrap();
    std::fs::write(dir.join("alpha.txt"), "").unwrap();
    std::fs::write(dir.join("alps.txt"), "").unwrap();
    std::fs::write(dir.join(".hidden"), "").unwrap();
    let base = dir.display().to_string();
    let mut s = server("x\n");
    s.set_size(200, 24);
    // One match: completed whole; a directory gets its slash.
    type_keys(&mut s, &format!(":e {base}/s<tab>"));
    assert_eq!(last_row(&mut s), format!(":e {base}/sub/"));
    // Several: listed as you type; <tab> puts in each in turn.
    type_keys(&mut s, &format!("<esc>:e {base}/a"));
    let rows = s.frame().text_rows();
    assert!(
        rows.iter().any(|r| r.contains("alpha.txt")) && rows.iter().any(|r| r.contains("alps.txt")),
        "{rows:?}"
    );
    type_keys(&mut s, "<tab>");
    assert_eq!(last_row(&mut s), format!(":e {base}/alpha.txt"));
    type_keys(&mut s, "<tab>");
    assert_eq!(last_row(&mut s), format!(":e {base}/alps.txt"));
    s.keys(&["<s-tab>"]);
    assert_eq!(last_row(&mut s), format!(":e {base}/alpha.txt"));
    // C-e puts back what was typed.
    s.keys(&["C-e"]);
    assert_eq!(last_row(&mut s), format!(":e {base}/a"));
    // Vim's wildmenu, with the menu off: as far as they agree first.
    s.eval("(set-option! 'cmdline-completion #f)").unwrap();
    type_keys(&mut s, &format!("<esc>:e {base}/a<tab>"));
    assert_eq!(last_row(&mut s), format!(":e {base}/alp"));
    type_keys(&mut s, "<tab>");
    assert_eq!(last_row(&mut s), format!(":e {base}/alpha.txt"));
    s.eval("(set-option! 'cmdline-completion #t)").unwrap();
    // Hidden files only when asked for.
    type_keys(&mut s, &format!("<esc>:e {base}/<tab>"));
    assert!(!s.frame().text_rows().iter().any(|r| r.contains(".hidden")));
    type_keys(&mut s, &format!("<esc>:e {base}/.<tab>"));
    assert_eq!(last_row(&mut s), format!(":e {base}/.hidden"));
    // Typing closes the list.
    type_keys(&mut s, "<esc>");
    assert!(!s.frame().text_rows().iter().any(|r| r.contains("alps.txt")));
}

#[test]
fn tab_completes_options_buffers_and_themes() {
    let mut s = server("x\n");
    type_keys(&mut s, ":set tabs<tab>");
    assert_eq!(last_row(&mut s), ":set tabstop");
    type_keys(&mut s, "<esc>:set nowra<tab>");
    assert_eq!(last_row(&mut s), ":set nowrap");
    type_keys(&mut s, "<esc>:colorscheme grub<tab>");
    assert_eq!(last_row(&mut s), ":colorscheme grub");
    type_keys(&mut s, "<esc>:colorscheme gru<tab>");
    assert_eq!(last_row(&mut s), ":colorscheme gruvbox-dark");
    type_keys(&mut s, "<esc>:b No<tab>");
    assert_eq!(last_row(&mut s), ":b [No Name]");
    type_keys(&mut s, "<esc>:noh<tab>");
    assert_eq!(last_row(&mut s), ":nohlsearch");
}

#[test]
fn k_without_a_language_server_says_so() {
    let mut s = server("x\n");
    type_keys(&mut s, "K");
    assert!(s.status().contains("language server"), "{}", s.status());
}
