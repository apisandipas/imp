//! Terminal buffers: a program on a pseudo-terminal (portable-pty), its
//! screen kept by vt100, drawn into a buffer (runtime/term.scm).
//!
//! Output is read on a thread and posted as `TermOutput` events; the main
//! thread feeds it to the parser, and Scheme asks for a redraw when it
//! likes. Lines that scroll off the top are moved into a history of our
//! own (vt100's scrollback is cleared each time), so the buffer holds the
//! history and then the screen.

use std::cell::RefCell;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::mpsc::Sender;

use imp_core::{Buffer, Color, Style};
use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};

use crate::editor::{Highlight, Layer};
use crate::events::Event;

/// History lines kept per terminal.
const HISTORY: usize = 10_000;

/// A line of text with styled runs: (start, end, style) in chars.
type Line = (String, Vec<(usize, usize, Style)>);

/// What the program has reported about itself, through escapes vt100
/// passes on rather than drawing.
#[derive(Default)]
struct Reports {
    /// The last title set (OSC 0 or 2); empty clears it.
    title: Option<String>,
    /// The last directory reported on this machine (OSC 7).
    directory: Option<String>,
    /// Each command the shell marked (OSC 133), oldest first.
    marks: Vec<Mark>,
    /// Lines dropped from the front of the history so far, and the
    /// history's length, as of the last render: with them a line's
    /// absolute number (counted from the first line the program printed)
    /// becomes a buffer line.
    dropped: usize,
    history_len: usize,
}

/// One command's marks, at absolute lines.
struct Mark {
    /// Where its prompt starts (`A`).
    prompt: usize,
    /// Where its output starts (`C`), once it runs.
    output: Option<usize>,
    /// The status it finished with (`D;N`).
    status: Option<i32>,
}

/// Marks kept per terminal, at most.
const MARKS: usize = 10_000;

impl Reports {
    /// The absolute line the cursor is on, while the parser is mid-output.
    fn cursor_line(&self, screen: &mut vt100::Screen) -> usize {
        // Lines scrolled off since the last render are still in vt100's
        // scrollback: as far as it scrolls is how many.
        screen.set_scrollback(usize::MAX);
        let scrolled = screen.scrollback();
        screen.set_scrollback(0);
        self.dropped + self.history_len + scrolled + screen.cursor_position().0 as usize
    }

    fn mark(&mut self, screen: &mut vt100::Screen, params: &[&[u8]]) {
        let line = self.cursor_line(screen);
        match params.get(1).and_then(|p| p.first()) {
            Some(b'A') => {
                // A prompt drawn again on the same line is the same one.
                if self
                    .marks
                    .last()
                    .is_some_and(|m| m.prompt == line && m.output.is_none())
                {
                    return;
                }
                self.marks.push(Mark {
                    prompt: line,
                    output: None,
                    status: None,
                });
                if self.marks.len() > MARKS {
                    self.marks.remove(0);
                }
            }
            Some(b'C') => {
                if let Some(m) = self.marks.last_mut().filter(|m| m.output.is_none()) {
                    m.output = Some(line);
                }
            }
            Some(b'D') => {
                let status = params
                    .get(2)
                    .and_then(|s| std::str::from_utf8(s).ok())
                    .and_then(|s| s.parse().ok());
                if let Some(m) = self.marks.last_mut().filter(|m| m.status.is_none()) {
                    m.status = status;
                }
            }
            _ => {}
        }
    }
}

impl vt100::Callbacks for Reports {
    fn set_window_title(&mut self, _: &mut vt100::Screen, title: &[u8]) {
        self.title = Some(String::from_utf8_lossy(title).into_owned());
    }

    fn unhandled_osc(&mut self, screen: &mut vt100::Screen, params: &[&[u8]]) {
        // The parser splits at `;`, which a title or a path can hold.
        let rest = || {
            let joined: Vec<u8> = params[1..].join(&b";"[..]);
            String::from_utf8_lossy(&joined).into_owned()
        };
        match params.first() {
            Some(&b"0") | Some(&b"2") if params.len() > 2 => self.title = Some(rest()),
            Some(&b"133") => self.mark(screen, params),
            Some(&b"7") if params.len() > 1 => {
                if let Some(dir) = local_directory(&rest()) {
                    self.directory = Some(dir);
                }
            }
            _ => {}
        }
    }
}

