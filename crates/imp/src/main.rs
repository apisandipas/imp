//! `imp`: starts the editor, in a window (crates/imp-gui) when there is a
//! display, otherwise in this terminal; and the terminal client itself.
//!
//! The terminal client turns terminal events into keys, sends them to the
//! server and draws the frames that come back. It knows nothing about modes
//! or keymaps.
//!
//!   imp [FILE...]                  the editor in a window, or in this
//!                                  terminal when there's no display
//!   imp --tui [FILE...]            the editor in this terminal
//!   imp --daemon [--name N]        an editor with no terminal, on a socket
//!   imp --connect [FILE...]        attach this terminal to the daemon
//!   imp --connect --via CMD        ... through CMD's stdin/stdout, e.g.
//!                                  --via 'ssh host imp --bridge'
//!   imp --bridge                   relay stdin/stdout to the local daemon
//!   imp --mcp                      relay stdin/stdout to the editor's MCP
//!                                  socket, for AI agents ((mcp-enable!))
//!
//! `--socket PATH` picks a socket instead of the named one.

use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::sync::mpsc;
use std::thread;

use crossterm::cursor::{MoveTo, SetCursorStyle};
use crossterm::event::{
    self, DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture,
    Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
};
use crossterm::style::{
    Attribute, Color as TermColor, Print, ResetColor, SetAttribute, SetBackgroundColor,
    SetForegroundColor,
};
use crossterm::terminal::{self, Clear, ClearType, EnterAlternateScreen, LeaveAlternateScreen};
use crossterm::{execute, queue};
use imp_core::{protocol, Buffer, ClientMsg, Color, CursorShape, Frame, ServerMsg, Style};
use imp_server::Options;

/// What the command line asked for.
#[derive(Debug, Default)]
struct Args {
    daemon: bool,
    connect: bool,
    bridge: bool,
    mcp: bool,
    name: String,
    socket: Option<PathBuf>,
    via: Option<String>,
    tui: bool,
    /// Window options given (`--font` ...), which the terminal can't use.
    gui_flags: Vec<String>,
    files: Vec<PathBuf>,
}

fn parse_args() -> Result<Args, String> {
    let mut args = Args {
        name: "default".into(),
        ..Args::default()
    };
    let mut it = std::env::args_os().skip(1);
    while let Some(arg) = it.next() {
        let mut value = |what: &str| {
            it.next()
                .map(|v| v.to_string_lossy().into_owned())
                .ok_or(format!("{what} needs a value"))
        };
        match arg.to_str() {
            Some("--daemon") => args.daemon = true,
            Some("--connect") => args.connect = true,
            Some("--bridge") => args.bridge = true,
            Some("--mcp") => args.mcp = true,
            Some("--name") => args.name = value("--name")?,
            Some("--socket") => args.socket = Some(PathBuf::from(value("--socket")?)),
            Some("--via") => args.via = Some(value("--via")?),
            Some("--tui") => args.tui = true,
            Some(flag) if GUI_FLAGS.contains(&flag) => {
                let flag = flag.to_string();
                value(&flag)?;
                args.gui_flags.push(flag);
            }
            Some("--help" | "-h") => {
                println!("{}", USAGE);
                std::process::exit(0);
            }
            Some("--version" | "-V") => {
                println!("imp {}", env!("CARGO_PKG_VERSION"));
                std::process::exit(0);
            }
            Some(flag) if flag.starts_with("--") => {
                return Err(format!("unknown option {flag}\n{USAGE}"))
            }
            _ => args.files.push(PathBuf::from(arg)),
        }
    }
    Ok(args)
}

/// The window's own options (crates/imp-gui), each followed by a value.
const GUI_FLAGS: &[&str] = &[
    "--screenshot",
    "--grid",
    "--keys",
    "--font",
    "--font-file",
    "--font-size",
    "--scale",
];

const USAGE: &str =
    "usage: imp [--font FAMILY] [--font-file PATH] [--font-size PX] [--scale F] [FILE...]
       imp --tui [FILE...]
       imp --screenshot OUT.png [--grid COLSxROWS] [--keys KEYS] [FILE...]
       imp --daemon [--name NAME | --socket PATH]
       imp --connect [--tui] [--name NAME | --socket PATH | --via COMMAND] [FILE...]
       imp --bridge [--name NAME | --socket PATH]
       imp --mcp [--socket PATH]
       imp --version

imp opens a window when there is a display ($WAYLAND_DISPLAY or $DISPLAY;
on macOS, outside SSH) and uses this terminal otherwise or with --tui.";

