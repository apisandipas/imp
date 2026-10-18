//! Background work: timers, jobs and socket listeners, reported to the
//! main loop as events.
//!
//! Only the thread that runs the server touches the editor and the Steel
//! VM. Timers and jobs run on their own threads and post events to the
//! server's channel; the server hands each to Scheme on its own thread.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::Sender;
use std::sync::Arc;
use std::time::Duration;

use imp_core::{ClientMsg, ServerMsg};

/// Everything the server's loop reacts to.
#[derive(Debug)]
pub enum Event {
    /// From the only client, when the server runs in-process.
    Client(ClientMsg),
    /// From client `id` of a daemon.
    FromClient(u64, ClientMsg),
    /// A daemon client connected; frames for it go to the sender.
    Connected(u64, Sender<ServerMsg>),
    Disconnected(u64),
    Timer(u64),
    /// Output from a job: (job, stream, text). Stream is "stdout" or
    /// "stderr".
    JobOutput(u64, &'static str, String),
    JobExit(u64),
    /// A connection to a socket listener: (listener, connection, the
    /// stream to write to it).
    SocketOpened(u64, u64, UnixStream),
    /// A line from a connection, without its line break.
    SocketLine(u64, String),
    SocketClosed(u64),
    /// A background parse finished: (buffer, buffer version it parsed,
    /// tree).
    Parsed(usize, u64, tree_sitter::Tree),
}

/// The handles background work needs, kept with the editor.
#[derive(Debug, Default)]
pub struct Background {
    pub sender: Option<Sender<Event>>,
    next_id: u64,
    timers: HashMap<u64, Arc<AtomicBool>>,
    jobs: HashMap<u64, (Child, Option<ChildStdin>)>,
    /// Socket listeners: their path, and a flag that stops accepting.
    listeners: HashMap<u64, (PathBuf, Arc<AtomicBool>)>,
    /// Open connections, for writing.
    connections: HashMap<u64, UnixStream>,
}

/// Connection ids, unique across listeners (accept threads hand them out).
static NEXT_CONNECTION: AtomicU64 = AtomicU64::new(1);

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

impl Background {
    /// Listens on a Unix socket only this user can reach. Each connection
    /// is reported with `SocketOpened`, then its lines with `SocketLine`,
    /// then `SocketClosed`.
    pub fn listen(&mut self, path: &Path) -> Result<u64, String> {
        let sender = self.sender.clone().ok_or("no event loop")?;
        let listener = crate::daemon::bind(path, "something is already listening")?;
        let id = self.id();
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                if stopped.load(Ordering::SeqCst) {
                    break;
                }
                let Ok(stream) = stream else { continue };
                let Ok(write_half) = stream.try_clone() else {
                    continue;
                };
                let conn = NEXT_CONNECTION.fetch_add(1, Ordering::SeqCst);
                if sender
                    .send(Event::SocketOpened(id, conn, write_half))
                    .is_err()
                {
                    break;
                }
                let sender = sender.clone();
                std::thread::spawn(move || {
                    for line in BufReader::new(stream).lines().map_while(Result::ok) {
                        if sender.send(Event::SocketLine(conn, line)).is_err() {
                            return;
                        }
                    }
                    let _ = sender.send(Event::SocketClosed(conn));
                });
            }
        });
        self.listeners.insert(id, (path.to_path_buf(), stop));
        Ok(id)
    }

    /// Stops accepting connections and removes the socket.
    pub fn stop_listening(&mut self, id: u64) {
        if let Some((path, stop)) = self.listeners.remove(&id) {
            stop.store(true, Ordering::SeqCst);
            // Wake the accept loop so it sees the flag.
            let _ = UnixStream::connect(&path);
            let _ = std::fs::remove_file(&path);
        }
    }

    /// Connects to a Unix socket. Its lines come back as `SocketLine`,
    /// then `SocketClosed`, as for a connection to a listener.
    pub fn connect(&mut self, path: &Path) -> Result<u64, String> {
        let sender = self.sender.clone().ok_or("no event loop")?;
        let stream = UnixStream::connect(path).map_err(|e| format!("{}: {e}", path.display()))?;
        let read_half = stream.try_clone().map_err(|e| e.to_string())?;
        let conn = NEXT_CONNECTION.fetch_add(1, Ordering::SeqCst);
        self.connections.insert(conn, stream);
        std::thread::spawn(move || {
            for line in BufReader::new(read_half).lines().map_while(Result::ok) {
                if sender.send(Event::SocketLine(conn, line)).is_err() {
                    return;
                }
            }
            let _ = sender.send(Event::SocketClosed(conn));
        });
        Ok(conn)
    }

    pub fn connection_opened(&mut self, conn: u64, stream: UnixStream) {
        self.connections.insert(conn, stream);
    }

    pub fn connection_closed(&mut self, conn: u64) {
        self.connections.remove(&conn);
    }

    /// Writes to a connection. False if it is gone.
    pub fn send_to_connection(&mut self, conn: u64, text: &str) -> bool {
        match self.connections.get_mut(&conn) {
            Some(stream) => stream
                .write_all(text.as_bytes())
                .and_then(|_| stream.flush())
                .is_ok(),
            None => false,
        }
    }

    pub fn close_connection(&mut self, conn: u64) {
        if let Some(stream) = self.connections.remove(&conn) {
            let _ = stream.shutdown(std::net::Shutdown::Both);
        }
    }
}

impl Drop for Background {
    /// Jobs (language servers, debuggers) end with the editor, and its
    /// sockets go away.
    fn drop(&mut self) {
        for (child, _) in self.jobs.values_mut() {
            let _ = child.kill();
        }
        let listeners: Vec<u64> = self.listeners.keys().copied().collect();
        for id in listeners {
            self.stop_listening(id);
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