/// The path in an OSC 7 `file://HOST/PATH` URL, percent-decoded, if HOST
/// is this machine (empty, `localhost`, or its host name).
fn local_directory(url: &str) -> Option<String> {
    let rest = url.strip_prefix("file://")?;
    let slash = rest.find('/')?;
    let (host, path) = rest.split_at(slash);
    if !(host.is_empty() || host == "localhost" || host == hostname()) {
        return None;
    }
    let bytes = path.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = |b: u8| (b as char).to_digit(16);
        match (bytes[i], bytes.get(i + 1), bytes.get(i + 2)) {
            (b'%', Some(&a), Some(&b)) if hex(a).is_some() && hex(b).is_some() => {
                out.push((hex(a).unwrap() * 16 + hex(b).unwrap()) as u8);
                i += 3;
            }
            (b, _, _) => {
                out.push(b);
                i += 1;
            }
        }
    }
    let path = String::from_utf8_lossy(&out).into_owned();
    // A trailing slash is dropped, as directories are named elsewhere.
    Some(if path.len() > 1 {
        path.trim_end_matches('/').to_string()
    } else {
        path
    })
}

/// This machine's host name, as OSC 7 names it.
fn hostname() -> String {
    let mut buf = [0u8; 256];
    // SAFETY: gethostname writes at most buf.len() bytes into buf.
    let ok = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) } == 0;
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    if ok {
        String::from_utf8_lossy(&buf[..end]).into_owned()
    } else {
        String::new()
    }
}

struct Term {
    parser: vt100::Parser<Reports>,
    writer: Box<dyn Write + Send>,
    master: Box<dyn MasterPty + Send>,
    killer: Box<dyn ChildKiller + Send + Sync>,
    history: Vec<Line>,
}

thread_local! {
    static TERMS: RefCell<HashMap<u64, Term>> = RefCell::new(HashMap::new());
    static NEXT: RefCell<u64> = const { RefCell::new(0) };
    /// The theme's colors for ANSI colors 0-15 (set-terminal-palette!).
    static PALETTE: RefCell<[Option<Color>; 16]> = const { RefCell::new([None; 16]) };
}

/// Sets the colors programs get when they ask for ANSI colors 0-15, so
/// they match the theme rather than whatever the outer terminal uses.
pub fn set_palette(colors: &[Color]) {
    PALETTE.with(|p| {
        let mut p = p.borrow_mut();
        for (i, slot) in p.iter_mut().enumerate() {
            *slot = colors.get(i).copied();
        }
    });
}

fn size(rows: u16, cols: u16) -> PtySize {
    PtySize {
        rows: rows.max(2),
        cols: cols.max(10),
        pixel_width: 0,
        pixel_height: 0,
    }
}

/// Starts `command` (sh -c), or the user's shell, in `cwd`.
pub fn spawn(
    command: &str,
    cwd: &str,
    rows: u16,
    cols: u16,
    sender: Sender<Event>,
) -> Result<u64, String> {
    let size = size(rows, cols);
    let pair = native_pty_system()
        .openpty(size)
        .map_err(|e| format!("can't open a terminal: {e}"))?;
    let mut cmd = if command.is_empty() {
        CommandBuilder::new(std::env::var("SHELL").unwrap_or_else(|_| "sh".into()))
    } else {
        let mut c = CommandBuilder::new("sh");
        c.args(["-c", command]);
        c
    };
    cmd.cwd(cwd);
    cmd.env("TERM", "xterm-256color");
    let mut child = pair
        .slave
        .spawn_command(cmd)
        .map_err(|e| format!("can't start {command:?}: {e}"))?;
    let killer = child.clone_killer();
    drop(pair.slave);
    let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
    let writer = pair.master.take_writer().map_err(|e| e.to_string())?;
    let id = NEXT.with(|n| {
        *n.borrow_mut() += 1;
        *n.borrow()
    });
    let (drained, until_drained) = std::sync::mpsc::channel::<()>();
    let output = sender.clone();
    std::thread::spawn(move || {
        let mut buf = [0u8; 16384];
        loop {
            match reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if output
                        .send(Event::TermOutput(id, buf[..n].to_vec()))
                        .is_err()
                    {
                        return;
                    }
                }
            }
        }
        let _ = drained.send(());
    });
    // The exit is reported after the output, once it has drained (or soon
    // after, if something the program started keeps the terminal open).
    std::thread::spawn(move || {
        let code = child.wait().map(|s| s.exit_code() as i32).unwrap_or(-1);
        let _ = until_drained.recv_timeout(std::time::Duration::from_millis(500));
        let _ = sender.send(Event::TermExit(id, code));
    });
    TERMS.with(|t| {
        t.borrow_mut().insert(
            id,
            Term {
                parser: vt100::Parser::new_with_callbacks(
                    size.rows,
                    size.cols,
                    HISTORY,
                    Reports::default(),
                ),
                writer,
                master: pair.master,
                killer,
                history: Vec::new(),
            },
        )
    });
    Ok(id)
}

