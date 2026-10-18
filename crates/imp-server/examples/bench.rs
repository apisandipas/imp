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

    // The same with Rust syntax highlighting on a 100k-line Rust file.
    let code: String = (0..25_000)
        .map(|i| format!("fn f{i}(x: u32) -> u32 {{\n    let y = x + {i}; // add\n    y * 2\n}}\n"))
        .collect();
    let mut s = Server::new(Buffer::from_text(&code), Options { user_config: None }).unwrap();
    s.handle(ClientMsg::Resize {
        width: 120,
        height: 40,
    });
    s.eval("(set-buffer-language! \"rust\")").unwrap();
    // A frame never waits long for the parser: a parse over budget moves
    // to a background thread, and frames use the last tree meanwhile.
    let t = Instant::now();
    s.frame();
    println!(
        "{:>16}: {:>8.2} ms (the parse continues in the background)",
        "first frame",
        t.elapsed().as_secs_f64() * 1000.0
    );
    let t = Instant::now();
    s.pump(std::time::Duration::from_millis(500));
    println!(
        "{:>16}: {:>8.2} ms until the tree arrived",
        "background",
        (t.elapsed().as_secs_f64() - 0.5) * 1000.0
    );
    let cases: &[(&str, &[&str])] = &[
        ("j", &["j"]),
        ("x", &["x"]),
        ("ihello<esc>", &["i", "h", "e", "l", "l", "o", "<esc>"]),
        ("G", &["G"]),
        ("u", &["u"]),
        ("dd", &["d", "d"]),
        ("daf", &["d", "a", "f"]),
    ];
    for (name, keys) in cases {
        let t = Instant::now();
        let n = 20;
        for _ in 0..n {
            s.keys(keys);
            s.frame();
            // Take any finished background parse, as the loop would.
            s.pump(std::time::Duration::ZERO);
        }
        println!(
            "{:>16}: {:>8.2} ms per command (rust, highlighted)",
            name,
            t.elapsed().as_secs_f64() * 1000.0 / n as f64
        );
        s.pump(std::time::Duration::from_millis(300));
    }
}
