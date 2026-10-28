//! Tree-sitter: a parse tree per buffer, kept up to date incrementally,
//! for highlighting and structural text objects.
//!
//! The grammars bundled are the owner's choice: Rust, Scheme, TypeScript
//! and TSX, JavaScript, Nix, Markdown, HTML, CSS, JSON, YAML, TOML,
//! Bash, C, Go, Python and Lua. C++, Ruby and Elixir are left to be
//! installed: they're most of the binary's size and fewer people need
//! them. Which language a buffer uses is up to Scheme (major modes call
//! `set-buffer-language!`).

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

/// How deep embedded languages nest: an HTML fence in Markdown is 1, its
/// `<script>` 2. A limit, so a pathological file can't recurse forever.
const MAX_DEPTH: usize = 4;

/// A grammar, its highlight query, and its injections query if it has one.
pub struct Lang {
    pub name: &'static str,
    language: Language,
    highlights: Query,
    /// For each capture in the query, the faces to try, most specific
    /// first: `syntax.function.method`, then `syntax.function`.
    faces: Vec<Vec<String>>,
    injections: Option<Injections>,
}

/// Which parts of a tree are in another language.
struct Injections {
    query: Query,
    /// `@injection.content`: the text in the other language.
    content: u32,
    /// `@injection.language`: a node naming it, where the pattern doesn't
    /// `#set!` it.
    language: Option<u32>,
}

/// The injections query a bundled grammar's crate gives.
fn injections_source(name: &str) -> &'static str {
    match name {
        "html" => tree_sitter_html::INJECTIONS_QUERY,
        _ => "",
    }
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
            // TypeScript's query only adds to JavaScript's. Combined
            // queries go in the order the grammar's own setup gives.
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
                    tree_sitter_javascript::JSX_HIGHLIGHT_QUERY,
                    tree_sitter_javascript::HIGHLIGHT_QUERY
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
            (
                "yaml",
                tree_sitter_yaml::LANGUAGE.into(),
                tree_sitter_yaml::HIGHLIGHTS_QUERY.into(),
            ),
            (
                "toml",
                tree_sitter_toml_ng::LANGUAGE.into(),
                tree_sitter_toml_ng::HIGHLIGHTS_QUERY.into(),
            ),
            (
                "bash",
                tree_sitter_bash::LANGUAGE.into(),
                tree_sitter_bash::HIGHLIGHT_QUERY.into(),
            ),
            (
                "c",
                tree_sitter_c::LANGUAGE.into(),
                tree_sitter_c::HIGHLIGHT_QUERY.into(),
            ),
            (
                "go",
                tree_sitter_go::LANGUAGE.into(),
                tree_sitter_go::HIGHLIGHTS_QUERY.into(),
            ),
            (
                "python",
                tree_sitter_python::LANGUAGE.into(),
                tree_sitter_python::HIGHLIGHTS_QUERY.into(),
            ),
            (
                "lua",
                tree_sitter_lua::LANGUAGE.into(),
                tree_sitter_lua::HIGHLIGHTS_QUERY.into(),
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
                let injections = Query::new(&language, injections_source(name))
                    .ok()
                    .and_then(|query| {
                        Some(Injections {
                            content: query.capture_index_for_name("injection.content")?,
                            language: query.capture_index_for_name("injection.language"),
                            query,
                        })
                    });
                Some((
                    name,
                    Lang {
                        name,
                        language,
                        highlights,
                        faces,
                        injections,
                    },
                ))
            })
            .collect()
    })
}

/// Capture names some queries still use from before Neovim renamed them,
/// with the names themes set faces for.
const OLD_CAPTURES: &[(&str, &str)] = &[
    ("conditional", "keyword.conditional"),
    ("repeat", "keyword.repeat"),
    ("field", "property"),
    ("method", "function.method"),
    ("parameter", "variable.parameter"),
    ("preproc", "keyword.directive"),
    ("delimiter", "punctuation.delimiter"),
];

