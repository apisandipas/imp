//! Running shell commands for :!, :r ! and filters.

use std::io::Write;
use std::process::{Command, Stdio};

/// Runs `command` with `sh -c`, writing `input` to its stdin. Returns the
/// exit code and stdout followed by stderr.
pub fn run(command: &str, input: &str) -> Result<(i32, String), String> {
    let mut child = Command::new("sh")
        .arg("-c")
        .arg(command)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("{command}: {e}"))?;
    // Write from another thread so a command that fills its output pipe
    // before reading all its input can't deadlock us.
    let mut stdin = child.stdin.take().expect("stdin is piped");
    let input = input.to_string();
    let writer = std::thread::spawn(move || {
        let _ = stdin.write_all(input.as_bytes());
    });
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    let _ = writer.join();
    let mut text = String::from_utf8_lossy(&out.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&out.stderr));
    Ok((out.status.code().unwrap_or(-1), text))
}
