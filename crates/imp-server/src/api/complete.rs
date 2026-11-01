//! Completion: fuzzy matching (fuzzy.rs), the completion stores
//! (complete.rs) and project files.

use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;

use super::clamp;
use crate::complete;
use crate::editor;
use crate::files;
use crate::fuzzy;

pub(super) fn register(engine: &mut Engine) {
    // Completion: orderless fuzzy matching (fuzzy.rs) and project files.
    // As fuzzy-filter, with each candidate's use score (completion by use).
    engine.register_fn(
        "fuzzy-filter-ranked",
        |query: String, candidates: Vec<String>, uses: Vec<f64>, limit: isize| {
            fuzzy::filter_ranked(&query, &candidates, &uses, clamp(limit))
        },
    );

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
        // A negative `near` is -1 - the offset, for words near it when
        // nothing is being typed there (a search prompt's).
        |ids: Vec<isize>, prefix: String, extra: String, near: isize, limit: isize| {
            let ids: Vec<usize> = ids.into_iter().map(clamp).collect();
            let (near, typing) = if near < 0 {
                (clamp(-1 - near), false)
            } else {
                (clamp(near), true)
            };
            editor::with(|e| {
                complete::buffer_words(e, &ids, &prefix, &extra, near, typing, clamp(limit))
            })
        },
    );
    engine.register_fn(
        "completion-store-set!",
        |source: isize, priority: isize, labels: Vec<String>, start: isize, starts: Vec<isize>| {
            let starts: Vec<usize> = starts.into_iter().map(clamp).collect();
            complete::set_candidates(
                0,
                clamp(source),
                priority as i64,
                labels,
                clamp(start),
                &starts,
            ) as isize
        },
    );
    engine.register_fn("completion-store-clear!", || complete::clear_candidates(0));
    // The command line's menu: one source, matched against `typed`.
    engine.register_fn("cmdline-store-set!", |labels: Vec<String>| {
        complete::clear_candidates(1);
        complete::set_candidates(1, 0, 0, labels, 0, &[]) as isize
    });
    engine.register_fn(
        "cmdline-store-filter",
        |typed: String, prefix_only: bool, limit: isize| {
            complete::filter_text(&typed, prefix_only, clamp(limit))
        },
    );
    engine.register_fn(
        "completion-store-filter",
        |prefix_only: bool, live: Vec<isize>, fuzzy: Vec<isize>, limit: isize| {
            let live: Vec<usize> = live.into_iter().map(clamp).collect();
            let fuzzy: Vec<usize> = fuzzy.into_iter().map(clamp).collect();
            editor::with(|e| {
                complete::filter_candidates(e, e.cursor(), prefix_only, &live, &fuzzy, clamp(limit))
            })
        },
    );
    engine.register_fn("list-files", |root: String, limit: isize| {
        files::list(&root, clamp(limit))
    });
}
