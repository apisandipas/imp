//! KDL config (feature `kdl`; see lore:spec/kdl-config).
//!
//! `(kdl-parse TEXT)` turns a KDL document into lists Scheme can walk;
//! runtime/config.scm gives the nodes their meaning. Each node is
//! `(name (arg ...) ((key value) ...) (child ...) line)`, with strings,
//! integers, floats, booleans and the symbol `null` as values. A document
//! that doesn't parse is an error naming the line. Without the feature
//! the primitive still exists and says so.

use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;

pub fn register(engine: &mut Engine) {
    engine.register_fn("kdl-parse", |text: String| imp::parse(&text));
    engine.register_fn("kdl-available?", || cfg!(feature = "kdl"));
}

#[cfg(not(feature = "kdl"))]
mod imp {
    use steel::rvals::SteelVal;

    pub fn parse(_: &str) -> Result<SteelVal, String> {
        Err("imp was built without the kdl feature".into())
    }
}

#[cfg(feature = "kdl")]
mod imp {
    use ::kdl::{KdlDocument, KdlNode, KdlValue};
    use steel::rvals::SteelVal;

    fn list(items: Vec<SteelVal>) -> SteelVal {
        SteelVal::ListV(items.into())
    }

    /// The 1-based line of byte `offset`.
    fn line_of(text: &str, offset: usize) -> usize {
        text.as_bytes()[..offset.min(text.len())]
            .iter()
            .filter(|&&b| b == b'\n')
            .count()
            + 1
    }

    fn value(v: &KdlValue) -> SteelVal {
        match v {
            KdlValue::String(s) => SteelVal::StringV(s.clone().into()),
            KdlValue::Integer(n) => SteelVal::IntV(*n as isize),
            KdlValue::Float(f) => SteelVal::NumV(*f),
            KdlValue::Bool(b) => SteelVal::BoolV(*b),
            KdlValue::Null => SteelVal::SymbolV("null".into()),
        }
    }

    fn node(text: &str, node: &KdlNode) -> SteelVal {
        let mut args = Vec::new();
        let mut props = Vec::new();
        for entry in node.entries() {
            match entry.name() {
                Some(key) => props.push(list(vec![
                    SteelVal::StringV(key.value().into()),
                    value(entry.value()),
                ])),
                None => args.push(value(entry.value())),
            }
        }
        list(vec![
            SteelVal::StringV(node.name().value().into()),
            list(args),
            list(props),
            node.children().map_or(list(vec![]), |doc| nodes(text, doc)),
            SteelVal::IntV(line_of(text, node.span().offset()) as isize),
        ])
    }

    fn nodes(text: &str, doc: &KdlDocument) -> SteelVal {
        list(doc.nodes().iter().map(|n| node(text, n)).collect())
    }

    pub fn parse(text: &str) -> Result<SteelVal, String> {
        let doc = KdlDocument::parse(text).map_err(|e| {
            match e.diagnostics.first() {
                Some(d) => {
                    // Diagnostic spans count chars.
                    let byte = text
                        .char_indices()
                        .nth(d.span.offset())
                        .map_or(text.len(), |(i, _)| i);
                    let what = d.message.clone().unwrap_or_else(|| "bad KDL".into());
                    match &d.help {
                        Some(help) => format!("line {}: {what} ({help})", line_of(text, byte)),
                        None => format!("line {}: {what}", line_of(text, byte)),
                    }
                }
                None => e.to_string(),
            }
        })?;
        Ok(nodes(text, &doc))
    }
}
