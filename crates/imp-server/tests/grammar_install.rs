//! :TSInstallGrammar, against a local git repository of the fixture
//! grammar (tests/fixtures/imptest), with the real git and cc. One test,
//! in order: it changes $CC, which the whole process shares.

mod common;

use common::*;
use std::path::{Path, PathBuf};
use std::process::Command;

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .expect("git runs");
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_dir(&entry.path(), &target);
        } else {
            std::fs::copy(entry.path(), target).unwrap();
        }
    }
}

/// A repository with the fixture grammar at `subdir` ("" for its root),
/// and its first commit.
fn repo(name: &str, subdir: &str) -> (PathBuf, String) {
    let dir = temp_path(name);
    let _ = std::fs::remove_dir_all(&dir);
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/imptest");
    copy_dir(&fixture, &dir.join(subdir));
    git(&dir, &["init", "-q", "-b", "main"]);
    git(&dir, &["config", "user.name", "Ada Lovelace"]);
    git(&dir, &["config", "user.email", "ada@example.com"]);
    git(&dir, &["config", "commit.gpgsign", "false"]);
    git(&dir, &["add", "."]);
    git(&dir, &["commit", "-q", "-m", "Add the grammar"]);
    let rev = git(&dir, &["rev-parse", "HEAD"]);
    (dir, rev)
}

/// The last message, once one starting with `grammar NAME:` says it's
/// installed or failed.
fn wait_for_install(s: &mut imp_server::Server, name: &str) -> String {
    for _ in 0..600 {
        s.pump(std::time::Duration::from_millis(50));
        let said = s.eval("(car *messages*)").unwrap();
        if said.starts_with(&format!("\"grammar {name}:"))
            && (said.contains("installed") || said.contains("failed"))
        {
            return said;
        }
    }
    panic!(
        "grammar {name} never finished: {}\nstatus: {}",
        s.eval("*messages*").unwrap(),
        status_row(s)
    );
}

fn face_on(s: &mut imp_server::Server, file: &str, text: &str, word: &str) -> String {
    let path = temp_path(file);
    std::fs::write(&path, text).unwrap();
    type_keys(s, &format!(":e {}<ret>", path.display()));
    let at = text.find(word).unwrap();
    s.eval(&format!(
        "(list-find (lambda (f) (starts-with? f \"syntax.\")) (reverse (faces-at {at})))"
    ))
    .unwrap()
}

fn libraries(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .filter(|n| n.ends_with(".so"))
        .collect();
    names.sort();
    names
}

