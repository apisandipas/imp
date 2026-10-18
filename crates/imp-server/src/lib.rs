//! The imp server: owns the buffers and the Steel VM, turns client input into
//! frames.
//!
//! Key handling is entirely in Scheme. For each key the server calls
//! `(imp-handle-key key)`, which the runtime (`runtime/*.scm`) defines and the
//! user's `init.scm` may redefine.

mod api;
mod clipboard;
mod crdt;
#[cfg(unix)]
pub mod daemon;
mod editor;
mod events;
mod files;
mod fuzzy;
mod json;
mod kdl;
mod layout;
mod render;
mod scan;
mod search;
mod shell;
mod syntax;
mod wasm;

use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, Sender};
use std::time::Duration;

use imp_core::{Buffer, ClientMsg, Frame, ServerMsg};
use steel::steel_vm::engine::Engine;
use steel::SteelVal;

use editor::Editor;
use events::Event;

/// The runtime Scheme files, in load order. Embedded so the binary works on
/// its own; set `IMP_RUNTIME` to a directory to load them from disk instead,
/// which lets you edit them without rebuilding.
const RUNTIME: &[(&str, &str)] = &[
    ("core.scm", include_str!("../../../runtime/core.scm")),
    ("vim.scm", include_str!("../../../runtime/vim.scm")),
    ("help.scm", include_str!("../../../runtime/help.scm")),
    (
        "completion.scm",
        include_str!("../../../runtime/completion.scm"),
    ),
    ("leader.scm", include_str!("../../../runtime/leader.scm")),
    ("modes.scm", include_str!("../../../runtime/modes.scm")),
    ("special.scm", include_str!("../../../runtime/special.scm")),
    ("emacs.scm", include_str!("../../../runtime/emacs.scm")),
    (
        "packages.scm",
        include_str!("../../../runtime/packages.scm"),
    ),
    ("files.scm", include_str!("../../../runtime/files.scm")),
    ("syntax.scm", include_str!("../../../runtime/syntax.scm")),
    ("lsp.scm", include_str!("../../../runtime/lsp.scm")),
    ("dap.scm", include_str!("../../../runtime/dap.scm")),
    ("mouse.scm", include_str!("../../../runtime/mouse.scm")),
    ("mcp.scm", include_str!("../../../runtime/mcp.scm")),
    ("wasm.scm", include_str!("../../../runtime/wasm.scm")),
    ("collab.scm", include_str!("../../../runtime/collab.scm")),
    ("theme.scm", include_str!("../../../runtime/theme.scm")),
    ("config.scm", include_str!("../../../runtime/config.scm")),
];

pub struct Options {
    /// The user's config, loaded after the runtime if it exists. Usually
    /// [`user_config_path`]; `None` skips it, as tests do.
    pub user_config: Option<PathBuf>,
}

/// One editor session. The Scheme API reaches its state through a
/// thread-local, so create at most one `Server` per thread and keep it on the
/// thread that created it.
pub struct Server {
    engine: Engine,
    /// Events from timers and jobs (and, under `run`, the client).
    events: Receiver<Event>,
    sender: Sender<Event>,
}

impl Server {
    pub fn new(buffer: Buffer, options: Options) -> Result<Self, String> {
        let mut ed = Editor {
            buffer,
            width: 80,
            height: 24,
            tab_width: 8,
            ..Editor::default()
        };
        ed.init_windows();
        let (sender, events) = mpsc::channel();
        ed.background.sender = Some(sender.clone());
        editor::install(ed);

        let mut engine = Engine::new();
        api::register(&mut engine);

        let runtime_dir = std::env::var_os("IMP_RUNTIME").map(PathBuf::from);
        for (name, embedded) in RUNTIME {
            let (source, path) = match &runtime_dir {
                Some(dir) => (
                    std::fs::read_to_string(dir.join(name))
                        .map_err(|e| format!("{}: {e}", dir.join(name).display()))?,
                    Some(dir.join(name).display().to_string()),
                ),
                None => (embedded.to_string(), None),
            };
            editor::with(|e| {
                e.sources
                    .push((format!("runtime/{name}"), path, source.clone()))
            });
            engine
                .run(with_mutable_globals(&source))
                .map_err(|e| format!("runtime/{name}: {e}"))?;
        }

        let mut server = Self {
            engine,
            events,
            sender,
        };
        // Settings as data (config.kdl) load first, so init.scm can
        // change them.
        if let Some(kdl) = options
            .user_config
            .as_ref()
            .map(|p| p.with_file_name("config.kdl"))
        {
            if kdl.exists() {
                server.call(
                    "load-kdl-config!",
                    vec![SteelVal::StringV(kdl.display().to_string().into())],
                );
            }
        }
        if let Some(path) = options.user_config.filter(|p| p.exists()) {
            // A broken init.scm shouldn't stop the editor from starting; say
            // what went wrong and carry on with whatever loaded.
            if let Err(e) = server.load_file(&path) {
                editor::with(|ed| ed.status = e);
            }
        }
        server.call("imp-init", vec![]);
        Ok(server)
    }