fn with<T>(id: u64, f: impl FnOnce(&mut Term) -> T) -> Option<T> {
    TERMS.with(|t| t.borrow_mut().get_mut(&id).map(f))
}

pub fn feed(id: u64, bytes: &[u8]) {
    with(id, |t| t.parser.process(bytes));
}

/// Writes to the program. False if the terminal is gone.
pub fn send(id: u64, text: &str) -> bool {
    with(id, |t| {
        t.writer.write_all(text.as_bytes()).is_ok() && t.writer.flush().is_ok()
    })
    .unwrap_or(false)
}

pub fn resize(id: u64, rows: u16, cols: u16) {
    with(id, |t| {
        let size = size(rows, cols);
        if t.parser.screen().size() != (size.rows, size.cols) {
            t.parser.screen_mut().set_size(size.rows, size.cols);
            let _ = t.master.resize(size);
        }
    });
}

/// What mouse reporting the program asked for, as (mode, encoding): mode
/// "none", "press", "press-release", "button-motion" or "any-motion";
/// encoding "default", "utf8" or "sgr".
pub fn mouse_mode(id: u64) -> Option<(&'static str, &'static str)> {
    use vt100::{MouseProtocolEncoding as E, MouseProtocolMode as M};
    with(id, |t| {
        let screen = t.parser.screen();
        let mode = match screen.mouse_protocol_mode() {
            M::None => "none",
            M::Press => "press",
            M::PressRelease => "press-release",
            M::ButtonMotion => "button-motion",
            M::AnyMotion => "any-motion",
        };
        let encoding = match screen.mouse_protocol_encoding() {
            E::Default => "default",
            E::Utf8 => "utf8",
            E::Sgr => "sgr",
        };
        (mode, encoding)
    })
}

/// The buffer line the program's screen starts on (the history comes
/// before it), as of the last render.
pub fn screen_top(id: u64) -> Option<usize> {
    with(id, |t| t.history.len())
}

/// The terminal's (rows, columns), or `None` if it is gone.
pub fn screen_size(id: u64) -> Option<(u16, u16)> {
    with(id, |t| t.parser.screen().size())
}

pub fn kill(id: u64) {
    if let Some(mut t) = TERMS.with(|t| t.borrow_mut().remove(&id)) {
        let _ = t.killer.kill();
    }
}

/// Whether the program asked for application cursor keys (arrows as
/// ESC O A rather than ESC [ A).
pub fn application_cursor(id: u64) -> bool {
    with(id, |t| t.parser.screen().application_cursor()).unwrap_or(false)
}

/// Whether the program asked for pasted text to be bracketed (ESC [ 200 ~
/// before it, ESC [ 201 ~ after), so it can tell a paste from typing.
pub fn bracketed_paste(id: u64) -> bool {
    with(id, |t| t.parser.screen().bracketed_paste()).unwrap_or(false)
}

/// The commands the shell marked (OSC 133), as (prompt line, output
/// line, status) in buffer lines, as of the last render.
pub fn prompts(id: u64) -> Vec<(usize, Option<usize>, Option<i32>)> {
    with(id, |t| {
        let r = t.parser.callbacks();
        r.marks
            .iter()
            .map(|m| {
                (
                    m.prompt - r.dropped,
                    m.output.map(|o| o - r.dropped),
                    m.status,
                )
            })
            .collect()
    })
    .unwrap_or_default()
}

