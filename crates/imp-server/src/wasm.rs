//! WASM plugins (feature `wasm`; see lore:spec/wasm-plugins).
//!
//! A plugin is a core WebAssembly module with a string ABI: it exports
//! `memory` and `imp_alloc(len) -> ptr`, and each function it offers takes
//! the (ptr, len) of a UTF-8 string and returns `ptr << 32 | len` of its
//! UTF-8 result. Its one import is `imp.log(ptr, len)`. It gets no WASI,
//! so no files, network or clock; each call has a fuel budget and each
//! plugin a memory limit, so a bad plugin errors instead of hanging or
//! eating the editor.
//!
//! Without the feature the primitives still exist and say so, so runtime
//! files load either way.

use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;

pub fn register(engine: &mut Engine) {
    engine.register_fn("wasm-load", |path: String| imp::load(&path));
    engine.register_fn("wasm-call", |plugin: isize, name: String, input: String| {
        imp::call(plugin, &name, &input)
    });
    engine.register_fn("wasm-exports", |plugin: isize| imp::exports(plugin));
    engine.register_fn("wasm-log", imp::log_lines);
    // How much work (roughly, instructions) one call may do.
    engine.register_fn("wasm-set-fuel!", |fuel: isize| {
        imp::set_fuel(fuel.max(1) as u64)
    });
    engine.register_fn("wasm-available?", || cfg!(feature = "wasm"));
}

#[cfg(not(feature = "wasm"))]
mod imp {
    const MISSING: &str = "imp was built without the wasm feature";

    pub fn load(_: &str) -> Result<isize, String> {
        Err(MISSING.into())
    }
    pub fn call(_: isize, _: &str, _: &str) -> Result<String, String> {
        Err(MISSING.into())
    }
    pub fn exports(_: isize) -> Result<Vec<String>, String> {
        Err(MISSING.into())
    }
    pub fn log_lines() -> Vec<String> {
        Vec::new()
    }
    pub fn set_fuel(_: u64) {}
}

#[cfg(feature = "wasm")]
mod imp {
    use std::cell::{Cell, RefCell};
    use wasmtime::{
        Caller, Config, Engine, Instance, Linker, Module, Store, StoreLimits, StoreLimitsBuilder,
        Trap,
    };

    /// The most memory one plugin may grow to.
    const MEMORY: usize = 64 << 20;
    const LOG_LINES: usize = 500;

    struct State {
        limits: StoreLimits,
        name: String,
    }

    struct Plugin {
        module: Module,
        store: Store<State>,
        instance: Instance,
    }

    thread_local! {
        static ENGINE: RefCell<Option<Engine>> = const { RefCell::new(None) };
        static PLUGINS: RefCell<Vec<Plugin>> = const { RefCell::new(Vec::new()) };
        static LOG: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
        /// Instructions (roughly) one call may run: about a second.
        static FUEL: Cell<u64> = const { Cell::new(1_000_000_000) };
    }

    pub fn set_fuel(fuel: u64) {
        FUEL.with(|f| f.set(fuel))
    }

    fn fuel() -> u64 {
        FUEL.with(|f| f.get())
    }

    fn log(line: String) {
        LOG.with(|l| {
            let mut l = l.borrow_mut();
            l.push(line);
            if l.len() > LOG_LINES {
                l.remove(0);
            }
        })
    }

    pub fn log_lines() -> Vec<String> {
        LOG.with(|l| l.borrow().clone())
    }

    fn engine() -> Result<Engine, String> {
        ENGINE.with(|slot| {
            let mut slot = slot.borrow_mut();
            if slot.is_none() {
                let mut config = Config::new();
                config.consume_fuel(true);
                *slot = Some(Engine::new(&config).map_err(|e| e.to_string())?);
            }
            Ok(slot.clone().unwrap())
        })
    }