/// The faces to try for `capture`, most specific first: `syntax.a.b`,
/// then `syntax.a`. An old name (`method.call`) tries its new one's
/// (`syntax.function.method.call`, down to `syntax.function`) after its own.
fn face_candidates(capture: &str) -> Vec<String> {
    let chain = |capture: &str| -> Vec<String> {
        let parts: Vec<&str> = capture.split('.').collect();
        (1..=parts.len())
            .rev()
            .map(|n| format!("syntax.{}", parts[..n].join(".")))
            .collect()
    };
    let mut faces = chain(capture);
    let (head, rest) = capture.split_once('.').unwrap_or((capture, ""));
    if let Some((_, new)) = OLD_CAPTURES.iter().find(|(old, _)| *old == head) {
        let renamed = if rest.is_empty() {
            new.to_string()
        } else {
            format!("{new}.{rest}")
        };
        faces.extend(chain(&renamed));
    }
    faces
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
    /// The embedded languages' trees, edited along with `tree`.
    layers: Vec<Layer>,
    /// The text changed since `tree` was parsed.
    stale: bool,
    /// The whole text was replaced, so the next parse can't reuse `tree`.
    reset: bool,
    /// The buffer version a background parse is working on.
    parsing: Option<u64>,
}

/// A region of the buffer in an embedded language, and its tree.
#[derive(Clone)]
struct Layer {
    lang: &'static Lang,
    tree: Tree,
    /// 1 for a region of the buffer's own language, 2 for one inside that.
    depth: usize,
    /// The bytes it covers, moved along with edits.
    ranges: Vec<Range<usize>>,
    /// An edit since the last parse touched it, so its tree needs one.
    touched: bool,
}

impl Layer {
    /// Follows an edit of `start..old_end` that made it `start..new_end`.
    /// A layer wholly before it is left alone, which matters with
    /// thousands of them (one per Markdown paragraph).
    fn edit(&mut self, edit: &InputEdit) {
        let (start, old_end) = (edit.start_byte, edit.old_end_byte);
        if self.ranges.last().is_some_and(|r| r.end < start) {
            return;
        }
        self.tree.edit(edit);
        let shift = |b: usize| b + edit.new_end_byte - old_end;
        for r in &mut self.ranges {
            if r.start > old_end {
                *r = shift(r.start)..shift(r.end);
            } else if r.end >= start {
                self.touched = true;
                r.end = if r.end > old_end {
                    shift(r.end)
                } else {
                    edit.new_end_byte
                };
            }
        }
    }
}

/// A finished parse: the buffer's tree and its embedded languages'.
pub struct Parse {
    root: Tree,
    layers: Vec<Layer>,
}

