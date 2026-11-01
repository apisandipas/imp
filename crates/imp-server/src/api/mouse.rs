//! Screen cells to what is drawn there, for the mouse.

use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;
use steel::SteelVal;

use super::clamp;
use crate::editor;

pub(super) fn register(engine: &mut Engine) {
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

    // The line whose fold chevron is at screen cell (x, y), or #f.
    engine.register_fn("fold-column-at", |x: isize, y: isize| {
        editor::with(|e| crate::render::fold_column_at(e, clamp(x), clamp(y)).map(|l| l as isize))
    });

    // The border at screen cell (x, y): "width" between side-by-side
    // windows (dragging it changes their widths), "height" on a status
    // line with a window below it; #f elsewhere.
    engine.register_fn("border-at", |x: isize, y: isize| {
        use crate::layout::Dir;
        editor::with(|e| {
            let at = e
                .layout
                .border_at(e.windows_area(), e.divider(), clamp(x), clamp(y));
            match at {
                Some(Dir::Row) => SteelVal::StringV("width".into()),
                Some(Dir::Column) => SteelVal::StringV("height".into()),
                None => SteelVal::BoolV(false),
            }
        })
    });
    // Moves the border at screen cell (x, y) by `delta` columns or rows;
    // where it is now (its first column, or the status line's row), or
    // #f if there is no border there.
    engine.register_fn("move-border!", |x: isize, y: isize, delta: isize| {
        editor::with(|e| {
            let (area, gap) = (e.windows_area(), e.divider());
            e.layout
                .move_border(area, gap, clamp(x), clamp(y), delta)
                .map(|at| at as isize)
        })
    });

    // The text cell at screen cell (x, y) as (window line column), or #f
    // (render::window_cell).
    engine.register_fn("window-cell", |x: isize, y: isize| {
        editor::with(|e| {
            crate::render::window_cell(e, clamp(x), clamp(y)).map(|(w, l, c)| {
                vec![
                    SteelVal::IntV(w as isize),
                    SteelVal::IntV(l as isize),
                    SteelVal::IntV(c as isize),
                ]
            })
        })
    });
}