/// The title the program last set, or `None` if it hasn't (or the
/// terminal is gone). Empty once it has cleared it.
pub fn title(id: u64) -> Option<String> {
    with(id, |t| t.parser.callbacks().title.clone()).flatten()
}

/// The directory the shell last reported (OSC 7) on this machine, or
/// `None` if it hasn't.
pub fn directory(id: u64) -> Option<String> {
    with(id, |t| t.parser.callbacks().directory.clone()).flatten()
}

fn color(c: vt100::Color) -> Option<Color> {
    match c {
        vt100::Color::Default => None,
        vt100::Color::Idx(i) => Some(
            PALETTE
                .with(|p| p.borrow().get(i as usize).copied().flatten())
                .unwrap_or(Color::Indexed(i)),
        ),
        vt100::Color::Rgb(r, g, b) => Some(Color::Rgb(r, g, b)),
    }
}

fn cell_style(cell: &vt100::Cell) -> Style {
    let (fg, bg) = (color(cell.fgcolor()), color(cell.bgcolor()));
    Style {
        fg,
        bg,
        bold: cell.bold(),
        italic: cell.italic(),
        underline: cell.underline(),
        reverse: cell.inverse(),
        height: 0,
    }
}

/// Visible row `row` of the screen as text and styled runs, keeping at
/// least `min_len` chars (so the cursor can sit after a trailing space).
fn read_row(screen: &vt100::Screen, row: u16, cols: u16, min_len: usize) -> Line {
    let mut text = String::new();
    let mut runs: Vec<(usize, usize, Style)> = Vec::new();
    let mut n = 0;
    for col in 0..cols {
        let Some(cell) = screen.cell(row, col) else {
            break;
        };
        if cell.is_wide_continuation() {
            continue;
        }
        let contents = cell.contents();
        let chars = if contents.is_empty() { " " } else { contents };
        let len = chars.chars().count();
        let style = cell_style(cell);
        if style != Style::default() {
            match runs.last_mut() {
                Some(last) if last.1 == n && last.2 == style => last.1 += len,
                _ => runs.push((n, n + len, style)),
            }
        }
        text.push_str(chars);
        n += len;
    }
    // Trailing blanks go, unless styled or needed for the cursor.
    let styled_end = runs.iter().map(|r| r.1).max().unwrap_or(0);
    let keep = text
        .trim_end_matches(' ')
        .chars()
        .count()
        .max(min_len)
        .max(styled_end);
    let text: String = text.chars().take(keep).collect();
    runs.retain(|r| r.0 < keep);
    (text, runs)
}

/// The face name for a terminal style, made on first use.
fn face_name(style: &Style, faces: &mut HashMap<String, Style>) -> String {
    let c = |c: Option<Color>| match c {
        None => "-".to_string(),
        Some(Color::Indexed(i)) => i.to_string(),
        Some(Color::Rgb(r, g, b)) => format!("{r},{g},{b}"),
    };
    let name = format!(
        "term:{}:{}:{}{}{}{}",
        c(style.fg),
        c(style.bg),
        u8::from(style.bold),
        u8::from(style.italic),
        u8::from(style.underline),
        u8::from(style.reverse)
    );
    faces.entry(name.clone()).or_insert(*style);
    name
}

