//! Each top-level name in the runtime belongs to one file.
//!
//! Evaluating a runtime file's definitions again (`eval-defun` on them,
//! `:source`, `imp-load-file`) turns each define into a `set!` of the
//! binding every file sees. So if two files define the same name,
//! re-evaluating one gives the other its meaning too (#127).

mod common;

use common::*;

/// Evaluates every top-level `define` in runtime file `name` again, one
/// at a time, as `eval-defun` on each would.
fn redefine_all(s: &mut imp_server::Server, name: &str) {
    let path = format!("{}/../../runtime/{name}", env!("CARGO_MANIFEST_DIR"));
    s.eval(&format!(
        r#"(let ([port (open-input-string (read-file "{path}"))])
             (let loop ([form (read port)])
               (unless (eof-object? form)
                 (when (and (pair? form) (eq? (car form) 'define))
                   (with-handler (lambda (e) #f) (imp-eval-form form)))
                 (loop (read port))))
             #t)"#
    ))
    .unwrap();
}

#[test]
fn redefining_a_runtime_file_leaves_other_files_helpers_alone() {
    // Re-evaluating vim.scm mustn't make which-key pad keys with zeros...
    let mut s = server("0x0009\n");
    redefine_all(&mut s, "vim.scm");
    let key = s
        .eval(r#"(car (cadr (car (which-key-table (list (cons "a" "x"))))))"#)
        .unwrap();
    assert_eq!(key, "\"  a\"");
    // ...and re-evaluating leader.scm mustn't make C-a pad hex with spaces.
    redefine_all(&mut s, "leader.scm");
    s.keys(&["C-a"]);
    assert_eq!(s.text(), "0x000a\n");
}

/// Names more than one file defines on purpose: core.scm's placeholders,
/// which vim.scm replaces.
const OVERRIDES: &[&str] = &["imp-init", "imp-handle-key"];

/// The name each top-level `(define ...)` line in `source` defines, as
/// the server reads them to keep definitions redefinable.
fn defined_names(source: &str) -> Vec<String> {
    source
        .lines()
        .filter_map(|line| line.strip_prefix("(define "))
        .map(|rest| {
            rest.trim_start_matches('(')
                .chars()
                .take_while(|c| !c.is_whitespace() && *c != '(' && *c != ')')
                .collect::<String>()
        })
        .filter(|name| !name.is_empty())
        .collect()
}

#[test]
fn no_two_runtime_files_define_the_same_name() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let mut files: Vec<std::path::PathBuf> = std::fs::read_dir(root.join("runtime"))
        .unwrap()
        .map(|e| e.unwrap().path())
        .collect();
    for package in std::fs::read_dir(root.join("packages")).unwrap() {
        let dir = package.unwrap().path();
        if let Some(name) = dir.file_name().and_then(|n| n.to_str()) {
            files.push(dir.join(format!("{name}.scm")));
        }
    }
    let mut owner = std::collections::HashMap::new();
    let mut clashes = Vec::new();
    for file in files
        .iter()
        .filter(|f| f.extension().is_some_and(|e| e == "scm") && f.exists())
    {
        let short = file.strip_prefix(&root).unwrap().display().to_string();
        for name in defined_names(&std::fs::read_to_string(file).unwrap()) {
            match owner.get(&name) {
                Some(first) if first != &short && !OVERRIDES.contains(&name.as_str()) => {
                    clashes.push(format!("{name}: {first} and {short}"))
                }
                Some(_) => {}
                None => {
                    owner.insert(name, short.clone());
                }
            }
        }
    }
    clashes.sort();
    assert!(
        clashes.is_empty(),
        "defined in two files:\n{}",
        clashes.join("\n")
    );
}
