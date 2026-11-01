//! Faces and highlight layers. Scheme decides what is highlighted; Rust
//! draws it.

use imp_core::Style;
use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;

use super::clamp;
use crate::editor::{self, Highlight};
use crate::search;

pub(super) fn register(engine: &mut Engine) {
    // Faces and highlights. Scheme decides what is highlighted; Rust draws it.
    engine.register_fn("set-face!", |name: String, spec: String| {
        let style = Style::parse(&spec)?;
        editor::with(|e| e.faces.insert(name, style));
        Ok::<(), String>(())
    });
    // Removes a face, so text drawn in it falls back to its general face
    // (syntax.function.builtin to syntax.function). For load-theme!.
    engine.register_fn("remove-face!", |name: String| {
        editor::with(|e| e.faces.remove(&name));
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
    // The faces at `at` in the text as it is: the tree is parsed now if
    // a parse is still running in the background, as drawing allows.
    engine.register_fn("faces-at", |at: isize| {
        editor::with(|e| {
            e.update_syntax_now(e.current());
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
    // Hides what `pattern`'s groups match in the current buffer (all of a
    // match without groups), except on the cursor's line; "" stops.
    engine.register_fn(
        "buffer-conceal-pattern!",
        |layer: String, pattern: String| {
            let re = if pattern.is_empty() {
                None
            } else {
                Some(search::compile(&pattern)?)
            };
            editor::with(|e| e.buffer_layer_mut(&layer).conceal = re);
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
}
