//! Tree-sitter: a parse tree per buffer, kept up to date incrementally,
//! for highlighting and structural text objects.
//!
//! The grammars bundled are the owner's choice: Rust, Scheme, TypeScript
//! and TSX, JavaScript, Nix, Markdown, HTML, CSS and JSON. Which language a buffer uses is
//! up to Scheme (major modes call `set-buffer-language!`).

use std::collections::HashMap;
use std::ops::Range;
use std::sync::mpsc::Sender;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use crate::events::Event;

use imp_core::buffer::Edit;
use imp_core::Buffer;
use ropey::Rope;
use tree_sitter::{
    InputEdit, Language, Node, ParseOptions, Parser, Point, Query, QueryCursor, StreamingIterator,
    Tree,
};

/// How long a frame may spend parsing before the parse moves to a
/// background thread. Typing must never wait on the parser: after a big
/// change to a big file, tree-sitter's error recovery can take seconds.
const PARSE_BUDGET: Duration = Duration::from_millis(8);

/// A grammar and its highlight query.
pub struct Lang {
    pub name: &'static str,
    language: Language,
    highlights: Query,
    /// For each capture in the query, the faces to try, most specific
    /// first: `syntax.function.method`, then `syntax.function`.
    faces: Vec<Vec<String>>,
}

/// Every bundled language, compiled once on first use.
pub fn languages() -> &'static HashMap<&'static str, Lang> {
    static LANGS: OnceLock<HashMap<&'static str, Lang>> = OnceLock::new();
    LANGS.get_or_init(|| {
        let specs: Vec<(&'static str, Language, String)> = vec![
            (
                "rust",
                tree_sitter_rust::LANGUAGE.into(),
                tree_sitter_rust::HIGHLIGHTS_QUERY.into(),
            ),
            (
                "scheme",
                tree_sitter_scheme::LANGUAGE.into(),
                tree_sitter_scheme::HIGHLIGHTS_QUERY.into(),
            ),
            (
                "javascript",
                tree_sitter_javascript::LANGUAGE.into(),
                format!(
                    "{}\n{}",
                    tree_sitter_javascript::HIGHLIGHT_QUERY,
                    tree_sitter_javascript::JSX_HIGHLIGHT_QUERY
                ),
            ),
            // TypeScript's query only adds to JavaScript's, as in the
            // grammar's own setup.
            (
                "typescript",
                tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
                format!(
                    "{}\n{}",
                    tree_sitter_typescript::HIGHLIGHTS_QUERY,
                    tree_sitter_javascript::HIGHLIGHT_QUERY
                ),
            ),
            (
                "tsx",
                tree_sitter_typescript::LANGUAGE_TSX.into(),
                format!(
                    "{}\n{}\n{}",
                    tree_sitter_typescript::HIGHLIGHTS_QUERY,
                    tree_sitter_javascript::HIGHLIGHT_QUERY,
                    tree_sitter_javascript::JSX_HIGHLIGHT_QUERY
                ),
            ),
            (
                "nix",
                tree_sitter_nix::LANGUAGE.into(),
                tree_sitter_nix::HIGHLIGHTS_QUERY.into(),
            ),
            (
                "markdown",
                tree_sitter_md::LANGUAGE.into(),
                tree_sitter_md::HIGHLIGHT_QUERY_BLOCK.into(),
            ),
            (
                "html",
                tree_sitter_html::LANGUAGE.into(),
                tree_sitter_html::HIGHLIGHTS_QUERY.into(),
            ),
            (
                "css",
                tree_sitter_css::LANGUAGE.into(),
                tree_sitter_css::HIGHLIGHTS_QUERY.into(),
            ),
            (
                "json",
                tree_sitter_json::LANGUAGE.into(),
                tree_sitter_json::HIGHLIGHTS_QUERY.into(),
            ),
        ];
        specs
            .into_iter()
            .filter_map(|(name, language, source)| {
                // A query a grammar update broke shouldn't take the editor
                // down; that language just goes without highlighting.
                let highlights = Query::new(&language, &source)
                    .or_else(|_| Query::new(&language, ""))
                    .ok()?;
                let faces = highlights
                    .capture_names()
                    .iter()
                    .map(|capture| face_candidates(capture))
                    .collect();
                Some((
                    name,
                    Lang {
                        name,
                        language,
                        highlights,
                        faces,
                    },
                ))
            })
            .collect()
    })
}

fn face_candidates(capture: &str) -> Vec<String> {
    let parts: Vec<&str> = capture.split('.').collect();
    (1..=parts.len())
        .rev()
        .map(|n| format!("syntax.{}", parts[..n].join(".")))
        .collect()
}

impl std::fmt::Debug for Syntax {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Syntax({})", self.lang.name)
    }
}

