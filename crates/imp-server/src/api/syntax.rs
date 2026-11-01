//! Tree-sitter (syntax.rs): a language per buffer, and its tree.

use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;
use steel::SteelVal;

use super::clamp;
use crate::editor;

pub(super) fn register(engine: &mut Engine) {
    // Tree-sitter (syntax.rs): a language per buffer, and its tree.
    engine.register_fn("set-buffer-language!", |name: String| {
        editor::with(|e| {
            let id = e.current();
            match crate::syntax::Syntax::new(&name) {
                Ok(Some(syntax)) => {
                    e.buffer_mut().track_edits(true);
                    e.syntax.insert(id, syntax);
                    SteelVal::BoolV(true)
                }
                other => {
                    e.buffer_mut().track_edits(false);
                    e.syntax.remove(&id);
                    match other {
                        Err(why) => SteelVal::StringV(why.into()),
                        _ => SteelVal::BoolV(false),
                    }
                }
            }
        })
    });
    engine.register_fn(
        "define-language-alias!",
        |alias: String, language: String| {
            crate::syntax::define_alias(&alias, &language);
        },
    );
    // A grammar built at runtime (runtime/grammars.scm builds them).
    engine.register_fn(
        "register-grammar!",
        |name: String, library: String, queries: String| {
            crate::syntax::register_grammar(&name, library.into(), queries.into());
        },
    );
    // Where queries/NAME/highlights.scm and injections.scm replace a
    // language's own; "" for nowhere.
    engine.register_fn("set-query-dir!", |dir: String| {
        crate::syntax::set_query_dir((!dir.is_empty()).then(|| dir.into()));
    });
    engine.register_fn("buffer-language", || {
        editor::with(|e| e.syntax.get(&e.current()).map(|s| s.lang.name.to_string()))
    });
    engine.register_fn("syntax-languages", || {
        let mut names: Vec<String> = crate::syntax::bundled_names()
            .into_iter()
            .map(|n| n.to_string())
            .chain(crate::syntax::registered_names())
            .collect();
        names.sort();
        names.dedup();
        names
    });
    // The named nodes around char offset `at`, innermost first, as
    // (kind field start end); the field is "" when the node has none.
    engine.register_fn("syntax-ancestors", |at: isize| {
        editor::with(|e| {
            let id = e.current();
            e.update_syntax(id);
            let Some(root) = e.syntax.get(&id).and_then(|s| s.root()) else {
                return Vec::new();
            };
            crate::syntax::ancestors(root, e.buffer().rope(), clamp(at))
                .into_iter()
                .map(|(k, f, s, t)| node_value(k, f, s, t, true))
                .collect::<Vec<_>>()
        })
    });
    // The innermost language at char offset `at`, an embedded one inside
    // a fence or <script>, and its named nodes around `at`: (language
    // (kind field start end) ...), innermost first; '() with no tree. The
    // tree is the text's as it is, parsed now if need be, as closing a tag
    // just typed needs it.
    engine.register_fn("syntax-at", |at: isize| {
        editor::with(|e| {
            let id = e.current();
            e.update_syntax_now(id);
            let rope = e.buffer().rope();
            let Some((name, root)) = e
                .syntax
                .get(&id)
                .and_then(|s| s.root_at(rope.char_to_byte(clamp(at).min(rope.len_chars()))))
            else {
                return Vec::new();
            };
            std::iter::once(SteelVal::StringV(name.into()))
                .chain(
                    crate::syntax::ancestors(root, rope, clamp(at))
                        .into_iter()
                        .map(|(k, f, s, t)| node_value(k, f, s, t, true)),
                )
                .collect::<Vec<_>>()
        })
    });
    // syntax-children in the innermost language's tree at `start`, the one
    // syntax-at gives nodes of.
    engine.register_fn("syntax-children-at", |start: isize, end: isize| {
        editor::with(|e| {
            let id = e.current();
            e.update_syntax_now(id);
            let rope = e.buffer().rope();
            let Some((_, root)) = e
                .syntax
                .get(&id)
                .and_then(|s| s.root_at(rope.char_to_byte(clamp(start).min(rope.len_chars()))))
            else {
                return Vec::new();
            };
            crate::syntax::children(root, rope, clamp(start), clamp(end))
                .into_iter()
                .map(|(k, f, s, t, named)| node_value(k, f, s, t, named))
                .collect::<Vec<_>>()
        })
    });
    // The children of the node spanning chars start..end, as (kind field
    // start end named?).
    engine.register_fn("syntax-children", |start: isize, end: isize| {
        editor::with(|e| {
            let id = e.current();
            e.update_syntax(id);
            let Some(root) = e.syntax.get(&id).and_then(|s| s.root()) else {
                return Vec::new();
            };
            crate::syntax::children(root, e.buffer().rope(), clamp(start), clamp(end))
                .into_iter()
                .map(|(k, f, s, t, named)| node_value(k, f, s, t, named))
                .collect::<Vec<_>>()
        })
    });
    // (first last) lines of each multi-line node of one of `kinds`, for
    // foldmethod syntax (syntax::fold_lines).
    engine.register_fn("syntax-fold-lines", |kinds: Vec<String>| {
        editor::with(|e| {
            let id = e.current();
            e.update_syntax(id);
            let Some(root) = e.syntax.get(&id).and_then(|s| s.root()) else {
                return Vec::new();
            };
            crate::syntax::fold_lines(root, &kinds)
                .into_iter()
                .map(|(a, b)| vec![a as isize, b as isize])
                .collect::<Vec<_>>()
        })
    });
    // The whole tree as an S-expression, for looking at while writing
    // text objects.
    engine.register_fn("syntax-tree", || {
        editor::with(|e| {
            let id = e.current();
            e.update_syntax(id);
            e.syntax
                .get(&id)
                .and_then(|s| s.root())
                .map(|r| r.to_sexp())
        })
    });
}

/// A syntax node for Scheme: (kind field start end named?).
fn node_value(kind: String, field: String, start: usize, end: usize, named: bool) -> SteelVal {
    SteelVal::ListV(
        vec![
            SteelVal::StringV(kind.into()),
            SteelVal::StringV(field.into()),
            SteelVal::IntV(start as isize),
            SteelVal::IntV(end as isize),
            SteelVal::BoolV(named),
        ]
        .into(),
    )
}