fn main() {
    let result = parse_args().and_then(|args| {
        let socket = || {
            args.socket
                .clone()
                .unwrap_or_else(|| imp_server::daemon::socket_path(&args.name))
        };
        if args.daemon {
            eprintln!("imp: daemon on {}", socket().display());
            imp_server::daemon::run(&socket(), options())
        } else if args.bridge {
            bridge(&socket()).map_err(|e| format!("{e}; start one with imp --daemon"))
        } else if args.mcp {
            let socket = args
                .socket
                .clone()
                .unwrap_or_else(|| imp_server::daemon::socket_path("mcp"));
            bridge(&socket)
                .map_err(|e| format!("{e}; is imp running with (mcp-enable!) in its init.scm?"))
        } else if use_window(&args) && window(args.gui_flags.is_empty())? {
            Ok(())
        } else if !args.gui_flags.is_empty() {
            Err(format!(
                "{} {} for the window, and imp is running in this terminal",
                args.gui_flags.join(", "),
                if args.gui_flags.len() == 1 {
                    "is"
                } else {
                    "are"
                }
            ))
        } else if args.connect {
            connect(&args, &socket())
        } else {
            standalone(args.files)
        }
    });
    if let Err(e) = result {
        eprintln!("imp: {e}");
        std::process::exit(1);
    }
}

/// Whether to open a window: not with --tui or --via, and only where one
/// can open (a --screenshot needs no display).
#[cfg(feature = "gui")]
fn use_window(args: &Args) -> bool {
    let screenshot = args.gui_flags.iter().any(|f| f == "--screenshot");
    !args.tui && args.via.is_none() && (screenshot || imp_gui::display_available())
}

#[cfg(not(feature = "gui"))]
fn use_window(_: &Args) -> bool {
    false
}

/// Runs the window client with this command line. False when no window
/// could open and `fall_back` lets the terminal client run instead (a
/// stale $WAYLAND_DISPLAY in tmux, say).
#[cfg(feature = "gui")]
fn window(fall_back: bool) -> Result<bool, String> {
    match imp_gui::run(std::env::args_os().skip(1).collect()) {
        Ok(()) => Ok(true),
        Err(imp_gui::Error::NoWindow(_)) if fall_back => Ok(false),
        Err(imp_gui::Error::NoWindow(e) | imp_gui::Error::Other(e)) => {
            Err(format!("{e} (imp --tui uses the terminal instead)"))
        }
    }
}

#[cfg(not(feature = "gui"))]
fn window(_: bool) -> Result<bool, String> {
    unreachable!("built without the window client")
}

fn options() -> Options {
    Options {
        user_config: imp_server::user_config_path(),
    }
}

/// The editor in this process: the server on a thread, talking over
/// channels.
fn standalone(paths: Vec<PathBuf>) -> Result<(), String> {
    // Directories open in the file browser once the runtime is up.
    let (dirs, files): (Vec<_>, Vec<_>) = paths.iter().partition(|p| p.is_dir());
    let buffers = files
        .iter()
        .map(|path| Buffer::open(path).map_err(|e| format!("{}: {e}", path.display())))
        .collect::<Result<Vec<_>, _>>()?;
    let cwd = std::env::current_dir().map_err(|e| e.to_string())?;
    let first = if dirs.is_empty() {
        Vec::new()
    } else {
        vec![ClientMsg::Open(
            dirs.iter()
                .map(|p| {
                    std::fs::canonicalize(p)
                        .unwrap_or_else(|_| cwd.join(p))
                        .display()
                        .to_string()
                })
                .collect(),
        )]
    };

    let (to_server, from_client) = mpsc::channel();
    let (to_client, from_server) = mpsc::channel();
    let server = thread::spawn(move || imp_server::run(buffers, options(), from_client, to_client));

    let result = terminal_session(to_server, from_server, first);
    result?;
    match server.join() {
        Ok(r) => r,
        Err(_) => Err("server thread panicked".to_string()),
    }
}

