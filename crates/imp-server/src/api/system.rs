//! Files, directories, the environment, shell commands and the
//! clipboard.

use std::path::{Path, PathBuf};
use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;
use steel::SteelVal;

use super::fail;
use crate::clipboard;
use crate::editor;
use crate::shell;

pub(super) fn register(engine: &mut Engine) {
    // Files and processes.
    engine.register_fn("write-file!", |path: String| {
        editor::with(|e| {
            e.buffer()
                .write_to(Path::new(&path))
                .map_err(|err| fail(format!("{path}: {err}")))
        })
    });
    engine.register_fn("set-buffer-path!", |path: String| {
        editor::with(|e| e.buffer_mut().set_path(Some(PathBuf::from(path))))
    });
    engine.register_fn("read-file", |path: String| {
        std::fs::read_to_string(&path).map_err(|err| fail(format!("{path}: {err}")))
    });
    engine.register_fn("file-exists?", |path: String| Path::new(&path).exists());
    // Milliseconds since the epoch the file was modified, or #f.
    engine.register_fn("file-mtime", |path: String| {
        std::fs::metadata(&path)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_millis() as isize)
    });
    engine.register_fn("write-text-file!", |path: String, text: String| {
        let path = Path::new(&path);
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(fail)?;
        }
        imp_core::fileio::write_atomic(path, text.as_bytes(), false).map_err(fail)
    });
    // (permissions size mtime) for `path`, not following a symlink:
    // permissions as ls shows them ("drwxr-xr-x"), size in bytes, mtime
    // in seconds since the epoch. #f if it isn't there.
    engine.register_fn("file-info", |path: String| {
        let m = std::fs::symlink_metadata(&path).ok()?;
        let mtime = m
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map_or(0, |d| d.as_secs() as isize);
        Some(vec![
            SteelVal::StringV(crate::files::permissions(&m).into()),
            SteelVal::IntV(m.len() as isize),
            SteelVal::IntV(mtime),
        ])
    });
    engine.register_fn("delete-file!", |path: String| {
        std::fs::remove_file(&path).map_err(|err| fail(format!("{path}: {err}")))
    });
    // Directories, for the file browser.
    engine.register_fn("file-directory?", |path: String| Path::new(&path).is_dir());
    // (name directory?) for each entry of `path`, dotfiles included,
    // sorted by name; an error if it can't be read.
    engine.register_fn(
        "directory-entries",
        |path: String| match std::fs::read_dir(&path) {
            Ok(dir) => {
                let mut entries: Vec<(String, bool)> = dir
                    .filter_map(Result::ok)
                    .map(|e| {
                        let is_dir = e.path().is_dir();
                        (e.file_name().to_string_lossy().into_owned(), is_dir)
                    })
                    .collect();
                entries.sort();
                Ok(SteelVal::ListV(
                    entries
                        .into_iter()
                        .map(|(name, is_dir)| {
                            SteelVal::ListV(
                                vec![SteelVal::StringV(name.into()), SteelVal::BoolV(is_dir)]
                                    .into(),
                            )
                        })
                        .collect::<Vec<_>>()
                        .into(),
                ))
            }
            Err(err) => Err(fail(format!("{path}: {err}"))),
        },
    );
    // The names in a directory git ignores, for the file tree.
    engine.register_fn("directory-ignored", |path: String| {
        crate::files::ignored(&path)
    });
    let outcome =
        |r: std::io::Result<()>, what: &str| r.map_err(|err| fail(format!("{what}: {err}")));
    engine.register_fn("rename-file!", move |from: String, to: String| {
        if Path::new(&to).exists() {
            return Err(fail(format!("{to} already exists")));
        }
        outcome(std::fs::rename(&from, &to), &from)
    });
    // Copies a file, its permissions too; refuses to overwrite one.
    engine.register_fn("copy-file!", move |from: String, to: String| {
        if Path::new(&to).exists() {
            return Err(fail(format!("{to} already exists")));
        }
        outcome(std::fs::copy(&from, &to).map(|_| ()), &from)
    });
    engine.register_fn("make-directory!", move |path: String| {
        outcome(std::fs::create_dir_all(&path), &path)
    });
    // Deletes a file, or a directory and everything in it.
    engine.register_fn("delete-path!", move |path: String| {
        let p = Path::new(&path);
        let r = if p.is_dir() && !p.is_symlink() {
            std::fs::remove_dir_all(p)
        } else {
            std::fs::remove_file(p)
        };
        outcome(r, &path)
    });
    // $XDG_STATE_HOME/imp, or ~/.local/state/imp.
    engine.register_fn("state-dir", || {
        std::env::var_os("XDG_STATE_HOME")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/state")))
            .map(|d| d.join("imp").display().to_string())
            .unwrap_or_else(|| ".".to_string())
    });

    engine.register_fn("getenv", |name: String| std::env::var(name).ok());
    engine.register_fn("imp-version", || env!("CARGO_PKG_VERSION"));
    // imp's config directory (where init.scm and packages/ live).
    engine.register_fn("config-dir", || {
        crate::user_config_path()
            .and_then(|p| p.parent().map(|d| d.display().to_string()))
            .unwrap_or_else(|| ".".to_string())
    });
    engine.register_fn("current-dir", || {
        std::env::current_dir()
            .map(|d| d.display().to_string())
            .unwrap_or_else(|_| ".".to_string())
    });
    // Runs `command` with sh, feeding it `input`. Returns (exit-code output),
    // the output being stdout and stderr together.
    engine.register_fn("run-shell", |command: String, input: String| {
        shell::run(&command, &input)
            .map_err(fail)
            .map(|(code, out)| vec![SteelVal::IntV(code as isize), SteelVal::StringV(out.into())])
    });

    // The system clipboard. `primary?` picks the primary selection ("*).
    engine.register_fn("clipboard-get", |primary: bool| clipboard::get(primary));
    engine.register_fn("clipboard-set!", |text: String, primary: bool| {
        clipboard::set(&text, primary)
    });

    // The full path of an executable on $PATH, or #f.
    engine.register_fn("find-executable", |name: String| {
        if name.contains('/') {
            return Path::new(&name).is_file().then_some(name);
        }
        std::env::var_os("PATH").and_then(|paths| {
            std::env::split_paths(&paths)
                .map(|dir| dir.join(&name))
                .find(|p| p.is_file())
                .map(|p| p.display().to_string())
        })
    });
    engine.register_fn("absolute-path", |path: String| {
        std::path::absolute(&path)
            .map(|p| p.display().to_string())
            .unwrap_or(path)
    });

    // Seconds since 1970, for what needs to know how long ago.
    engine.register_fn("unix-time", || {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs() as isize)
    });
}
