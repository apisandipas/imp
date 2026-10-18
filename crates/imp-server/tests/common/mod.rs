//! Helpers shared by the integration tests: a server per test, and keys
//! written the way a user types them.
#![allow(dead_code)]

use imp_core::Buffer;
use imp_server::{Options, Server};

/// A server for `text`. The theme's background is left off, so rows hold
/// only what was drawn (tests/theme.rs checks the theme).
pub fn server(text: &str) -> Server {
    let mut s =
        Server::new(Buffer::from_text(text), Options { user_config: None }).expect("runtime loads");
    s.eval(r#"(set-face! "normal" "")"#).unwrap();
    // State (autosaves, remembered projects) stays out of the real one.
    s.eval(&format!(
        "(set-option! 'state-directory {:?})",
        temp_path("state").display().to_string()
    ))
    .unwrap();
    s
}

/// Splits "dw" into ["d", "w"] and leaves "<esc>"-style names whole;
/// "<C-o>" is the key "C-o".
pub fn keys(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        let rest: String = chars.clone().take(4).collect();
        if c == '<' && (rest.starts_with("C-") || rest.starts_with("M-")) && rest.ends_with('>') {
            out.push(rest[..3].to_string());
            chars.nth(3);
        } else if c == '<' && chars.peek().is_some_and(|c| c.is_ascii_lowercase()) {
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

/// The current window's status line (the row above the message line).
pub fn status_row(s: &mut Server) -> String {
    let rows = s.frame().text_rows();
    rows[rows.len() - 2].clone()
}