/// Draws terminal `id` into `buffer`: its history, then its screen.
/// Returns where its cursor is, as a buffer offset.
pub fn render(
    id: u64,
    buffer: &mut Buffer,
    faces: &mut HashMap<String, Style>,
    layer: &mut Layer,
) -> Option<usize> {
    with(id, |t| {
        let (rows, cols) = t.parser.screen().size();
        // Lines that scrolled off since last time join the history.
        // (scrollback_len() is the capacity; scrolling as far as possible
        // gives how many lines there are.)
        t.parser.screen_mut().set_scrollback(usize::MAX);
        let scrolled = t.parser.screen().scrollback();
        if scrolled > 0 {
            let mut new = Vec::with_capacity(scrolled);
            let mut offset = scrolled;
            while offset > 0 {
                t.parser.screen_mut().set_scrollback(offset);
                let take = offset.min(rows as usize);
                for row in 0..take {
                    new.push(read_row(t.parser.screen(), row as u16, cols, 0));
                }
                offset -= take;
            }
            t.parser.screen_mut().set_scrollback(0);
            t.parser.screen_mut().clear_scrollback();
            t.history.extend(new);
            if t.history.len() > HISTORY {
                let extra = t.history.len() - HISTORY;
                t.history.drain(..extra);
                let reports = t.parser.callbacks_mut();
                reports.dropped += extra;
                let dropped = reports.dropped;
                reports.marks.retain(|m| m.prompt >= dropped);
            }
            t.parser.callbacks_mut().history_len = t.history.len();
        }
        let screen = t.parser.screen();
        let (cursor_row, cursor_col) = screen.cursor_position();
        let mut lines: Vec<&Line> = t.history.iter().collect();
        let screen_rows: Vec<Line> = (0..rows)
            .map(|row| {
                let min = if row == cursor_row {
                    cursor_col as usize
                } else {
                    0
                };
                read_row(screen, row, cols, min)
            })
            .collect();
        lines.extend(screen_rows.iter());
        // Blank rows below the cursor don't need to be in the buffer.
        let last = (t.history.len() + cursor_row as usize)
            .max(lines.iter().rposition(|l| !l.0.is_empty()).unwrap_or(0));
        lines.truncate(last + 1);

        let mut text = String::new();
        let mut at = 0;
        layer.ranges.clear();
        let mut cursor = 0;
        for (i, (line, runs)) in lines.iter().enumerate() {
            for (s, e, style) in runs {
                layer.ranges.push(Highlight {
                    start: at + s,
                    end: at + e,
                    face: face_name(style, faces),
                });
            }
            if i == t.history.len() + cursor_row as usize {
                cursor = at + cursor_col as usize;
            }
            text.push_str(line);
            text.push('\n');
            at += line.chars().count() + 1;
        }

        // Change only what differs, so marks and the view stay put.
        let old = buffer.text();
        if old != text {
            let (prefix, suffix) = crate::crdt::common_ends(&old, &text);
            let start = old[..prefix].chars().count();
            let removed = old[prefix..old.len() - suffix].chars().count();
            buffer.delete(start, start + removed);
            buffer.insert(start, &text[prefix..text.len() - suffix]);
            buffer.set_unmodified();
        }
        cursor.min(buffer.len())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn osc_7_urls_on_this_machine() {
        assert_eq!(
            local_directory("file:///tmp/a%20b/"),
            Some("/tmp/a b".into())
        );
        assert_eq!(
            local_directory("file://localhost/home"),
            Some("/home".into())
        );
        let here = format!("file://{}/srv", hostname());
        assert_eq!(local_directory(&here), Some("/srv".into()));
        assert_eq!(local_directory("file://elsewhere.example/srv"), None);
        assert_eq!(local_directory("file:///"), Some("/".into()));
        assert_eq!(local_directory("http://x/y"), None);
    }

    fn marks(p: &vt100::Parser<Reports>) -> Vec<(usize, Option<usize>, Option<i32>)> {
        p.callbacks()
            .marks
            .iter()
            .map(|m| (m.prompt, m.output, m.status))
            .collect()
    }

    #[test]
    fn osc_133_marks_each_command_at_its_lines() {
        let mut p = vt100::Parser::new_with_callbacks(4, 20, 100, Reports::default());
        let command = |out: &str, status: i32| {
            format!(
                "\x1b]133;A\x07$ \x1b]133;B\x07run\r\n\x1b]133;C\x07{out}\x1b]133;D;{status}\x07"
            )
        };
        p.process(command("a\r\nb\r\n", 0).as_bytes());
        p.process(command("", 2).as_bytes());
        // Its prompt drawn again on the same line is the same prompt.
        p.process(b"\x1b]133;A\x07$ \r\x1b]133;A\x07$ ");
        assert_eq!(
            marks(&p),
            [
                (0, Some(1), Some(0)),
                (3, Some(4), Some(2)),
                (4, None, None)
            ]
        );
        // Past the bottom of the screen, lines keep counting.
        p.process(b"\r\n1\r\n2\r\n3\r\n4\r\n\x1b]133;A\x07");
        assert_eq!(marks(&p).last().unwrap().0, 9);
    }
}
