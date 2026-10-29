//! The org-export package (packages/org-export), against a fake pandoc
//! that records what it was asked to do, and the real one if installed.

mod common;

use common::*;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// A directory holding notes.org and a fake pandoc. The fake writes its
/// arguments, stdin and working directory beside itself, then "made"
/// to its --output file or stdout; it fails when a file `fail` is there.
fn setup(name: &str) -> PathBuf {
    let dir = temp_path(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("notes.org"), "#+TITLE: Notes\n* One\ntext\n").unwrap();
    let fake = dir.join("pandoc");
    std::fs::write(
        &fake,
        format!(
            r#"#!/bin/sh
d='{}'
printf '%s\n' "$@" > "$d/args"
cat > "$d/input"
pwd > "$d/cwd"
if [ -e "$d/fail" ]; then echo "pandoc: it went wrong" >&2; exit 1; fi
out=
while [ $# -gt 0 ]; do [ "$1" = --output ] && out="$2"; shift; done
if [ -n "$out" ]; then echo made > "$out"; else echo made; fi
"#,
            dir.display()
        ),
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    dir
}

/// A server with the package loaded and the fake pandoc in `dir`,
/// visiting notes.org there.
fn visiting(dir: &Path) -> imp_server::Server {
    let mut s = server("");
    s.eval("(use-package! 'org-export)").unwrap();
    s.eval(&format!(
        "(set! *org-export-pandoc* \"{}\")",
        dir.join("pandoc").display()
    ))
    .unwrap();
    type_keys(
        &mut s,
        &format!(":e {}<ret>", dir.join("notes.org").display()),
    );
    s
}

fn message(s: &mut imp_server::Server) -> String {
    s.frame().text_rows().last().unwrap().trim_end().to_string()
}

/// Waits for the message line to be `want`, as pandoc runs.
fn wait_for_message(s: &mut imp_server::Server, want: &str) {
    let start = Instant::now();
    loop {
        s.pump(Duration::from_millis(50));
        if message(s) == want {
            return;
        }
        assert!(
            start.elapsed() < Duration::from_secs(5),
            "wanted {want:?}, got {:?}",
            message(s)
        );
    }
}

fn args(dir: &Path) -> Vec<String> {
    std::fs::read_to_string(dir.join("args"))
        .unwrap()
        .lines()
        .map(String::from)
        .collect()
}

#[test]
fn exports_the_buffer_beside_its_file() {
    let dir = setup("export-html");
    let mut s = visiting(&dir);
    // Unsaved edits are exported too.
    type_keys(&mut s, "Gotyped<esc>");
    s.eval("(org-export! \"html\" 'file '())").unwrap();
    wait_for_message(&mut s, "exported notes.html");
    assert_eq!(
        std::fs::read_to_string(dir.join("notes.html")).unwrap(),
        "made\n"
    );
    assert_eq!(
        args(&dir),
        [
            "--from",
            "org",
            "--to",
            "html",
            "--standalone",
            "--output",
            dir.join("notes.html").to_str().unwrap()
        ]
    );
    assert_eq!(
        std::fs::read_to_string(dir.join("input")).unwrap(),
        "#+TITLE: Notes\n* One\ntext\ntyped\n"
    );
    // pandoc runs from the file's directory, so relative links resolve.
    let cwd = std::fs::read_to_string(dir.join("cwd")).unwrap();
    assert_eq!(
        Path::new(cwd.trim()).canonicalize().unwrap(),
        dir.canonicalize().unwrap()
    );
}

#[test]
fn each_format_has_its_pandoc_format_and_extension() {
    let dir = setup("export-formats");
    let mut s = visiting(&dir);
    for (name, to, ext) in [
        ("markdown", "gfm", "md"),
        ("docx", "docx", "docx"),
        ("latex", "latex", "tex"),
        ("odt", "odt", "odt"),
        ("text", "plain", "txt"),
    ] {
        s.eval(&format!("(org-export! \"{name}\" 'file '())"))
            .unwrap();
        wait_for_message(&mut s, &format!("exported notes.{ext}"));
        let a = args(&dir);
        assert_eq!(a[3], to, "{name}");
        assert!(dir.join(format!("notes.{ext}")).exists(), "{name}");
    }
}

#[test]
fn pdf_uses_the_engine_option_and_extra_args_go_to_every_run() {
    let dir = setup("export-pdf");
    let mut s = visiting(&dir);
    s.eval("(set-option! 'org-export-pandoc-args \"--toc\")")
        .unwrap();
    s.eval("(org-export! \"pdf\" 'file '())").unwrap();
    wait_for_message(&mut s, "exported notes.pdf");
    assert_eq!(
        args(&dir)[..7],
        [
            "--from",
            "org",
            "--to",
            "latex",
            "--standalone",
            "--pdf-engine=xelatex",
            "--toc"
        ]
    );
    s.eval("(set-option! 'org-export-pdf-engine \"lualatex\")")
        .unwrap();
    s.eval("(org-export! \"pdf\" 'file '())").unwrap();
    wait_for_message(&mut s, "exported notes.pdf");
    assert_eq!(args(&dir)[5], "--pdf-engine=lualatex");
}

#[test]
fn failures_say_why() {
    let dir = setup("export-fail");
    let mut s = visiting(&dir);
    std::fs::write(dir.join("fail"), "").unwrap();
    s.eval("(org-export! \"html\" 'file '())").unwrap();
    wait_for_message(&mut s, "export failed: see *org-export*");
    type_keys(&mut s, ":b *org-export*<ret>");
    assert_eq!(s.text(), "pandoc: it went wrong\n");

    let mut s = visiting(&dir);
    s.eval("(set! *org-export-pandoc* \"imp-no-such-pandoc\")")
        .unwrap();
    s.eval("(org-export! \"html\" 'file '())").unwrap();
    assert_eq!(message(&mut s), "org-export needs pandoc");

    let mut s = server("* One\n");
    s.eval("(use-package! 'org-export)").unwrap();
    s.eval("(org-export! \"html\" 'file '())").unwrap();
    assert_eq!(message(&mut s), "the buffer has no file to export beside");
}

#[test]
fn the_real_pandoc_makes_html() {
    if std::process::Command::new("pandoc")
        .arg("--version")
        .output()
        .is_err()
    {
        return;
    }
    let dir = setup("export-real");
    let mut s = server("");
    s.eval("(use-package! 'org-export)").unwrap();
    type_keys(
        &mut s,
        &format!(":e {}<ret>", dir.join("notes.org").display()),
    );
    s.eval("(org-export! \"html\" 'file '())").unwrap();
    wait_for_message(&mut s, "exported notes.html");
    let html = std::fs::read_to_string(dir.join("notes.html")).unwrap();
    assert!(html.contains("<title>Notes</title>"), "{html}");
    assert!(html.contains(">One</h1>"), "{html}");
}

#[test]
fn text_formats_export_into_a_buffer() {
    let dir = setup("export-buffer");
    let mut s = visiting(&dir);
    s.eval("(org-export! \"markdown\" 'buffer '())").unwrap();
    let start = Instant::now();
    while s.eval("(buffer-name)").unwrap() != "\"*Org Export: Markdown*\"" {
        s.pump(Duration::from_millis(50));
        assert!(start.elapsed() < Duration::from_secs(5), "no export buffer");
    }
    assert_eq!(s.text(), "made\n");
    // No file is written, and pandoc writes to stdout.
    assert!(!dir.join("notes.md").exists());
    assert!(!args(&dir).contains(&"--output".to_string()));
    assert_eq!(s.eval("(major-mode)").unwrap(), "markdown-mode");

    // A buffer with no file can go to a buffer, but not to a file.
    let mut s = server("* One\n");
    s.eval("(use-package! 'org-export)").unwrap();
    s.eval(&format!(
        "(set! *org-export-pandoc* \"{}\")",
        dir.join("pandoc").display()
    ))
    .unwrap();
    s.eval("(org-export! \"html\" 'buffer '())").unwrap();
    let start = Instant::now();
    while s.eval("(buffer-name)").unwrap() != "\"*Org Export: HTML*\"" {
        s.pump(Duration::from_millis(50));
        assert!(start.elapsed() < Duration::from_secs(5), "no export buffer");
    }

    let mut s = visiting(&dir);
    s.eval("(org-export! \"pdf\" 'buffer '())").unwrap();
    assert_eq!(message(&mut s), "PDF can't be exported to a buffer");
}

#[test]
fn open_writes_the_file_then_opens_it() {
    let dir = setup("export-open");
    let opener = dir.join("open");
    std::fs::write(
        &opener,
        format!("#!/bin/sh\necho \"$1\" > '{}/opened'\n", dir.display()),
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&opener, std::fs::Permissions::from_mode(0o755)).unwrap();
    let mut s = visiting(&dir);
    s.eval(&format!(
        "(set! *org-export-open* \"{}\")",
        opener.display()
    ))
    .unwrap();
    s.eval("(org-export! \"html\" 'open '())").unwrap();
    wait_for_message(&mut s, "exported notes.html");
    let start = Instant::now();
    while !dir.join("opened").exists() {
        s.pump(Duration::from_millis(50));
        assert!(start.elapsed() < Duration::from_secs(5), "not opened");
    }
    assert_eq!(
        std::fs::read_to_string(dir.join("opened")).unwrap().trim(),
        dir.join("notes.html").to_str().unwrap()
    );
}

fn input(dir: &Path) -> String {
    std::fs::read_to_string(dir.join("input")).unwrap()
}

#[test]
fn subtree_only_exports_the_heading_at_the_cursor() {
    let dir = setup("export-subtree");
    std::fs::write(
        dir.join("notes.org"),
        "#+TITLE: Notes\n#+AUTHOR: Ada\n* One\nfirst\n* Two :work:\nsecond\n** Deeper\nthird\n* Three\n",
    )
    .unwrap();
    let mut s = visiting(&dir);
    type_keys(&mut s, "6G");
    s.eval("(org-export! \"html\" 'file '(subtree))").unwrap();
    wait_for_message(&mut s, "exported notes.html");
    // Its title is the document's, and its children move up a level.
    assert_eq!(
        input(&dir),
        "#+AUTHOR: Ada\n#+TITLE: Two\nsecond\n* Deeper\nthird\n"
    );

    type_keys(&mut s, "1G");
    s.eval("(org-export! \"html\" 'file '(subtree))").unwrap();
    assert_eq!(message(&mut s), "not under a heading");
}

#[test]
fn body_only_leaves_out_the_surrounding_document() {
    let dir = setup("export-body");
    let mut s = visiting(&dir);
    s.eval("(org-export! \"html\" 'file '(body))").unwrap();
    wait_for_message(&mut s, "exported notes.html");
    assert!(!args(&dir).contains(&"--standalone".to_string()));
    assert_eq!(input(&dir), "#+TITLE: Notes\n* One\ntext\n");
}

#[test]
fn visible_only_leaves_out_closed_folds() {
    let dir = setup("export-visible");
    std::fs::write(
        dir.join("notes.org"),
        "* One\nfirst\n* Two\nsecond\nmore\n* Three\nthird\n",
    )
    .unwrap();
    let mut s = visiting(&dir);
    // Close Two's subtree with <tab> on its heading.
    type_keys(&mut s, "3G<tab>");
    s.eval("(org-export! \"html\" 'file '(visible))").unwrap();
    wait_for_message(&mut s, "exported notes.html");
    assert_eq!(input(&dir), "* One\nfirst\n* Two\n* Three\nthird\n");

    // With subtree only too, from inside the closed fold's heading.
    s.eval("(org-export! \"html\" 'file '(subtree visible))")
        .unwrap();
    wait_for_message(&mut s, "exported notes.html");
    assert_eq!(input(&dir), "#+TITLE: Two\n");
}

fn screen(s: &mut imp_server::Server) -> String {
    s.frame().text_rows().join("\n")
}

#[test]
fn the_menu_picks_a_format_then_what_to_do() {
    let dir = setup("export-menu");
    let mut s = visiting(&dir);
    type_keys(&mut s, "<C-c><C-e>");
    let menu = screen(&mut s);
    for label in [
        "Export",
        "HTML",
        "PDF",
        "Markdown",
        "Word",
        "LaTeX",
        "OpenDocument",
        "Text",
        "subtree only",
    ] {
        assert!(menu.contains(label), "{label} in {menu}");
    }
    type_keys(&mut s, "h");
    let menu = screen(&mut s);
    assert!(menu.contains("Export: HTML"), "{menu}");
    assert!(menu.contains("to buffer"), "{menu}");
    type_keys(&mut s, "h");
    wait_for_message(&mut s, "exported notes.html");
    assert!(dir.join("notes.html").exists());

    // SPC m e opens it too; PDF has no buffer entry.
    type_keys(&mut s, " mep");
    let menu = screen(&mut s);
    assert!(menu.contains("Export: PDF"), "{menu}");
    assert!(!menu.contains("to buffer"), "{menu}");
    type_keys(&mut s, "<esc>");

    // ODT's key is o, so O writes and opens it.
    type_keys(&mut s, "<C-c><C-e>o");
    let menu = screen(&mut s);
    assert!(menu.contains("to file and open"), "{menu}");
    type_keys(&mut s, "o");
    wait_for_message(&mut s, "exported notes.odt");
}

#[test]
fn the_menus_toggles_flip_and_show_in_its_title() {
    let dir = setup("export-menu-toggles");
    let mut s = visiting(&dir);
    type_keys(&mut s, "<C-c><C-e><C-b><C-s>");
    let menu = screen(&mut s);
    assert!(menu.contains("Export (subtree only, body only)"), "{menu}");
    // Pressed again, it goes off.
    type_keys(&mut s, "<C-s>");
    assert!(screen(&mut s).contains("Export (body only)"));
    type_keys(&mut s, "hh");
    wait_for_message(&mut s, "exported notes.html");
    assert!(!args(&dir).contains(&"--standalone".to_string()));
    // Each menu starts with them off.
    type_keys(&mut s, "<C-c><C-e>");
    assert!(!screen(&mut s).contains("body only)"));
    type_keys(&mut s, "hh");
    wait_for_message(&mut s, "exported notes.html");
    assert!(args(&dir).contains(&"--standalone".to_string()));
}

#[test]
fn org_export_exports_without_the_menu() {
    let dir = setup("export-ex");
    let mut s = visiting(&dir);
    // The format completes after the command's name.
    type_keys(&mut s, ":org-export mark<tab><ret>");
    wait_for_message(&mut s, "exported notes.md");
    // Without one, the menu opens, as from C-c C-e.
    feed(&mut s, ":org-export<ret>");
    assert!(
        screen(&mut s).contains("OpenDocument"),
        "{}",
        screen(&mut s)
    );
    feed(&mut s, "<esc>");
    feed(&mut s, ":OrgExport html<ret>");
    assert!(message(&mut s).contains("not an editor command: OrgExport"));
}
