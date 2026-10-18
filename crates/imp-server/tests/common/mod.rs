//! Helpers shared by the integration tests: a server per test, and keys
//! written the way a user types them.
#![allow(dead_code)]

use imp_core::Buffer;
use imp_server::{Options, Server};

pub fn server(text: &str) -> Server {
    Server::new(Buffer::from_text(text), Options { user_config: None }).expect("runtime loads")
}

/// Splits "dw" into ["d", "w"] and leaves "<esc>"-style names whole.
pub fn keys(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '<' && chars.peek().is_some_and(|c| c.is_ascii_lowercase()) {
            let mut name = String::from("<");
            for c in chars.by_ref() {
                name.push(c);
                if c == '>' {
                    break;
                }
            }
            out.push(name);
        } else {
            out.push(c.to_string());
        }
    }
    out
}

pub fn type_keys(s: &mut Server, input: &str) {
    let keys = keys(input);
    let refs: Vec<&str> = keys.iter().map(String::as_str).collect();
    s.keys(&refs);
    assert!(
        !s.status().starts_with("error"),
        "scheme error: {}",
        s.status()
    );
}

/// A path in a per-process temp directory.
pub fn temp_path(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("imp-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

/// Feeds keys without checking the status line for errors.
pub fn feed(s: &mut Server, input: &str) {
    let keys = keys(input);
    let refs: Vec<&str> = keys.iter().map(String::as_str).collect();
    s.keys(&refs);
}
