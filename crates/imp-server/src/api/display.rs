//! What is drawn beside and around a buffer's text: folds, signs, change
//! marks, margins, line-end text, footers and the body width.

use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;
use steel::SteelVal;

use super::clamp;
use crate::editor;

pub(super) fn register(engine: &mut Engine) {
    // The current buffer's folds, as (first last closed?) lines. The
    // renderer hides what closed ones hold, nested ones dropped since the
    // outer fold hides them, and puts a chevron on each first line.
    engine.register_fn("set-folds!", |folds: Vec<Vec<SteelVal>>| {
        let folds: Vec<(usize, usize, bool)> = folds
            .iter()
            .filter_map(|f| match f.as_slice() {
                [SteelVal::IntV(a), SteelVal::IntV(b), closed] if a <= b => Some((
                    clamp(*a),
                    clamp(*b),
                    !matches!(closed, SteelVal::BoolV(false)),
                )),
                _ => None,
            })
            .collect();
        let mut starts: std::collections::BTreeMap<usize, (usize, bool)> = Default::default();
        for &(a, b, closed) in &folds {
            if starts.get(&a).is_none_or(|&(last, _)| b > last) {
                starts.insert(a, (b, closed));
            }
        }
        let starts = starts
            .into_iter()
            .map(|(a, (_, closed))| (a, closed))
            .collect();
        let mut ranges: Vec<(usize, usize)> = folds
            .iter()
            .filter(|f| f.2)
            .map(|&(a, b, _)| (a, b))
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
            let id = e.current();
            e.folds.insert(id, outer);
            e.fold_starts.insert(id, starts);
        })
    });
    // The blocks of lines that differ between two texts, as a list of
    // (old-start old-count new-start new-count), lines counted from 0.
    engine.register_fn("line-diff", |old: String, new: String| {
        crate::diff::line_hunks(&old, &new)
            .into_iter()
            .map(|h| {
                vec![h.old_start, h.old_count, h.new_start, h.new_count]
                    .into_iter()
                    .map(|n| SteelVal::IntV(n as isize))
                    .collect::<Vec<_>>()
            })
            .collect::<Vec<_>>()
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
            let id = e.current();
            e.signs.insert(id, map);
        })
    });

    // The current buffer's change column: a list of (line text face), or
    // #f to take the column away. '() keeps the column with no marks.
    engine.register_fn("set-change-marks!", |marks: SteelVal| {
        let marks = match marks {
            SteelVal::BoolV(false) => None,
            SteelVal::ListV(list) => Some(
                list.iter()
                    .filter_map(|mark| match mark {
                        SteelVal::ListV(m) => match m.iter().collect::<Vec<_>>().as_slice() {
                            [SteelVal::IntV(line), SteelVal::StringV(text), SteelVal::StringV(face)] => {
                                Some((clamp(*line), (text.to_string(), face.to_string())))
                            }
                            _ => None,
                        },
                        _ => None,
                    })
                    .collect::<std::collections::BTreeMap<_, _>>(),
            ),
            _ => return Err("set-change-marks!: expected a list or #f".to_string()),
        };
        editor::with(|e| {
            let id = e.current();
            match marks {
                Some(marks) => e.change_marks.insert(id, marks),
                None => e.change_marks.remove(&id),
            };
        });
        Ok(())
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
            let id = e.current();
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
            let id = e.current();
            if width > 0 {
                e.body_widths.insert(id, clamp(width));
            } else {
                e.body_widths.remove(&id);
            }
        })
    });
    engine.register_fn("body-width", || {
        editor::with(|e| e.body_widths.get(&e.current()).map_or(0, |w| *w as isize))
    });

    // Text after the end of line `line` of the current buffer, in `face`;
    // #f for `text` removes it.
    engine.register_fn(
        "set-line-end-text!",
        |line: isize, text: SteelVal, face: String| {
            editor::with(|e| {
                let id = e.current();
                let texts = e.line_end_texts.entry(id).or_default();
                match text {
                    SteelVal::StringV(t) => {
                        texts.insert(clamp(line), (t.to_string(), face));
                    }
                    _ => {
                        texts.remove(&clamp(line));
                    }
                }
            })
        },
    );

    // The current buffer's footer: a list of lines, each a list of (text
    // face) parts, face #f for none; '() removes it.
    engine.register_fn("set-footer!", |lines: Vec<Vec<Vec<SteelVal>>>| {
        let lines: Vec<editor::FooterLine> = lines
            .into_iter()
            .map(|parts| {
                parts
                    .into_iter()
                    .filter_map(|part| match part.as_slice() {
                        [SteelVal::StringV(text), face] => Some((
                            text.to_string(),
                            match face {
                                SteelVal::StringV(f) => Some(f.to_string()),
                                _ => None,
                            },
                        )),
                        _ => None,
                    })
                    .collect()
            })
            .collect();
        editor::with(|e| {
            let id = e.current();
            if lines.is_empty() {
                e.footers.remove(&id);
            } else {
                e.footers.insert(id, lines);
            }
        })
    });
}