impl std::fmt::Debug for Parse {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Parse({} layers)", self.layers.len())
    }
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
            layers: Vec::new(),
            stale: true,
            reset: true,
            parsing: None,
        })
    }

    /// Brings the trees up to date with `buffer`'s edits since last time:
    /// a quick incremental parse if it fits the budget, otherwise one on a
    /// background thread that reports back as `Event::Parsed`.
    pub fn update(&mut self, buffer: &mut Buffer, id: usize, events: Option<&Sender<Event>>) {
        self.apply_edits(buffer.take_edits());
        // Up to date, or a background parse is already on it: draw with
        // what we have rather than spend the budget again.
        if !self.stale || self.parsing.is_some() {
            return;
        }
        let (old, old_layers) = if self.reset {
            (None, Vec::new())
        } else {
            (self.tree.clone(), self.layers.clone())
        };
        let rope = buffer.rope();
        // Without a background thread to hand over to (no event loop), the
        // parse takes as long as it takes. The buffer's language and its
        // embedded ones share the budget.
        let deadline = events.map(|_| Instant::now() + PARSE_BUDGET);
        match parse(
            &mut self.parser,
            self.lang,
            rope,
            old.as_ref(),
            &old_layers,
            deadline,
        ) {
            Some(parse) => self.parsed(parse),
            None => {
                // Cancelled: carry on drawing with the edited old trees.
                // One background parse at a time per buffer; if the text
                // moves on meanwhile, its result is dropped and the next
                // frame starts one for the newer text.
                let version = buffer.version();
                if self.parsing.is_none() {
                    if let Some(events) = events {
                        self.parsing = Some(version);
                        spawn_parse(
                            self.lang,
                            rope.clone(),
                            old,
                            old_layers,
                            id,
                            version,
                            events.clone(),
                        );
                    }
                }
            }
        }
    }

    fn parsed(&mut self, parse: Parse) {
        self.tree = Some(parse.root);
        self.layers = parse.layers;
        self.stale = false;
        self.reset = false;
        self.parsing = None;
    }

    /// A background parse of buffer `version` finished. It is used if the
    /// text hasn't changed since; otherwise the next update starts again.
    pub fn background_parsed(&mut self, buffer: &Buffer, version: u64, parse: Parse) {
        self.parsing = None;
        if buffer.version() == version {
            self.parsed(parse);
        }
    }

    fn apply_edits(&mut self, edits: Vec<Edit>) {
        if edits.is_empty() {
            return;
        }
        self.stale = true;
        if edits.contains(&Edit::Reset) {
            self.reset = true;
            return;
        }
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
                let edit = InputEdit {
                    start_byte,
                    old_end_byte,
                    new_end_byte,
                    start_position: point(start),
                    old_end_position: point(old_end),
                    new_end_position: point(new_end),
                };
                if let Some(tree) = self.tree.as_mut() {
                    tree.edit(&edit);
                }
                for layer in &mut self.layers {
                    layer.edit(&edit);
                }
            }
        }
    }

    pub fn root(&self) -> Option<Node<'_>> {
        self.tree.as_ref().map(|t| t.root_node())
    }

    /// Highlighted char ranges within `bytes` of `rope`, as (start char,
    /// end char, faces to try), in the order they win where they overlap,
    /// as in tree-sitter's own highlighter: an embedded language's first,
    /// over the language around it; then the narrower capture, so an
    /// escape wins over the string around it; and of two captures of the
    /// same text, the later pattern, so a Rust doc comment is
    /// `comment.documentation`, not the `comment` listed before it.
    pub fn highlights(
        &self,
        rope: &Rope,
        bytes: Range<usize>,
    ) -> Vec<(usize, usize, &'static [String])> {
        let Some(root) = &self.tree else {
            return Vec::new();
        };
        let overlaps = |ranges: &[Range<usize>], bytes: &Range<usize>| {
            ranges
                .iter()
                .any(|r| r.start < bytes.end && bytes.start < r.end)
        };
        let layers = self
            .layers
            .iter()
            .filter(|l| overlaps(&l.ranges, &bytes))
            .map(|l| (l.lang, &l.tree, l.depth));
        let trees = std::iter::once((self.lang, root, 0)).chain(layers);
        let mut out: Vec<(usize, usize, usize, usize, &'static [String])> = Vec::new();
        for (lang, tree, depth) in trees {
            let mut cursor = QueryCursor::new();
            cursor.set_byte_range(bytes.clone());
            let mut captures = cursor.captures(&lang.highlights, tree.root_node(), RopeText(rope));
            while let Some((m, i)) = captures.next() {
                let c = m.captures[*i];
                let r = c.node.byte_range();
                out.push((
                    depth,
                    m.pattern_index,
                    rope.byte_to_char(r.start.min(rope.len_bytes())),
                    rope.byte_to_char(r.end.min(rope.len_bytes())),
                    &lang.faces[c.index as usize],
                ));
            }
        }
        // Deeper first, then narrower, then the later pattern, so painting
        // "only where nothing is painted yet" gives those priority.
        out.sort_by_key(|&(depth, pattern, start, end, _)| {
            (
                std::cmp::Reverse(depth),
                end - start,
                std::cmp::Reverse(pattern),
            )
        });
        out.into_iter().map(|(_, _, s, e, f)| (s, e, f)).collect()
    }
}

/// The text of nodes in a rope, for query predicates.
struct RopeText<'a>(&'a Rope);

impl<'a> tree_sitter::TextProvider<&'a [u8]> for RopeText<'a> {
    type I = std::vec::IntoIter<&'a [u8]>;

    fn text(&mut self, node: Node) -> Self::I {
        let (rope, r) = (self.0, node.byte_range());
        rope.byte_slice(r.start.min(rope.len_bytes())..r.end.min(rope.len_bytes()))
            .chunks()
            .map(|c| c.as_bytes())
            .collect::<Vec<_>>()
            .into_iter()
    }
}

