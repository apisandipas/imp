//! The client/server protocol.
//!
//! In-process the messages travel over channels; between processes (the
//! daemon) as JSON, one message per line (`to_line`, `from_line`).
//!
//! Clients are dumb: they send raw input and draw whatever frame they are
//! given. Modes, keymaps and layout all live in the server, where Scheme can
//! reach them.

use serde::{Deserialize, Serialize};

/// Client -> server.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ClientMsg {
    /// A key in imp's notation: `"j"`, `"<esc>"`, `"<ret>"`, `"C-c"`.
    Key(String),
    Resize {
        width: u16,
        height: u16,
    },
    /// Open these files (absolute paths) in the editor, as `imp --connect
    /// FILE...` asks the daemon to.
    Open(Vec<String>),
    /// The mouse at screen cell (`x`, `y`). `action` is "press", "drag",
    /// "release", "scroll-up" or "scroll-down"; `button` is "left",
    /// "middle", "right" (or "" for scrolling).
    Mouse {
        action: String,
        button: String,
        x: u16,
        y: u16,
    },
}

/// One message as a line of JSON, without the line break.
pub fn to_line<T: Serialize>(msg: &T) -> String {
    serde_json::to_string(msg).expect("protocol messages always serialize")
}

pub fn from_line<'a, T: Deserialize<'a>>(line: &'a str) -> Result<T, String> {
    serde_json::from_str(line).map_err(|e| e.to_string())
}

/// Server -> client.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ServerMsg {
    /// A whole screen: the first one, and after a resize.
    Frame(Frame),
    /// The rows that changed since the last frame sent.
    Patch(Patch),
    Quit,
}

/// Changes to apply to the last frame: replaced rows, by index, and where
/// the cursor is now.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Patch {
    pub rows: Vec<(u16, Row)>,
    pub cursor: (u16, u16),
    pub cursor_shape: CursorShape,
}

impl Patch {
    pub fn apply(&self, frame: &mut Frame) {
        for (i, row) in &self.rows {
            if let Some(slot) = frame.rows.get_mut(*i as usize) {
                *slot = row.clone();
            }
        }
        frame.cursor = self.cursor;
        frame.cursor_shape = self.cursor_shape;
    }
}

/// A full screen as a grid of rows of styled text. The last row is the status
/// line.
///
/// Full frames are sent every time for now; incremental updates come later
/// without changing who decides what.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Frame {
    pub rows: Vec<Row>,
    /// Screen position (column, row) of the cursor.
    pub cursor: (u16, u16),
    pub cursor_shape: CursorShape,
}

/// One screen row, as runs of text that share a style.
pub type Row = Vec<Span>;

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Span {
    pub text: String,
    pub style: Style,
}

impl Span {
    pub fn new(text: impl Into<String>, style: Style) -> Self {
        Self {
            text: text.into(),
            style,
        }
    }
}

/// How text looks. `None` colors mean the terminal's default.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Style {
    pub fg: Option<Color>,
    pub bg: Option<Color>,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub reverse: bool,
}

impl Style {
    /// `self` drawn over `under`: colors and attributes set here win.
    pub fn over(self, under: Style) -> Style {
        Style {
            fg: self.fg.or(under.fg),
            bg: self.bg.or(under.bg),
            bold: self.bold || under.bold,
            italic: self.italic || under.italic,
            underline: self.underline || under.underline,
            reverse: self.reverse || under.reverse,
        }
    }

