//! KDL config (runtime/config.scm, src/kdl.rs). Most tests need the `kdl`
//! feature: cargo test --features kdl.

mod common;

use common::*;

#[test]
#[cfg(not(feature = "kdl"))]
fn without_the_feature_it_says_so() {
    let mut s = server("text\n");
    assert_eq!(s.eval("(kdl-available?)").unwrap(), "#false");
    let problems = s
        .eval(r#"(apply-kdl-config! "theme \"one-dark\"")"#)
        .unwrap();
    assert!(problems.contains("without the kdl feature"), "{problems}");
}

#[cfg(feature = "kdl")]
mod with_kdl {
    use super::*;
    use imp_core::Buffer;
    use imp_server::{Options, Server};

    #[test]
    fn parses_into_lists() {
        let mut s = server("");
        let out = s
            .eval(r#"(kdl-parse "a 1 2.5 \"x\" #true #null k=\"v\"\nb {\n  c\n}")"#)
            .unwrap();
        assert_eq!(
            out,
            r#"(("a" (1 2.5 "x" #true null) (("k" "v")) () 1) ("b" () () (("c" () () () 3)) 2))"#
        );
        let err = s.eval(r#"(kdl-parse "a\nb \"unclosed")"#).unwrap_err();
        assert!(err.contains("line 2"), "{err}");
    }

    const CONFIG: &str = r#"
// Comments are fine.
theme "gruvbox-dark"
option "number" #true
options {
    tabstop 2
    relativenumber #true
}
key "normal" "C-s" "save-buffer"
keys "insert" {
    "C-s" "save-buffer"
}
leader "zz" "save-buffer" "save it"
language-server "python-mode" "pylsp" markers=".git pyproject.toml" language="python"
"#;

    #[test]
    fn settings_apply() {
        let mut s = server("x\n");
        assert_eq!(
            s.eval(&format!("(apply-kdl-config! {CONFIG:?})")).unwrap(),
            "()"
        );
        assert_eq!(s.eval("(option 'number)").unwrap(), "#true");
        assert_eq!(s.eval("(option 'tabstop)").unwrap(), "2");
        assert_eq!(s.eval("(option 'relativenumber)").unwrap(), "#true");
        assert_eq!(s.eval("*theme*").unwrap(), "gruvbox-dark");
        assert_eq!(
            s.eval("(hash-ref *language-servers* 'python-mode)")
                .unwrap(),
            r#"("pylsp" (".git" "pyproject.toml") "python")"#
        );
        assert!(s
            .eval("(hash-ref *leader-bindings* \"zz\")")
            .unwrap()
            .contains("save it"));
    }

    #[test]
    fn the_example_config_loads() {
        let mut s = server("x\n");
        let text = include_str!("../../../examples/config.kdl");
        assert_eq!(
            s.eval(&format!("(apply-kdl-config! {text:?})")).unwrap(),
            "()"
        );
        assert_eq!(s.eval("(option 'clipboard)").unwrap(), "\"unnamedplus\"");
    }

    #[test]
    fn problems_name_their_lines() {
        let mut s = server("x\n");
        let config = "option \"number\" #true\nbogus 1\noption \"nosuch\" 1\noptions {\n  tabstop 1 2\n}\noption \"cursorline\" #true\n";
        let problems = s.eval(&format!("(apply-kdl-config! {config:?})")).unwrap();
        assert!(
            problems.contains("line 2: unknown setting bogus"),
            "{problems}"
        );
        assert!(
            problems.contains("line 3: unknown option: nosuch"),
            "{problems}"
        );
        assert!(
            problems.contains("line 5: tabstop takes one value"),
            "{problems}"
        );
        // The good ones around them still load.
        assert_eq!(s.eval("(option 'number)").unwrap(), "#true");
        assert_eq!(s.eval("(option 'cursorline)").unwrap(), "#true");
    }

    #[test]
    fn config_kdl_loads_before_init_scm() {
        let dir = temp_path("kdl-config");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("config.kdl"),
            "option \"tabstop\" 3\noption \"number\" #true\n",
        )
        .unwrap();
        std::fs::write(dir.join("init.scm"), "(set-option! 'number #f)\n").unwrap();
        let mut s = Server::new(
            Buffer::from_text("x\n"),
            Options {
                user_config: Some(dir.join("init.scm")),
            },
        )
        .unwrap();
        assert_eq!(s.eval("(option 'tabstop)").unwrap(), "3");
        assert_eq!(s.eval("(option 'number)").unwrap(), "#false");
    }
}
