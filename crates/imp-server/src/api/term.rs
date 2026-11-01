//! Terminal buffers (term.rs).

use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;
use steel::SteelVal;

use super::{clamp, fail};
use crate::editor;

pub(super) fn register(engine: &mut Engine) {
    // Terminal buffers (term.rs). term-start! returns the terminal's id,
    // or the error as a string.
    engine.register_fn(
        "term-start!",
        |command: String, cwd: String, rows: isize, cols: isize| {
            editor::with(|e| match e.background.sender.clone() {
                Some(sender) => {
                    match crate::term::spawn(
                        &command,
                        &cwd,
                        clamp(rows) as u16,
                        clamp(cols) as u16,
                        sender,
                    ) {
                        Ok(id) => SteelVal::IntV(id as isize),
                        Err(err) => SteelVal::StringV(err.into()),
                    }
                }
                None => SteelVal::StringV("no event loop".into()),
            })
        },
    );
    engine.register_fn("term-send!", |id: isize, text: String| {
        crate::term::send(clamp(id) as u64, &text)
    });
    engine.register_fn("term-resize!", |id: isize, rows: isize, cols: isize| {
        crate::term::resize(clamp(id) as u64, clamp(rows) as u16, clamp(cols) as u16)
    });
    engine.register_fn(
        "term-kill!",
        |id: isize| crate::term::kill(clamp(id) as u64),
    );
    // The theme's colors for ANSI 0-15 in terminals, as "#rrggbb" strings.
    engine.register_fn("set-terminal-palette!", |colors: Vec<String>| {
        let parsed: Result<Vec<_>, _> = colors.iter().map(|c| imp_core::Color::parse(c)).collect();
        parsed.map(|p| crate::term::set_palette(&p)).map_err(fail)
    });
    engine.register_fn("term-application-cursor?", |id: isize| {
        crate::term::application_cursor(clamp(id) as u64)
    });
    // What mouse reporting the program asked for, as (mode encoding)
    // strings (term::mouse_mode), or #f once it is gone.
    engine.register_fn("term-mouse-mode", |id: isize| {
        crate::term::mouse_mode(clamp(id) as u64)
            .map(|(m, e)| vec![SteelVal::StringV(m.into()), SteelVal::StringV(e.into())])
    });
    // The buffer line the terminal's screen starts on, or #f.
    engine.register_fn("term-screen-top", |id: isize| {
        crate::term::screen_top(clamp(id) as u64).map(|n| n as isize)
    });

    // The terminal's screen as (rows columns), or #f once it is gone.
    engine.register_fn("term-size", |id: isize| {
        crate::term::screen_size(clamp(id) as u64)
            .map(|(r, c)| vec![SteelVal::IntV(r as isize), SteelVal::IntV(c as isize)])
    });
    engine.register_fn("term-bracketed-paste?", |id: isize| {
        crate::term::bracketed_paste(clamp(id) as u64)
    });
    // The commands the shell marked (OSC 133) as (prompt-line output-line
    // status), output-line and status #f until known.
    engine.register_fn("term-prompts", |id: isize| {
        crate::term::prompts(clamp(id) as u64)
            .into_iter()
            .map(|(prompt, output, status)| {
                vec![
                    SteelVal::IntV(prompt as isize),
                    output.map_or(SteelVal::BoolV(false), |o| SteelVal::IntV(o as isize)),
                    status.map_or(SteelVal::BoolV(false), |s| SteelVal::IntV(s as isize)),
                ]
            })
            .collect::<Vec<_>>()
    });
    // Takes what the program copied (OSC 52) since last asked, as
    // (text primary?) lists.
    engine.register_fn("term-take-copies!", |id: isize| {
        crate::term::take_copies(clamp(id) as u64)
            .into_iter()
            .map(|(text, primary)| vec![SteelVal::StringV(text.into()), SteelVal::BoolV(primary)])
            .collect::<Vec<_>>()
    });
    // The title the program last set (OSC 0 or 2), or #f.
    engine.register_fn("term-title", |id: isize| {
        crate::term::title(clamp(id) as u64)
    });
    // The directory the shell last reported on this machine (OSC 7), or #f.
    engine.register_fn("term-directory", |id: isize| {
        crate::term::directory(clamp(id) as u64)
    });
    // Draws terminal `id` into buffer `buf`; returns its cursor's offset.
    engine.register_fn("term-render!", |id: isize, buf: isize| {
        editor::with(|e| {
            let buf = clamp(buf);
            let mut faces = std::mem::take(&mut e.faces);
            let mut layers = e.buffer_layers.remove(&buf).unwrap_or_default();
            let i = match layers.iter().position(|l| l.name == "term") {
                Some(i) => i,
                None => {
                    layers.push(editor::Layer {
                        name: "term".into(),
                        ..Default::default()
                    });
                    layers.len() - 1
                }
            };
            let at = e.buffer_and_cursor_mut(buf).and_then(|(buffer, _)| {
                crate::term::render(clamp(id) as u64, buffer, &mut faces, &mut layers[i])
            });
            e.faces = faces;
            e.buffer_layers.insert(buf, layers);
            at.map(|a| a as isize)
        })
    });
}
