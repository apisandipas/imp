//! Shared buffers (runtime/collab.scm, src/crdt.rs). Most tests need the
//! `crdt` feature: cargo test --features crdt.

mod common;

use common::*;

#[test]
#[cfg(not(feature = "crdt"))]
fn without_the_feature_it_says_so() {
    let mut s = server("text\n");
    assert_eq!(s.eval("(crdt-available?)").unwrap(), "#false");
    let err = s.eval("(crdt-share! (current-buffer))").unwrap_err();
    assert!(err.contains("without the crdt feature"), "{err}");
    feed(&mut s, ":share<ret>");
    assert!(status_row_or_message(&mut s).contains("without the crdt feature"));
}

// Messages a peer sends, handled by collab-receive! (no socket needed).

#[test]
fn the_name_message_names_the_joined_buffer_even_when_not_current() {
    let mut s = server("text\n");
    let here = s.eval("(current-buffer)").unwrap();
    let joined = s.eval("(buffer-new! \"[shared] imp\")").unwrap();
    assert_eq!(s.eval("(current-buffer)").unwrap(), here);
    s.eval(&format!("(collab-receive! {joined} #f \"name main.rs\")"))
        .unwrap();
    assert_eq!(s.eval("(current-buffer)").unwrap(), here);
    assert_eq!(
        s.eval(&format!("(car (buffer-info {joined}))")).unwrap(),
        "\"[shared] main.rs\""
    );
    assert_eq!(
        s.eval(&format!("(with-buffer {joined} major-mode)"))
            .unwrap(),
        "rust-mode"
    );
}

#[test]
fn a_malformed_update_is_reported_not_an_error() {
    let mut s = server("text\n");
    s.eval("(collab-receive! (current-buffer) #f \"update\")")
        .unwrap();
    assert!(s.status().contains("bad update"), "{}", s.status());
    s.eval("(set-status! \"\")").unwrap();
    s.eval("(collab-receive! (current-buffer) #f \"update !!!not-an-update\")")
        .unwrap();
    assert!(s.status().contains("bad update"), "{}", s.status());
    assert_eq!(s.text(), "text\n");
}

#[cfg(not(feature = "crdt"))]
fn status_row_or_message(s: &mut imp_server::Server) -> String {
    s.frame().text_rows().join("\n")
}

#[cfg(feature = "crdt")]
mod shared {
    use super::*;
    use std::sync::mpsc::{channel, Sender};
    use std::time::{Duration, Instant};

    fn text(s: &mut imp_server::Server) -> String {
        s.eval("(buffer-substring 0 (buffer-length))").unwrap()
    }

    /// Two buffers of one editor, each with its own document, exchanging
    /// updates directly.
    #[test]
    fn concurrent_edits_merge() {
        let mut s = server("hello\n");
        s.eval("(define a (current-buffer)) (define b (buffer-new! \"b\"))")
            .unwrap();
        s.eval("(crdt-share! a) (crdt-share! b)").unwrap();
        assert_eq!(s.eval("(crdt-shared? a)").unwrap(), "#true");
        // B catches up with A.
        s.eval("(crdt-apply! b (crdt-diff a (crdt-state b)))")
            .unwrap();
        // A's first sync hands out its text; then there's nothing new.
        assert_ne!(s.eval("(crdt-sync! a)").unwrap(), "#false");
        assert_eq!(s.eval("(crdt-sync! a)").unwrap(), "#false");
        s.eval("(switch-to-buffer! b)").unwrap();
        assert_eq!(text(&mut s), "\"hello\\n\"");
        // Both change at once, then trade updates.
        s.eval("(set-cursor! 3) (buffer-insert! 6 \"Y\")").unwrap();
        s.eval("(switch-to-buffer! a) (buffer-insert! 0 \"X\")")
            .unwrap();
        s.eval("(define ua (crdt-sync! a)) (define ub (crdt-sync! b))")
            .unwrap();
        s.eval("(crdt-apply! a ub) (crdt-apply! b ua)").unwrap();
        assert_eq!(text(&mut s), "\"Xhello\\nY\"");
        s.eval("(switch-to-buffer! b)").unwrap();
        assert_eq!(text(&mut s), "\"Xhello\\nY\"");
        // B's cursor moved with the text inserted before it.
        assert_eq!(s.eval("(cursor)").unwrap(), "4");
        // Applying an update twice changes nothing.
        s.eval("(crdt-apply! b ua)").unwrap();
        assert_eq!(text(&mut s), "\"Xhello\\nY\"");
    }

