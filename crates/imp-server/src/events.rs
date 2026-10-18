//! Background work: timers and jobs, reported to the main loop as events.
//!
//! Only the thread that runs the server touches the editor and the Steel
//! VM. Timers and jobs run on their own threads and post events to the
//! server's channel; the server hands each to Scheme on its own thread.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::Arc;
use std::time::Duration;

use imp_core::ClientMsg;

/// Everything the server's loop reacts to.
#[derive(Debug)]
pub enum Event {
    Client(ClientMsg),
    Timer(u64),
    /// Output from a job: (job, stream, text). Stream is "stdout" or
    /// "stderr".
    JobOutput(u64, &'static str, String),
    JobExit(u64),
}

/// The handles background work needs, kept with the editor.
#[derive(Debug, Default)]
pub struct Background {
    pub sender: Option<Sender<Event>>,
    next_id: u64,
    timers: HashMap<u64, Arc<AtomicBool>>,
    jobs: HashMap<u64, (Child, Option<ChildStdin>)>,
}

impl Background {
    fn id(&mut self) -> u64 {
        self.next_id += 1;
        self.next_id
    }

    /// Posts `Timer(id)` after `ms`, and again every `ms` if `repeat`,
    /// until cancelled.
    pub fn start_timer(&mut self, ms: u64, repeat: bool) -> Option<u64> {
        let sender = self.sender.clone()?;
        let id = self.id();
        let cancelled = Arc::new(AtomicBool::new(false));
        self.timers.insert(id, cancelled.clone());
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_millis(ms));
            if cancelled.load(Ordering::Relaxed)
                || sender.send(Event::Timer(id)).is_err()
                || !repeat
            {
                break;
            }
        });
        Some(id)
    }

    pub fn cancel_timer(&mut self, id: u64) {
        if let Some(flag) = self.timers.remove(&id) {
            flag.store(true, Ordering::Relaxed);
        }
    }

    /// Forgets a one-shot timer once it has fired.
    pub fn timer_fired(&mut self, id: u64, repeat: bool) {
        if !repeat {
            self.timers.remove(&id);
        }
    }

    /// Starts `command` with `sh -c`. With `input`, writes it and closes
    /// stdin; without, stdin stays open for `send_to_job`. Output comes
    /// back as `JobOutput` events as it arrives, then `JobExit`.
    pub fn start_job(&mut self, command: &str, input: Option<&str>) -> Result<u64, String> {
        let sender = self.sender.clone().ok_or("no event loop")?;
        let mut child = Command::new("sh")
            .arg("-c")
            .arg(command)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("{command}: {e}"))?;
        let id = self.id();
        let mut stdin = child.stdin.take();
        if let Some(input) = input {
            if let Some(mut s) = stdin.take() {
                // A thread, so a command that writes a lot before reading
                // all its input can't block us.
                let input = input.to_string();
                std::thread::spawn(move || {
                    let _ = s.write_all(input.as_bytes());
                });
            }
        }
        let out = child.stdout.take().expect("stdout is piped");
        let err = child.stderr.take().expect("stderr is piped");
        let readers = [
            spawn_reader(id, "stdout", out, sender.clone()),
            spawn_reader(id, "stderr", err, sender.clone()),
        ];
        self.jobs.insert(id, (child, stdin));
        // When both streams end the process has finished (or closed them);
        // wait for it there and report the exit.
        let exit_sender = sender;
        std::thread::spawn(move || {
            for r in readers {
                let _ = r.join();
            }
            let _ = exit_sender.send(Event::JobExit(id));
        });
        Ok(id)
    }

    /// Writes to a job's stdin. False if the job is gone or closed it.
    pub fn send_to_job(&mut self, id: u64, text: &str) -> bool {
        match self.jobs.get_mut(&id) {
            Some((_, Some(stdin))) => {
                stdin.write_all(text.as_bytes()).is_ok() && stdin.flush().is_ok()
            }
            _ => false,
        }
    }

    /// Closes a job's stdin, so it sees end of input.
    pub fn close_job_input(&mut self, id: u64) {
        if let Some((_, stdin)) = self.jobs.get_mut(&id) {
            stdin.take();
        }
    }

    pub fn kill_job(&mut self, id: u64) -> bool {
        match self.jobs.get_mut(&id) {
            Some((child, _)) => child.kill().is_ok(),
            None => false,
        }
    }

    /// Collects a finished job's exit code.
    pub fn job_finished(&mut self, id: u64) -> i32 {
        match self.jobs.remove(&id) {
            Some((mut child, _)) => child.wait().ok().and_then(|s| s.code()).unwrap_or(-1),
            None => -1,
        }
    }
}

fn spawn_reader(
    id: u64,
    stream: &'static str,
    mut from: impl Read + Send + 'static,
    sender: Sender<Event>,
) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        let mut buf = [0u8; 8192];
        // Bytes of a UTF-8 char split across reads wait for the rest.
        let mut pending: Vec<u8> = Vec::new();
        loop {
            match from.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    pending.extend_from_slice(&buf[..n]);
                    let valid = match std::str::from_utf8(&pending) {
                        Ok(_) => pending.len(),
                        Err(e) if e.error_len().is_none() => e.valid_up_to(),
                        Err(_) => pending.len(),
                    };
                    let text = String::from_utf8_lossy(&pending[..valid]).into_owned();
                    pending.drain(..valid);
                    if !text.is_empty() && sender.send(Event::JobOutput(id, stream, text)).is_err()
                    {
                        break;
                    }
                }
            }
        }
    })
}
