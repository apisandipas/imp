//! Windows and the layout, and how text is drawn in them: wrap, line
//! numbers, gutter columns, tab width.

use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;
use steel::SteelVal;

use super::clamp;
use crate::editor;

pub(super) fn register(engine: &mut Engine) {
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
        editor::with(|e| e.current_window() as isize)
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
        editor::with(|e| e.window_buffer(clamp(id)).map(|b| b as isize))
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
            let (area, gap) = (e.windows_area(), e.divider());
            let id = e.current_window();
            e.layout.resize(id, dir, delta, area, gap)
        })
    });
    engine.register_fn("equalize-windows!", || {
        editor::with(|e| e.layout.equalize())
    });
    // What clients do beyond the grid: "font" (a family, "" for the
    // client's), "font-size", "padding" and "divider" (logical pixels),
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
                "divider" => e.divider_px = int(&value)?.clamp(0, 1000) as u16,
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
    // Any window's text area as (rows columns), or #f.
    engine.register_fn("window-text-size", |id: isize| {
        editor::with(|e| {
            crate::render::window_text_size(e, clamp(id))
                .map(|(r, c)| vec![SteelVal::IntV(r as isize), SteelVal::IntV(c as isize)])
        })
    });
    engine.register_fn("window-text-width", || {
        editor::with(|e| crate::render::window_text_width(e) as isize)
    });

    // The window: which buffer lines are on screen.
    engine.register_fn("window-top", || editor::with(|e| e.scroll() as isize));
    engine.register_fn("window-width", || editor::with(|e| e.width as isize));
    engine.register_fn("window-height", || editor::with(|e| e.text_rows() as isize));
    engine.register_fn("set-window-top!", |line: isize| {
        editor::with(|e| e.set_scroll(clamp(line).min(e.buffer().line_count().saturating_sub(1))))
    });

    // "off", "absolute", "relative" or "hybrid": the line numbers of
    // buffers that don't set their own.
    engine.register_fn("set-line-numbers!", |mode: String| {
        editor::with(|e| e.line_numbers = line_numbers(&mode))
    });
    // The current buffer's own line numbers, as set-line-numbers! takes,
    // or #f to use everyone's.
    engine.register_fn("set-buffer-line-numbers!", |mode: Option<String>| {
        editor::with(|e| {
            let id = e.current();
            match mode {
                Some(mode) => e.buffer_line_numbers.insert(id, line_numbers(&mode)),
                None => e.buffer_line_numbers.remove(&id),
            };
        })
    });
    // When the current buffer shows its sign column: "yes", "no" or
    // "auto" (while it has signs).
    engine.register_fn("set-sign-column!", |mode: String| {
        editor::with(|e| {
            let id = e.current();
            e.sign_columns.insert(id, gutter_column(&mode));
        })
    });
    // When the current buffer shows its fold column: "yes", "no" or
    // "auto" (while it has folds).
    engine.register_fn("set-fold-column!", |mode: String| {
        editor::with(|e| {
            let id = e.current();
            e.fold_columns.insert(id, gutter_column(&mode));
        })
    });
    // Draws the current buffer indented by outline level, `per-level`
    // columns a level, as Org's org-indent-mode does; 0 stops.
    engine.register_fn("set-outline-indent!", |per_level: isize| {
        editor::with(|e| {
            let id = e.current();
            if per_level > 0 {
                e.outline_indents.insert(id, per_level as usize);
            } else {
                e.outline_indents.remove(&id);
            }
        })
    });
    engine.register_fn("set-cursorline!", |on: bool| {
        editor::with(|e| e.cursorline = on)
    });
    engine.register_fn("set-tab-width!", |width: isize| {
        editor::with(|e| e.tab_width = clamp(width).clamp(1, 32))
    });
}

/// Line numbers from their name: "absolute", "relative", "hybrid", else off.
fn line_numbers(mode: &str) -> crate::render::LineNumbers {
    use crate::render::LineNumbers;
    match mode {
        "absolute" => LineNumbers::Absolute,
        "relative" => LineNumbers::Relative,
        "hybrid" => LineNumbers::Hybrid,
        _ => LineNumbers::Off,
    }
}

/// A gutter column's option value ("yes", "no", "auto") as the renderer
/// takes it.
fn gutter_column(mode: &str) -> crate::render::GutterColumn {
    use crate::render::GutterColumn;
    match mode {
        "yes" => GutterColumn::Yes,
        "no" => GutterColumn::No,
        _ => GutterColumn::Auto,
    }
}
