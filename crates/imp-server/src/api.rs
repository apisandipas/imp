//! The Rust functions Scheme can call.
//!
//! This is the boundary from the design: Rust owns data and speed, Scheme owns
//! behavior. Everything here is a primitive -- read the buffer, change it,
//! move the cursor, report state. What a key *means* is decided in Scheme.
//!
//! Offsets and counts are `isize` because Steel integers are signed; negative
//! values clamp to zero.

use imp_core::{CursorShape, Style};
use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;

use crate::clipboard;
use crate::complete;
use crate::editor::{self, Editor, Highlight};
use crate::files;
use crate::fuzzy;
use crate::scan;
use crate::search;
use crate::shell;
use std::path::{Path, PathBuf};
use steel::SteelVal;

/// A popup line from Scheme: a string, or a list of strings and (text
/// face) lists.
fn popup_line(value: &SteelVal) -> crate::editor::PopupLine {
    let text = |v: &SteelVal| match v {
        SteelVal::StringV(s) => s.to_string(),
        other => other.to_string(),
    };
    match value {
        SteelVal::ListV(runs) => runs
            .iter()
            .map(|run| match run {
                SteelVal::ListV(parts) if parts.len() == 2 => {
                    (text(&parts[0]), text(parts.iter().nth(1).unwrap()))
                }
                other => (text(other), String::new()),
            })
            .collect(),
        other => vec![(text(other), String::new())],
    }
}

fn clamp(n: isize) -> usize {
    n.max(0) as usize
}

/// Fails if the current buffer is read-only.
fn writable(e: &Editor) -> Result<(), String> {
    if e.buffer.read_only {
        Err("E21: Cannot make changes, 'modifiable' is off".into())
    } else {
        Ok(())
    }
}

/// A syntax node for Scheme: (kind field start end named?).
fn node_value(kind: String, field: String, start: usize, end: usize, named: bool) -> SteelVal {
    SteelVal::ListV(
        vec![
            SteelVal::StringV(kind.into()),
            SteelVal::StringV(field.into()),
            SteelVal::IntV(start as isize),
            SteelVal::IntV(end as isize),
            SteelVal::BoolV(named),
        ]
        .into(),
    )
}

