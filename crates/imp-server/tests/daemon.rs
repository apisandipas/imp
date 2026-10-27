//! The daemon: clients attach over a socket and share one editor, each
//! with its own windows.

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
    start_daemon_at(name, &socket);
    socket
}

fn options(name: &str) -> imp_server::Options {
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
    imp_server::Options {
        user_config: Some(config),
    }
}

fn start_daemon_at(name: &str, socket: &std::path::Path) {
    let (s, options) = (socket.to_path_buf(), options(name));
    std::thread::spawn(move || imp_server::daemon::run(&s, options).unwrap());
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
    // :q detaches b; a carries on, its cursor still on the i, not where
    // b's was.
    b.keys(&[":", "q", "!", "<ret>"]);
    assert!(!b.until(|_| false));
    a.keys(&["x"]);
    assert!(a.until(|f| f.text_rows()[0].trim_end() == "h!"));
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

#[test]
fn the_socket_directory_is_private() {
    use std::os::unix::fs::PermissionsExt;
    // A directory this user owns is made 0700.
    let dir = common::temp_path("loose");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
    let socket = dir.join("imp.sock");
    start_daemon_at("loose", &socket);
    let mut a = Client::connect(&socket);
    let mode = std::fs::metadata(&dir).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o700);
    a.keys(&[
        ":", "k", "i", "l", "l", "-", "s", "e", "r", "v", "e", "r", "<ret>",
    ]);
    assert!(!a.until(|_| false));
    // A symlink is refused: someone else may have put it there.
    let link = common::temp_path("link");
    std::os::unix::fs::symlink(&dir, &link).unwrap();
    let err = imp_server::daemon::run(&link.join("imp.sock"), options("link"));
    assert!(err.unwrap_err().contains("not a directory"));
}

fn kill_server(c: &mut Client) {
    c.keys(&[
        ":", "k", "i", "l", "l", "-", "s", "e", "r", "v", "e", "r", "<ret>",
    ]);
    assert!(!c.until(|_| false));
}

fn ex(c: &mut Client, command: &str) {
    c.keys(&[":"]);
    for ch in command.chars() {
        c.keys(&[&ch.to_string()]);
    }
    c.keys(&["<ret>"]);
}

/// Whether the screen shows two windows side by side.
fn split(f: &Frame) -> bool {
    f.text_rows()[0].contains('│')
}

#[test]
fn each_client_has_its_own_windows() {
    let socket = start_daemon("own-windows");
    let mut a = Client::connect(&socket);
    a.keys(&[
        "i", "o", "n", "e", "<ret>", "t", "w", "o", "<ret>", "t", "h", "r", "e", "e", "<esc>",
    ]);
    assert!(a.until(|f| f.text_rows()[2].trim_end() == "three"));
    let mut b = Client::connect(&socket);
    // b starts on a's buffer, in one window of its own.
    b.keys(&["g", "g"]);
    assert!(b.until(|f| f.text_rows()[0].trim_end() == "one"));
    // a splits; b doesn't.
    a.keys(&["C-w", "v"]);
    assert!(a.until(split));
    b.keys(&["l"]);
    assert!(b.until(|f| !split(f) && f.text_rows()[0].starts_with("one")));
    // Each keeps its own cursor: b on "one", a on "three", where x lands
    // after b adds a line above it.
    b.keys(&["O", "z", "e", "r", "o", "<esc>"]);
    assert!(b.until(|f| f.text_rows()[0].trim_end() == "zero"));
    a.keys(&["0", "x"]);
    assert!(a.until(|f| f.text_rows()[3].starts_with("hree")));
    // :q on a's split closes a window, and a stays.
    ex(&mut a, "q");
    assert!(a.until(|f| !split(f)));
    // b switching buffers leaves a's window alone.
    let path = common::temp_path("daemon-own.txt");
    std::fs::write(&path, "elsewhere\n").unwrap();
    ex(&mut b, &format!("e {}", path.display()));
    assert!(b.until(|f| f.text_rows()[0].trim_end() == "elsewhere"));
    a.keys(&["k"]);
    assert!(a.until(|f| f.text_rows()[0].trim_end() == "zero"));
    kill_server(&mut a);
}

