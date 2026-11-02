//! KDL config (kdl.rs, feature `kdl`).

use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;

use super::fail;

pub(super) fn register(engine: &mut Engine) {
    // The nodes of KDL document `text`, as lists; an error names the line.
    engine.register_fn("kdl-parse", |text: String| {
        crate::kdl::parse(&text).map_err(fail)
    });
    engine.register_fn("kdl-available?", || cfg!(feature = "kdl"));
}
