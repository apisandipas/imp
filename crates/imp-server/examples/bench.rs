//! Times common commands on a 100,000-line buffer, including drawing a
//! frame after each. Run it before moving behavior from Scheme to Rust:
//!
//!     cargo run --release -p imp-server --example bench
use imp_core::{Buffer, ClientMsg};
use imp_server::{Options, Server};
use std::time::Instant;
fn main() {
    let text: String = (0..100_000)
        .map(|i| format!("line {i} with some words (and parens) here\n"))
        .collect();
    let mut s = Server::new(Buffer::from_text(&text), Options { user_config: None }).unwrap();
    s.handle(ClientMsg::Resize {
        width: 120,
        height: 40,
    });
    let cases: &[(&str, &[&str])] = &[
        ("j", &["j"]),
        ("w", &["w"]),
        ("x", &["x"]),
        ("dd", &["d", "d"]),
        ("ihello<esc>", &["i", "h", "e", "l", "l", "o", "<esc>"]),
        ("G", &["G"]),
        ("gg", &["g", "g"]),
        ("u", &["u"]),
        ("/words<ret>", &["/", "w", "o", "r", "d", "s", "<ret>"]),
        ("n", &["n"]),
        ("50%", &["5", "0", "%"]),
        ("ci(", &["c", "i", "(", "<esc>"]),
        ("dit (no tags)", &["d", "i", "t"]),
        ("}", &["}"]),
        ("vjjd", &["v", "j", "j", "d"]),
    ];
    for (name, keys) in cases {
        let t = Instant::now();
        let n = 20;
        for _ in 0..n {
            s.keys(keys);
            s.frame();
        }
        println!(
            "{name:>16}: {:>8.2} ms per command (incl. frame)",
            t.elapsed().as_secs_f64() * 1000.0 / n as f64
        );
    }
    println!("status: {}", s.status());
}