#[test]
fn a_buffer_deleted_elsewhere_is_replaced() {
    let socket = start_daemon("deleted");
    let path = common::temp_path("daemon-deleted.txt");
    std::fs::write(&path, "doomed\n").unwrap();
    let mut a = Client::connect(&socket);
    a.keys(&["i", "k", "e", "p", "t", "<esc>"]);
    assert!(a.until(|f| f.text_rows()[0].trim_end() == "kept"));
    let mut b = Client::connect(&socket);
    b.send(ClientMsg::Open(vec![path.display().to_string()]));
    assert!(b.until(|f| f.text_rows()[0].trim_end() == "doomed"));
    // a opens it too, then deletes it: b's window shows another buffer.
    ex(&mut a, &format!("e {}", path.display()));
    assert!(a.until(|f| f.text_rows()[0].trim_end() == "doomed"));
    ex(&mut a, "bd");
    assert!(a.until(|f| f.text_rows()[0].trim_end() == "kept"));
    b.keys(&["l"]);
    assert!(b.until(|f| f.text_rows()[0].trim_end() != "doomed"));
    kill_server(&mut a);
}

#[test]
fn a_popup_stays_in_its_client() {
    let socket = start_daemon("popup");
    let mut a = Client::connect(&socket);
    a.keys(&["i", "t", "e", "x", "t", "<esc>"]);
    assert!(a.until(|f| f.text_rows()[0].trim_end() == "text"));
    let mut b = Client::connect(&socket);
    b.keys(&["l"]);
    assert!(b.until(|f| f.text_rows()[0].trim_end() == "text"));
    // a lists the faces in a popup down the right; b has none.
    a.send(ClientMsg::Resize {
        width: 80,
        height: 6,
    });
    ex(&mut a, "eval (run-command 'list-faces)");
    assert!(a.until(split));
    b.keys(&["l"]);
    assert!(b.until(|f| !split(f) && f.text_rows()[0].starts_with("text")));
    // b opens one of its own; q in a's still closes a's and goes back.
    b.send(ClientMsg::Resize {
        width: 80,
        height: 6,
    });
    ex(&mut b, "eval (run-command 'list-faces)");
    assert!(b.until(split));
    a.keys(&["q"]);
    assert!(a.until(|f| !split(f) && f.text_rows()[0].starts_with("text")));
    kill_server(&mut a);
}

#[test]
fn each_client_has_its_own_file_tree() {
    let socket = start_daemon("file-trees");
    let project = |name: &str| {
        let dir = common::temp_path(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        std::fs::write(dir.join(format!("{name}.txt")), "").unwrap();
        dir
    };
    let (one, two) = (project("tree-one"), project("tree-two"));
    let mut a = Client::connect(&socket);
    ex(&mut a, "eval (use-package! 'file-tree)");
    ex(&mut a, &format!("e {}", one.join("tree-one.txt").display()));
    a.keys(&[" ", "t", "e"]);
    assert!(a.until(|f| f.text_rows()[0].starts_with("tree-one")));
    let mut b = Client::connect(&socket);
    ex(&mut b, &format!("e {}", two.join("tree-two.txt").display()));
    b.keys(&[" ", "t", "e"]);
    assert!(b.until(|f| f.text_rows()[0].starts_with("tree-two")));
    // a's tree still shows its own project, in its own buffer.
    a.keys(&["k"]);
    assert!(a
        .until(|f| f.text_rows()[0].starts_with("tree-one")
            && f.text_rows()[1].contains("tree-one.txt")));
    // Closing b's tree leaves a's.
    b.keys(&["q"]);
    assert!(b.until(|f| f.text_rows()[0].trim_end().is_empty()));
    a.keys(&["j"]);
    assert!(a.until(|f| f.text_rows()[0].starts_with("tree-one")));
    kill_server(&mut a);
}
