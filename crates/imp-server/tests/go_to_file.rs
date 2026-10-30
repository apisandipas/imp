//! Go to file (runtime/gofile.scm, docs/specs/go-to-file.md): gf opens
//! the file named under the cursor.

mod common;

use common::*;
use std::path::{Path, PathBuf};

/// A fresh directory holding `files` (path, text), a project (it has a
/// .git) unless a path says otherwise.
fn tree(name: &str, files: &[(&str, &str)]) -> PathBuf {
    let root = temp_path(name);
    let _ = std::fs::remove_dir_all(&root);
    for (path, text) in files {
        let p = root.join(path);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        if path.ends_with('/') {
            std::fs::create_dir_all(&p).unwrap();
        } else {
            std::fs::write(p, text).unwrap();
        }
    }
    root
}

/// A server with `path` open.
fn open(path: &Path) -> imp_server::Server {
    let mut s = server("");
    s.eval(&format!("(open-file! {:?})", path.display().to_string()))
        .unwrap();
    s
}

fn current_path(s: &mut imp_server::Server) -> String {
    s.eval("(buffer-path)")
        .unwrap()
        .trim_matches('"')
        .to_string()
}

#[test]
fn a_name_from_the_buffers_directory() {
    let root = tree(
        "gf-dir",
        &[
            ("a/notes.txt", "see other.txt here\n"),
            ("a/other.txt", "x\n"),
        ],
    );
    let mut s = open(&root.join("a/notes.txt"));
    type_keys(&mut s, "wgf");
    assert!(current_path(&mut s).ends_with("a/other.txt"));
    // The jump is kept: C-o comes back.
    type_keys(&mut s, "<C-o>");
    assert!(current_path(&mut s).ends_with("a/notes.txt"));
}

#[test]
fn quotes_end_the_name_and_endings_are_tried() {
    let root = tree(
        "gf-ts",
        &[
            (".git/", ""),
            (
                "src/lib/form.ts",
                "import { x } from \"./form-context\";\nimport \"./lib\";\n",
            ),
            ("src/lib/form-context.ts", "export const x = 1;\n"),
            ("src/lib/lib/index.tsx", "\n"),
        ],
    );
    let mut s = open(&root.join("src/lib/form.ts"));
    // Anywhere on the string.
    type_keys(&mut s, "f\"lllgf");
    assert_eq!(
        current_path(&mut s),
        root.join("src/lib/form-context.ts").display().to_string()
    );
    // On the quote, the next name on the line; a directory gives its
    // index, with an ending.
    type_keys(&mut s, "<C-o>j0f\"gf");
    assert!(current_path(&mut s).ends_with("src/lib/lib/index.tsx"));
}

#[test]
fn then_the_project_root_but_not_for_dot_slash() {
    let root = tree(
        "gf-root",
        &[
            (".git/", ""),
            ("README.md", "top\n"),
            ("docs/guide.txt", "README.md\n./README.md\n"),
        ],
    );
    let mut s = open(&root.join("docs/guide.txt"));
    type_keys(&mut s, "gf");
    assert_eq!(
        current_path(&mut s),
        root.join("README.md").display().to_string()
    );
    // ./ means the buffer's directory, and only that.
    type_keys(&mut s, "<C-o>jgf");
    assert!(current_path(&mut s).ends_with("docs/guide.txt"));
    assert_eq!(s.status(), "Can't find file \"./README.md\" in path");
}

#[test]
fn nothing_found_opens_nothing() {
    let root = tree("gf-none", &[("a.txt", "nowhere.txt  ;\n")]);
    let mut s = open(&root.join("a.txt"));
    let buffers = s.eval("(length (buffer-list))").unwrap();
    type_keys(&mut s, "gf");
    assert_eq!(s.status(), "Can't find file \"nowhere.txt\" in path");
    assert_eq!(s.eval("(length (buffer-list))").unwrap(), buffers);
    // Past the last name on the line there is none.
    type_keys(&mut s, "$gf");
    assert_eq!(s.status(), "No file name under cursor");
}

#[test]
fn a_directory_with_no_index_opens_in_the_file_browser() {
    let root = tree("gf-browse", &[("a.txt", "sub\n"), ("sub/one.txt", "1\n")]);
    let mut s = open(&root.join("a.txt"));
    type_keys(&mut s, "gf");
    let dir = s.eval("(buffer-local 'dired-dir)").unwrap();
    assert!(dir.trim_matches('"').ends_with("sub"), "{dir}");
}

#[test]
fn the_selection_is_the_name_in_visual_mode() {
    let root = tree(
        "gf-visual",
        &[("a.txt", "x my file.txt y\n"), ("my file.txt", "!\n")],
    );
    let mut s = open(&root.join("a.txt"));
    type_keys(&mut s, "wv10lgf");
    assert!(current_path(&mut s).ends_with("my file.txt"));
    assert_eq!(s.eval("*mode*").unwrap(), "normal");
}

#[test]
fn home_and_environment_variables_are_expanded() {
    assert_eq!(
        server("")
            .eval(r#"(equal? (expand-env "$HOME/a/${HOME}b$") (string-append (getenv "HOME") "/a/" (getenv "HOME") "b$"))"#)
            .unwrap(),
        "#true"
    );
    let mut s = server("");
    assert_eq!(
        s.eval(r#"(equal? (expand-env "$IMP_NO_SUCH_VAR/x") "/x")"#)
            .unwrap(),
        "#true"
    );
}

#[test]
fn only_script_modes_add_endings() {
    let root = tree("gf-plain", &[("a.txt", "b\n"), ("b.ts", "\n")]);
    let mut s = open(&root.join("a.txt"));
    type_keys(&mut s, "gf");
    assert_eq!(s.status(), "Can't find file \"b\" in path");
    // Set by hand, any buffer has them.
    type_keys(&mut s, ":setlocal sua=.ts<ret>gf");
    assert!(current_path(&mut s).ends_with("b.ts"));
}
