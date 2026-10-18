//! An example imp plugin: changes the case style of identifiers.
//!
//! The ABI (crates/imp-server/src/wasm.rs): export `imp_alloc`, and
//! functions taking a (ptr, len) UTF-8 string and returning
//! `ptr << 32 | len` of the result. The `export!` macro below does the
//! plumbing, so each function is plain `fn(&str) -> String`.

use std::alloc::{alloc, Layout};

#[link(wasm_import_module = "imp")]
extern "C" {
    fn log(ptr: *const u8, len: usize);
}

/// Writes a line to the editor's :wasm-log.
fn log_line(text: &str) {
    unsafe { log(text.as_ptr(), text.len()) }
}

/// Memory for the host to write an argument into. Plugins live for the
/// editor session, so for simplicity nothing here is freed: each call leaks
/// its input and output (fine for a demo; a real plugin can keep a scratch
/// buffer instead).
#[no_mangle]
pub extern "C" fn imp_alloc(len: usize) -> *mut u8 {
    unsafe { alloc(Layout::from_size_align(len.max(1), 1).unwrap()) }
}

fn result(text: String) -> u64 {
    let text = text.into_bytes().leak();
    ((text.as_ptr() as u64) << 32) | text.len() as u64
}

macro_rules! export {
    ($($name:ident),*) => {$(
        #[no_mangle]
        pub extern "C" fn $name(ptr: *const u8, len: usize) -> u64 {
            let input = unsafe { std::slice::from_raw_parts(ptr, len) };
            result(self::imp::$name(&String::from_utf8_lossy(input)))
        }
    )*};
}

export!(snake, camel, kebab);

mod imp {
    /// The words of each identifier-ish run in `text`, rejoined by `join`;
    /// everything else is kept.
    fn convert(text: &str, join: fn(&[String]) -> String) -> String {
        let mut out = String::new();
        let mut word = String::new();
        let flush = |word: &mut String, out: &mut String| {
            if !word.is_empty() {
                out.push_str(&join(&split(word)));
                word.clear();
            }
        };
        for c in text.chars() {
            if c.is_alphanumeric() || c == '_' || (c == '-' && !word.is_empty()) {
                word.push(c);
            } else {
                flush(&mut word, &mut out);
                out.push(c);
            }
        }
        flush(&mut word, &mut out);
        out
    }

    /// "fooBar_baz-qux" -> ["foo", "bar", "baz", "qux"]
    fn split(ident: &str) -> Vec<String> {
        let mut words = Vec::new();
        let mut current = String::new();
        let mut prev_lower = false;
        for c in ident.chars() {
            if c == '_' || c == '-' {
                if !current.is_empty() {
                    words.push(std::mem::take(&mut current));
                }
                prev_lower = false;
                continue;
            }
            if c.is_uppercase() && prev_lower && !current.is_empty() {
                words.push(std::mem::take(&mut current));
            }
            prev_lower = c.is_lowercase() || c.is_numeric();
            current.extend(c.to_lowercase());
        }
        if !current.is_empty() {
            words.push(current);
        }
        words
    }

    pub fn snake(text: &str) -> String {
        convert(text, |w| w.join("_"))
    }

    pub fn kebab(text: &str) -> String {
        convert(text, |w| w.join("-"))
    }

    pub fn camel(text: &str) -> String {
        let out = convert(text, |w| {
            w.iter()
                .enumerate()
                .map(|(i, w)| {
                    let mut c = w.chars();
                    match (i, c.next()) {
                        (0, Some(f)) => f.to_string() + c.as_str(),
                        (_, Some(f)) => f.to_uppercase().collect::<String>() + c.as_str(),
                        _ => String::new(),
                    }
                })
                .collect()
        });
        super::log_line(&format!("camel: {} chars", out.len()));
        out
    }
}
