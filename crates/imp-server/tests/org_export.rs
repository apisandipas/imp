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
    s.eval("(org-export! \"html\")").unwrap();
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
        s.eval(&format!("(org-export! \"{name}\")")).unwrap();
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
    s.eval("(org-export! \"pdf\")").unwrap();
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
    s.eval("(org-export! \"pdf\")").unwrap();
    wait_for_message(&mut s, "exported notes.pdf");
    assert_eq!(args(&dir)[5], "--pdf-engine=lualatex");
}

#[test]
fn failures_say_why() {
    let dir = setup("export-fail");
    let mut s = visiting(&dir);
    std::fs::write(dir.join("fail"), "").unwrap();
    s.eval("(org-export! \"html\")").unwrap();
    wait_for_message(&mut s, "export failed: see *org-export*");
    type_keys(&mut s, ":b *org-export*<ret>");
    assert_eq!(s.text(), "pandoc: it went wrong\n");

    let mut s = visiting(&dir);
    s.eval("(set! *org-export-pandoc* \"imp-no-such-pandoc\")")
        .unwrap();
    s.eval("(org-export! \"html\")").unwrap();
    assert_eq!(message(&mut s), "org-export needs pandoc");

    let mut s = server("* One\n");
    s.eval("(use-package! 'org-export)").unwrap();
    s.eval("(org-export! \"html\")").unwrap();
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
    s.eval("(org-export! \"html\")").unwrap();
    wait_for_message(&mut s, "exported notes.html");
    let html = std::fs::read_to_string(dir.join("notes.html")).unwrap();
    assert!(html.contains("<title>Notes</title>"), "{html}");
    assert!(html.contains(">One</h1>"), "{html}");
}