/// Attaches to a daemon over its socket, or over `--via`'s stdio.
fn connect(args: &Args, socket: &std::path::Path) -> Result<(), String> {
    let (reader, writer): (Box<dyn Read + Send>, Box<dyn Write + Send>) = match &args.via {
        Some(command) => {
            let mut child = std::process::Command::new("sh")
                .arg("-c")
                .arg(command)
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .spawn()
                .map_err(|e| format!("{command}: {e}"))?;
            let out = child.stdout.take().expect("piped");
            let input = child.stdin.take().expect("piped");
            (Box::new(out), Box::new(input))
        }
        None => {
            let stream = std::os::unix::net::UnixStream::connect(socket).map_err(|e| {
                format!(
                    "can't reach a daemon on {} ({e}); start one with imp --daemon",
                    socket.display()
                )
            })?;
            let write_half = stream.try_clone().map_err(|e| e.to_string())?;
            (Box::new(stream), Box::new(write_half))
        }
    };

    // Lines from the daemon become ServerMsgs; ClientMsgs become lines.
    let (to_server, outgoing) = mpsc::channel::<ClientMsg>();
    let (incoming, from_server) = mpsc::channel::<ServerMsg>();
    thread::spawn(move || {
        let mut w = io::BufWriter::new(writer);
        for msg in outgoing {
            if writeln!(w, "{}", protocol::to_line(&msg)).is_err() || w.flush().is_err() {
                break;
            }
        }
    });
    thread::spawn(move || {
        for line in BufReader::new(reader).lines().map_while(Result::ok) {
            match protocol::from_line::<ServerMsg>(&line) {
                Ok(msg) => {
                    if incoming.send(msg).is_err() {
                        break;
                    }
                }
                Err(_) => continue,
            }
        }
    });

    // Paths are resolved here, where the user typed them.
    let cwd = std::env::current_dir().map_err(|e| e.to_string())?;
    let files: Vec<String> = args
        .files
        .iter()
        .map(|p| cwd.join(p).display().to_string())
        .collect();
    let first = if files.is_empty() {
        Vec::new()
    } else {
        vec![ClientMsg::Open(files)]
    };
    terminal_session(to_server, from_server, first)
}

/// Relays stdin to a socket and its replies to stdout: the daemon's, so a
/// client elsewhere can use `--via 'ssh host imp --bridge'`, or the MCP
/// socket, so an agent can run `imp --mcp` as a stdio MCP server.
fn bridge(socket: &std::path::Path) -> Result<(), String> {
    let stream = std::os::unix::net::UnixStream::connect(socket)
        .map_err(|e| format!("can't reach {}: {e}", socket.display()))?;
    let mut to_daemon = stream.try_clone().map_err(|e| e.to_string())?;
    let mut from_daemon = stream;
    let up = thread::spawn(move || {
        relay(&mut io::stdin().lock(), &mut to_daemon);
        let _ = to_daemon.shutdown(std::net::Shutdown::Write);
    });
    relay(&mut from_daemon, &mut io::stdout().lock());
    drop(up);
    Ok(())
}

/// Copies until end of input, passing on whatever arrives at once.
/// (io::copy between a pipe and a socket can wait for more input before
/// passing any on, which stalls a request-reply conversation.)
fn relay(from: &mut impl io::Read, to: &mut impl io::Write) {
    let mut buf = [0u8; 8192];
    loop {
        match from.read(&mut buf) {
            Ok(0) | Err(_) => return,
            Ok(n) => {
                if to.write_all(&buf[..n]).and_then(|_| to.flush()).is_err() {
                    return;
                }
            }
        }
    }
}

/// Runs the terminal: raw mode, the alternate screen, and the loop that
/// sends keys and draws frames. `first` goes to the server after the size.
fn terminal_session(
    to_server: mpsc::Sender<ClientMsg>,
    from_server: mpsc::Receiver<ServerMsg>,
    first: Vec<ClientMsg>,
) -> Result<(), String> {
    let (width, height) = terminal::size().map_err(|e| e.to_string())?;
    let _ = to_server.send(ClientMsg::Resize { width, height });
    for msg in first {
        let _ = to_server.send(msg);
    }

    let mut out = io::stdout();
    terminal::enable_raw_mode().map_err(|e| e.to_string())?;
    // Bracketed paste: a paste arrives as one Event::Paste, not as keys.
    execute!(
        out,
        EnterAlternateScreen,
        EnableMouseCapture,
        EnableBracketedPaste
    )
    .map_err(|e| e.to_string())?;

    let result = event_loop(&mut out, &to_server, &from_server);

    let _ = execute!(
        out,
        SetCursorStyle::DefaultUserShape,
        DisableBracketedPaste,
        DisableMouseCapture,
        LeaveAlternateScreen
    );
    let _ = terminal::disable_raw_mode();
    drop(to_server);
    result
}

