//! Loaded Scheme sources and the packages that come with imp, for help
//! and loading.

use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;
use steel::SteelVal;

use crate::editor;

pub(super) fn register(engine: &mut Engine) {
    // Why `text` doesn't parse as Scheme, or #f if it does. `read` just
    // stops at an unclosed paren, so loaders check with this first.
    engine.register_fn("parse-error", |text: String| {
        steel::parser::parser::Parser::parse(&text)
            .err()
            .map(|e| e.to_string())
    });

    // Loaded Scheme sources, newest last.
    engine.register_fn(
        "record-source!",
        |name: String, path: String, text: String| {
            editor::with(|e| {
                let path = (!path.is_empty()).then_some(path);
                e.sources.retain(|(n, _, _)| *n != name);
                e.sources.push((name, path, text));
            })
        },
    );
    // A package that comes with imp: (source-name path text), path "" when
    // it's the copy built into the binary; #f if there's none called that.
    engine.register_fn("builtin-package", |name: String| {
        crate::builtin_package(&name).map(|(source, path, text)| {
            SteelVal::ListV(
                vec![
                    SteelVal::StringV(source.into()),
                    SteelVal::StringV(path.unwrap_or_default().into()),
                    SteelVal::StringV(text.into()),
                ]
                .into(),
            )
        })
    });
    engine.register_fn("builtin-package-names", || {
        crate::PACKAGES
            .iter()
            .map(|(name, _)| name.to_string())
            .collect::<Vec<_>>()
    });
    engine.register_fn("source-names", || {
        editor::with(|e| {
            e.sources
                .iter()
                .map(|(n, _, _)| n.clone())
                .collect::<Vec<_>>()
        })
    });
    // The definitions in a loaded source and their docs' first lines,
    // read in Rust (docs.rs): help.scm's doc-lines and apropos.
    engine.register_fn("source-lengths", || {
        editor::with(|e| {
            e.sources
                .iter()
                .map(|(_, _, t)| t.len() as isize)
                .collect::<Vec<_>>()
        })
    });
    engine.register_fn("defined-names-containing", |text: String| {
        editor::with(|e| {
            let mut names: Vec<String> = e
                .sources
                .iter()
                .flat_map(|(_, _, t)| crate::docs::defined_names(t))
                .filter(|n| n.contains(&text))
                .collect();
            names.sort();
            names.dedup();
            names
        })
    });
    engine.register_fn("source-doc-table", |name: String| {
        editor::with(|e| {
            let (docs, aliases) = e
                .sources
                .iter()
                .find(|(n, _, _)| *n == name)
                .map(|(_, _, t)| crate::docs::doc_lines(t))
                .unwrap_or_default();
            let flat = |pairs: Vec<(String, String)>| {
                pairs
                    .into_iter()
                    .flat_map(|(a, b)| [a, b])
                    .collect::<Vec<_>>()
            };
            vec![flat(docs), flat(aliases)]
        })
    });
    engine.register_fn("source-text", |name: String| {
        editor::with(|e| {
            e.sources
                .iter()
                .find(|(n, _, _)| *n == name)
                .map(|(_, _, t)| t.clone())
        })
    });
    engine.register_fn("source-path", |name: String| {
        editor::with(|e| {
            e.sources
                .iter()
                .find(|(n, _, _)| *n == name)
                .and_then(|(_, p, _)| p.clone())
        })
    });
}
