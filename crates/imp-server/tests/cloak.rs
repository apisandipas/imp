//! The cloak package (packages/cloak): values in .env files drawn as a
//! mask, the text left as it is. It comes with imp but is off until
//! init.scm asks for it.

mod common;

use common::*;
use std::path::PathBuf;

/// An 80x10 screen with no line numbers and the package loaded.
fn screen() -> imp_server::Server {
    let mut s = server("");
    s.set_size(80, 10);
    s.eval("(set-option! 'number #f) (set-option! 'relativenumber #f) (use-package! 'cloak)")
        .unwrap();
    s
}

/// A fresh directory holding `files`, each (name, text).
fn dir_with(name: &str, files: &[(&str, &str)]) -> PathBuf {
    let dir = temp_path(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    for (file, text) in files {
        std::fs::write(dir.join(file), text).unwrap();
    }
    dir
}

fn open(s: &mut imp_server::Server, path: &std::path::Path) {
    type_keys(s, &format!(":e {}<ret>", path.display()));
}

const ENV: &str = "API_KEY=sk-123\nexport TOKEN=\"abc\"\n# plain\n";

#[test]
fn it_is_off_until_used() {
    let mut s = server("");
    assert_eq!(s.eval("(command-proc 'cloak-mode)").unwrap(), "#false");
    s.eval("(use-package! 'cloak)").unwrap();
    assert_ne!(s.eval("(command-proc 'cloak-mode)").unwrap(), "#false");
    type_keys(&mut s, ":list-packages<ret>");
    let rows = s.frame().text_rows().join("\n");
    assert!(
        rows.contains("cloak") && rows.contains("built-in"),
        "{rows}"
    );
}

#[test]
fn env_files_draw_their_values_masked_and_keep_the_text() {
    let dir = dir_with("cloak-env", &[(".env", ENV)]);
    let mut s = screen();
    open(&mut s, &dir.join(".env"));
    let rows = s.frame().text_rows();
    assert_eq!(
        &rows[..3],
        ["API_KEY=******", "export TOKEN=*****", "# plain"],
        "{rows:?}"
    );
    // y yanks the real value, and p puts it back as it was.
    type_keys(&mut s, "yyGp");
    assert_eq!(s.text(), format!("{ENV}API_KEY=sk-123\n"));
    assert_eq!(s.frame().text_rows()[3], "API_KEY=******");
    // :w saves the real text.
    type_keys(&mut s, "dd:w<ret>");
    assert_eq!(std::fs::read_to_string(dir.join(".env")).unwrap(), ENV);
    // SPC t c shows it plain, and again masks it.
    type_keys(&mut s, " tc");
    assert_eq!(s.frame().text_rows()[0], "API_KEY=sk-123");
    type_keys(&mut s, " tc");
    assert_eq!(s.frame().text_rows()[0], "API_KEY=******");
}

#[test]
fn only_files_matching_the_patterns_cloak_themselves() {
    let files = [
        (".env.local", "K=secret\n"),
        ("prod.env", "K=secret\n"),
        (".envrc", "K=secret\n"),
        ("notes.txt", "K=secret\n"),
        (".environment", "K=secret\n"),
        ("env.txt", "K=secret\n"),
    ];
    let dir = dir_with("cloak-patterns", &files);
    let mut s = screen();
    for (name, _) in files {
        open(&mut s, &dir.join(name));
        let masked = s.frame().text_rows()[0] == "K=******";
        let wanted = [".env.local", "prod.env", ".envrc"].contains(&name);
        assert_eq!(masked, wanted, "{name}");
    }
    // The patterns are the user's to change.
    s.eval("(set-option! 'cloak-file-patterns '(\"*.txt\"))")
        .unwrap();
    // For buffers opened after: env.txt, open already, opens again.
    open(&mut s, &dir.join("env.txt"));
    type_keys(&mut s, ":bd<ret>");
    open(&mut s, &dir.join("env.txt"));
    assert_eq!(s.frame().text_rows()[0], "K=******");
    // And what is masked: here YAML's values too.
    s.eval(r#"(set-option! 'cloak-pattern "[=:] *\\(.\\+\\)")"#)
        .unwrap();
    type_keys(&mut s, "ccurl: http://x<esc>");
    assert_eq!(s.frame().text_rows()[0], "url: ********");
    assert_eq!(
        s.eval("(cloak-glob-match? \".env.*\" \".env\")").unwrap(),
        "#false"
    );
    assert_eq!(
        s.eval("(cloak-glob-match? \"?.env\" \"a.env\")").unwrap(),
        "#true"
    );
}

#[test]
fn a_line_can_be_revealed_for_a_look() {
    let dir = dir_with("cloak-reveal", &[(".env", ENV)]);
    let mut s = screen();
    open(&mut s, &dir.join(".env"));
    // cloak-reveal-line shows the cursor's line until the cursor leaves.
    type_keys(&mut s, ":cloak-reveal-line<ret>");
    let rows = s.frame().text_rows();
    assert_eq!(
        &rows[..2],
        ["API_KEY=sk-123", "export TOKEN=*****"],
        "{rows:?}"
    );
    type_keys(&mut s, "j");
    let rows = s.frame().text_rows();
    assert_eq!(
        &rows[..2],
        ["API_KEY=******", "export TOKEN=*****"],
        "{rows:?}"
    );
    // cloak-reveal-cursor-line shows whichever line the cursor is on,
    // and the options take effect at once.
    s.eval("(set-option! 'cloak-reveal-cursor-line #t) (set-option! 'cloak-mask-char \"#\")")
        .unwrap();
    let rows = s.frame().text_rows();
    assert_eq!(
        &rows[..2],
        ["API_KEY=######", "export TOKEN=\"abc\""],
        "{rows:?}"
    );
    // With the mode off there is nothing to reveal.
    type_keys(&mut s, " tc:cloak-reveal-line<ret>");
    assert!(s.status().contains("cloak-mode is off"), "{}", s.status());
}

#[test]
fn cloaked_values_stay_out_of_completion() {
    let dir = dir_with(
        "cloak-words",
        &[(".env", "K=supersecretvalue\n"), ("a.txt", "")],
    );
    let mut s = screen();
    open(&mut s, &dir.join(".env"));
    open(&mut s, &dir.join("a.txt"));
    let menu = |s: &mut imp_server::Server| s.eval("(map car *menu-matches*)").unwrap();
    type_keys(&mut s, "isupe");
    s.keys(&["C-n"]);
    assert!(
        !menu(&mut s).contains("supersecretvalue"),
        "{}",
        menu(&mut s)
    );
    type_keys(&mut s, "<C-e><esc>u");
    // Turned off, its words are offered again.
    open(&mut s, &dir.join(".env"));
    type_keys(&mut s, " tc");
    open(&mut s, &dir.join("a.txt"));
    type_keys(&mut s, "isupe<C-n>");
    assert!(
        menu(&mut s).contains("supersecretvalue"),
        "{}",
        menu(&mut s)
    );
}