    /// Loads a user file through the runtime's `imp-load-file`, so a
    /// `define` of an existing function replaces it everywhere (see
    /// core.scm).
    fn load_file(&mut self, path: &Path) -> Result<(), String> {
        let path_text = path.display().to_string();
        self.engine
            .call_function_by_name_with_args(
                "imp-load-file",
                vec![SteelVal::StringV(path_text.clone().into())],
            )
            .map(|_| ())
            .map_err(|e| format!("{path_text}: {e}"))
    }

    /// Calls a Scheme function, reporting any error on the status line.
    fn call(&mut self, function: &str, args: Vec<SteelVal>) {
        if let Err(e) = self.engine.call_function_by_name_with_args(function, args) {
            editor::with(|ed| ed.status = format!("error: {e}"));
        }
    }

    /// Handles one event from the loop: client input, or a timer or job
    /// reporting back, which goes to Scheme.
    fn handle_event(&mut self, event: Event) {
        match event {
            Event::Client(msg) => self.handle(msg),
            Event::Timer(id) => self.call("imp-timer-fired", vec![SteelVal::IntV(id as isize)]),
            Event::JobOutput(id, stream, text) => self.call(
                "imp-job-output",
                vec![
                    SteelVal::IntV(id as isize),
                    SteelVal::StringV(stream.into()),
                    SteelVal::StringV(text.into()),
                ],
            ),
            // Daemon events are handled by its own loop (daemon.rs).
            Event::FromClient(_, msg) => self.handle(msg),
            Event::Connected(..) | Event::Disconnected(_) => {}
            Event::Parsed(id, version, tree) => {
                editor::with(|e| e.syntax_parsed(id, version, tree))
            }
            Event::SocketOpened(listener, conn, stream) => {
                editor::with(|e| e.background.connection_opened(conn, stream));
                self.call(
                    "imp-socket-opened",
                    vec![
                        SteelVal::IntV(listener as isize),
                        SteelVal::IntV(conn as isize),
                    ],
                )
            }
            Event::SocketLine(conn, line) => self.call(
                "imp-socket-line",
                vec![
                    SteelVal::IntV(conn as isize),
                    SteelVal::StringV(line.into()),
                ],
            ),
            Event::SocketClosed(conn) => {
                editor::with(|e| e.background.connection_closed(conn));
                self.call("imp-socket-closed", vec![SteelVal::IntV(conn as isize)])
            }
            Event::JobExit(id) => {
                let code = editor::with(|e| e.background.job_finished(id));
                self.call(
                    "imp-job-exit",
                    vec![SteelVal::IntV(id as isize), SteelVal::IntV(code as isize)],
                )
            }
        }
    }

    /// Handles timer and job events until none arrive for `idle`. Tests use
    /// it to let background work finish; `run` has its own loop.
    pub fn pump(&mut self, idle: Duration) -> usize {
        let mut n = 0;
        while let Ok(event) = self.events.recv_timeout(idle) {
            self.handle_event(event);
            n += 1;
        }
        n
    }

    pub fn handle(&mut self, msg: ClientMsg) {
        match msg {
            ClientMsg::Open(paths) => {
                let list = paths
                    .into_iter()
                    .map(|p| SteelVal::StringV(p.into()))
                    .collect();
                self.call("imp-open-files", vec![SteelVal::ListV(list)])
            }
            ClientMsg::Key(key) => self.call("imp-handle-key", vec![SteelVal::StringV(key.into())]),
            ClientMsg::Mouse {
                action,
                button,
                x,
                y,
            } => self.call(
                "imp-handle-mouse",
                vec![
                    SteelVal::StringV(action.into()),
                    SteelVal::StringV(button.into()),
                    SteelVal::IntV(x as isize),
                    SteelVal::IntV(y as isize),
                ],
            ),
            ClientMsg::Resize { width, height } => editor::with(|e| {
                e.width = width;
                e.height = height;
            }),
        }
    }

    /// Runs Scheme source in the editor and returns the printed value of the
    /// last expression. It goes through the runtime's `imp-eval-string`, as
    /// `:eval` does, so a `define` replaces an existing function everywhere.
    pub fn eval(&mut self, source: &str) -> Result<String, String> {
        let value = self
            .engine
            .call_function_by_name_with_args(
                "imp-eval-string",
                vec![SteelVal::StringV(source.to_string().into())],
            )
            .map_err(|e| e.to_string())?;
        Ok(match value {
            SteelVal::Void => String::new(),
            v => v.to_string(),
        })
    }

