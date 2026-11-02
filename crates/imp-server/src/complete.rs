//! The hot loops of completion at point (runtime/complete.scm), kept out
//! of Scheme: an index of each buffer's words, and the menu's candidates,
//! filtered and ranked on every key typed while it is open.

use crate::editor::Editor;
use crate::fuzzy;
use std::cell::RefCell;
use std::collections::HashMap;

/// A buffer's words and where each occurs, as of one version of it.
struct Index {
    /// (version, length, extra word chars) it was read at.
    key: (u64, usize, String),
    /// Word -> the offsets it starts at, ascending.
    words: HashMap<String, Vec<usize>>,
}

/// One menu candidate: its label, where the text it completes starts,
/// and the source it came from (an index into its call's list).
struct Candidate {
    label: String,
    start: usize,
    source: usize,
    priority: i64,
    order: usize,
}

thread_local! {
    static INDEXES: RefCell<HashMap<usize, Index>> = RefCell::new(HashMap::new());
    /// The menus' candidates: completion at point's, and the command line's.
    static MENU: RefCell<[Vec<Candidate>; 2]> = const { RefCell::new([Vec::new(), Vec::new()]) };
}

/// Buffers longer than this have only this many chars around the cursor
/// read, so a huge file doesn't stall typing.
const MAX_SCAN: usize = 1_000_000;

fn is_word(c: char, extra: &str) -> bool {
    c.is_alphanumeric() || c == '_' || extra.contains(c)
}

/// Reads the words of `rope` (from `from` to `to`).
fn read_words(
    rope: &ropey::Rope,
    from: usize,
    to: usize,
    extra: &str,
) -> HashMap<String, Vec<usize>> {
    let mut words: HashMap<String, Vec<usize>> = HashMap::new();
    let mut word = String::new();
    let mut start = from;
    for (i, c) in rope.slice(from..to).chars().enumerate() {
        if is_word(c, extra) {
            if word.is_empty() {
                start = from + i;
            }
            word.push(c);
        } else if !word.is_empty() {
            words
                .entry(std::mem::take(&mut word))
                .or_default()
                .push(start);
        }
    }
    if !word.is_empty() {
        words.entry(word).or_default().push(start);
    }
    words
}

/// Whether `word` completes `prefix`: starts with it, ignoring case unless
/// `prefix` has an uppercase letter (smartcase), and is longer.
fn completes(word: &str, prefix: &str, sensitive: bool) -> bool {
    if word.len() <= prefix.len() {
        return false;
    }
    if sensitive {
        word.starts_with(prefix)
    } else {
        word.char_indices()
            .nth(prefix.chars().count())
            .is_some_and(|(at, _)| word[..at].to_lowercase() == prefix)
    }
}

/// The words completing `prefix` in buffers `ids`, at most `limit`: the
/// first buffer's nearest `near` (the cursor) first, then the others' in
/// the order they appear. When `typing`, the word being typed (ending
/// at `near` in the first buffer) isn't one. Each buffer's index is kept until it changes.
pub fn buffer_words(
    e: &Editor,
    ids: &[usize],
    prefix: &str,
    extra: &str,
    near: usize,
    typing: bool,
    limit: usize,
) -> Vec<String> {
    let sensitive = prefix.chars().any(char::is_uppercase);
    let typed_at = typing.then(|| near.saturating_sub(prefix.chars().count()));
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    INDEXES.with(|indexes| {
        let mut indexes = indexes.borrow_mut();
        indexes.retain(|&id, _| e.buffer_by_id(id).is_some());
        for (n, &id) in ids.iter().enumerate() {
            let Some(buffer) = e.buffer_by_id(id) else {
                continue;
            };
            let key = (buffer.version(), buffer.len(), extra.to_string());
            let index = indexes.entry(id).or_insert_with(|| Index {
                key: (u64::MAX, 0, String::new()),
                words: HashMap::new(),
            });
            if index.key != key {
                let len = buffer.len();
                let center = if n == 0 { near.min(len) } else { 0 };
                let from = center.saturating_sub(MAX_SCAN / 2);
                let to = (from + MAX_SCAN).min(len);
                index.words = read_words(buffer.rope(), from, to, extra);
                index.key = key;
            }
            let mut hits: Vec<(usize, &String)> = index
                .words
                .iter()
                .filter(|(w, _)| completes(w, prefix, sensitive) && !seen.contains(*w))
                .filter_map(|(w, at)| {
                    if n > 0 {
                        return Some((at[0], w));
                    }
                    // Nearest occurrence that isn't the word being typed.
                    let i = at.partition_point(|&o| o < near);
                    let before = at[..i]
                        .iter()
                        .rev()
                        .find(|&&o| Some(o) != typed_at)
                        .map(|&o| near - o);
                    let after = at[i..]
                        .iter()
                        .find(|&&o| Some(o) != typed_at)
                        .map(|&o| o - near);
                    before.into_iter().chain(after).min().map(|d| (d, w))
                })
                .collect();
            hits.sort();
            for (_, w) in hits {
                if out.len() >= limit {
                    return;
                }
                seen.insert(w.clone());
                out.push(w.clone());
            }
        }
    });
    out
}

