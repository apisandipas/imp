//! The imp server: owns the buffers and the Steel VM, turns client input into
//! frames.
//!
//! Key handling is entirely in Scheme. For each key the server calls
//! `(imp-handle-key key)`, which the runtime (`runtime/*.scm`) defines and the
//! user's `init.scm` may redefine.

mod api;
mod clipboard;
mod editor;
mod render;
mod search;

use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, Sender};

use imp_core::{Buffer, ClientMsg, Frame, ServerMsg};
use steel::steel_vm::engine::Engine;
use steel::SteelVal;

use editor::Editor;

/// The runtime Scheme files, in load order. Embedded so the binary works on
/// its own; set `IMP_RUNTIME` to a directory to load them from disk instead,
/// which lets you edit them without rebuilding.
const RUNTIME: &[(&str, &str)] = &[
    ("core.scm", include_str!("../../../runtime/core.scm")),
    ("vim.scm", include_str!("../../../runtime/vim.scm")),
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
}

impl Server {
    pub fn new(buffer: Buffer, options: Options) -> Result<Self, String> {
        editor::install(Editor {
            buffer,
            width: 80,
            height: 24,
            tab_width: 8,
            ..Editor::default()
        });

        let mut engine = Engine::new();
        api::register(&mut engine);

        let runtime_dir = std::env::var_os("IMP_RUNTIME").map(PathBuf::from);
        for (name, embedded) in RUNTIME {
            let source = match &runtime_dir {
                Some(dir) => std::fs::read_to_string(dir.join(name))
                    .map_err(|e| format!("{}: {e}", dir.join(name).display()))?,
                None => embedded.to_string(),
            };
            engine
                .run(source)
                .map_err(|e| format!("runtime/{name}: {e}"))?;
        }

        let mut server = Self { engine };
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

    fn load_file(&mut self, path: &Path) -> Result<(), String> {
        let source =
            std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
        self.engine
            .run(source)
            .map(|_| ())
            .map_err(|e| format!("{}: {e}", path.display()))
    }

    /// Calls a Scheme function, reporting any error on the status line.
    fn call(&mut self, function: &str, args: Vec<SteelVal>) {
        if let Err(e) = self.engine.call_function_by_name_with_args(function, args) {
            editor::with(|ed| ed.status = format!("error: {e}"));
        }
    }

    pub fn handle(&mut self, msg: ClientMsg) {
        match msg {
            ClientMsg::Key(key) => self.call("imp-handle-key", vec![SteelVal::StringV(key.into())]),
            ClientMsg::Resize { width, height } => editor::with(|e| {
                e.width = width;
                e.height = height;
            }),
        }
    }

    /// Runs Scheme source in the editor's VM and returns the printed value of
    /// the last expression.
    pub fn eval(&mut self, source: &str) -> Result<String, String> {
        let values = self
            .engine
            .run(source.to_string())
            .map_err(|e| e.to_string())?;
        Ok(values.last().map(|v| v.to_string()).unwrap_or_default())
    }

    /// Feeds each key in turn. Convenient for tests.
    pub fn keys(&mut self, keys: &[&str]) {
        for key in keys {
            self.handle(ClientMsg::Key(key.to_string()));
        }
    }

    pub fn frame(&mut self) -> Frame {
        editor::with(render::frame)
    }

    pub fn should_quit(&self) -> bool {
        editor::with(|e| e.quit)
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
    buffer: Buffer,
    options: Options,
    from_client: Receiver<ClientMsg>,
    to_client: Sender<ServerMsg>,
) -> Result<(), String> {
    let mut server = Server::new(buffer, options)?;
    if to_client.send(ServerMsg::Frame(server.frame())).is_err() {
        return Ok(());
    }
    for msg in from_client {
        server.handle(msg);
        if server.should_quit() {
            let _ = to_client.send(ServerMsg::Quit);
            break;
        }
        if to_client.send(ServerMsg::Frame(server.frame())).is_err() {
            break;
        }
    }
    Ok(())
}
