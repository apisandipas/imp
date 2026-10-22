//! The daemon: one editor that terminals attach to over a Unix socket.
//!
//! Messages are JSON lines (see `imp_core::protocol`). Each client sends
//! its keys and size and gets frames drawn at its own size; they all see
//! the same buffers. When a client quits (`:q`), only it detaches;
//! `:kill-server` stops the daemon.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Sender};

use imp_core::{protocol, Buffer, ClientMsg, Frame, ServerMsg};

use crate::events::Event;
use crate::{Options, Server};

/// The socket for daemon `name`: `$XDG_RUNTIME_DIR/imp/NAME.sock`, or under
/// `/tmp/imp-$USER` without a runtime directory.
pub fn socket_path(name: &str) -> PathBuf {
    let dir = std::env::var_os("XDG_RUNTIME_DIR")
        .filter(|v| !v.is_empty())
        .map(|d| PathBuf::from(d).join("imp"))
        .unwrap_or_else(|| {
            let user = std::env::var("USER").unwrap_or_else(|_| "user".into());
            PathBuf::from(format!("/tmp/imp-{user}"))
        });
    dir.join(format!("{name}.sock"))
}

struct Client {
    out: Sender<ServerMsg>,
    size: (u16, u16),
    /// Whether it draws text heights (it said so in its Hello).
    heights: bool,
    /// Its cell width (`ClientMsg::Cell`), 0 until it says.
    cell_width: u16,
    /// The last frame sent, to send only what changed.
    last: Option<Frame>,
}

/// Runs a daemon on `socket` until `:kill-server`.
pub fn run(socket: &Path, options: Options) -> Result<(), String> {
    let listener = bind(socket, "a daemon is already running")?;
    let mut server = Server::new(Buffer::default(), options)?;
    let events = server.sender.clone();

    // Accept connections on another thread; each client gets a reader that
    // turns its lines into events and a writer that sends it frames.
    std::thread::spawn(move || {
        for (n, stream) in listener.incoming().map_while(Result::ok).enumerate() {
            let id = n as u64 + 1;
            let Ok(write_half) = stream.try_clone() else {
                continue;
            };
            let (out, frames) = mpsc::channel::<ServerMsg>();
            std::thread::spawn(move || {
                let mut w = std::io::BufWriter::new(write_half);
                for msg in frames {
                    let quit = msg == ServerMsg::Quit;
                    if writeln!(w, "{}", protocol::to_line(&msg)).is_err()
                        || w.flush().is_err()
                        || quit
                    {
                        break;
                    }
                }
            });
            if events.send(Event::Connected(id, out)).is_err() {
                break;
            }
            let events = events.clone();
            std::thread::spawn(move || {
                for line in BufReader::new(stream).lines().map_while(Result::ok) {
                    if let Ok(msg) = protocol::from_line::<ClientMsg>(&line) {
                        if events.send(Event::FromClient(id, msg)).is_err() {
                            return;
                        }
                    }
                }
                let _ = events.send(Event::Disconnected(id));
            });
        }
    });

    let mut clients: HashMap<u64, Client> = HashMap::new();
    while let Ok(event) = server.events.recv() {
        let from = match &event {
            Event::FromClient(id, _) => Some(*id),
            _ => None,
        };
        match event {
            Event::Connected(id, out) => {
                clients.insert(
                    id,
                    Client {
                        out,
                        size: (80, 24),
                        heights: false,
                        cell_width: 0,
                        last: None,
                    },
                );
            }
            Event::Disconnected(id) => {
                clients.remove(&id);
            }
            Event::FromClient(id, ClientMsg::Hello { heights }) => {
                if let Some(c) = clients.get_mut(&id) {
                    c.heights = heights;
                    c.last = None;
                }
            }
            Event::FromClient(id, ClientMsg::Cell { width }) => {
                if let Some(c) = clients.get_mut(&id) {
                    c.cell_width = width;
                    c.last = None;
                }
            }
            Event::FromClient(id, ClientMsg::Resize { width, height }) => {
                if let Some(c) = clients.get_mut(&id) {
                    c.size = (width, height);
                    c.last = None;
                }
            }
            Event::FromClient(id, msg) => {
                // Draw with this client's size while handling its keys, so
                // scrolling suits the screen it is looking at.
                if let Some(c) = clients.get(&id) {
                    server.set_size(c.size.0, c.size.1);
                    server.set_heights(c.heights);
                    server.set_cell_width(c.cell_width);
                    server.set_cell_width(c.cell_width);
                }
                server.handle(msg);
            }
            other => server.handle_event(other),
        }
        if server.should_quit() {
            if server.kill_requested() {
                for c in clients.values() {
                    let _ = c.out.send(ServerMsg::Quit);
                }
                break;
            }
            // :q detaches the client that asked; the editor carries on.
            server.clear_quit();
            if let Some(c) = from.and_then(|id| clients.remove(&id)) {
                let _ = c.out.send(ServerMsg::Quit);
            }
        }
        for c in clients.values_mut() {
            server.set_size(c.size.0, c.size.1);
            server.set_heights(c.heights);
            server.set_cell_width(c.cell_width);
            let next = server.frame();
            let update = match c.last.as_ref().and_then(|last| last.diff(&next)) {
                Some(patch)
                    if patch.rows.is_empty()
                        && patch.windows.is_none()
                        && c.last.as_ref().is_some_and(|l| l.cursor == next.cursor) =>
                {
                    None
                }
                Some(patch) => Some(ServerMsg::Patch(patch)),
                None => Some(ServerMsg::Frame(next.clone())),
            };
            c.last = Some(next);
            if let Some(update) = update {
                let _ = c.out.send(update);
            }
        }
    }
    let _ = std::fs::remove_file(socket);
    Ok(())
}

/// Binds the socket, refusing (with `busy`, e.g. "a daemon is already
/// running") if something already answers on it, and clearing a stale one
/// left by a process that died.
pub(crate) fn bind(socket: &Path, busy: &str) -> Result<UnixListener, String> {
    if UnixStream::connect(socket).is_ok() {
        return Err(format!("{busy} on {}", socket.display()));
    }
    let _ = std::fs::remove_file(socket);
    if let Some(dir) = socket.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        // Only this user may connect: the socket gives full control.
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
    }
    UnixListener::bind(socket).map_err(|e| format!("{}: {e}", socket.display()))
}