    #[test]
    fn deletes_and_unicode() {
        let mut s = server("née café\n");
        s.eval("(define a (current-buffer)) (define b (buffer-new! \"b\"))")
            .unwrap();
        s.eval("(crdt-share! a) (crdt-share! b) (crdt-apply! b (crdt-diff a \"\"))")
            .unwrap();
        // Delete "é c" (chars 2..5) in A; insert "ü" at the end of B.
        s.eval("(buffer-delete! 2 5)").unwrap();
        s.eval("(switch-to-buffer! b) (buffer-insert! 8 \"ü\") (switch-to-buffer! a)")
            .unwrap();
        s.eval("(define ua (crdt-sync! a)) (define ub (crdt-sync! b))")
            .unwrap();
        s.eval("(crdt-apply! a ub) (crdt-apply! b ua)").unwrap();
        assert_eq!(text(&mut s), "\"néaféü\\n\"");
        s.eval("(switch-to-buffer! b)").unwrap();
        assert_eq!(text(&mut s), "\"néaféü\\n\"");
    }

    #[test]
    fn bad_input_is_an_error() {
        let mut s = server("x\n");
        let err = s.eval("(crdt-sync! (current-buffer))").unwrap_err();
        assert!(err.contains("isn't shared"), "{err}");
        s.eval("(crdt-share! (current-buffer))").unwrap();
        let err = s
            .eval("(crdt-apply! (current-buffer) \"not base64!\")")
            .unwrap_err();
        assert!(err.contains("bad base64"), "{err}");
    }

    enum Msg {
        Keys(String),
        Eval(String, Sender<Result<String, String>>),
        Stop,
    }

    /// An editor on its own thread, handling its events between messages.
    struct Peer(Sender<Msg>, Option<std::thread::JoinHandle<()>>);

    impl Peer {
        fn start(text: &'static str) -> Peer {
            let (tx, rx) = channel();
            let handle = std::thread::spawn(move || {
                let mut s = server(text);
                loop {
                    match rx.try_recv() {
                        Ok(Msg::Keys(k)) => type_keys(&mut s, &k),
                        Ok(Msg::Eval(code, reply)) => {
                            let _ = reply.send(s.eval(&code));
                        }
                        Ok(Msg::Stop) => return,
                        Err(_) => {
                            s.pump(Duration::from_millis(5));
                        }
                    }
                }
            });
            Peer(tx, Some(handle))
        }

        fn keys(&self, keys: &str) {
            self.0.send(Msg::Keys(keys.into())).unwrap();
        }

        fn eval(&self, code: &str) -> String {
            let (tx, rx) = channel();
            self.0.send(Msg::Eval(code.into(), tx)).unwrap();
            rx.recv().unwrap().unwrap()
        }

        fn text(&self) -> String {
            self.eval("(buffer-substring 0 (buffer-length))")
        }

        /// Waits for the buffer to read `want` (as Scheme writes it).
        fn wait_for(&self, want: &str) {
            let start = Instant::now();
            loop {
                let got = self.text();
                if got == want {
                    return;
                }
                assert!(
                    start.elapsed() < Duration::from_secs(10),
                    "wanted {want}, have {got}"
                );
                std::thread::sleep(Duration::from_millis(20));
            }
        }
    }

    impl Drop for Peer {
        fn drop(&mut self) {
            let _ = self.0.send(Msg::Stop);
            if let Some(h) = self.1.take() {
                let _ = h.join();
            }
        }
    }

    #[test]
    fn editors_share_a_buffer_over_a_socket() {
        let socket = temp_path("share.sock");
        let path = socket.display().to_string();
        let host = Peer::start("one\ntwo\n");
        host.keys(&format!(":share {path}<ret>"));
        assert!(host.eval("(status-text)").contains("sharing on"));
        let guest = Peer::start("");
        let third = Peer::start("");
        guest.keys(&format!(":join {path}<ret>"));
        third.keys(&format!(":join {path}<ret>"));
        guest.wait_for("\"one\\ntwo\\n\"");
        third.wait_for("\"one\\ntwo\\n\"");
        assert!(guest.eval("(buffer-name)").contains("[shared]"));

        // The host types; both see it.
        host.keys("Ahost<esc>");
        guest.wait_for("\"onehost\\ntwo\\n\"");
        third.wait_for("\"onehost\\ntwo\\n\"");
        // A guest types; the host relays it to the other guest.
        guest.keys("jIguest <esc>");
        host.wait_for("\"onehost\\nguest two\\n\"");
        third.wait_for("\"onehost\\nguest two\\n\"");
        // Its edits are its own undo step.
        guest.keys("u");
        host.wait_for("\"onehost\\ntwo\\n\"");

        // When the host stops, guests keep their copy.
        host.keys(":unshare<ret>");
        let start = Instant::now();
        while guest.eval("(crdt-shared? (current-buffer))") != "#false" {
            assert!(
                start.elapsed() < Duration::from_secs(10),
                "guest still shared"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(guest.text(), "\"onehost\\ntwo\\n\"");
    }
}
