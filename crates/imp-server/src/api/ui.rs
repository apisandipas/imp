//! Telling the user what's going on: the status line, the command line,
//! popups and floats.

use imp_core::CursorShape;
use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;
use steel::SteelVal;

use super::{clamp, fail};
use crate::editor;

pub(super) fn register(engine: &mut Engine) {
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
    // Whether imp is a daemon, where :q detaches a client and everything
    // keeps running.
    engine.register_fn("daemon?", || editor::with(|e| e.daemon));
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
    // A box over the windows at a corner or the middle of an edge, named
    // so showing it again replaces it: `lines` as popups take them,
    // `position` a symbol ('bottom-right, 'top-center...), and the
    // border's face (#f or "" for "float.border"). core.scm's float-show!
    // makes the border optional.
    engine.register_fn(
        "float-put!",
        |name: String, lines: Vec<SteelVal>, position: SteelVal, border: Option<String>| {
            const POSITIONS: [&str; 6] = [
                "bottom-right",
                "bottom-left",
                "bottom-center",
                "top-right",
                "top-left",
                "top-center",
            ];
            let position = match &position {
                SteelVal::SymbolV(s) | SteelVal::StringV(s) => s.to_string(),
                other => other.to_string(),
            };
            if !POSITIONS.contains(&position.as_str()) {
                return Err(fail(format!("float-show!: no position {position}")));
            }
            let float = crate::editor::Float {
                name: name.clone(),
                lines: lines.iter().map(popup_line).collect(),
                position,
                border: border
                    .filter(|b| !b.is_empty())
                    .unwrap_or_else(|| "float.border".into()),
            };
            editor::with(|e| match e.floats.iter_mut().find(|f| f.name == name) {
                Some(f) => *f = float,
                None => e.floats.push(float),
            });
            Ok(())
        },
    );
    engine.register_fn("float-hide!", |name: String| {
        editor::with(|e| e.floats.retain(|f| f.name != name))
    });
    // Each line is a string, or a list of runs: strings, or (text face)
    // lists. Clearing the popup puts it back at the bottom, untitled.
    engine.register_fn("set-popup!", |lines: Vec<SteelVal>| {
        let lines: Vec<crate::editor::PopupLine> = lines.iter().map(popup_line).collect();
        editor::with(|e| {
            if lines.is_empty() {
                e.popup_at_cursor = None;
                e.popup_center = None;
                e.popup_title.clear();
                e.popup_under.set(None);
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
                if place != "cursor" {
                    e.popup_under.set(None);
                }
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
    // A %{name} value for buffer `buf` (a terminal's title, set as its
    // output arrives).
    engine.register_fn(
        "set-buffer-status-value!",
        |buf: isize, name: String, value: String| {
            editor::with(|e| {
                e.status_values
                    .entry(clamp(buf))
                    .or_default()
                    .insert(name, value);
            })
        },
    );
    // A %{name} value for the current buffer, or every buffer if
    // `global?`.
    engine.register_fn(
        "set-status-value!",
        |name: String, value: String, global: bool| {
            editor::with(|e| {
                let id = if global { usize::MAX } else { e.current() };
                e.status_values.entry(id).or_default().insert(name, value);
            })
        },
    );

    engine.register_fn("popup-lines", || {
        editor::with(|e| {
            e.popup
                .iter()
                .map(|l| l.iter().map(|(t, _)| t.as_str()).collect::<String>())
                .collect::<Vec<_>>()
        })
    });

    engine.register_fn("set-popup-selected!", |n: isize| {
        editor::with(|e| e.popup_selected = (n >= 0).then_some(n as usize))
    });
}

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