/// Puts `labels` in the menu as source `source`'s candidates, replacing
/// those it had. Each completes the text from `starts[i]` (or `start`)
/// to the cursor. Returns how many candidates the menu has.
pub fn set_candidates(
    store: usize,
    source: usize,
    priority: i64,
    labels: Vec<String>,
    start: usize,
    starts: &[usize],
) -> usize {
    MENU.with(|menu| {
        let menu = &mut menu.borrow_mut()[store.min(1)];
        menu.retain(|c| c.source != source);
        for (order, label) in labels.into_iter().enumerate() {
            let start = starts.get(order).copied().unwrap_or(start);
            menu.push(Candidate {
                label,
                start,
                source,
                priority,
                order,
            });
        }
        menu.len()
    })
}

pub fn clear_candidates(store: usize) {
    MENU.with(|menu| menu.borrow_mut()[store.min(1)].clear());
}

/// The menu's candidates matching what is typed before `cursor` in the
/// current buffer, best first, at most `limit`, as (source, index) pairs
/// flattened. Only those of `live` sources count; with `prefix_only`,
/// only labels starting with the typed text (smartcase), except from
/// `fuzzy` sources, else fuzzy matches too. Ranked by how well they
/// match, then their source's priority, then the order their source
/// gave. A label offered twice shows once.
pub fn filter_candidates(
    e: &Editor,
    cursor: usize,
    prefix_only: bool,
    live: &[usize],
    fuzzy: &[usize],
    limit: usize,
) -> Vec<isize> {
    let typed = |start: usize| {
        (start <= cursor)
            .then(|| e.buffer().slice(start, cursor))
            .filter(|t| !t.contains(char::is_whitespace))
    };
    filter(0, &typed, prefix_only, live, fuzzy, limit)
}

/// The command line's candidates matching `typed`, ranked as
/// filter_candidates ranks them.
pub fn filter_text(typed: &str, prefix_only: bool, limit: usize) -> Vec<isize> {
    filter(
        1,
        &|_| Some(typed.to_string()),
        prefix_only,
        &[0],
        &[],
        limit,
    )
}

fn filter(
    store: usize,
    typed_from: &dyn Fn(usize) -> Option<String>,
    prefix_only: bool,
    live: &[usize],
    fuzzy: &[usize],
    limit: usize,
) -> Vec<isize> {
    MENU.with(|menu| {
        let menu = &menu.borrow()[store];
        let mut typed: HashMap<usize, Option<String>> = HashMap::new();
        let mut hits: Vec<(i64, &Candidate)> = menu
            .iter()
            .filter(|c| live.contains(&c.source))
            .filter_map(|c| {
                let t = typed
                    .entry(c.start)
                    .or_insert_with(|| typed_from(c.start))
                    .as_deref()?;
                if t.is_empty() {
                    return Some((0, c));
                }
                if prefix_only && !fuzzy.contains(&c.source) {
                    let sensitive = t.chars().any(char::is_uppercase);
                    let ok = if sensitive {
                        c.label.starts_with(t)
                    } else {
                        c.label.to_lowercase().starts_with(&t.to_lowercase())
                    };
                    if !ok {
                        return None;
                    }
                }
                fuzzy::score(t, &c.label).map(|s| (s, c))
            })
            .collect();
        hits.sort_by(|a, b| {
            b.0.cmp(&a.0)
                .then(b.1.priority.cmp(&a.1.priority))
                .then(a.1.source.cmp(&b.1.source))
                .then(a.1.order.cmp(&b.1.order))
        });
        // A label two sources offer shows once, from the better ranked.
        let mut seen = std::collections::HashSet::new();
        hits.into_iter()
            .filter(|(_, c)| seen.insert(c.label.as_str()))
            .take(limit)
            .flat_map(|(_, c)| [c.source as isize, c.order as isize])
            .collect()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn smartcase_prefixes() {
        assert!(completes("Frobnicate", "fro", false));
        assert!(!completes("frobnicate", "Fro", true));
        assert!(!completes("fro", "fro", false));
        assert!(completes("élan", "é", false));
    }

    #[test]
    fn words_and_where_they_are() {
        let rope = ropey::Rope::from_str("foo-bar baz_1 foo\n");
        let w = read_words(&rope, 0, rope.len_chars(), "");
        assert_eq!(w["foo"], [0, 14]);
        assert_eq!(w["baz_1"], [8]);
        let w = read_words(&rope, 0, rope.len_chars(), "-");
        assert_eq!(w["foo-bar"], [0]);
    }
}