/// A buffer's parser and tree.
pub struct Syntax {
    pub lang: &'static Lang,
    parser: Parser,
    /// The last tree, edited to follow the text even while a newer parse
    /// is pending, so highlights stay roughly in place.
    tree: Option<Tree>,
    /// The text changed since `tree` was parsed.
    stale: bool,
    /// The whole text was replaced, so the next parse can't reuse `tree`.
    reset: bool,
    /// The buffer version a background parse is working on.
    parsing: Option<u64>,
}

impl Syntax {
    pub fn new(name: &str) -> Option<Syntax> {
        let lang = languages().get(name)?;
        let mut parser = Parser::new();
        parser.set_language(&lang.language).ok()?;
        Some(Syntax {
            lang,
            parser,
            tree: None,
            stale: true,
            reset: true,
            parsing: None,
        })
    }

    /// Brings the tree up to date with `buffer`'s edits since last time: a
    /// quick incremental parse if it fits the budget, otherwise one on a
    /// background thread that reports back as `Event::Parsed`.
    pub fn update(&mut self, buffer: &mut Buffer, id: usize, events: Option<&Sender<Event>>) {
        self.apply_edits(buffer.take_edits());
        // Up to date, or a background parse is already on it: draw with
        // what we have rather than spend the budget again.
        if !self.stale || self.parsing.is_some() {
            return;
        }
        let old = if self.reset { None } else { self.tree.clone() };
        let rope = buffer.rope();
        let mut read = |byte: usize, _: Point| -> &[u8] {
            if byte >= rope.len_bytes() {
                return &[];
            }
            let (chunk, start, _, _) = rope.chunk_at_byte(byte);
            &chunk.as_bytes()[byte - start..]
        };
        let started = Instant::now();
        // Without a background thread to hand over to (no event loop), the
        // parse takes as long as it takes.
        let budget = if events.is_some() {
            PARSE_BUDGET
        } else {
            Duration::MAX
        };
        let mut over_budget = |_: &tree_sitter::ParseState| started.elapsed() > budget;
        let options = ParseOptions::new().progress_callback(&mut over_budget);
        match self
            .parser
            .parse_with_options(&mut read, old.as_ref(), Some(options))
        {
            Some(tree) => self.parsed(tree),
            None => {
                // Cancelled: carry on drawing with the edited old tree.
                self.parser.reset();
                // One background parse at a time per buffer; if the text
                // moves on meanwhile, its result is dropped and the next
                // frame starts one for the newer text.
                let version = buffer.version();
                if self.parsing.is_none() {
                    if let Some(events) = events {
                        self.parsing = Some(version);
                        spawn_parse(self.lang, rope.clone(), old, id, version, events.clone());
                    }
                }
            }
        }
    }

    fn parsed(&mut self, tree: Tree) {
        self.tree = Some(tree);
        self.stale = false;
        self.reset = false;
        self.parsing = None;
    }

    /// A background parse of buffer `version` finished. It is used if the
    /// text hasn't changed since; otherwise the next update starts again.
    pub fn background_parsed(&mut self, buffer: &Buffer, version: u64, tree: Tree) {
        self.parsing = None;
        if buffer.version() == version {
            self.parsed(tree);
        }
    }

    fn apply_edits(&mut self, edits: Vec<Edit>) {
        if edits.is_empty() {
            return;
        }
        self.stale = true;
        if edits.contains(&Edit::Reset) {
            self.reset = true;
        } else if let Some(tree) = self.tree.as_mut() {
            for edit in &edits {
                if let Edit::Change {
                    start_byte,
                    old_end_byte,
                    new_end_byte,
                    start,
                    old_end,
                    new_end,
                } = *edit
                {
                    tree.edit(&InputEdit {
                        start_byte,
                        old_end_byte,
                        new_end_byte,
                        start_position: point(start),
                        old_end_position: point(old_end),
                        new_end_position: point(new_end),
                    });
                }
            }
        }
    }

