//! WASM plugins (runtime/wasm.scm, src/wasm.rs), with plugins written as
//! WAT. Most tests need the `wasm` feature: cargo test --features wasm.

mod common;

use common::*;

#[test]
#[cfg(not(feature = "wasm"))]
fn without_the_feature_it_says_so() {
    let mut s = server("text\n");
    assert_eq!(s.eval("(wasm-available?)").unwrap(), "#false");
    let err = s.eval(r#"(wasm-load "x.wasm")"#).unwrap_err();
    assert!(err.contains("without the wasm feature"), "{err}");
    feed(&mut s, ":wasm<ret>");
    assert!(s
        .frame()
        .text_rows()
        .join("\n")
        .contains("without the wasm feature"));
}

/// A plugin: upcase (ASCII, logging its result), spin (forever), bad
/// (returns a string outside memory) and huge (returns a 4 GiB length).
#[cfg(feature = "wasm")]
const PLUGIN: &str = r#"
(module
  (import "imp" "log" (func $log (param i32 i32)))
  (memory (export "memory") 1)
  (global $next (mut i32) (i32.const 1024))
  (func (export "imp_alloc") (param $len i32) (result i32)
    (local $p i32)
    (local.set $p (global.get $next))
    (global.set $next (i32.add (global.get $next) (local.get $len)))
    (local.get $p))
  (func (export "upcase") (param $p i32) (param $len i32) (result i64)
    (local $i i32) (local $c i32)
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
        (local.set $c (i32.load8_u (i32.add (local.get $p) (local.get $i))))
        (if (i32.and (i32.ge_u (local.get $c) (i32.const 97))
                     (i32.le_u (local.get $c) (i32.const 122)))
          (then (i32.store8 (i32.add (local.get $p) (local.get $i))
                            (i32.sub (local.get $c) (i32.const 32)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $next)))
    (call $log (local.get $p) (local.get $len))
    (i64.or (i64.shl (i64.extend_i32_u (local.get $p)) (i64.const 32))
            (i64.extend_i32_u (local.get $len))))
  (func (export "spin") (param i32 i32) (result i64)
    (loop $forever (br $forever))
    (i64.const 0))
  (func (export "bad") (param i32 i32) (result i64)
    (i64.const 0x0001000000000010))
  (func (export "huge") (param i32 i32) (result i64)
    (i64.const 0x00000000ffffffff)))
"#;

#[cfg(feature = "wasm")]
fn with_plugin(text: &str) -> imp_server::Server {
    let path = temp_path("caps.wat");
    std::fs::write(&path, PLUGIN).unwrap();
    let mut s = server(text);
    s.eval(&format!(
        "(load-wasm-plugin! 'caps {:?})",
        path.display().to_string()
    ))
    .unwrap();
    s
}

#[test]
#[cfg(feature = "wasm")]
fn calls_a_plugin_function() {
    let mut s = with_plugin("");
    assert_eq!(
        s.eval(r#"(wasm-call (wasm-plugin 'caps) "upcase" "hello, wasm")"#)
            .unwrap(),
        "\"HELLO, WASM\""
    );
    assert_eq!(
        s.eval("(wasm-exports (wasm-plugin 'caps))").unwrap(),
        r#"("upcase" "spin" "bad" "huge")"#
    );
    assert_eq!(s.eval("(wasm-log)").unwrap(), r#"("caps: HELLO, WASM")"#);
    let err = s
        .eval(r#"(wasm-call (wasm-plugin 'caps) "nope" "")"#)
        .unwrap_err();
    assert!(err.contains("nope"), "{err}");
}

#[test]
#[cfg(feature = "wasm")]
fn a_runaway_or_broken_plugin_errors_and_recovers() {
    let mut s = with_plugin("");
    s.eval("(wasm-set-fuel! 1000000)").unwrap();
    let err = s
        .eval(r#"(wasm-call (wasm-plugin 'caps) "spin" "")"#)
        .unwrap_err();
    assert!(err.contains("spin ran too long"), "{err}");
    let err = s
        .eval(r#"(wasm-call (wasm-plugin 'caps) "bad" "")"#)
        .unwrap_err();
    assert!(err.contains("bad returned a bad string"), "{err}");
    // A length far past its memory is refused, not allocated.
    let err = s
        .eval(r#"(wasm-call (wasm-plugin 'caps) "huge" "")"#)
        .unwrap_err();
    assert!(err.contains("huge returned a bad string"), "{err}");
    // It still works afterwards.
    assert_eq!(
        s.eval(r#"(wasm-call (wasm-plugin 'caps) "upcase" "ok")"#)
            .unwrap(),
        "\"OK\""
    );
}

#[test]
#[cfg(feature = "wasm")]
fn plugins_edit_as_operators_filters_and_ex_commands() {
    let mut s = with_plugin("one two\nthree\nfour\nfive\n");
    s.eval(r#"(define-operator! "gs" (wasm-operator 'caps "upcase"))"#)
        .unwrap();
    type_keys(&mut s, "wgsiw");
    assert_eq!(s.text(), "one TWO\nthree\nfour\nfive\n");
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "one two\nthree\nfour\nfive\n");
    type_keys(&mut s, "jVjgs");
    assert_eq!(s.text(), "one two\nTHREE\nFOUR\nfive\n");
    type_keys(&mut s, ":4wasm caps upcase<ret>");
    assert_eq!(s.text(), "one two\nTHREE\nFOUR\nFIVE\n");
    s.eval(r#"(define-wasm-filter! 'shout 'caps "upcase")"#)
        .unwrap();
    type_keys(&mut s, "u<M-x>shout<ret>");
    assert_eq!(s.text(), "ONE TWO\nTHREE\nFOUR\nFIVE\n");
    // One undo step undoes the whole filter.
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "one two\nTHREE\nFOUR\nfive\n");
    type_keys(&mut s, ":wasm<ret>");
    assert!(s
        .frame()
        .text_rows()
        .join("\n")
        .contains("caps: upcase spin bad huge"));
}

/// The Rust example in examples/wasm-plugin, when it has been built.
#[test]
#[cfg(feature = "wasm")]
fn the_example_plugin() {
    let wasm = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../examples/wasm-plugin/target/wasm32-unknown-unknown/release/case.wasm"
    );
    if !std::path::Path::new(wasm).exists() {
        return;
    }
    let mut s = server("let fooBar = baz_qux;\n");
    s.eval(&format!("(load-wasm-plugin! 'case {wasm:?})"))
        .unwrap();
    s.eval(r#"(define-operator! "gs" (wasm-operator 'case "snake"))"#)
        .unwrap();
    type_keys(&mut s, "wgsiw");
    assert_eq!(s.text(), "let foo_bar = baz_qux;\n");
    type_keys(&mut s, ":wasm case camel<ret>");
    assert_eq!(s.text(), "let fooBar = bazQux;\n");
    assert_eq!(
        s.eval("(wasm-log)").unwrap(),
        r#"("case: camel: 21 chars")"#
    );
}
