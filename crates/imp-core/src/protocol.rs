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
    /// What the client can draw, sent first: `heights` when it draws text
    /// at other sizes (a window client), so frames carry them. Without it a
    /// client gets every row one cell tall.
    Hello {
        heights: bool,
    },
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
    /// Every window block, when any changed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub windows: Option<Vec<WindowBlock>>,
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
        if let Some(windows) = &self.windows {
            frame.windows = windows.clone();
        }
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
    /// How clients should present it; a change sends a whole frame.
    #[serde(default)]
    pub appearance: Appearance,
    /// For a client that draws heights (`ClientMsg::Hello`): each window's
    /// text, drawn under `rows`, whose cells over it are left blank. Empty
    /// for other clients, whose `rows` hold everything.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub windows: Vec<WindowBlock>,
}

/// A window's text area for a client that draws heights: a rectangle of
/// screen cells and the rows in it, top down, each as tall as its height
/// says. Rows that don't fill the rectangle leave the rest blank.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct WindowBlock {
    /// The rectangle, in cells: left, top, width, height.
    pub x: u16,
    pub y: u16,
    pub w: u16,
    pub h: u16,
    pub rows: Vec<BlockRow>,
    /// The cursor, when it is in this window: the row, and how far across
    /// in hundredths of a cell (text on a taller row is wider).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<(u16, u32)>,
}

/// One row of a `WindowBlock`.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct BlockRow {
    /// How tall, in hundredths of a cell (100 is one row).
    pub height: u16,
    /// Its runs; one whose style has a height takes that many times its
    /// cells' width.
    pub spans: Row,
}

/// Settings for the client rather than the grid, set from Scheme (the
/// font, padding and background-opacity options).
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Appearance {
    /// The background of the theme's "normal" face, which opacity and
    /// padding apply to; `None` without one.
    pub background: Option<Color>,
    /// For window clients: a font family ("" for theirs) and size in
    /// logical pixels (0 for theirs).
    pub font: String,
    pub font_size: u16,
    /// For window clients: empty space around the grid, logical pixels.
    pub padding: u16,
    /// For window clients: how transparent `background` is, in percent
    /// (0 is opaque).
    pub transparency: u8,
    /// For terminals: leave cells in `background` unpainted, so the
    /// terminal's own background shows.
    pub clear_terminal_background: bool,
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
    /// The text's size in percent of the font's (130 is 1.3 times), for
    /// clients that draw sizes (`ClientMsg::Hello`); 0 is unset, the font's
    /// own size. A line is as tall as its tallest text.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub height: u16,
}

fn is_zero(n: &u16) -> bool {
    *n == 0
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
            height: if self.height != 0 {
                self.height
            } else {
                under.height
            },
        }
    }

    /// How many times the font's size this text is drawn: 1.0 unset.
    pub fn scale(&self) -> f32 {
        if self.height == 0 {
            1.0
        } else {
            self.height as f32 / 100.0
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
                    if key == "height" {
                        // A multiple of the font's size: height=1.3.
                        let h: f32 = value
                            .parse()
                            .ok()
                            .filter(|h: &f32| (0.5..=4.0).contains(h))
                            .ok_or_else(|| format!("bad height {value:?} (0.5 to 4)"))?;
                        style.height = (h * 100.0).round() as u16;
                        continue;
                    }
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

    /// The spec `parse` reads back as this style, e.g. `"fg=#ff8800 bold"`.
    pub fn spec(&self) -> String {
        let colors = [("fg", self.fg), ("bg", self.bg)]
            .into_iter()
            .filter_map(|(key, c)| c.map(|c| format!("{key}={}", c.spec())));
        let attrs = [
            ("bold", self.bold),
            ("italic", self.italic),
            ("underline", self.underline),
            ("reverse", self.reverse),
        ]
        .into_iter()
        .filter(|(_, on)| *on)
        .map(|(name, _)| name.to_string());
        let height = (self.height != 0).then(|| format!("height={}", self.height as f32 / 100.0));
        colors
            .chain(attrs)
            .chain(height)
            .collect::<Vec<_>>()
            .join(" ")
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

    /// How `parse` spells this color: `#rrggbb`, or an index.
    pub fn spec(&self) -> String {
        match self {
            Color::Rgb(r, g, b) => format!("#{r:02x}{g:02x}{b:02x}"),
            Color::Indexed(n) => n.to_string(),
        }
    }
}

impl Frame {
    /// What changed from `self` to `next`, or `None` if the screen size
    /// changed and the whole frame should be sent.
    pub fn diff(&self, next: &Frame) -> Option<Patch> {
        if self.rows.len() != next.rows.len() || self.appearance != next.appearance {
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
            windows: (self.windows != next.windows).then(|| next.windows.clone()),
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
            appearance: Appearance {
                padding: 40,
                ..Appearance::default()
            },
            windows: vec![WindowBlock {
                w: 10,
                h: 3,
                rows: vec![BlockRow {
                    height: 140,
                    spans: vec![Span::new("* Big", Style::parse("height=1.4").unwrap())],
                }],
                cursor: Some((0, 250)),
                ..WindowBlock::default()
            }],
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
        assert!(patch.windows.is_none());
        let mut c = a.clone();
        patch.apply(&mut c);
        assert_eq!(c, b);
        // Window blocks go whole when any changed.
        let mut d = b.clone();
        d.windows = vec![WindowBlock::default()];
        let patch = b.diff(&d).unwrap();
        assert!(patch.rows.is_empty() && patch.windows.is_some());
        patch.apply(&mut c);
        assert_eq!(c, d);
        assert!(a.diff(&Frame::default()).is_none());
        // A new appearance needs the whole frame.
        let mut d = a.clone();
        d.appearance.padding = 10;
        assert!(a.diff(&d).is_none());
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

    #[test]
    fn face_specs_round_trip() {
        let s = Style::parse("bold fg=#ff8000 italic bg=bright-blue").unwrap();
        assert_eq!(s.spec(), "fg=#ff8000 bg=12 bold italic");
        assert_eq!(Style::parse(&s.spec()).unwrap(), s);
        assert_eq!(Style::default().spec(), "");
    }

    #[test]
    fn heights() {
        let s = Style::parse("bold height=1.3").unwrap();
        assert_eq!(s.height, 130);
        assert_eq!(s.scale(), 1.3);
        assert_eq!(s.spec(), "bold height=1.3");
        assert_eq!(Style::default().scale(), 1.0);
        assert!(Style::parse("height=9").is_err());
        assert!(Style::parse("height=big").is_err());
        // Set over unset wins; unset leaves what is under it.
        let plain = Style::parse("fg=red").unwrap();
        assert_eq!(plain.over(s).height, 130);
        assert_eq!(Style::parse("height=2").unwrap().over(s).height, 200);
        // Unset, it stays out of the JSON clients get.
        assert!(!to_line(&Style::default()).contains("height"));
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum CursorShape {
    #[default]
    Block,
    Bar,
    Underline,
}