    pub fn root(&self) -> Option<Node<'_>> {
        self.tree.as_ref().map(|t| t.root_node())
    }

    /// Highlighted char ranges within `bytes` of `rope`, as (start char,
    /// end char, faces to try), in the order they win where they overlap,
    /// as in tree-sitter's own highlighter: the narrower capture first, so
    /// an escape wins over the string around it. Of two captures of the
    /// same text, the earlier pattern wins, except that a more specific
    /// one wins over its general one: `comment.documentation` over the
    /// `comment` the Rust query lists first.
    pub fn highlights(
        &self,
        rope: &Rope,
        bytes: Range<usize>,
    ) -> Vec<(usize, usize, &'static [String])> {
        let Some(root) = self.root() else {
            return Vec::new();
        };
        let mut cursor = QueryCursor::new();
        cursor.set_byte_range(bytes);
        let text = |node: Node| {
            let r = node.byte_range();
            rope.byte_slice(r.start.min(rope.len_bytes())..r.end.min(rope.len_bytes()))
                .chunks()
                .map(|c| c.as_bytes())
        };
        let mut out: Vec<(usize, usize, usize, &'static [String])> = Vec::new();
        let lang: &'static Lang = self.lang;
        let mut captures = cursor.captures(&lang.highlights, root, text);
        while let Some((m, i)) = captures.next() {
            let c = m.captures[*i];
            let r = c.node.byte_range();
            out.push((
                m.pattern_index,
                rope.byte_to_char(r.start.min(rope.len_bytes())),
                rope.byte_to_char(r.end.min(rope.len_bytes())),
                &lang.faces[c.index as usize],
            ));
        }
        // Narrower first, then lower pattern index, so painting "only
        // where nothing is painted yet" gives those priority.
        out.sort_by_key(|&(pattern, start, end, _)| (end - start, pattern));
        let mut first: HashMap<(usize, usize), usize> = HashMap::new();
        for i in 0..out.len() {
            let range = (out[i].1, out[i].2);
            match first.get(&range) {
                Some(&j) if more_specific(out[i].3, out[j].3) => out.swap(i, j),
                Some(_) => {}
                None => {
                    first.insert(range, i);
                }
            }
        }
        out.into_iter().map(|(_, s, e, f)| (s, e, f)).collect()
    }
}

/// Whether the faces of capture `a` are a more specific form of `b`'s:
/// `syntax.comment.documentation` of `syntax.comment`.
fn more_specific(a: &[String], b: &[String]) -> bool {
    match (a.first(), b.first()) {
        (Some(a), Some(b)) => {
            a.len() > b.len() && a.starts_with(b.as_str()) && a[b.len()..].starts_with('.')
        }
        _ => false,
    }
}

/// Parses `rope` on another thread and posts the tree back.
fn spawn_parse(
    lang: &'static Lang,
    rope: Rope,
    old: Option<Tree>,
    id: usize,
    version: u64,
    events: Sender<Event>,
) {
    std::thread::spawn(move || {
        let mut parser = Parser::new();
        if parser.set_language(&lang.language).is_err() {
            return;
        }
        let mut read = |byte: usize, _: Point| -> &[u8] {
            if byte >= rope.len_bytes() {
                return &[];
            }
            let (chunk, start, _, _) = rope.chunk_at_byte(byte);
            &chunk.as_bytes()[byte - start..]
        };
        if let Some(tree) = parser.parse_with_options(&mut read, old.as_ref(), None) {
            let _ = events.send(Event::Parsed(id, version, tree));
        }
    });
}

fn point((row, column): (usize, usize)) -> Point {
    Point { row, column }
}

/// A node as Scheme sees it: (kind field start end) in chars.
pub fn describe(node: Node, field: Option<&str>, rope: &Rope) -> (String, String, usize, usize) {
    let r = node.byte_range();
    (
        node.kind().to_string(),
        field.unwrap_or("").to_string(),
        rope.byte_to_char(r.start.min(rope.len_bytes())),
        rope.byte_to_char(r.end.min(rope.len_bytes())),
    )
}

/// The named nodes containing char offset `at`, innermost first, each with
/// the field name it has in its parent.
pub fn ancestors(root: Node, rope: &Rope, at: usize) -> Vec<(String, String, usize, usize)> {
    let byte = rope.char_to_byte(at.min(rope.len_chars()));
    let Some(mut node) = root.named_descendant_for_byte_range(byte, byte) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    loop {
        let field = node.parent().and_then(|p| field_of(p, node));
        out.push(describe(node, field, rope));
        match node.parent() {
            Some(p) => node = p,
            None => break,
        }
    }
    out
}

/// The children of the smallest node spanning chars `start..end` exactly
/// (named or not), each with its field name.
/// The (first, last) lines of every named node of one of `kinds` that
/// spans more than one line, in tree order: what foldmethod syntax folds.
/// A node ending at the start of a line ends on the line before.
pub fn fold_lines(root: Node, kinds: &[String]) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut cursor = root.walk();
    loop {
        let node = cursor.node();
        if node.is_named() && kinds.iter().any(|k| k == node.kind()) {
            let (start, end) = (node.start_position(), node.end_position());
            let last = if end.column == 0 && end.row > start.row {
                end.row - 1
            } else {
                end.row
            };
            if last > start.row {
                out.push((start.row, last));
            }
        }
        if cursor.goto_first_child() {
            continue;
        }
        loop {
            if cursor.goto_next_sibling() {
                break;
            }
            if !cursor.goto_parent() {
                return out;
            }
        }
    }
}