/// Parses `rope` as `lang`, then each region in an embedded language,
/// reusing the old trees where they fit: a layer's old tree is the one of
/// the same language and depth that started at the same place, used as it
/// is if no edit touched it. None if it ran past `deadline`.
fn parse(
    parser: &mut Parser,
    lang: &'static Lang,
    rope: &Rope,
    old: Option<&Tree>,
    old_layers: &[Layer],
    deadline: Option<Instant>,
) -> Option<Parse> {
    let root = parse_ranges(parser, lang, rope, old, &[], deadline)?;
    let mut unused: HashMap<(&str, usize, usize), &Layer> = old_layers
        .iter()
        .filter_map(|l| Some(((l.lang.name, l.depth, l.ranges.first()?.start), l)))
        .collect();
    let mut layers: Vec<Layer> = Vec::new();
    let mut pending = vec![(lang, root.clone(), 0)];
    while let Some((lang, tree, depth)) = pending.pop() {
        if depth == MAX_DEPTH {
            continue;
        }
        for (embedded, ranges) in injections(lang, &tree, rope) {
            let bytes: Vec<Range<usize>> =
                ranges.iter().map(|r| r.start_byte..r.end_byte).collect();
            let old = unused.remove(&(embedded.name, depth + 1, bytes[0].start));
            // An old tree no edit touched, over the same text, is still
            // right as it is.
            let tree = match old {
                Some(old) if !old.touched && old.ranges == bytes => old.tree.clone(),
                old => parse_ranges(
                    parser,
                    embedded,
                    rope,
                    old.map(|l| &l.tree),
                    &ranges,
                    deadline,
                )?,
            };
            pending.push((embedded, tree.clone(), depth + 1));
            layers.push(Layer {
                lang: embedded,
                tree,
                depth: depth + 1,
                ranges: bytes,
                touched: false,
            });
        }
    }
    Some(Parse { root, layers })
}

/// Parses the `ranges` of `rope` (all of it when empty) as `lang`.
fn parse_ranges(
    parser: &mut Parser,
    lang: &Lang,
    rope: &Rope,
    old: Option<&Tree>,
    ranges: &[tree_sitter::Range],
    deadline: Option<Instant>,
) -> Option<Tree> {
    parser.set_language(&lang.language).ok()?;
    parser.set_included_ranges(ranges).ok()?;
    let mut read = |byte: usize, _: Point| -> &[u8] {
        if byte >= rope.len_bytes() {
            return &[];
        }
        let (chunk, start, _, _) = rope.chunk_at_byte(byte);
        &chunk.as_bytes()[byte - start..]
    };
    let tree = match deadline {
        Some(deadline) => {
            let mut over = |_: &tree_sitter::ParseState| Instant::now() > deadline;
            let options = ParseOptions::new().progress_callback(&mut over);
            parser.parse_with_options(&mut read, old, Some(options))
        }
        None => parser.parse_with_options(&mut read, old, None),
    };
    if tree.is_none() {
        parser.reset();
    }
    tree
}