    /// Feeds each key in turn. Convenient for tests.
    pub fn keys(&mut self, keys: &[&str]) {
        for key in keys {
            self.handle(ClientMsg::Key(key.to_string()));
        }
    }

    /// Adds another buffer, as for `imp a.txt b.txt`. The first buffer
    /// stays current.
    pub fn add_buffer(&mut self, buffer: Buffer) {
        editor::with(|e| e.add_buffer(buffer));
    }

    pub fn frame(&mut self) -> Frame {
        editor::with(render::frame)
    }

    pub fn should_quit(&self) -> bool {
        editor::with(|e| e.quit)
    }

    /// Whether quitting should stop a daemon rather than detach a client.
    pub fn kill_requested(&self) -> bool {
        editor::with(|e| e.kill_server)
    }

    /// Clears the quit request, as after a daemon client detaches.
    pub fn clear_quit(&mut self) {
        editor::with(|e| e.quit = false);
    }

    /// Sets the screen size used for the next frame (each daemon client
    /// has its own).
    pub fn set_size(&mut self, width: u16, height: u16) {
        editor::with(|e| {
            e.width = width;
            e.height = height;
        });
    }

    pub fn text(&self) -> String {
        editor::with(|e| e.buffer.text())
    }

    pub fn cursor(&self) -> usize {
        editor::with(|e| e.cursor)
    }

    pub fn status(&self) -> String {
        editor::with(|e| e.status.clone())
    }
}

/// `source` followed by `(set! name name)` for each of its top-level
/// definitions.
///
/// Steel compiles a call to a function defined in the same file, and never
/// `set!` there, as a direct call that later redefinitions can't reach. A
/// `set!` anywhere in the file makes the name mutable, so the runtime's
/// functions stay redefinable from init.scm and `:eval`. This is the
/// property the whole design rests on; tests/eval.rs checks it.
fn with_mutable_globals(source: &str) -> String {
    let mut out = source.to_string();
    out.push_str("\n;; Generated: keep every definition redefinable.\n");
    for line in source.lines() {
        let Some(rest) = line.strip_prefix("(define ") else {
            continue;
        };
        let name: String = rest
            .trim_start_matches('(')
            .chars()
            .take_while(|c| !c.is_whitespace() && *c != '(' && *c != ')')
            .collect();
        if !name.is_empty() {
            out.push_str(&format!("(set! {name} {name})\n"));
        }
    }
    out
}

/// `$XDG_CONFIG_HOME/imp/init.scm`, falling back to `~/.config/imp/init.scm`.
pub fn user_config_path() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?;
    Some(base.join("imp").join("init.scm"))
}

/// Runs a server until the client goes away or Scheme calls `quit!`.
///
/// The server lives on whichever thread calls this. Today the client runs it
/// on a thread in the same process; a socket transport can replace the
/// channels later without touching anything else.
pub fn run(
    buffers: Vec<Buffer>,
    options: Options,
    from_client: Receiver<ClientMsg>,
    to_client: Sender<ServerMsg>,
) -> Result<(), String> {
    let mut buffers = buffers.into_iter();
    let mut server = Server::new(buffers.next().unwrap_or_default(), options)?;
    for buffer in buffers {
        server.add_buffer(buffer);
    }
    let mut last = server.frame();
    if to_client.send(ServerMsg::Frame(last.clone())).is_err() {
        return Ok(());
    }
    // Client messages join the timers' and jobs' events, so the loop waits
    // on one channel.
    let forward = server.sender.clone();
    std::thread::spawn(move || {
        for msg in from_client {
            if forward.send(Event::Client(msg)).is_err() {
                break;
            }
        }
    });
    while let Ok(event) = server.events.recv() {
        let from_client = matches!(event, Event::Client(_));
        server.handle_event(event);
        if server.should_quit() {
            let _ = to_client.send(ServerMsg::Quit);
            break;
        }
        let next = server.frame();
        // Only what changed, unless the screen size did; background events
        // that changed nothing send nothing.
        let update = match last.diff(&next) {
            Some(patch) if patch.rows.is_empty() && next.cursor == last.cursor && !from_client => {
                None
            }
            Some(patch) => Some(ServerMsg::Patch(patch)),
            None => Some(ServerMsg::Frame(next.clone())),
        };
        last = next;
        if let Some(update) = update {
            if to_client.send(update).is_err() {
                break;
            }
        }
    }
    Ok(())
}
