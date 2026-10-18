//! `imp`: the terminal client.
//!
//! It turns terminal events into keys, sends them to the server and draws the
//! frames that come back. It knows nothing about modes or keymaps. For now
//! the server runs on a thread in this process; the channels between them are
//! where a socket goes later.

use std::io::{self, Write};
use std::path::PathBuf;
use std::sync::mpsc;
use std::thread;

use crossterm::cursor::{MoveTo, SetCursorStyle};
use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use crossterm::style::{
    Attribute, Color as TermColor, Print, ResetColor, SetAttribute, SetBackgroundColor,
    SetForegroundColor,
};
use crossterm::terminal::{self, Clear, ClearType, EnterAlternateScreen, LeaveAlternateScreen};
use crossterm::{execute, queue};
use imp_core::{Buffer, ClientMsg, Color, CursorShape, Frame, ServerMsg, Style};
use imp_server::Options;

fn main() {
    let path = std::env::args_os().nth(1).map(PathBuf::from);
    if let Err(e) = run(path) {
        eprintln!("imp: {e}");
        std::process::exit(1);
    }
}

fn run(path: Option<PathBuf>) -> Result<(), String> {
    let buffer = match &path {
        Some(path) => Buffer::open(path).map_err(|e| format!("{}: {e}", path.display()))?,
        None => Buffer::default(),
    };

    let (to_server, from_client) = mpsc::channel();
    let (to_client, from_server) = mpsc::channel();
    let server = thread::spawn(move || {
        imp_server::run(
            buffer,
            Options {
                user_config: imp_server::user_config_path(),
            },
            from_client,
            to_client,
        )
    });

    let (width, height) = terminal::size().map_err(|e| e.to_string())?;
    let _ = to_server.send(ClientMsg::Resize { width, height });

    let mut out = io::stdout();
    terminal::enable_raw_mode().map_err(|e| e.to_string())?;
    execute!(out, EnterAlternateScreen).map_err(|e| e.to_string())?;

    let result = event_loop(&mut out, &to_server, &from_server);

    let _ = execute!(out, SetCursorStyle::DefaultUserShape, LeaveAlternateScreen);
    let _ = terminal::disable_raw_mode();
    drop(to_server);

    result?;
    match server.join() {
        Ok(r) => r,
        Err(_) => Err("server thread panicked".to_string()),
    }
}

fn event_loop(
    out: &mut impl Write,
    to_server: &mpsc::Sender<ClientMsg>,
    from_server: &mpsc::Receiver<ServerMsg>,
) -> Result<(), String> {
    loop {
        // Draw everything the server has sent, keeping only the newest frame.
        let mut latest = None;
        loop {
            match from_server.try_recv() {
                Ok(ServerMsg::Frame(frame)) => latest = Some(frame),
                Ok(ServerMsg::Quit) => return Ok(()),
                Err(mpsc::TryRecvError::Empty) => break,
                // The server stopped; its own error is reported by the caller.
                Err(mpsc::TryRecvError::Disconnected) => return Ok(()),
            }
        }
        if let Some(frame) = latest {
            draw(out, &frame).map_err(|e| e.to_string())?;
        }

        if !event::poll(std::time::Duration::from_millis(10)).map_err(|e| e.to_string())? {
            continue;
        }
        let msg = match event::read().map_err(|e| e.to_string())? {
            Event::Key(key) if key.kind != KeyEventKind::Release => {
                key_name(key).map(ClientMsg::Key)
            }
            Event::Resize(width, height) => Some(ClientMsg::Resize { width, height }),
            _ => None,
        };
        if let Some(msg) = msg {
            if to_server.send(msg).is_err() {
                return Ok(());
            }
        }
    }
}

/// Names a key in imp's notation: `"j"`, `"<esc>"`, `"C-r"`.
fn key_name(key: KeyEvent) -> Option<String> {
    let name = match key.code {
        KeyCode::Char(c) if key.modifiers.contains(KeyModifiers::CONTROL) => format!("C-{c}"),
        KeyCode::Char(c) if key.modifiers.contains(KeyModifiers::ALT) => format!("M-{c}"),
        KeyCode::Char(c) => c.to_string(),
        KeyCode::Esc => "<esc>".into(),
        KeyCode::Enter => "<ret>".into(),
        KeyCode::Backspace => "<bs>".into(),
        KeyCode::Tab => "<tab>".into(),
        KeyCode::Delete => "<del>".into(),
        KeyCode::Left => "<left>".into(),
        KeyCode::Right => "<right>".into(),
        KeyCode::Up => "<up>".into(),
        KeyCode::Down => "<down>".into(),
        KeyCode::Home => "<home>".into(),
        KeyCode::End => "<end>".into(),
        KeyCode::PageUp => "<pageup>".into(),
        KeyCode::PageDown => "<pagedown>".into(),
        KeyCode::Insert => "<insert>".into(),
        KeyCode::BackTab => "<s-tab>".into(),
        KeyCode::F(n) => format!("<f{n}>"),
        _ => return None,
    };
    Some(name)
}

fn draw(out: &mut impl Write, frame: &Frame) -> io::Result<()> {
    queue!(out, Clear(ClearType::All))?;
    for (row, spans) in frame.rows.iter().enumerate() {
        queue!(out, MoveTo(0, row as u16))?;
        for span in spans {
            set_style(out, span.style)?;
            queue!(out, Print(&span.text))?;
        }
        queue!(out, SetAttribute(Attribute::Reset), ResetColor)?;
    }
    let style = match frame.cursor_shape {
        CursorShape::Block => SetCursorStyle::SteadyBlock,
        CursorShape::Bar => SetCursorStyle::SteadyBar,
        CursorShape::Underline => SetCursorStyle::SteadyUnderScore,
    };
    queue!(out, MoveTo(frame.cursor.0, frame.cursor.1), style)?;
    out.flush()
}

fn set_style(out: &mut impl Write, style: Style) -> io::Result<()> {
    queue!(out, SetAttribute(Attribute::Reset), ResetColor)?;
    if let Some(fg) = style.fg {
        queue!(out, SetForegroundColor(term_color(fg)))?;
    }
    if let Some(bg) = style.bg {
        queue!(out, SetBackgroundColor(term_color(bg)))?;
    }
    for (on, attr) in [
        (style.bold, Attribute::Bold),
        (style.italic, Attribute::Italic),
        (style.underline, Attribute::Underlined),
        (style.reverse, Attribute::Reverse),
    ] {
        if on {
            queue!(out, SetAttribute(attr))?;
        }
    }
    Ok(())
}

fn term_color(c: Color) -> TermColor {
    match c {
        Color::Indexed(n) => TermColor::AnsiValue(n),
        Color::Rgb(r, g, b) => TermColor::Rgb { r, g, b },
    }
}