pub fn children(
    root: Node,
    rope: &Rope,
    start: usize,
    end: usize,
) -> Vec<(String, String, usize, usize, bool)> {
    let (sb, eb) = (
        rope.char_to_byte(start.min(rope.len_chars())),
        rope.char_to_byte(end.min(rope.len_chars())),
    );
    let Some(mut node) = root.descendant_for_byte_range(sb, eb) else {
        return Vec::new();
    };
    // descendant_for_byte_range can return a smaller node at the edges;
    // climb to the one that covers the range.
    while node.byte_range() != (sb..eb) {
        match node.parent() {
            Some(p) if p.start_byte() <= sb && p.end_byte() >= eb => node = p,
            _ => break,
        }
    }
    let mut cursor = node.walk();
    let mut out = Vec::new();
    if cursor.goto_first_child() {
        loop {
            let child = cursor.node();
            let (kind, field, s, e) = describe(child, cursor.field_name(), rope);
            out.push((kind, field, s, e, child.is_named()));
            if !cursor.goto_next_sibling() {
                break;
            }
        }
    }
    out
}

fn field_of<'a>(parent: Node<'a>, child: Node<'a>) -> Option<&'static str> {
    let mut cursor = parent.walk();
    if cursor.goto_first_child() {
        loop {
            if cursor.node() == child {
                return cursor.field_name();
            }
            if !cursor.goto_next_sibling() {
                break;
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slow_parses_move_to_the_background() {
        let code: String = (0..25_000)
            .map(|i| format!("fn f{i}(x: u32) -> u32 {{\n    x + {i}\n}}\n"))
            .collect();
        let mut buffer = Buffer::from_text(&code);
        buffer.track_edits(true);
        let (tx, rx) = std::sync::mpsc::channel();
        let mut syntax = Syntax::new("rust").unwrap();
        // The first parse of a big file is over budget: it goes to a
        // thread and returns at once.
        let t = Instant::now();
        syntax.update(&mut buffer, 7, Some(&tx));
        assert!(
            t.elapsed() < Duration::from_millis(200),
            "{:?}",
            t.elapsed()
        );
        assert!(syntax.root().is_none());
        match rx.recv_timeout(Duration::from_secs(20)).unwrap() {
            Event::Parsed(7, version, tree) => syntax.background_parsed(&buffer, version, tree),
            other => panic!("{other:?}"),
        }
        assert!(syntax.root().is_some());
        assert!(!syntax.stale);
    }

    #[test]
    #[ignore]
    fn timing_of_a_broken_top_line() {
        let code: String = (0..25_000)
            .map(|i| {
                format!("fn f{i}(x: u32) -> u32 {{\n    let y = x + {i}; // add\n    y * 2\n}}\n")
            })
            .collect();
        let mut buffer = Buffer::from_text(&code);
        buffer.track_edits(true);
        let mut syntax = Syntax::new("rust").unwrap();
        let t = std::time::Instant::now();
        syntax.update(&mut buffer, 1, None);
        eprintln!("first parse {:?}", t.elapsed());
        for i in 0..3 {
            buffer.delete(0, 1);
            let t = std::time::Instant::now();
            syntax.update(&mut buffer, 1, None);
            let parse = t.elapsed();
            let t = std::time::Instant::now();
            let n = syntax.highlights(buffer.rope(), 0..2000).len();
            eprintln!(
                "delete {i}: parse {parse:?}, highlight {:?} ({n} spans)",
                t.elapsed()
            );
        }
    }

    #[test]
    fn every_language_loads_with_highlights() {
        let names: Vec<&str> = {
            let mut v: Vec<&str> = languages().keys().copied().collect();
            v.sort();
            v
        };
        assert_eq!(
            names,
            [
                "css",
                "html",
                "javascript",
                "json",
                "markdown",
                "nix",
                "rust",
                "scheme",
                "tsx",
                "typescript"
            ]
        );
        for lang in languages().values() {
            assert!(
                lang.highlights.pattern_count() > 0,
                "{} has no highlight patterns",
                lang.name
            );
        }
    }

    #[test]
    fn incremental_parse_and_highlight() {
        let mut buffer = Buffer::from_text("fn main() {}\n");
        buffer.track_edits(true);
        let mut syntax = Syntax::new("rust").unwrap();
        syntax.update(&mut buffer, 1, None);
        let hl = syntax.highlights(buffer.rope(), 0..buffer.rope().len_bytes());
        assert!(hl
            .iter()
            .any(|(s, e, f)| (*s, *e) == (0, 2) && f[0] == "syntax.keyword"));
        buffer.insert(3, "x");
        syntax.update(&mut buffer, 1, None);
        let root = syntax.root().unwrap();
        assert_eq!(root.to_sexp(), "(source_file (function_item name: (identifier) parameters: (parameters) body: (block)))");
        let a = ancestors(root, buffer.rope(), 4);
        assert_eq!(a[0].0, "identifier");
        assert_eq!(a[0].1, "name");
        assert_eq!(a[1].0, "function_item");
    }
}
