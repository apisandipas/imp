//! WASM plugins (wasm.rs, feature `wasm`).

use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;

use super::fail;

pub(super) fn register(engine: &mut Engine) {
    // Loads a .wasm (or .wat) file; a plugin handle.
    engine.register_fn("wasm-load", |path: String| {
        crate::wasm::load(&path).map_err(fail)
    });
    engine.register_fn("wasm-call", |plugin: isize, name: String, input: String| {
        crate::wasm::call(plugin, &name, &input).map_err(fail)
    });
    engine.register_fn("wasm-exports", |plugin: isize| {
        crate::wasm::exports(plugin).map_err(fail)
    });
    engine.register_fn("wasm-log", crate::wasm::log_lines);
    // How much work (roughly, instructions) one call may do.
    engine.register_fn("wasm-set-fuel!", |fuel: isize| {
        crate::wasm::set_fuel(fuel.max(1) as u64)
    });
    engine.register_fn("wasm-available?", || cfg!(feature = "wasm"));
}
