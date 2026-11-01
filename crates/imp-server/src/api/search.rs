//! Searching (patterns use Vim's syntax; see search.rs) and bracket and
//! tag scans (scan.rs).

use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;

use super::{clamp, writable};
use crate::editor;
use crate::scan;
use crate::search;

pub(super) fn register(engine: &mut Engine) {
    // Whether regexp `pattern` (Rust's syntax, ignoring case) matches
    // somewhere in `text`; a bad pattern is an error naming it. For the
    // agenda's {regexp} matches.
    engine.register_fn("regexp-match?", |pattern: String, text: String| {
        regex::RegexBuilder::new(&pattern)
            .case_insensitive(true)
            .build()
            .map(|re| re.is_match(&text))
            .map_err(|e| format!("bad regexp {pattern}: {e}"))
    });

    // Char offsets of every match of `pattern` in the buffer, up to `limit`.
    engine.register_fn("search-all", |pattern: String, limit: isize| {
        let re = search::compile(&pattern)?;
        Ok::<_, String>(editor::with(|e| {
            let text = e.buffer().shared_text();
            re.find_iter(&text)
                .take(clamp(limit))
                .map(|m| e.buffer().byte_to_char(m.start()) as isize)
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
            let text = e.buffer().shared_text();
            text.match_indices(&needle)
                .take(clamp(limit))
                .map(|(b, _)| e.buffer().byte_to_char(b) as isize)
                .collect::<Vec<_>>()
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
                scan::find_open(e.buffer().rope(), open, close, from as usize, clamp(count))
                    .map(|p| p as isize)
            })
        },
    );
    engine.register_fn("find-close", |open: char, close: char, from: isize| {
        editor::with(|e| {
            scan::find_close(e.buffer().rope(), open, close, clamp(from)).map(|p| p as isize)
        })
    });
    engine.register_fn("tag-pairs-around", |offset: isize| {
        editor::with(|e| {
            scan::tag_pairs_around(e.buffer().rope(), clamp(offset))
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
                search::next_match(e.buffer(), &re, clamp(from), forward)
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
                    e.buffer_mut(),
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
}