fn event_loop(
    out: &mut impl Write,
    to_server: &mpsc::Sender<ClientMsg>,
    from_server: &mpsc::Receiver<ServerMsg>,
) -> Result<(), String> {
    // The screen as last drawn; patches apply to it.
    let mut screen = Frame::default();
    loop {
        // Apply everything the server has sent, then draw once: a whole
        // frame redraws everything, patches only the rows they change.
        let mut full = false;
        let mut changed: Vec<u16> = Vec::new();
        let mut any = false;
        loop {
            match from_server.try_recv() {
                Ok(ServerMsg::Frame(frame)) => {
                    screen = frame;
                    full = true;
                    any = true;
                }
                Ok(ServerMsg::Patch(patch)) => {
                    changed.extend(patch.rows.iter().map(|(i, _)| *i));
                    patch.apply(&mut screen);
                    any = true;
                }
                Ok(ServerMsg::Quit) => return Ok(()),
                Err(mpsc::TryRecvError::Empty) => break,
                // The server stopped; its own error is reported by the caller.
                Err(mpsc::TryRecvError::Disconnected) => return Ok(()),
            }
        }
        if any {
            let rows = if full { None } else { Some(changed.as_slice()) };
            draw(out, &screen, rows).map_err(|e| e.to_string())?;
        }

        if !event::poll(std::time::Duration::from_millis(10)).map_err(|e| e.to_string())? {
            continue;
        }
        let msg = match event::read().map_err(|e| e.to_string())? {
            Event::Key(key) if key.kind != KeyEventKind::Release => {
                key_name(key).map(ClientMsg::Key)
            }
            Event::Resize(width, height) => Some(ClientMsg::Resize { width, height }),
            Event::Mouse(mouse) => mouse_msg(mouse),
            Event::Paste(text) => Some(ClientMsg::Paste(text)),
            _ => None,
        };
        if let Some(msg) = msg {
            if to_server.send(msg).is_err() {
                return Ok(());
            }
        }
    }
}

/// A mouse event as the server wants it; plain movement isn't sent.
fn mouse_msg(mouse: MouseEvent) -> Option<ClientMsg> {
    let button = |b: MouseButton| match b {
        MouseButton::Left => "left",
        MouseButton::Right => "right",
        MouseButton::Middle => "middle",
    };
    let (action, button) = match mouse.kind {
        MouseEventKind::Down(b) => ("press", button(b)),
        MouseEventKind::Drag(b) => ("drag", button(b)),
        MouseEventKind::Up(b) => ("release", button(b)),
        MouseEventKind::ScrollUp => ("scroll-up", ""),
        MouseEventKind::ScrollDown => ("scroll-down", ""),
        _ => return None,
    };
    Some(ClientMsg::Mouse {
        action: action.into(),
        button: button.into(),
        x: mouse.column,
        y: mouse.row,
        fine: None,
    })
}

/// Names a key in imp's notation: `"j"`, `"<esc>"`, `"C-r"`.
fn key_name(key: KeyEvent) -> Option<String> {
    let name = match key.code {
        KeyCode::Char(c) if key.modifiers.contains(KeyModifiers::CONTROL) => format!("C-{c}"),
        KeyCode::Char(c) if key.modifiers.contains(KeyModifiers::ALT) => format!("M-{c}"),
        KeyCode::Char(c) => c.to_string(),
        KeyCode::Esc => "<esc>".into(),
        KeyCode::Enter if key.modifiers.contains(KeyModifiers::ALT) => "M-<ret>".into(),
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

/// Draws `frame`: every row, or just `rows` when given.
fn draw(out: &mut impl Write, frame: &Frame, rows: Option<&[u16]>) -> io::Result<()> {
    if rows.is_none() {
        queue!(out, Clear(ClearType::All))?;
    }
    for (row, spans) in frame.rows.iter().enumerate() {
        if rows.is_some_and(|rows| !rows.contains(&(row as u16))) {
            continue;
        }
        queue!(out, MoveTo(0, row as u16), Clear(ClearType::CurrentLine))?;
        for span in spans {
            let mut style = span.style;
            // With terminal-background off, the theme's background is left
            // to the terminal.
            if frame.appearance.clear_terminal_background && style.bg == frame.appearance.background
            {
                style.bg = None;
            }
            set_style(out, style)?;
            // The server draws control chars in caret notation; should one
            // still come (an older daemon), it mustn't reach the terminal,
            // where it could move the cursor or set the title or clipboard.
            if span.text.contains(char::is_control) {
                queue!(out, Print(span.text.replace(char::is_control, "?")))?;
            } else {
                queue!(out, Print(&span.text))?;
            }
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