    /// Parses a face spec such as `"fg=#ff8800 bg=blue bold"`.
    ///
    /// Colors are `#rrggbb`, one of the 16 ANSI names (`red`,
    /// `bright-blue`...) or a 256-color index.
    pub fn parse(spec: &str) -> Result<Style, String> {
        let mut style = Style::default();
        for word in spec.split_whitespace() {
            match word {
                "bold" => style.bold = true,
                "italic" => style.italic = true,
                "underline" => style.underline = true,
                "reverse" => style.reverse = true,
                _ => {
                    let (key, value) = word
                        .split_once('=')
                        .ok_or_else(|| format!("unknown face attribute {word:?}"))?;
                    let color = Color::parse(value)?;
                    match key {
                        "fg" => style.fg = Some(color),
                        "bg" => style.bg = Some(color),
                        _ => return Err(format!("unknown face attribute {word:?}")),
                    }
                }
            }
        }
        Ok(style)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Color {
    /// 0-15 are the terminal's ANSI colors, 16-255 the fixed 256-color cube.
    Indexed(u8),
    Rgb(u8, u8, u8),
}

const ANSI_NAMES: [&str; 8] = [
    "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
];

impl Color {
    pub fn parse(s: &str) -> Result<Color, String> {
        if let Some(hex) = s.strip_prefix('#') {
            let n = u32::from_str_radix(hex, 16).map_err(|_| format!("bad color {s:?}"))?;
            if hex.len() != 6 {
                return Err(format!("bad color {s:?}"));
            }
            return Ok(Color::Rgb((n >> 16) as u8, (n >> 8) as u8, n as u8));
        }
        if let Ok(n) = s.parse::<u8>() {
            return Ok(Color::Indexed(n));
        }
        let (bright, name) = match s.strip_prefix("bright-") {
            Some(name) => (8, name),
            None => (0, s),
        };
        ANSI_NAMES
            .iter()
            .position(|n| *n == name)
            .map(|i| Color::Indexed(i as u8 + bright))
            .ok_or_else(|| format!("bad color {s:?}"))
    }
}

impl Frame {
    /// What changed from `self` to `next`, or `None` if the screen size
    /// changed and the whole frame should be sent.
    pub fn diff(&self, next: &Frame) -> Option<Patch> {
        if self.rows.len() != next.rows.len() {
            return None;
        }
        let rows = self
            .rows
            .iter()
            .zip(&next.rows)
            .enumerate()
            .filter(|(_, (old, new))| old != new)
            .map(|(i, (_, new))| (i as u16, new.clone()))
            .collect();
        Some(Patch {
            rows,
            cursor: next.cursor,
            cursor_shape: next.cursor_shape,
        })
    }

    /// The text of each row without styles. Handy in tests.
    pub fn text_rows(&self) -> Vec<String> {
        self.rows
            .iter()
            .map(|row| row.iter().map(|span| span.text.as_str()).collect())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn messages_round_trip_as_lines() {
        let msg = ServerMsg::Frame(Frame {
            rows: vec![vec![Span::new(
                "hi\nthere",
                Style {
                    fg: Some(Color::Rgb(1, 2, 3)),
                    ..Style::default()
                },
            )]],
            cursor: (1, 2),
            cursor_shape: CursorShape::Bar,
        });
        let line = to_line(&msg);
        assert!(!line.contains('\n'));
        assert_eq!(from_line::<ServerMsg>(&line).unwrap(), msg);
        let key = ClientMsg::Key("<esc>".into());
        assert_eq!(from_line::<ClientMsg>(&to_line(&key)).unwrap(), key);
    }

    #[test]
    fn diffs_apply() {
        let a = Frame {
            rows: vec![vec![Span::new("a", Style::default())], vec![]],
            ..Frame::default()
        };
        let mut b = a.clone();
        b.rows[1] = vec![Span::new("b", Style::default())];
        b.cursor = (1, 1);
        let patch = a.diff(&b).unwrap();
        assert_eq!(patch.rows.len(), 1);
        let mut c = a.clone();
        patch.apply(&mut c);
        assert_eq!(c, b);
        assert!(a.diff(&Frame::default()).is_none());
    }

    #[test]
    fn parses_face_specs() {
        let s = Style::parse("fg=#ff8000 bg=bright-blue bold").unwrap();
        assert_eq!(s.fg, Some(Color::Rgb(255, 128, 0)));
        assert_eq!(s.bg, Some(Color::Indexed(12)));
        assert!(s.bold && !s.italic);
        assert_eq!(
            Style::parse("fg=200").unwrap().fg,
            Some(Color::Indexed(200))
        );
        assert!(Style::parse("fg=nope").is_err());
        assert!(Style::parse("sparkly").is_err());
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum CursorShape {
    #[default]
    Block,
    Bar,
    Underline,
}