    fn instantiate(module: &Module, name: &str) -> Result<(Store<State>, Instance), String> {
        let engine = module.engine();
        let mut store = Store::new(
            engine,
            State {
                limits: StoreLimitsBuilder::new().memory_size(MEMORY).build(),
                name: name.to_string(),
            },
        );
        store.limiter(|s| &mut s.limits);
        store.set_fuel(fuel()).map_err(|e| e.to_string())?;
        let mut linker = Linker::new(engine);
        linker
            .func_wrap(
                "imp",
                "log",
                |mut caller: Caller<'_, State>, ptr: i32, len: i32| {
                    let text = caller
                        .get_export("memory")
                        .and_then(|m| m.into_memory())
                        .and_then(|m| {
                            m.data(&caller)
                                .get(ptr as u32 as usize..)?
                                .get(..len as u32 as usize)
                                .map(|b| String::from_utf8_lossy(b).into_owned())
                        })
                        .unwrap_or_else(|| "(log out of bounds)".into());
                    log(format!("{}: {text}", caller.data().name));
                },
            )
            .map_err(|e| e.to_string())?;
        let instance = linker
            .instantiate(&mut store, module)
            .map_err(|e| format!("{name}: {e}"))?;
        Ok((store, instance))
    }

    /// Loads a .wasm (or .wat) file; a plugin handle.
    pub fn load(path: &str) -> Result<isize, String> {
        let module = Module::from_file(&engine()?, path).map_err(|e| format!("{path}: {e:#}"))?;
        let name = std::path::Path::new(path)
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        let (store, instance) = instantiate(&module, &name)?;
        PLUGINS.with(|p| {
            let mut p = p.borrow_mut();
            p.push(Plugin {
                module,
                store,
                instance,
            });
            Ok(p.len() as isize - 1)
        })
    }

    fn with_plugin<T>(
        plugin: isize,
        f: impl FnOnce(&mut Plugin) -> Result<T, String>,
    ) -> Result<T, String> {
        PLUGINS.with(|p| {
            let mut p = p.borrow_mut();
            let plugin = usize::try_from(plugin)
                .ok()
                .and_then(|i| p.get_mut(i))
                .ok_or("no such plugin")?;
            f(plugin)
        })
    }

    /// The functions a plugin offers (not its ABI plumbing).
    pub fn exports(plugin: isize) -> Result<Vec<String>, String> {
        with_plugin(plugin, |p| {
            Ok(p.module
                .exports()
                .filter(|e| e.ty().func().is_some() && e.name() != "imp_alloc")
                .map(|e| e.name().to_string())
                .collect())
        })
    }

    pub fn call(plugin: isize, name: &str, input: &str) -> Result<String, String> {
        with_plugin(plugin, |p| {
            let result = call_in(p, name, input);
            if let Err(e) = &result {
                // A trap can leave the plugin's memory half-updated: start
                // it afresh.
                if e.trapped {
                    let plugin_name = p.store.data().name.clone();
                    let (store, instance) = instantiate(&p.module, &plugin_name)?;
                    p.store = store;
                    p.instance = instance;
                }
            }
            result.map_err(|e| e.message)
        })
    }

    struct CallError {
        message: String,
        trapped: bool,
    }

    impl From<String> for CallError {
        fn from(message: String) -> Self {
            CallError {
                message,
                trapped: false,
            }
        }
    }

    fn call_in(p: &mut Plugin, name: &str, input: &str) -> Result<String, CallError> {
        let store = &mut p.store;
        store.set_fuel(fuel()).map_err(|e| e.to_string())?;
        let memory = p
            .instance
            .get_memory(&mut *store, "memory")
            .ok_or_else(|| "the plugin exports no memory".to_string())?;
        let alloc = p
            .instance
            .get_typed_func::<i32, i32>(&mut *store, "imp_alloc")
            .map_err(|e| format!("imp_alloc: {e}"))?;
        let func = p
            .instance
            .get_typed_func::<(i32, i32), i64>(&mut *store, name)
            .map_err(|e| format!("{name}: {e}"))?;
        let trap = |e: wasmtime::Error| CallError {
            message: match e.downcast_ref::<Trap>() {
                Some(Trap::OutOfFuel) => format!("{name} ran too long"),
                _ => format!("{name}: {e:#}"),
            },
            trapped: true,
        };
        let len = i32::try_from(input.len()).map_err(|_| "input too large".to_string())?;
        let ptr = alloc.call(&mut *store, len).map_err(trap)?;
        memory
            .write(&mut *store, ptr as u32 as usize, input.as_bytes())
            .map_err(|e| format!("imp_alloc gave a bad pointer: {e}"))?;
        let packed = func.call(&mut *store, (ptr, len)).map_err(trap)? as u64;
        let (out_ptr, out_len) = ((packed >> 32) as usize, (packed & 0xffff_ffff) as usize);
        // Slice the plugin's memory rather than allocate `out_len` first: a
        // length up to 4 GiB that the plugin doesn't have would otherwise
        // allocate past its memory limit before the bounds were checked.
        let out = out_ptr
            .checked_add(out_len)
            .and_then(|end| memory.data(&*store).get(out_ptr..end))
            .ok_or_else(|| format!("{name} returned a bad string: out of bounds"))?;
        String::from_utf8(out.to_vec()).map_err(|_| format!("{name} returned invalid UTF-8").into())
    }
}
