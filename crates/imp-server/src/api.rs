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
use crate::editor::{self, Highlight};
use crate::files;
use crate::fuzzy;
use crate::scan;
use crate::search;
use crate::shell;
use std::path::{Path, PathBuf};
use steel::SteelVal;

fn clamp(n: isize) -> usize {
    n.max(0) as usize
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
        editor::with(|e| e.buffer.insert(clamp(offset), &text))
    });
    engine.register_fn("buffer-delete!", |start: isize, end: isize| {
        editor::with(|e| e.buffer.delete(clamp(start), clamp(end)))
    });
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
        editor::with(|e| e.buffer.undo().map(|at| at as isize))
    });
    engine.register_fn("redo!", || {
        editor::with(|e| e.buffer.redo().map(|at| at as isize))
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
    // Lines shown above the status line until cleared, for output longer
    // than the status line (:registers) and menus (which-key).
    engine.register_fn("set-cmdline!", |text: String, col: isize| {
        editor::with(|e| e.cmdline = Some((text, clamp(col))))
    });
    engine.register_fn("clear-cmdline!", || editor::with(|e| e.cmdline = None));
    engine.register_fn("set-popup!", |lines: Vec<String>| {
        editor::with(|e| e.popup = lines)
    });

    // Faces and highlights. Scheme decides what is highlighted; Rust draws it.
    engine.register_fn("set-face!", |name: String, spec: String| {
        let style = Style::parse(&spec)?;
        editor::with(|e| e.faces.insert(name, style));
        Ok::<(), String>(())
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

    // Completion: orderless fuzzy matching (fuzzy.rs) and project files.
    engine.register_fn(
        "fuzzy-filter",
        |query: String, candidates: Vec<String>, limit: isize| {
            fuzzy::filter(&query, &candidates, clamp(limit))
        },
    );
    engine.register_fn("list-files", |root: String, limit: isize| {
        files::list(&root, clamp(limit))
    });
    engine.register_fn("set-popup-selected!", |n: isize| {
        editor::with(|e| e.popup_selected = (n >= 0).then_some(n as usize))
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
}
