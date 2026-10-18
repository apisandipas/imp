//! The system clipboard, by way of the usual command-line tools.
//!
//! Shelling out keeps imp free of display-server libraries and works the
//! same over ssh with a forwarded clipboard tool. The first tool found wins:
//! wl-clipboard on Wayland, then xclip or xsel on X11, then pbcopy on macOS.

use std::io::Write;
use std::process::{Command, Stdio};

/// `primary` is the X11/Wayland primary selection (Vim's `"*`); otherwise
/// the clipboard (`"+`).
pub fn get(primary: bool) -> Option<String> {
    for (cmd, args) in paste_commands(primary) {
        if let Ok(out) = Command::new(cmd).args(args).stderr(Stdio::null()).output() {
            if out.status.success() {
                return Some(String::from_utf8_lossy(&out.stdout).into_owned());
            }
        }
    }
    None
}

pub fn set(text: &str, primary: bool) -> bool {
    for (cmd, args) in copy_commands(primary) {
        let child = Command::new(cmd)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
        let Ok(mut child) = child else { continue };
        let wrote = child
            .stdin
            .take()
            .is_some_and(|mut stdin| stdin.write_all(text.as_bytes()).is_ok());
        // wl-copy and xclip fork to keep serving the selection, so the
        // command we started exits promptly.
        if wrote && child.wait().is_ok_and(|s| s.success()) {
            return true;
        }
    }
    false
}

fn wayland() -> bool {
    std::env::var_os("WAYLAND_DISPLAY").is_some()
}

fn paste_commands(primary: bool) -> Vec<(&'static str, Vec<&'static str>)> {
    let mut cmds = Vec::new();
    if wayland() {
        let mut args = vec!["--no-newline"];
        if primary {
            args.push("--primary");
        }
        cmds.push(("wl-paste", args));
    }
    let sel = if primary { "primary" } else { "clipboard" };
    cmds.push(("xclip", vec!["-o", "-selection", sel]));
    cmds.push(("xsel", vec!["-o", if primary { "-p" } else { "-b" }]));
    cmds.push(("pbpaste", vec![]));
    cmds
}

fn copy_commands(primary: bool) -> Vec<(&'static str, Vec<&'static str>)> {
    let mut cmds = Vec::new();
    if wayland() {
        cmds.push(("wl-copy", if primary { vec!["--primary"] } else { vec![] }));
    }
    let sel = if primary { "primary" } else { "clipboard" };
    cmds.push(("xclip", vec!["-i", "-selection", sel]));
    cmds.push(("xsel", vec!["-i", if primary { "-p" } else { "-b" }]));
    cmds.push(("pbcopy", vec![]));
    cmds
}
