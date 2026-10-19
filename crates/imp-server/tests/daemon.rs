//! The daemon: clients attach over a socket and share one editor.

mod common;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use imp_core::{protocol, ClientMsg, Frame, ServerMsg};

/// A test client: sends messages, keeps the screen up to date from frames
/// and patches.
struct Client {
    w: UnixStream,
    r: BufReader<UnixStream>,
    screen: Frame,
}

impl Client {
    fn connect(socket: &std::path::Path) -> Client {
        // The daemon may still be starting.
        let mut tries = 0;
        let stream = loop {
            match UnixStream::connect(socket) {
                Ok(s) => break s,
                Err(_) if tries < 100 => {
                    tries += 1;
                    std::thread::sleep(Duration::from_millis(50));
                }
                Err(e) => panic!("daemon never came up: {e}"),
            }
        };
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut c = Client {
            w: stream.try_clone().unwrap(),
            r: BufReader::new(stream),
            screen: Frame::default(),
        };
        c.send(ClientMsg::Resize {
            width: 40,
            height: 6,
        });
        c
    }

    fn send(&mut self, msg: ClientMsg) {
        writeln!(self.w, "{}", protocol::to_line(&msg)).unwrap();
    }

    fn keys(&mut self, keys: &[&str]) {
        for k in keys {
            self.send(ClientMsg::Key(k.to_string()));
        }
    }

    /// Reads updates until one satisfies `done`, or returns false on Quit.
    fn until(&mut self, done: impl Fn(&Frame) -> bool) -> bool {
        loop {
            let mut line = String::new();
            if self.r.read_line(&mut line).unwrap_or(0) == 0 {
                return false;
            }
            match protocol::from_line::<ServerMsg>(&line).unwrap() {
                ServerMsg::Frame(f) => self.screen = f,
                ServerMsg::Patch(p) => p.apply(&mut self.screen),
                ServerMsg::Quit => return false,
            }
            if done(&self.screen) {
                return true;
            }
        }
    }

    fn row(&self, i: usize) -> String {
        self.screen.text_rows()[i].clone()
    }
}

fn start_daemon(name: &str) -> std::path::PathBuf {
    let socket = common::temp_path(&format!("{name}.sock"));
    // State (recent files, remembered projects) stays out of the real one.
    let config = common::temp_path(&format!("{name}-init.scm"));
    std::fs::write(
        &config,
        format!(
            "(set-option! 'state-directory {:?})\n",
            common::temp_path("state").display().to_string()
        ),
    )
    .unwrap();
    let s = socket.clone();
    std::thread::spawn(move || {
        let options = imp_server::Options {
            user_config: Some(config),
        };
        imp_server::daemon::run(&s, options).unwrap();
    });
    socket
}

#[test]
fn clients_share_one_editor() {
    let socket = start_daemon("share");
    let mut a = Client::connect(&socket);
    a.keys(&["i", "h", "i", "<esc>"]);
    assert!(a.until(|f| f.text_rows()[0].trim_end() == "hi"));
    // A second client sees the same buffer.
    let mut b = Client::connect(&socket);
    b.keys(&["$"]);
    assert!(b.until(|f| f.text_rows()[0].trim_end() == "hi"));
    b.keys(&["A", "!", "<esc>"]);
    assert!(a.until(|f| f.text_rows()[0].trim_end() == "hi!"));
    // :q detaches b; a carries on.
    b.keys(&[":", "q", "!", "<ret>"]);
    assert!(!b.until(|_| false));
    a.keys(&["x"]);
    assert!(a.until(|f| f.text_rows()[0].trim_end() == "hi"));
    // :kill-server stops the daemon for everyone.
    a.keys(&[
        ":", "k", "i", "l", "l", "-", "s", "e", "r", "v", "e", "r", "<ret>",
    ]);
    assert!(!a.until(|_| false));
    std::thread::sleep(Duration::from_millis(100));
    assert!(UnixStream::connect(&socket).is_err());
}

#[test]
fn clients_open_files_and_get_their_own_size() {
    let socket = start_daemon("open");
    let path = common::temp_path("daemon-file.txt");
    std::fs::write(&path, "from disk\n").unwrap();
    let mut a = Client::connect(&socket);
    a.send(ClientMsg::Open(vec![path.display().to_string()]));
    assert!(a.until(|f| f.text_rows()[0].trim_end() == "from disk"));
    let mut b = Client::connect(&socket);
    b.send(ClientMsg::Resize {
        width: 20,
        height: 4,
    });
    b.keys(&["l"]);
    assert!(b.until(|f| f.rows.len() == 4 && f.text_rows()[0].trim_end() == "from disk"));
    assert_eq!(a.screen.rows.len(), 6);
    a.keys(&[
        ":", "k", "i", "l", "l", "-", "s", "e", "r", "v", "e", "r", "<ret>",
    ]);
    assert!(!a.until(|_| false));
    let _ = b.row(0);
}

#[test]
fn a_second_daemon_on_the_same_socket_is_refused() {
    let socket = start_daemon("twice");
    let mut a = Client::connect(&socket);
    let err =
        imp_server::daemon::run(&socket, imp_server::Options { user_config: None }).unwrap_err();
    assert!(err.contains("already running"), "{err}");
    a.keys(&[
        ":", "k", "i", "l", "l", "-", "s", "e", "r", "v", "e", "r", "<ret>",
    ]);
    assert!(!a.until(|_| false));
}
