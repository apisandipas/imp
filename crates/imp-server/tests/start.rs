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

    // The recent files are a section to ask for.
    s.eval("(set-option! 'start-sections '(recent-files actions))")
        .unwrap();
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
    type_keys(&mut s, ":start-screen<ret>A!<esc>");
    assert_eq!(s.text(), "hello!");
    type_keys(&mut s, ":start-screen<ret>n");
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

/// The start screen's rows, trimmed at the end.
fn rows(s: &mut imp_server::Server) -> Vec<String> {
    s.frame()
        .text_rows()
        .into_iter()
        .map(|r| r.trim_end().to_string())
        .collect()
}

#[test]
fn a_banner_over_the_actions_and_a_footer() {
    let mut s = server("");
    s.set_size(100, 40);
    s.eval("(imp-start-screen)").unwrap();
    let r = rows(&mut s);
    let banner = r
        .iter()
        .position(|l| l.contains("██ ███    ███ ██████"))
        .expect("banner");
    // The actions, label left and key right, keys lined up, a blank line
    // between each.
    let find = r
        .iter()
        .position(|l| l.trim_start().starts_with("Find file"))
        .unwrap();
    let recent = r
        .iter()
        .position(|l| l.trim_start().starts_with("Recent files"))
        .unwrap();
    assert!(banner < recent && recent + 2 == find, "{r:#?}");
    assert!(
        r[recent].ends_with(" r") && r[find].ends_with(" f"),
        "{r:#?}"
    );
    assert_eq!(r[recent].len(), r[find].len());
    assert!(r[recent + 1].is_empty());
    // The footer, centred under them.
    let version = s.eval("(imp-version)").unwrap();
    let footer = format!("imp {}", version.trim_matches('"'));
    assert!(r.iter().any(|l| l.trim() == footer), "{r:#?}");
    // The cursor on the first action; <ret> runs it, a key runs its own.
    assert_eq!(s.eval("(car (line-item))").unwrap(), "\"r\"");
    type_keys(&mut s, "n");
    assert_eq!(s.eval("(major-mode)").unwrap(), "fundamental-mode");
}

#[test]
fn without_room_the_banner_goes_and_comes_back() {
    let mut s = server("");
    s.set_size(20, 40);
    s.eval("(imp-start-screen)").unwrap();
    let r = rows(&mut s);
    assert!(!r.iter().any(|l| l.contains("████")), "{r:#?}");
    assert!(r.iter().any(|l| l.trim() == "imp"), "{r:#?}");
    // Short: the banner goes, then the blank lines between entries.
    s.handle(imp_core::ClientMsg::Resize {
        width: 100,
        height: 18,
    });
    let r = rows(&mut s);
    assert!(!r.iter().any(|l| l.contains("████")), "{r:#?}");
    let find = r
        .iter()
        .position(|l| l.trim_start().starts_with("Find file"))
        .unwrap();
    assert!(
        r[find - 1].trim_start().starts_with("Recent files"),
        "{r:#?}"
    );
    // Back to full size: redrawn with the banner.
    s.handle(imp_core::ClientMsg::Resize {
        width: 100,
        height: 40,
    });
    assert!(rows(&mut s).iter().any(|l| l.contains("████")));
}

#[test]
fn init_scm_changes_the_banner_sections_and_actions() {
    let mut s = server("");
    s.set_size(100, 50);
    s.eval(
        r#"(set-option! 'start-banner '("HELLO"))
           (define-start-action! "t" "Terminal" 'terminal)
           (define-start-action! "f" "Find a file" 'find-file)
           (remove-start-action! "q")
           (define *ran* #f)
           (define-start-section! 'mine "Mine" (lambda () (list (start-entry "x" "Mark it" (lambda () (set! *ran* #t))) (start-entry "r" "Taken key" (lambda () #f)))))
           (set-option! 'start-sections '(mine actions))"#,
    )
    .unwrap();
    s.eval("(imp-start-screen)").unwrap();
    let r = rows(&mut s);
    assert!(r.iter().any(|l| l.trim() == "HELLO"), "{r:#?}");
    // Your section first, under its heading.
    let mine = r.iter().position(|l| l.trim() == "Mine").unwrap();
    let mark = r
        .iter()
        .position(|l| l.trim_start().starts_with("Mark it"))
        .unwrap();
    let recent = r
        .iter()
        .position(|l| l.trim_start().starts_with("Recent files"))
        .unwrap();
    assert!(mine < mark && mark < recent, "{r:#?}");
    // f replaced in place of the old one, but last; t added; q gone.
    let text = r.join("\n");
    assert!(
        text.contains("Find a file") && !text.contains("Find file"),
        "{text}"
    );
    assert!(r
        .iter()
        .any(|l| l.trim_start().starts_with("Terminal") && l.ends_with(" t")));
    assert!(!text.contains("Quit"));
    // A key used twice is the first entry's (here, the section's, which
    // comes first); the later one shows without it.
    let taken = r
        .iter()
        .find(|l| l.trim_start().starts_with("Taken key"))
        .unwrap();
    assert!(taken.ends_with(" r"), "{taken}");
    assert!(!r[recent].ends_with(" r"), "{}", r[recent]);
    type_keys(&mut s, "x");
    assert_eq!(s.eval("*ran*").unwrap(), "#true");
}

#[test]
fn recent_files_and_projects_show_as_many_as_asked() {
    let mut s = server("");
    s.set_size(100, 60);
    let dir = temp_path("start-counts");
    std::fs::create_dir_all(&dir).unwrap();
    for n in 0..4 {
        let f = dir.join(format!("f{n}.txt"));
        std::fs::write(&f, "x\n").unwrap();
        type_keys(&mut s, &format!(":e {}<ret>", f.display()));
    }
    s.eval(
        "(set-option! 'start-sections '(recent-files actions)) (set-option! 'start-recent-files 2)",
    )
    .unwrap();
    s.eval("(imp-start-screen)").unwrap();
    let r = rows(&mut s);
    let files = r
        .iter()
        .filter(|l| l.contains("f") && l.contains(".txt"))
        .count();
    assert_eq!(files, 2, "{r:#?}");
    // The newest, on 1 and 2.
    assert!(
        r.iter().any(|l| l.contains("f3.txt") && l.ends_with(" 1")),
        "{r:#?}"
    );
    assert!(
        r.iter().any(|l| l.contains("f2.txt") && l.ends_with(" 2")),
        "{r:#?}"
    );
}