pub fn register(engine: &mut Engine) {
    // Reading the buffer.
    engine.register_fn("buffer-length", || {
        editor::with(|e| e.buffer.len() as isize)
    });
    engine.register_fn("buffer-char-at", |offset: isize| {
        editor::with(|e| e.buffer.char_at(clamp(offset)))
    });
    // Steel has no char-alphabetic?, and Unicode classification belongs here
    // anyway. Word chars are letters, digits and underscore, as in Vim.
    engine.register_fn("char-word?", |c: char| c.is_alphanumeric() || c == '_');
    engine.register_fn("buffer-substring", |start: isize, end: isize| {
        editor::with(|e| e.buffer.slice(clamp(start), clamp(end)))
    });
    engine.register_fn("buffer-line-count", || {
        editor::with(|e| e.buffer.line_count() as isize)
    });
    engine.register_fn("buffer-line-length", |line: isize| {
        editor::with(|e| e.buffer.line_len(clamp(line)) as isize)
    });
    engine.register_fn("line-col->offset", |line: isize, col: isize| {
        editor::with(|e| e.buffer.line_col_to_offset(clamp(line), clamp(col)) as isize)
    });
    engine.register_fn("offset->line", |offset: isize| {
        editor::with(|e| e.buffer.offset_to_line(clamp(offset)) as isize)
    });
    engine.register_fn("offset->col", |offset: isize| {
        editor::with(|e| e.buffer.offset_to_col(clamp(offset)) as isize)
    });
    engine.register_fn("buffer-path", || {
        editor::with(|e| e.buffer.path().map(|p| p.display().to_string()))
    });
    engine.register_fn("buffer-version", || {
        editor::with(|e| e.buffer.version() as isize)
    });
    engine.register_fn("buffer-modified?", || {
        editor::with(|e| e.buffer.is_modified())
    });
    engine.register_fn("buffer-name", || editor::with(|e| e.buffer.display_name()));

    // Buffers. The primitives above act on the current buffer; these list
    // buffers and switch between them. Ids are integers.
    engine.register_fn("buffer-list", || {
        editor::with(|e| {
            e.buffer_ids()
                .into_iter()
                .map(|id| id as isize)
                .collect::<Vec<_>>()
        })
    });
    engine.register_fn("current-buffer", || editor::with(|e| e.current as isize));
    engine.register_fn("switch-to-buffer!", |id: isize| {
        editor::with(|e| e.switch_to(clamp(id)))
    });
    // The id of the buffer visiting `path`, opening the file if no buffer
    // does yet (a missing file opens empty). Errors come back as a string.
    engine.register_fn("buffer-open!", |path: String| {
        editor::with(|e| {
            let path = PathBuf::from(&path);
            if let Some(id) = e.find_file_buffer(&path) {
                return SteelVal::IntV(id as isize);
            }
            match imp_core::Buffer::open(&path) {
                Ok(buffer) => SteelVal::IntV(e.add_buffer(buffer) as isize),
                Err(err) => SteelVal::StringV(format!("{}: {err}", path.display()).into()),
            }
        })
    });
    // A new buffer with no file; `name` may be "" for "[No Name]".
    engine.register_fn("buffer-new!", |name: String| {
        editor::with(|e| {
            let mut buffer = imp_core::Buffer::default();
            if !name.is_empty() {
                buffer.set_name(Some(name));
            }
            e.add_buffer(buffer) as isize
        })
    });
    engine.register_fn("buffer-kill!", |id: isize| {
        editor::with(|e| e.kill_buffer(clamp(id)))
    });
    // (name path-or-#f modified?) for buffer `id`, or #f.
    engine.register_fn("buffer-info", |id: isize| {
        editor::with(|e| {
            e.buffer_by_id(clamp(id)).map(|b| {
                vec![
                    SteelVal::StringV(b.display_name().into()),
                    match b.path() {
                        Some(p) => SteelVal::StringV(p.display().to_string().into()),
                        None => SteelVal::BoolV(false),
                    },
                    SteelVal::BoolV(b.is_modified()),
                ]
            })
        })
    });
    engine.register_fn("buffer-changed-on-disk?", || {
        editor::with(|e| e.buffer.changed_on_disk())
    });
    engine.register_fn("buffer-forget-disk-change!", || {
        editor::with(|e| e.buffer.forget_disk_change())
    });
    // ("unix"|"dos" "utf-8"|"latin1" bom?) for the current buffer.
    engine.register_fn("buffer-file-format", || {
        editor::with(|e| {
            let f = e.buffer.format();
            vec![
                SteelVal::StringV(if f.crlf { "dos" } else { "unix" }.into()),
                SteelVal::StringV(
                    match f.encoding {
                        imp_core::fileio::Encoding::Utf8 => "utf-8",
                        imp_core::fileio::Encoding::Latin1 => "latin1",
                    }
                    .into(),
                ),
                SteelVal::BoolV(f.bom),
            ]
        })
    });
    engine.register_fn(
        "set-buffer-file-format!",
        |ff: String, encoding: String, bom: bool| {
            use imp_core::fileio::{Encoding, FileFormat};
            let encoding = match encoding.as_str() {
                "latin1" | "latin-1" | "iso-8859-1" => Encoding::Latin1,
                "utf-8" | "utf8" => Encoding::Utf8,
                other => return Err(format!("unknown encoding {other}")),
            };
            let crlf = match ff.as_str() {
                "dos" => true,
                "unix" => false,
                other => return Err(format!("unknown fileformat {other}")),
            };
            editor::with(|e| {
                e.buffer.set_format(FileFormat {
                    crlf,
                    bom,
                    encoding,
                })
            });
            Ok(())
        },
    );
    engine.register_fn("set-backup!", |on: bool| {
        editor::with(|e| e.buffer.backup = on)
    });
    engine.register_fn("buffer-reload!", || {
        editor::with(|e| e.buffer.reload().map_err(|err| err.to_string()))
    });
    engine.register_fn("set-buffer-unmodified!", || {
        editor::with(|e| e.buffer.set_unmodified())
    });
    engine.register_fn("set-buffer-name!", |name: String| {
        editor::with(|e| e.buffer.set_name(Some(name)))
    });

    // Changing the buffer.
    engine.register_fn("buffer-insert!", |offset: isize, text: String| {
        editor::with(|e| {
            if !text.is_empty() {
                writable(e)?;
            }
            e.buffer.insert(clamp(offset), &text);
            Ok::<_, String>(())
        })
    });
    engine.register_fn("buffer-delete!", |start: isize, end: isize| {
        editor::with(|e| {
            if start < end {
                writable(e)?;
            }
            Ok::<_, String>(e.buffer.delete(clamp(start), clamp(end)))
        })
    });
    engine.register_fn("set-buffer-read-only!", |on: bool| {
        editor::with(|e| e.buffer.read_only = on)
    });
    engine.register_fn("buffer-read-only?", || editor::with(|e| e.buffer.read_only));
    // Files and processes.
    engine.register_fn("write-file!", |path: String| {
        editor::with(|e| {
            e.buffer
                .write_to(Path::new(&path))
                .map_err(|err| format!("{path}: {err}"))
        })
    });
    engine.register_fn("set-buffer-path!", |path: String| {
        editor::with(|e| e.buffer.set_path(Some(PathBuf::from(path))))
    });
    engine.register_fn("read-file", |path: String| {
        std::fs::read_to_string(&path).map_err(|err| format!("{path}: {err}"))
    });
    engine.register_fn("file-exists?", |path: String| Path::new(&path).exists());
    // Seconds since the epoch the file was modified, or #f.
    engine.register_fn("file-mtime", |path: String| {
        std::fs::metadata(&path)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as isize)
    });
    engine.register_fn("write-text-file!", |path: String, text: String| {
        let path = Path::new(&path);
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        imp_core::fileio::write_atomic(path, text.as_bytes(), false).map_err(|e| e.to_string())
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
        std::fs::remove_file(path).is_ok()
    });
    // Directories, for the file browser. The changing ones return #t, or
    // what went wrong as a string.
    engine.register_fn("file-directory?", |path: String| Path::new(&path).is_dir());
    // (name directory?) for each entry of `path`, dotfiles included,
    // sorted by name; an error string if it can't be read.
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
                SteelVal::ListV(
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
                )
            }
            Err(err) => SteelVal::StringV(format!("{path}: {err}").into()),
        },
    );
    let outcome = |r: std::io::Result<()>, what: &str| match r {
        Ok(()) => SteelVal::BoolV(true),
        Err(err) => SteelVal::StringV(format!("{what}: {err}").into()),
    };
    engine.register_fn("rename-file!", move |from: String, to: String| {
        if Path::new(&to).exists() {
            return SteelVal::StringV(format!("{to} already exists").into());
        }
        outcome(std::fs::rename(&from, &to), &from)
    });
    // Copies a file, its permissions too; refuses to overwrite one.
    engine.register_fn("copy-file!", move |from: String, to: String| {
        if Path::new(&to).exists() {
            return SteelVal::StringV(format!("{to} already exists").into());
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
    // Why `text` doesn't parse as Scheme, or #f if it does. `read` just
    // stops at an unclosed paren, so loaders check with this first.
    engine.register_fn("parse-error", |text: String| {
        steel::parser::parser::Parser::parse(&text)
            .err()
            .map(|e| e.to_string())
    });

    // Loaded Scheme sources, newest last.
    engine.register_fn(
        "record-source!",
        |name: String, path: String, text: String| {
            editor::with(|e| {
                let path = (!path.is_empty()).then_some(path);
                e.sources.retain(|(n, _, _)| *n != name);
                e.sources.push((name, path, text));
            })
        },
    );
    // A package that comes with imp: (source-name path text), path "" when
    // it's the copy built into the binary; #f if there's none called that.
    engine.register_fn("builtin-package", |name: String| {
        crate::builtin_package(&name).map(|(source, path, text)| {
            SteelVal::ListV(
                vec![
                    SteelVal::StringV(source.into()),
                    SteelVal::StringV(path.unwrap_or_default().into()),
                    SteelVal::StringV(text.into()),
                ]
                .into(),
            )
        })
    });
    engine.register_fn("builtin-package-names", || {
        crate::PACKAGES
            .iter()
            .map(|(name, _)| name.to_string())
            .collect::<Vec<_>>()
    });
    engine.register_fn("source-names", || {
        editor::with(|e| {
            e.sources
                .iter()
                .map(|(n, _, _)| n.clone())
                .collect::<Vec<_>>()
        })
    });
    engine.register_fn("source-text", |name: String| {
        editor::with(|e| {
            e.sources
                .iter()
                .find(|(n, _, _)| *n == name)
                .map(|(_, _, t)| t.clone())
        })
    });
    engine.register_fn("source-path", |name: String| {
        editor::with(|e| {
            e.sources
                .iter()
                .find(|(n, _, _)| *n == name)
                .and_then(|(_, p, _)| p.clone())
        })
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
            .map(|(code, out)| vec![SteelVal::IntV(code as isize), SteelVal::StringV(out.into())])
    });

    engine.register_fn("undo-boundary!", || {
        editor::with(|e| e.buffer.undo_boundary())
    });
    // Both return the offset where the text changed, or #f if there was
    // nothing to undo or redo.
    engine.register_fn("undo!", || {
        editor::with(|e| {
            writable(e)?;
            Ok::<_, String>(e.buffer.undo().map(|at| at as isize))
        })
    });
    engine.register_fn("redo!", || {
        editor::with(|e| {
            writable(e)?;
            Ok::<_, String>(e.buffer.redo().map(|at| at as isize))
        })
    });
    engine.register_fn("save!", || {
        editor::with(|e| match e.buffer.save() {
            Ok(()) => true,
            Err(err) => {
                e.status = format!("save failed: {err}");
                false
            }
        })
    });

    // Marks: positions that move with the text.
    engine.register_fn("mark-set!", |name: String, offset: isize| {
        editor::with(|e| e.buffer.set_mark(&name, clamp(offset)))
    });
    // A mark that stays put when text is inserted right at it.
    engine.register_fn("mark-set-sticky!", |name: String, offset: isize| {
        editor::with(|e| e.buffer.set_sticky_mark(&name, clamp(offset)))
    });
    engine.register_fn("mark-get", |name: String| {
        editor::with(|e| e.buffer.mark(&name).map(|m| m as isize))
    });
    engine.register_fn("mark-delete!", |name: String| {
        editor::with(|e| e.buffer.delete_mark(&name))
    });
    engine.register_fn("mark-names", || editor::with(|e| e.buffer.mark_names()));

    // The cursor.
    engine.register_fn("cursor", || editor::with(|e| e.cursor as isize));
    engine.register_fn("set-cursor!", |offset: isize| {
        editor::with(|e| e.cursor = clamp(offset).min(e.buffer.len()))
    });

    // Windows. Ids are integers; the current window's buffer is the current
    // buffer, so the buffer primitives act on what it shows.
    engine.register_fn("window-list", || {
        editor::with(|e| {
            e.layout
                .windows()
                .into_iter()
                .map(|w| w as isize)
                .collect::<Vec<_>>()
        })
    });
    engine.register_fn("current-window", || {
        editor::with(|e| e.current_window as isize)
    });
    // `where` is "above", "below", "left" or "right" of the current window.
    engine.register_fn("split-window!", |place: String| {
        use crate::layout::Dir;
        let (dir, before) = match place.as_str() {
            "above" => (Dir::Column, true),
            "left" => (Dir::Row, true),
            "right" => (Dir::Row, false),
            _ => (Dir::Column, false),
        };
        editor::with(|e| e.split_window(dir, before) as isize)
    });
    // A window along an edge of the whole frame ("above", "below", "left"
    // or "right"), `fraction` of its height or width.
    engine.register_fn("split-frame!", |place: String, fraction: f64| {
        use crate::layout::Dir;
        let (dir, before) = match place.as_str() {
            "above" => (Dir::Column, true),
            "left" => (Dir::Row, true),
            "right" => (Dir::Row, false),
            _ => (Dir::Column, false),
        };
        editor::with(|e| e.split_frame(dir, before, fraction) as isize)
    });
    engine.register_fn("close-window!", |id: isize| {
        editor::with(|e| e.close_window(clamp(id)))
    });
    engine.register_fn("focus-window!", |id: isize| {
        editor::with(|e| e.focus_window(clamp(id)))
    });
    engine.register_fn("only-window!", || editor::with(|e| e.only_window()));
    engine.register_fn("window-buffer", |id: isize| {
        editor::with(|e| e.windows.get(&clamp(id)).map(|w| w.buffer as isize))
    });
    // The window to the "left", "right", "up" or "down" of the current
    // one, or #f.
    engine.register_fn("window-in-direction", |dir: String| {
        editor::with(|e| {
            let (dx, dy) = match dir.as_str() {
                "left" => (-1, 0),
                "right" => (1, 0),
                "up" => (0, -1),
                _ => (0, 1),
            };
            let frame = crate::render::frame(e);
            let cursor = (frame.cursor.0 as usize, frame.cursor.1 as usize);
            e.window_in_direction(dx, dy, cursor).map(|w| w as isize)
        })
    });
    // Grows the current window by `delta` rows ("height") or columns
    // ("width"), taking the space from a neighbor.
    engine.register_fn("resize-window!", |what: String, delta: isize| {
        use crate::layout::Dir;
        let dir = if what == "width" {
            Dir::Row
        } else {
            Dir::Column
        };
        editor::with(|e| {
            let area = e.windows_area();
            let id = e.current_window;
            e.layout.resize(id, dir, delta, area)
        })
    });
    engine.register_fn("equalize-windows!", || {
        editor::with(|e| e.layout.equalize())
    });
    // What clients do beyond the grid: "font" (a family, "" for the
    // client's), "font-size" and "padding" (logical pixels),
    // "transparency" (percent) and "clear-terminal-background".
    engine.register_fn("set-appearance!", |what: String, value: SteelVal| {
        let int = |v: &SteelVal| match v {
            SteelVal::IntV(n) => Ok(*n),
            SteelVal::NumV(f) => Ok(f.round() as isize),
            _ => Err(format!("{what}: expected a number")),
        };
        editor::with(|e| {
            let a = &mut e.appearance;
            match what.as_str() {
                "font" => match &value {
                    SteelVal::StringV(s) => a.font = s.to_string(),
                    _ => return Err("font: expected a string".to_string()),
                },
                "font-size" => a.font_size = int(&value)?.clamp(0, 400) as u16,
                "padding" => a.padding = int(&value)?.clamp(0, 1000) as u16,
                "transparency" => a.transparency = int(&value)?.clamp(0, 100) as u8,
                "clear-terminal-background" => {
                    a.clear_terminal_background = matches!(value, SteelVal::BoolV(true))
                }
                _ => return Err(format!("no appearance setting {what}")),
            }
            Ok(())
        })
    });
    engine.register_fn("set-wrap!", |on: bool| editor::with(|e| e.wrap = on));
    engine.register_fn("set-linebreak!", |on: bool| {
        editor::with(|e| e.linebreak = on)
    });
    // Display columns, for motions over screen rows (gj, gk).
    engine.register_fn("line-display-col", |line: isize, col: isize| {
        editor::with(|e| crate::render::display_col(e, clamp(line), clamp(col)) as isize)
    });
    engine.register_fn("line-col-at-display", |line: isize, x: isize| {
        editor::with(|e| crate::render::col_at_display(e, clamp(line), clamp(x)) as isize)
    });
    engine.register_fn("window-text-width", || {
        editor::with(|e| crate::render::window_text_width(e) as isize)
    });

    // Timers and jobs (events.rs). Scheme's wrappers in core.scm keep the
    // procedures to call; these just start, stop and talk to them.
    engine.register_fn("timer-start!", |ms: isize, repeat: bool| {
        editor::with(|e| {
            e.background
                .start_timer(clamp(ms) as u64, repeat)
                .map(|id| id as isize)
        })
    });
    engine.register_fn("timer-cancel!", |id: isize| {
        editor::with(|e| e.background.cancel_timer(clamp(id) as u64))
    });
    engine.register_fn("timer-done!", |id: isize, repeat: bool| {
        editor::with(|e| e.background.timer_fired(clamp(id) as u64, repeat))
    });
    // The job's id, or an error message. Input #f keeps stdin open.
    engine.register_fn("job-start!", |command: String, input: SteelVal| {
        let input = match &input {
            SteelVal::StringV(s) => Some(s.to_string()),
            _ => None,
        };
        editor::with(
            |e| match e.background.start_job(&command, input.as_deref()) {
                Ok(id) => SteelVal::IntV(id as isize),
                Err(err) => SteelVal::StringV(err.into()),
            },
        )
    });
    engine.register_fn("job-send!", |id: isize, text: String| {
        editor::with(|e| e.background.send_to_job(clamp(id) as u64, &text))
    });
    engine.register_fn("job-close-input!", |id: isize| {
        editor::with(|e| e.background.close_job_input(clamp(id) as u64))
    });
    engine.register_fn("job-kill!", |id: isize| {
        editor::with(|e| e.background.kill_job(clamp(id) as u64))
    });

    // The system clipboard. `primary?` picks the primary selection ("*).
    engine.register_fn("clipboard-get", |primary: bool| clipboard::get(primary));
    engine.register_fn("clipboard-set!", |text: String, primary: bool| {
        clipboard::set(&text, primary)
    });

    // The window: which buffer lines are on screen.
    engine.register_fn("window-top", || editor::with(|e| e.scroll as isize));
    engine.register_fn("window-width", || editor::with(|e| e.width as isize));
    engine.register_fn("window-height", || editor::with(|e| e.text_rows() as isize));
    engine.register_fn("set-window-top!", |line: isize| {
        editor::with(|e| e.scroll = clamp(line).min(e.buffer.line_count().saturating_sub(1)))
    });

    // "off", "absolute", "relative" or "hybrid".
    engine.register_fn("set-line-numbers!", |mode: String| {
        use crate::render::LineNumbers;
        editor::with(|e| {
            e.line_numbers = match mode.as_str() {
                "absolute" => LineNumbers::Absolute,
                "relative" => LineNumbers::Relative,
                "hybrid" => LineNumbers::Hybrid,
                _ => LineNumbers::Off,
            }
        })
    });
    engine.register_fn("set-cursorline!", |on: bool| {
        editor::with(|e| e.cursorline = on)
    });
    engine.register_fn("set-tab-width!", |width: isize| {
        editor::with(|e| e.tab_width = clamp(width).clamp(1, 32))
    });

    // Telling the user what's going on.
    engine.register_fn("set-status!", |text: String| {
        editor::with(|e| e.status = text)
    });
    engine.register_fn("status-text", || editor::with(|e| e.status.clone()));
    engine.register_fn("set-mode-line-extra!", |text: String| {
        editor::with(|e| e.mode_line_extra = text)
    });
    engine.register_fn("set-mode-name!", |name: String| {
        editor::with(|e| e.mode_name = name)
    });
    engine.register_fn("set-cursor-shape!", |shape: String| {
        editor::with(|e| {
            e.cursor_shape = match shape.as_str() {
                "bar" => CursorShape::Bar,
                "underline" => CursorShape::Underline,
                _ => CursorShape::Block,
            }
        })
    });
    engine.register_fn("quit!", || editor::with(|e| e.quit = true));
    // Stops a daemon (for every client). Standalone, the same as quit!.
    engine.register_fn("kill-server!", || {
        editor::with(|e| {
            e.kill_server = true;
            e.quit = true;
        })
    });
    // Lines shown above the status line until cleared, for output longer
    // than the status line (:registers) and menus (which-key).
    engine.register_fn("set-cmdline!", |text: String, col: isize| {
        editor::with(|e| e.cmdline = Some((text, clamp(col))))
    });
    engine.register_fn("clear-cmdline!", || editor::with(|e| e.cmdline = None));
    // Each line is a string, or a list of runs: strings, or (text face)
    // lists. Clearing the popup puts it back at the bottom, untitled.
    engine.register_fn("set-popup!", |lines: Vec<SteelVal>| {
        let lines: Vec<crate::editor::PopupLine> = lines.iter().map(popup_line).collect();
        editor::with(|e| {
            if lines.is_empty() {
                e.popup_at_cursor = None;
                e.popup_center = None;
                e.popup_title.clear();
            }
            e.popup = lines
        })
    });
    // Where the popup goes: "bottom", or "cursor" shifted `dx` columns;
    // and its title.
    engine.register_fn(
        "set-popup-place!",
        |place: String, dx: isize, title: String| {
            editor::with(|e| {
                e.popup_at_cursor = (place == "cursor").then_some(dx);
                e.popup_center = (place == "center").then_some(dx.clamp(20, 100) as usize);
                e.popup_title = title;
            })
        },
    );
    // The status line formats (see render::status_line) and their values.
    engine.register_fn("set-statusline!", |focused: String, others: String| {
        editor::with(|e| {
            e.statusline = focused;
            e.statusline_inactive = others;
        })
    });
    engine.register_fn("set-mode-face!", |face: String| {
        editor::with(|e| e.mode_face = face)
    });
    // A %{name} value for the current buffer, or every buffer if
    // `global?`.
    engine.register_fn(
        "set-status-value!",
        |name: String, value: String, global: bool| {
            editor::with(|e| {
                let id = if global { usize::MAX } else { e.current };
                e.status_values.entry(id).or_default().insert(name, value);
            })
        },
    );

    // Faces and highlights. Scheme decides what is highlighted; Rust draws it.
    engine.register_fn("set-face!", |name: String, spec: String| {
        let style = Style::parse(&spec)?;
        editor::with(|e| e.faces.insert(name, style));
        Ok::<(), String>(())
    });
    // Every face's name, sorted; a face's spec ("fg=#rrggbb bold"), or #f
    // if there's no such face; and the faces drawn at an offset of the
    // current buffer, bottom first. For describe-face and list-faces.
    engine.register_fn("face-names", || {
        editor::with(|e| {
            let mut names: Vec<String> = e.faces.keys().cloned().collect();
            names.sort();
            names
        })
    });
    engine.register_fn("face-spec", |name: String| {
        editor::with(|e| e.faces.get(&name).map(|s| s.spec()))
    });
    engine.register_fn("faces-at", |at: isize| {
        editor::with(|e| {
            e.update_syntax(e.current);
            crate::render::faces_at(e, clamp(at))
        })
    });
    engine.register_fn("highlight-clear!", |layer: String| {
        editor::with(|e| {
            let layer = e.layer_mut(&layer);
            layer.ranges.clear();
            layer.pattern = None;
        })
    });
    engine.register_fn(
        "highlight-pattern!",
        |layer: String, pattern: String, face: String| {
            let re = search::compile(&pattern)?;
            editor::with(|e| e.layer_mut(&layer).pattern = Some((re, face)));
            Ok::<(), String>(())
        },
    );

    // The current buffer's closed folds, as (first last) lines; nested
    // ones are dropped, since the outer fold hides them.
    engine.register_fn("set-closed-folds!", |folds: Vec<Vec<isize>>| {
        let mut ranges: Vec<(usize, usize)> = folds
            .iter()
            .filter_map(|f| match f.as_slice() {
                [a, b] if a <= b => Some((clamp(*a), clamp(*b))),
                _ => None,
            })
            .collect();
        ranges.sort_by_key(|&(a, b)| (a, std::cmp::Reverse(b)));
        let mut outer: Vec<(usize, usize)> = Vec::new();
        for (a, b) in ranges {
            match outer.last_mut() {
                Some(last) if a <= last.1 => last.1 = last.1.max(b),
                _ => outer.push((a, b)),
            }
        }
        editor::with(|e| {
            let id = e.current;
            e.folds.insert(id, outer);
        })
    });
    // Gutter signs for the current buffer: a list of (line text face);
    // '() removes them, and the sign column with them.
    engine.register_fn("set-signs!", |signs: Vec<Vec<SteelVal>>| {
        let mut map = std::collections::BTreeMap::new();
        for sign in signs {
            if let [SteelVal::IntV(line), SteelVal::StringV(text), SteelVal::StringV(face)] =
                sign.as_slice()
            {
                map.insert(clamp(*line), (text.to_string(), face.to_string()));
            }
        }
        editor::with(|e| {
            let id = e.current;
            e.signs.insert(id, map);
        })
    });

    // Display-only text before lines of the current buffer: a list of
    // (line ((text face) ...)). The empty list removes the margin.
    engine.register_fn("set-margin!", |lines: Vec<SteelVal>| {
        let mut map = std::collections::BTreeMap::new();
        for entry in lines {
            let SteelVal::ListV(entry) = entry else {
                continue;
            };
            let (Some(SteelVal::IntV(line)), Some(SteelVal::ListV(parts))) =
                (entry.get(0), entry.get(1))
            else {
                continue;
            };
            let parts = parts
                .iter()
                .filter_map(|part| match part {
                    SteelVal::ListV(p) => match (p.get(0), p.get(1)) {
                        (Some(SteelVal::StringV(text)), Some(SteelVal::StringV(face))) => {
                            Some((text.to_string(), face.to_string()))
                        }
                        (Some(SteelVal::StringV(text)), _) => {
                            Some((text.to_string(), String::new()))
                        }
                        _ => None,
                    },
                    _ => None,
                })
                .collect();
            map.insert(clamp(*line), parts);
        }
        editor::with(|e| {
            let id = e.current;
            if map.is_empty() {
                e.margins.remove(&id);
            } else {
                e.margins.insert(id, map);
            }
        })
    });

    // The width the current buffer's text takes, centred in its windows
    // with blank margins either side; 0 lets it fill the window again.
    engine.register_fn("set-body-width!", |width: isize| {
        editor::with(|e| {
            let id = e.current;
            if width > 0 {
                e.body_widths.insert(id, clamp(width));
            } else {
                e.body_widths.remove(&id);
            }
        })
    });
    engine.register_fn("body-width", || {
        editor::with(|e| e.body_widths.get(&e.current).map_or(0, |w| *w as isize))
    });

    // (window offset) under screen cell (x, y), offset #f on a status
    // line; #f outside every window.
    engine.register_fn("screen-position", |x: isize, y: isize| {
        editor::with(|e| {
            crate::render::screen_position(e, clamp(x), clamp(y)).map(|(w, at)| {
                vec![
                    SteelVal::IntV(w as isize),
                    at.map_or(SteelVal::BoolV(false), |p| SteelVal::IntV(p as isize)),
                ]
            })
        })
    });

    // Unix sockets (events.rs): a listener id, or the error as a string.
    engine.register_fn("socket-listen!", |path: String| {
        editor::with(|e| match e.background.listen(Path::new(&path)) {
            Ok(id) => SteelVal::IntV(id as isize),
            Err(err) => SteelVal::StringV(err.into()),
        })
    });
    // Terminal buffers (term.rs). term-start! returns the terminal's id,
    // or the error as a string.
    engine.register_fn(
        "term-start!",
        |command: String, cwd: String, rows: isize, cols: isize| {
            editor::with(|e| match e.background.sender.clone() {
                Some(sender) => {
                    match crate::term::spawn(
                        &command,
                        &cwd,
                        clamp(rows) as u16,
                        clamp(cols) as u16,
                        sender,
                    ) {
                        Ok(id) => SteelVal::IntV(id as isize),
                        Err(err) => SteelVal::StringV(err.into()),
                    }
                }
                None => SteelVal::StringV("no event loop".into()),
            })
        },
    );
    engine.register_fn("term-send!", |id: isize, text: String| {
        crate::term::send(clamp(id) as u64, &text)
    });
    engine.register_fn("term-resize!", |id: isize, rows: isize, cols: isize| {
        crate::term::resize(clamp(id) as u64, clamp(rows) as u16, clamp(cols) as u16)
    });
    engine.register_fn(
        "term-kill!",
        |id: isize| crate::term::kill(clamp(id) as u64),
    );
    // The theme's colors for ANSI 0-15 in terminals, as "#rrggbb" strings.
    engine.register_fn("set-terminal-palette!", |colors: Vec<String>| {
        let parsed: Result<Vec<_>, _> = colors.iter().map(|c| imp_core::Color::parse(c)).collect();
        parsed.map(|p| crate::term::set_palette(&p))
    });
    engine.register_fn("term-application-cursor?", |id: isize| {
        crate::term::application_cursor(clamp(id) as u64)
    });
    engine.register_fn("term-bracketed-paste?", |id: isize| {
        crate::term::bracketed_paste(clamp(id) as u64)
    });
    // Draws terminal `id` into buffer `buf`; returns its cursor's offset.
    engine.register_fn("term-render!", |id: isize, buf: isize| {
        editor::with(|e| {
            let buf = clamp(buf);
            let mut faces = std::mem::take(&mut e.faces);
            let mut layers = e.buffer_layers.remove(&buf).unwrap_or_default();
            let i = match layers.iter().position(|l| l.name == "term") {
                Some(i) => i,
                None => {
                    layers.push(editor::Layer {
                        name: "term".into(),
                        ..Default::default()
                    });
                    layers.len() - 1
                }
            };
            let at = e.buffer_and_cursor_mut(buf).and_then(|(buffer, _)| {
                crate::term::render(clamp(id) as u64, buffer, &mut faces, &mut layers[i])
            });
            e.faces = faces;
            e.buffer_layers.insert(buf, layers);
            at.map(|a| a as isize)
        })
    });
    // A connection id, or the error as a string.
    engine.register_fn("socket-connect!", |path: String| {
        editor::with(|e| match e.background.connect(Path::new(&path)) {
            Ok(id) => SteelVal::IntV(id as isize),
            Err(err) => SteelVal::StringV(err.into()),
        })
    });
    engine.register_fn("socket-stop!", |id: isize| {
        editor::with(|e| e.background.stop_listening(clamp(id) as u64))
    });
    engine.register_fn("socket-send!", |conn: isize, text: String| {
        editor::with(|e| e.background.send_to_connection(clamp(conn) as u64, &text))
    });
    engine.register_fn("socket-close!", |conn: isize| {
        editor::with(|e| e.background.close_connection(clamp(conn) as u64))
    });
    // Where a socket called `name` goes ($XDG_RUNTIME_DIR/imp/NAME.sock).
    engine.register_fn("socket-path", |name: String| {
        crate::daemon::socket_path(&name).display().to_string()
    });
    // Char offsets of every match of `pattern` in the buffer, up to `limit`.
    engine.register_fn("search-all", |pattern: String, limit: isize| {
        let re = search::compile(&pattern)?;
        Ok::<_, String>(editor::with(|e| {
            let text = e.buffer.text();
            re.find_iter(&text)
                .take(clamp(limit))
                .map(|m| e.buffer.byte_to_char(m.start()) as isize)
                .collect::<Vec<_>>()
        }))
    });

    // Char offsets of each occurrence of `needle` (literal text), up to
    // `limit`.
    engine.register_fn("buffer-find-all", |needle: String, limit: isize| {
        editor::with(|e| {
            if needle.is_empty() {
                return Vec::new();
            }
            let text = e.buffer.text();
            text.match_indices(&needle)
                .take(clamp(limit))
                .map(|(b, _)| e.buffer.byte_to_char(b) as isize)
                .collect::<Vec<_>>()
        })
    });
    engine.register_fn("popup-lines", || {
        editor::with(|e| {
            e.popup
                .iter()
                .map(|l| l.iter().map(|(t, _)| t.as_str()).collect::<String>())
                .collect::<Vec<_>>()
        })
    });

    // JSON and the framing LSP and DAP use (json.rs).
    engine.register_fn("json-decode", |text: String| {
        serde_json::from_str::<serde_json::Value>(&text)
            .map(crate::json::to_steel)
            .map_err(|e| format!("bad JSON: {e}"))
    });
    engine.register_fn("json-encode", |value: SteelVal| {
        crate::json::from_steel(&value).map(|v| v.to_string())
    });
    engine.register_fn("lsp-frame", |body: String| crate::json::frame(&body));
    // (message rest) for the first whole message in `text`, the message
    // already decoded from JSON; or #f.
    engine.register_fn("lsp-take-message", |text: String| {
        crate::json::take_message(&text).map(|(body, rest)| {
            let msg = serde_json::from_str::<serde_json::Value>(&body)
                .map(crate::json::to_steel)
                .unwrap_or(SteelVal::BoolV(false));
            vec![msg, SteelVal::StringV(rest.into())]
        })
    });
    engine.register_fn("path->uri", |path: String| crate::json::path_to_uri(&path));
    engine.register_fn("uri->path", |uri: String| crate::json::uri_to_path(&uri));
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

    // Completion: orderless fuzzy matching (fuzzy.rs) and project files.
    engine.register_fn(
        "fuzzy-filter",
        |query: String, candidates: Vec<String>, limit: isize| {
            fuzzy::filter(&query, &candidates, clamp(limit))
        },
    );
    // Completion at point's hot loops (complete.rs): buffers' words, and
    // the menu's candidates filtered as you type.
    engine.register_fn(
        "buffer-words",
        |ids: Vec<isize>, prefix: String, extra: String, near: isize, limit: isize| {
            let ids: Vec<usize> = ids.into_iter().map(clamp).collect();
            editor::with(|e| {
                complete::buffer_words(e, &ids, &prefix, &extra, clamp(near), clamp(limit))
            })
        },
    );
    engine.register_fn(
        "completion-store-set!",
        |source: isize, priority: isize, labels: Vec<String>, start: isize, starts: Vec<isize>| {
            let starts: Vec<usize> = starts.into_iter().map(clamp).collect();
            complete::set_candidates(
                clamp(source),
                priority as i64,
                labels,
                clamp(start),
                &starts,
            ) as isize
        },
    );
    engine.register_fn("completion-store-clear!", complete::clear_candidates);
    engine.register_fn(
        "completion-store-filter",
        |prefix_only: bool, live: Vec<isize>, fuzzy: Vec<isize>, limit: isize| {
            let live: Vec<usize> = live.into_iter().map(clamp).collect();
            let fuzzy: Vec<usize> = fuzzy.into_iter().map(clamp).collect();
            editor::with(|e| {
                complete::filter_candidates(e, e.cursor, prefix_only, &live, &fuzzy, clamp(limit))
            })
        },
    );
    engine.register_fn("list-files", |root: String, limit: isize| {
        files::list(&root, clamp(limit))
    });
    engine.register_fn("set-popup-selected!", |n: isize| {
        editor::with(|e| e.popup_selected = (n >= 0).then_some(n as usize))
    });

    // Tree-sitter (syntax.rs): a language per buffer, and its tree.
    engine.register_fn("set-buffer-language!", |name: String| {
        editor::with(|e| {
            let id = e.current;
            match crate::syntax::Syntax::new(&name) {
                Some(syntax) => {
                    e.buffer.track_edits(true);
                    e.syntax.insert(id, syntax);
                    true
                }
                None => {
                    e.buffer.track_edits(false);
                    e.syntax.remove(&id);
                    false
                }
            }
        })
    });
    engine.register_fn("buffer-language", || {
        editor::with(|e| e.syntax.get(&e.current).map(|s| s.lang.name.to_string()))
    });
    engine.register_fn("syntax-languages", || {
        let mut names: Vec<String> = crate::syntax::languages()
            .keys()
            .map(|n| n.to_string())
            .collect();
        names.sort();
        names
    });
    // The named nodes around char offset `at`, innermost first, as
    // (kind field start end); the field is "" when the node has none.
    engine.register_fn("syntax-ancestors", |at: isize| {
        editor::with(|e| {
            let id = e.current;
            e.update_syntax(id);
            let Some(root) = e.syntax.get(&id).and_then(|s| s.root()) else {
                return Vec::new();
            };
            crate::syntax::ancestors(root, e.buffer.rope(), clamp(at))
                .into_iter()
                .map(|(k, f, s, t)| node_value(k, f, s, t, true))
                .collect::<Vec<_>>()
        })
    });
    // The children of the node spanning chars start..end, as (kind field
    // start end named?).
    engine.register_fn("syntax-children", |start: isize, end: isize| {
        editor::with(|e| {
            let id = e.current;
            e.update_syntax(id);
            let Some(root) = e.syntax.get(&id).and_then(|s| s.root()) else {
                return Vec::new();
            };
            crate::syntax::children(root, e.buffer.rope(), clamp(start), clamp(end))
                .into_iter()
                .map(|(k, f, s, t, named)| node_value(k, f, s, t, named))
                .collect::<Vec<_>>()
        })
    });
    // The whole tree as an S-expression, for looking at while writing
    // text objects.
    engine.register_fn("syntax-tree", || {
        editor::with(|e| {
            let id = e.current;
            e.update_syntax(id);
            e.syntax
                .get(&id)
                .and_then(|s| s.root())
                .map(|r| r.to_sexp())
        })
    });

    // Bracket and tag scans; see scan.rs.
    engine.register_fn(
        "find-open",
        |open: char, close: char, from: isize, count: isize| {
            if from < 0 {
                return None;
            }
            editor::with(|e| {
                scan::find_open(e.buffer.rope(), open, close, from as usize, clamp(count))
                    .map(|p| p as isize)
            })
        },
    );
    engine.register_fn("find-close", |open: char, close: char, from: isize| {
        editor::with(|e| {
            scan::find_close(e.buffer.rope(), open, close, clamp(from)).map(|p| p as isize)
        })
    });
    engine.register_fn("tag-pairs-around", |offset: isize| {
        editor::with(|e| {
            scan::tag_pairs_around(e.buffer.rope(), clamp(offset))
                .into_iter()
                .map(|t| t.iter().map(|&x| x as isize).collect::<Vec<isize>>())
                .collect::<Vec<_>>()
        })
    });

    // Searching. Patterns use Vim's syntax; see search.rs.
    engine.register_fn("pattern-error", |pattern: String| {
        search::compile(&pattern).err()
    });
    engine.register_fn(
        "search-next",
        |pattern: String, from: isize, forward: bool| {
            let re = search::compile(&pattern)?;
            Ok::<_, String>(editor::with(|e| {
                search::next_match(&e.buffer, &re, clamp(from), forward)
                    .map(|(at, wrapped)| vec![at as isize, isize::from(wrapped)])
            }))
        },
    );
    engine.register_fn(
        "substitute!",
        |pattern: String, replacement: String, first: isize, last: isize, global: bool| {
            let re = search::compile(&pattern)?;
            editor::with(|e| writable(e))?;
            Ok::<_, String>(editor::with(|e| {
                let (count, line) = search::substitute(
                    &mut e.buffer,
                    &re,
                    &replacement,
                    clamp(first),
                    clamp(last),
                    global,
                );
                // (count last-changed-line), the line being -1 if none.
                vec![count as isize, line.map_or(-1, |l| l as isize)]
            }))
        },
    );
    // The current buffer's own layers, drawn wherever it is shown.
    engine.register_fn("buffer-highlight-clear!", |layer: String| {
        editor::with(|e| {
            let layer = e.buffer_layer_mut(&layer);
            layer.ranges.clear();
            layer.pattern = None;
        })
    });
    engine.register_fn(
        "buffer-highlight-add!",
        |layer: String, start: isize, end: isize, face: String| {
            editor::with(|e| {
                e.buffer_layer_mut(&layer).ranges.push(Highlight {
                    start: clamp(start),
                    end: clamp(end),
                    face,
                })
            })
        },
    );
    engine.register_fn(
        "buffer-highlight-pattern!",
        |layer: String, pattern: String, face: String| {
            let re = search::compile(&pattern)?;
            editor::with(|e| e.buffer_layer_mut(&layer).pattern = Some((re, face)));
            Ok::<(), String>(())
        },
    );
    engine.register_fn(
        "highlight-add!",
        |layer: String, start: isize, end: isize, face: String| {
            editor::with(|e| {
                e.layer_mut(&layer).ranges.push(Highlight {
                    start: clamp(start),
                    end: clamp(end),
                    face,
                })
            })
        },
    );

    crate::wasm::register(engine);
    crate::crdt::register(engine);
    crate::kdl::register(engine);
}