#[test]
fn installing_grammars() {
    let mut s = server("");
    let grammars = temp_path("grammars");
    let _ = std::fs::remove_dir_all(&grammars);
    s.eval(&format!(
        "(set! *grammars-dir* {:?})",
        grammars.display().to_string()
    ))
    .unwrap();
    s.eval(
        "(define-major-mode! 'imptest-mode 'prog-mode '(\"imptest\") (lambda () void))
         (define-mode-language! 'imptest-mode \"imptest\")",
    )
    .unwrap();

    // Nothing declared.
    type_keys(&mut s, ":TSInstallGrammar<ret>");
    assert_eq!(
        s.eval("(car *messages*)").unwrap(),
        "\"every declared grammar is built\""
    );
    type_keys(&mut s, ":TSInstallGrammar nope<ret>");
    assert!(s
        .eval("(car *messages*)")
        .unwrap()
        .contains("no grammar nope is declared"));

    // The bare command installs what's declared and not built.
    let (url, rev) = repo("imptest-repo", "");
    s.eval(&format!(
        "(define-grammar! \"imptest\" {:?} {rev:?})",
        url.display().to_string()
    ))
    .unwrap();
    // Declared but not built: a buffer says how to build it, and nothing
    // is cloned.
    let early = temp_path("early.imptest");
    std::fs::write(&early, "let x = 1;\n").unwrap();
    type_keys(&mut s, &format!(":e {}<ret>", early.display()));
    assert_eq!(s.eval("(buffer-language)").unwrap(), "#false");
    assert_eq!(
        s.eval("(car *messages*)").unwrap(),
        "\"grammar imptest isn't built: run :TSInstallGrammar\""
    );
    assert!(!grammars.join("imptest").exists());
    type_keys(&mut s, ":TSInstallGrammar<ret>");
    assert_eq!(
        wait_for_install(&mut s, "imptest"),
        "\"grammar imptest: installed\""
    );
    assert_eq!(libraries(&grammars), [format!("imptest@{rev}.so")]);
    // The buffer open meanwhile is highlighted, without reopening it.
    assert_eq!(s.eval("(buffer-language)").unwrap(), "\"imptest\"");
    assert_eq!(
        s.eval("(list-find (lambda (f) (starts-with? f \"syntax.\")) (reverse (faces-at 0)))")
            .unwrap(),
        "\"syntax.keyword\""
    );
    // It said what it was doing.
    for step in [format!("fetching {rev}..."), "building...".to_string()] {
        let said = format!("(and (member \"grammar imptest: {step}\" *messages*) #t)");
        assert_eq!(s.eval(&said).unwrap(), "#true", "{step}");
    }
    assert_eq!(
        face_on(&mut s, "a.imptest", "let x = 1;\n", "let"),
        "\"syntax.keyword\""
    );
    type_keys(&mut s, ":TSInstallGrammar<ret>");
    assert_eq!(
        s.eval("(car *messages*)").unwrap(),
        "\"every declared grammar is built\""
    );

    // A new revision: fetched, built, and the old revision's library
    // removed. Its highlights make numbers strings.
    std::fs::write(
        url.join("queries/highlights.scm"),
        "[\"fn\" \"let\"] @keyword\n(number) @string\n",
    )
    .unwrap();
    git(&url, &["commit", "-q", "-am", "Numbers are strings"]);
    let rev2 = git(&url, &["rev-parse", "HEAD"]);
    s.eval(&format!(
        "(define-grammar! \"imptest\" {:?} {rev2:?})",
        url.display().to_string()
    ))
    .unwrap();
    type_keys(&mut s, ":TSInstallGrammar<ret>");
    assert_eq!(
        wait_for_install(&mut s, "imptest"),
        "\"grammar imptest: installed\""
    );
    assert_eq!(libraries(&grammars), [format!("imptest@{rev2}.so")]);
    assert_eq!(
        face_on(&mut s, "b.imptest", "let x = 1;\n", "1"),
        "\"syntax.string\""
    );
    // Named, it rebuilds one that's built.
    type_keys(&mut s, ":TSInstallGrammar imptest<ret>");
    assert_eq!(
        wait_for_install(&mut s, "imptest"),
        "\"grammar imptest: installed\""
    );

    // A grammar in a subdirectory of its repository, by branch name.
    let (url, _) = repo("imptest-sub-repo", "grammars/imptest");
    s.eval(&format!(
        "(define-grammar! \"imptest\" {:?} \"main\" \"grammars/imptest\")",
        url.display().to_string()
    ))
    .unwrap();
    let _ = std::fs::remove_dir_all(grammars.join("imptest"));
    type_keys(&mut s, ":TSInstallGrammar imptest<ret>");
    assert_eq!(
        wait_for_install(&mut s, "imptest"),
        "\"grammar imptest: installed\""
    );
    assert_eq!(libraries(&grammars), ["imptest@main.so"]);
    assert_eq!(
        face_on(&mut s, "c.imptest", "let x = 1;\n", "1"),
        "\"syntax.number\""
    );

    // Without a C compiler, it says so.
    std::env::set_var("CC", "no-such-cc");
    type_keys(&mut s, ":TSInstallGrammar imptest<ret>");
    let said = wait_for_install(&mut s, "imptest");
    std::env::remove_var("CC");
    assert!(
        said.contains("no C compiler: no-such-cc isn't installed"),
        "{said}"
    );

    // A repository that isn't there.
    s.eval("(define-grammar! \"missing\" \"/no/such/repo\" \"main\")")
        .unwrap();
    type_keys(&mut s, ":TSInstallGrammar missing<ret>");
    let said = wait_for_install(&mut s, "missing");
    assert!(said.contains("failed"), "{said}");

    // A new server that declares a built grammar has it at once. (Last:
    // the editor is per thread, so `s` is done with.)
    let mut fresh = server("");
    fresh
        .eval(&format!(
            "(set! *grammars-dir* {:?})
             (define-grammar! \"imptest\" {:?} \"main\" \"grammars/imptest\")
             (define-major-mode! 'imptest-mode 'prog-mode '(\"imptest\") (lambda () void))
             (define-mode-language! 'imptest-mode \"imptest\")",
            grammars.display().to_string(),
            url.display().to_string()
        ))
        .unwrap();
    assert_eq!(
        face_on(&mut fresh, "d.imptest", "let x = 1;\n", "let"),
        "\"syntax.keyword\""
    );
}
