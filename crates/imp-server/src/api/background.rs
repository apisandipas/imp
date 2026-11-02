//! Timers, jobs and Unix sockets (events.rs).

use std::path::Path;
use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;
use steel::SteelVal;

use super::{clamp, fail};
use crate::editor;

pub(super) fn register(engine: &mut Engine) {
    // Timers and jobs (events.rs). Scheme's wrappers in core.scm keep the
    // procedures to call; these just start, stop and talk to them.
    engine.register_fn("timer-start!", |ms: isize, repeat: bool| {
        editor::with(|e| {
            e.background
                .start_timer(clamp(ms) as u64, repeat)
                .map(|id| id as isize)
        })
    });
    engine.register_fn("timer-cancel!", |id: isize| {
        editor::with(|e| e.background.cancel_timer(clamp(id) as u64))
    });
    engine.register_fn("timer-done!", |id: isize, repeat: bool| {
        editor::with(|e| e.background.timer_fired(clamp(id) as u64, repeat))
    });
    // Milliseconds since the last key, paste or mouse event from any
    // client; before the first, a very long time.
    engine.register_fn("input-idle-ms", || {
        editor::with(|e| {
            e.last_input
                .map_or(isize::MAX / 2, |t| t.elapsed().as_millis() as isize)
        })
    });
    // The job's id. Input #f keeps stdin open.
    engine.register_fn("job-start!", |command: String, input: SteelVal| {
        let input = match &input {
            SteelVal::StringV(s) => Some(s.to_string()),
            _ => None,
        };
        editor::with(|e| {
            e.background
                .start_job(&command, input.as_deref())
                .map(|id| id as isize)
                .map_err(fail)
        })
    });
    engine.register_fn("job-send!", |id: isize, text: String| {
        editor::with(|e| e.background.send_to_job(clamp(id) as u64, &text))
    });
    engine.register_fn("job-close-input!", |id: isize| {
        editor::with(|e| e.background.close_job_input(clamp(id) as u64))
    });
    engine.register_fn("job-kill!", |id: isize| {
        editor::with(|e| e.background.kill_job(clamp(id) as u64))
    });

    // Unix sockets (events.rs): a listener id.
    engine.register_fn("socket-listen!", |path: String| {
        editor::with(|e| {
            e.background
                .listen(Path::new(&path))
                .map(|id| id as isize)
                .map_err(fail)
        })
    });

    // A connection id.
    engine.register_fn("socket-connect!", |path: String| {
        editor::with(|e| {
            e.background
                .connect(Path::new(&path))
                .map(|id| id as isize)
                .map_err(fail)
        })
    });
    engine.register_fn("socket-stop!", |id: isize| {
        editor::with(|e| e.background.stop_listening(clamp(id) as u64))
    });
    engine.register_fn("socket-send!", |conn: isize, text: String| {
        editor::with(|e| e.background.send_to_connection(clamp(conn) as u64, &text))
    });
    engine.register_fn("socket-close!", |conn: isize| {
        editor::with(|e| e.background.close_connection(clamp(conn) as u64))
    });
    // Where a socket called `name` goes ($XDG_RUNTIME_DIR/imp/NAME.sock).
    engine.register_fn("socket-path", |name: String| {
        crate::daemon::socket_path(&name).display().to_string()
    });
}
