//! The current buffer: reading and changing it, the buffer list, undo,
//! marks and the cursor.

use std::path::PathBuf;
use steel::rerrs::SteelErr;
use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;
use steel::SteelVal;

use super::{clamp, fail, writable};
use crate::editor;

pub(super) fn register(engine: &mut Engine) {
    // Reading the buffer.
    engine.register_fn("buffer-length", || {
        editor::with(|e| e.buffer().len() as isize)
    });
    engine.register_fn("buffer-char-at", |offset: isize| {
        editor::with(|e| e.buffer().char_at(clamp(offset)))
    });
    // Steel has no char-alphabetic?, and Unicode classification belongs here
    // anyway. Word chars are letters, digits and underscore, as in Vim.
    engine.register_fn("char-word?", |c: char| c.is_alphanumeric() || c == '_');
    engine.register_fn("buffer-substring", |start: isize, end: isize| {
        editor::with(|e| e.buffer().slice(clamp(start), clamp(end)))
    });
    engine.register_fn("buffer-line-count", || {
        editor::with(|e| e.buffer().line_count() as isize)
    });
    engine.register_fn("buffer-line-length", |line: isize| {
        editor::with(|e| e.buffer().line_len(clamp(line)) as isize)
    });
    engine.register_fn("line-col->offset", |line: isize, col: isize| {
        editor::with(|e| e.buffer().line_col_to_offset(clamp(line), clamp(col)) as isize)
    });
    engine.register_fn("offset->line", |offset: isize| {
        editor::with(|e| e.buffer().offset_to_line(clamp(offset)) as isize)
    });
    engine.register_fn("offset->col", |offset: isize| {
        editor::with(|e| e.buffer().offset_to_col(clamp(offset)) as isize)
    });
    engine.register_fn("buffer-path", || {
        editor::with(|e| e.buffer().path().map(|p| p.display().to_string()))
    });
    engine.register_fn("buffer-version", || {
        editor::with(|e| e.buffer().version() as isize)
    });
    // The edits since the buffer was at `version`, oldest first, as
    // (start old-end new-end text start-line start-col old-end-line
    // old-end-col), or #f when they aren't known (Buffer::changes_since).
    engine.register_fn("buffer-changes-since", |version: isize| {
        editor::with(|e| {
            let changes = u64::try_from(version)
                .ok()
                .and_then(|v| e.buffer().changes_since(v));
            changes.map(|changes| {
                let int = |n: usize| SteelVal::IntV(n as isize);
                SteelVal::ListV(
                    changes
                        .into_iter()
                        .map(|c| {
                            SteelVal::ListV(
                                vec![
                                    int(c.start),
                                    int(c.old_end),
                                    int(c.new_end),
                                    SteelVal::StringV(c.text.into()),
                                    int(c.start_point.0),
                                    int(c.start_point.1),
                                    int(c.old_end_point.0),
                                    int(c.old_end_point.1),
                                ]
                                .into(),
                            )
                        })
                        .collect::<Vec<_>>()
                        .into(),
                )
            })
        })
    });
    engine.register_fn("buffer-modified?", || {
        editor::with(|e| e.buffer().is_modified())
    });
    engine.register_fn("buffer-name", || {
        editor::with(|e| e.buffer().display_name())
    });

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
    engine.register_fn("current-buffer", || editor::with(|e| e.current() as isize));
    engine.register_fn("switch-to-buffer!", |id: isize| {
        editor::with(|e| e.switch_to(clamp(id)))
    });
    // The id of the buffer visiting `path`, opening the file if no buffer
    // does yet (a missing file opens empty). A file that can't be read is
    // an error.
    engine.register_fn("buffer-open!", |path: String| {
        editor::with(|e| {
            let path = PathBuf::from(&path);
            if let Some(id) = e.find_file_buffer(&path) {
                return Ok(id as isize);
            }
            match imp_core::Buffer::open(&path) {
                Ok(buffer) => Ok(e.add_buffer(buffer) as isize),
                Err(err) => Err(fail(format!("{}: {err}", path.display()))),
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
        editor::with(|e| e.buffer().changed_on_disk())
    });
    engine.register_fn("buffer-forget-disk-change!", || {
        editor::with(|e| e.buffer_mut().forget_disk_change())
    });
    // ("unix"|"dos" "utf-8"|"latin1" bom?) for the current buffer.
    engine.register_fn("buffer-file-format", || {
        editor::with(|e| {
            let f = e.buffer().format();
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
                other => return Err(fail(format!("unknown encoding {other}"))),
            };
            let crlf = match ff.as_str() {
                "dos" => true,
                "unix" => false,
                other => return Err(fail(format!("unknown fileformat {other}"))),
            };
            editor::with(|e| {
                e.buffer_mut().set_format(FileFormat {
                    crlf,
                    bom,
                    encoding,
                })
            });
            Ok(())
        },
    );
    engine.register_fn("set-backup!", |on: bool| {
        editor::with(|e| e.buffer_mut().backup = on)
    });
    engine.register_fn("buffer-reload!", || {
        editor::with(|e| e.buffer_mut().reload().map_err(fail))
    });
    engine.register_fn("set-buffer-unmodified!", || {
        editor::with(|e| e.buffer_mut().set_unmodified())
    });
    engine.register_fn("set-buffer-name!", |name: String| {
        editor::with(|e| e.buffer_mut().set_name(Some(name)))
    });

    // Changing the buffer.
    engine.register_fn("buffer-insert!", |offset: isize, text: String| {
        editor::with(|e| {
            if !text.is_empty() {
                writable(e)?;
            }
            e.buffer_mut().insert(clamp(offset), &text);
            Ok::<_, SteelErr>(())
        })
    });
    engine.register_fn("buffer-delete!", |start: isize, end: isize| {
        editor::with(|e| {
            if start < end {
                writable(e)?;
            }
            Ok::<_, SteelErr>(e.buffer_mut().delete(clamp(start), clamp(end)))
        })
    });
    engine.register_fn("set-buffer-read-only!", |on: bool| {
        editor::with(|e| e.buffer_mut().read_only = on)
    });
    engine.register_fn("buffer-read-only?", || {
        editor::with(|e| e.buffer().read_only)
    });

    engine.register_fn("undo-boundary!", || {
        editor::with(|e| e.buffer_mut().undo_boundary())
    });
    // Both return the offset where the text changed, or #f if there was
    // nothing to undo or redo.
    engine.register_fn("undo!", || {
        editor::with(|e| {
            writable(e)?;
            Ok::<_, SteelErr>(e.buffer_mut().undo().map(|at| at as isize))
        })
    });
    engine.register_fn("redo!", || {
        editor::with(|e| {
            writable(e)?;
            Ok::<_, SteelErr>(e.buffer_mut().redo().map(|at| at as isize))
        })
    });
    // g+ (#t) and g-: the state made just after or before, across
    // branches. Where the text changed, or #f past the newest or oldest.
    engine.register_fn("undo-step!", |forward: bool| {
        editor::with(|e| {
            writable(e)?;
            Ok::<_, SteelErr>(e.buffer_mut().undo_step(forward).map(|at| at as isize))
        })
    });
    // The tip of each undo branch as (change-number changes-deep
    // seconds-ago), oldest first.
    engine.register_fn("undo-list", || {
        editor::with(|e| {
            e.buffer_mut()
                .undo_list()
                .into_iter()
                .map(|(n, depth, made)| {
                    let ago = made.elapsed().map_or(0, |d| d.as_secs());
                    vec![n as isize, depth as isize, ago as isize]
                })
                .collect::<Vec<_>>()
        })
    });
    engine.register_fn("save!", || {
        editor::with(|e| {
            e.buffer_mut()
                .save()
                .map_err(|err| fail(format!("save failed: {err}")))
        })
    });

    // Marks: positions that move with the text.
    engine.register_fn("mark-set!", |name: String, offset: isize| {
        editor::with(|e| e.buffer_mut().set_mark(&name, clamp(offset)))
    });
    // A mark that stays put when text is inserted right at it.
    engine.register_fn("mark-set-sticky!", |name: String, offset: isize| {
        editor::with(|e| e.buffer_mut().set_sticky_mark(&name, clamp(offset)))
    });
    engine.register_fn("mark-get", |name: String| {
        editor::with(|e| e.buffer().mark(&name).map(|m| m as isize))
    });
    engine.register_fn("mark-delete!", |name: String| {
        editor::with(|e| e.buffer_mut().delete_mark(&name))
    });
    engine.register_fn("mark-names", || editor::with(|e| e.buffer().mark_names()));

    // The cursor.
    engine.register_fn("cursor", || editor::with(|e| e.cursor() as isize));
    engine.register_fn("set-cursor!", |offset: isize| {
        editor::with(|e| e.set_cursor(clamp(offset).min(e.buffer().len())))
    });
}
