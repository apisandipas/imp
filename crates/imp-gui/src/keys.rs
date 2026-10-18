//! winit keys in imp's notation (the terminal client's `key_name`).

use winit::event::{KeyEvent, Modifiers};
use winit::keyboard::{Key, NamedKey};

pub fn key_name(event: &KeyEvent, mods: &Modifiers) -> Option<String> {
    let state = mods.state();
    let (ctrl, alt, shift) = (state.control_key(), state.alt_key(), state.shift_key());
    let named = |name: &str| Some(format!("<{name}>"));
    match &event.logical_key {
        Key::Character(s) => {
            let c = s.chars().next()?;
            Some(if ctrl {
                format!("C-{}", c.to_lowercase())
            } else if alt {
                format!("M-{c}")
            } else {
                s.to_string()
            })
        }
        Key::Named(key) => match key {
            NamedKey::Space if ctrl => Some("C- ".into()),
            NamedKey::Space if alt => Some("M- ".into()),
            NamedKey::Space => Some(" ".into()),
            NamedKey::Escape => named("esc"),
            NamedKey::Enter if alt => Some("M-<ret>".into()),
            NamedKey::Enter => named("ret"),
            NamedKey::Backspace => named("bs"),
            NamedKey::Tab if shift => named("s-tab"),
            NamedKey::Tab => named("tab"),
            NamedKey::Delete => named("del"),
            NamedKey::ArrowLeft => named("left"),
            NamedKey::ArrowRight => named("right"),
            NamedKey::ArrowUp => named("up"),
            NamedKey::ArrowDown => named("down"),
            NamedKey::Home => named("home"),
            NamedKey::End => named("end"),
            NamedKey::PageUp => named("pageup"),
            NamedKey::PageDown => named("pagedown"),
            NamedKey::Insert => named("insert"),
            NamedKey::F1 => named("f1"),
            NamedKey::F2 => named("f2"),
            NamedKey::F3 => named("f3"),
            NamedKey::F4 => named("f4"),
            NamedKey::F5 => named("f5"),
            NamedKey::F6 => named("f6"),
            NamedKey::F7 => named("f7"),
            NamedKey::F8 => named("f8"),
            NamedKey::F9 => named("f9"),
            NamedKey::F10 => named("f10"),
            NamedKey::F11 => named("f11"),
            NamedKey::F12 => named("f12"),
            _ => None,
        },
        _ => None,
    }
}

/// Splits "ihello<esc>:w<ret>" into keys, as the tests' notation does:
/// `<name>` is one key ("<C-x>" the key "C-x"), anything else a char.
pub fn parse_keys(input: &str) -> Vec<String> {
    let mut keys = Vec::new();
    let mut rest = input;
    while let Some(c) = rest.chars().next() {
        if c == '<' {
            if let Some(end) = rest.find('>') {
                let name = &rest[1..end];
                if !name.is_empty() && name.chars().all(|c| c.is_alphanumeric() || c == '-') {
                    keys.push(match name.split_once('-') {
                        Some((m, _)) if m == "C" || m == "M" => name.to_string(),
                        _ => format!("<{name}>"),
                    });
                    rest = &rest[end + 1..];
                    continue;
                }
            }
        }
        keys.push(c.to_string());
        rest = &rest[c.len_utf8()..];
    }
    keys
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_key_notation() {
        assert_eq!(
            parse_keys("ix<esc><C-x>a<b"),
            ["i", "x", "<esc>", "C-x", "a", "<", "b"]
        );
        assert_eq!(parse_keys("<s-tab>"), ["<s-tab>"]);
    }
}