/// The regions of `tree` that `lang`'s injections query puts in another
/// bundled language, each as that language and its byte ranges, in order.
/// A pattern that says `injection.combined` makes one region of all its
/// matches in each language.
fn injections(
    lang: &Lang,
    tree: &Tree,
    rope: &Rope,
) -> Vec<(&'static Lang, Vec<tree_sitter::Range>)> {
    let Some(inj) = &lang.injections else {
        return Vec::new();
    };
    let mut out: Vec<(&'static Lang, Vec<tree_sitter::Range>)> = Vec::new();
    let mut combined: Vec<(usize, &'static Lang, Vec<tree_sitter::Range>)> = Vec::new();
    let mut cursor = QueryCursor::new();
    let mut matches = cursor.matches(&inj.query, tree.root_node(), RopeText(rope));
    while let Some(m) = matches.next() {
        let props = inj.query.property_settings(m.pattern_index);
        let has = |key: &str| props.iter().any(|p| &*p.key == key);
        let name = props
            .iter()
            .find(|p| &*p.key == "injection.language")
            .and_then(|p| p.value.as_deref().map(str::to_string))
            .or_else(|| {
                let node = m.nodes_for_capture_index(inj.language?).next()?;
                Some(rope.byte_slice(node.byte_range()).to_string())
            });
        let Some(embedded) = name.and_then(|n| language_named(&n)) else {
            continue;
        };
        let mut ranges = Vec::new();
        for node in m.nodes_for_capture_index(inj.content) {
            ranges.extend(content_ranges(node, has("injection.include-children")));
        }
        if ranges.is_empty() {
            continue;
        }
        if has("injection.combined") {
            match combined
                .iter_mut()
                .find(|(p, l, _)| *p == m.pattern_index && std::ptr::eq(*l, embedded))
            {
                Some((_, _, all)) => all.extend(ranges),
                None => combined.push((m.pattern_index, embedded, ranges)),
            }
        } else {
            out.push((embedded, ranges));
        }
    }
    for (_, embedded, mut ranges) in combined {
        ranges.sort_by_key(|r| r.start_byte);
        out.push((embedded, ranges));
    }
    out
}

/// The bundled language an injection names.
fn language_named(name: &str) -> Option<&'static Lang> {
    languages().get(name.to_lowercase().as_str())
}

/// `node`'s byte ranges, less its children's unless `include_children`,
/// as tree-sitter's own highlighter takes an injection's content.
fn content_ranges(node: Node, include_children: bool) -> Vec<tree_sitter::Range> {
    let mut ranges = Vec::new();
    let (mut from, mut from_point) = (node.start_byte(), node.start_position());
    let mut piece = |end: usize, end_point: Point, from: usize, from_point: Point| {
        if end > from {
            ranges.push(tree_sitter::Range {
                start_byte: from,
                end_byte: end,
                start_point: from_point,
                end_point,
            });
        }
    };
    if !include_children {
        let mut cursor = node.walk();
        for child in node.children(&mut cursor) {
            piece(child.start_byte(), child.start_position(), from, from_point);
            (from, from_point) = (child.end_byte(), child.end_position());
        }
    }
    piece(node.end_byte(), node.end_position(), from, from_point);
    ranges
}

/// Parses `rope` and its embedded languages on another thread, and posts
/// the trees back.
fn spawn_parse(
    lang: &'static Lang,
    rope: Rope,
    old: Option<Tree>,
    old_layers: Vec<Layer>,
    id: usize,
    version: u64,
    events: Sender<Event>,
) {
    std::thread::spawn(move || {
        let mut parser = Parser::new();
        if let Some(parse) = parse(&mut parser, lang, &rope, old.as_ref(), &old_layers, None) {
            let _ = events.send(Event::Parsed(id, version, Box::new(parse)));
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
            Event::Parsed(7, version, parse) => syntax.background_parsed(&buffer, version, *parse),
            other => panic!("{other:?}"),
        }
        assert!(syntax.root().is_some());
        assert!(!syntax.stale);
    }

    #[test]
    fn slow_parses_post_back_their_embedded_languages() {
        let page: String = (0..20_000)
            .map(|i| format!("<div><script>let x{i} = {i};</script></div>\n"))
            .collect();
        let mut buffer = Buffer::from_text(&page);
        buffer.track_edits(true);
        let (tx, rx) = std::sync::mpsc::channel();
        let mut syntax = Syntax::new("html").unwrap();
        syntax.update(&mut buffer, 3, Some(&tx));
        assert!(syntax.root().is_none());
        match rx.recv_timeout(Duration::from_secs(60)).unwrap() {
            Event::Parsed(3, version, parse) => syntax.background_parsed(&buffer, version, *parse),
            other => panic!("{other:?}"),
        }
        assert_eq!(syntax.layers.len(), 20_000);
        assert!(syntax
            .layers
            .iter()
            .all(|l| l.lang.name == "javascript" && l.depth == 1));
        let hl = syntax.highlights(buffer.rope(), 0..40);
        assert!(hl
            .iter()
            .any(|(s, e, f)| (*s, *e) == (13, 16) && f[0] == "syntax.keyword"));
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
    fn every_capture_has_a_face_in_the_themes() {
        // Variables are drawn in the text's own color, by design, and
        // @none means no highlighting.
        let unstyled = ["variable", "none"];
        let faces = |source: &str| -> std::collections::HashSet<String> {
            regex::Regex::new(r#""(syntax\.[a-z.]+)""#)
                .unwrap()
                .captures_iter(source)
                .map(|c| c[1].to_string())
                .collect()
        };
        for (theme, set) in [
            (
                "theme.scm",
                faces(include_str!("../../../runtime/theme.scm")),
            ),
            (
                "modus-themes.scm",
                faces(include_str!(
                    "../../../packages/modus-themes/modus-themes.scm"
                )),
            ),
        ] {
            for lang in languages().values() {
                for (capture, candidates) in lang.highlights.capture_names().iter().zip(&lang.faces)
                {
                    if capture.starts_with('_') || unstyled.contains(capture) {
                        continue;
                    }
                    assert!(
                        candidates.iter().any(|f| set.contains(f)),
                        "{}'s @{capture} has no face in {theme}",
                        lang.name
                    );
                }
            }
        }
    }

    #[test]
    fn old_capture_names_fall_back_to_new_ones() {
        assert_eq!(
            face_candidates("method.call"),
            [
                "syntax.method.call",
                "syntax.method",
                "syntax.function.method.call",
                "syntax.function.method",
                "syntax.function"
            ]
        );
        assert_eq!(face_candidates("keyword"), ["syntax.keyword"]);
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
                "bash",
                "c",
                "css",
                "go",
                "html",
                "javascript",
                "json",
                "lua",
                "markdown",
                "nix",
                "python",
                "rust",
                "scheme",
                "toml",
                "tsx",
                "typescript",
                "yaml"
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
