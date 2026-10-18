//! MCP (runtime/mcp.scm): an agent's JSON-RPC over the editor's socket.

mod common;

use common::*;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

struct Agent {
    stream: UnixStream,
    reader: BufReader<UnixStream>,
    next_id: u64,
}

impl Agent {
    fn connect(s: &mut imp_server::Server, socket: &std::path::Path) -> Agent {
        let stream = UnixStream::connect(socket).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_millis(20)))
            .unwrap();
        let reader = BufReader::new(stream.try_clone().unwrap());
        s.pump(Duration::from_millis(50));
        Agent {
            stream,
            reader,
            next_id: 1,
        }
    }

    /// Sends a request and pumps the editor until the reply comes.
    fn request(&mut self, s: &mut imp_server::Server, method: &str, params: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        let msg = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        writeln!(self.stream, "{msg}").unwrap();
        let mut line = String::new();
        for _ in 0..200 {
            s.pump(Duration::from_millis(5));
            if self.reader.read_line(&mut line).is_ok() && line.ends_with('\n') {
                let reply: Value = serde_json::from_str(&line).unwrap();
                assert_eq!(reply["id"], json!(id), "{reply}");
                return reply;
            }
        }
        panic!("no reply to {method}; status: {}", s.status());
    }

    /// Calls a tool; (its text, whether it is an error).
    fn call(&mut self, s: &mut imp_server::Server, tool: &str, args: Value) -> (String, bool) {
        let reply = self.request(s, "tools/call", json!({"name": tool, "arguments": args}));
        let result = &reply["result"];
        (
            result["content"][0]["text"]
                .as_str()
                .unwrap_or("")
                .to_string(),
            result["isError"].as_bool().unwrap_or(false),
        )
    }
}

/// An editor with MCP on, on a socket of the test's own, and an agent
/// that has initialized.
fn session(name: &str, text: &str) -> (imp_server::Server, Agent) {
    let socket = temp_path(&format!("{name}.sock"));
    let mut s = server(text);
    s.eval(&format!("(mcp-enable! {:?})", socket.display().to_string()))
        .unwrap();
    let mut agent = Agent::connect(&mut s, &socket);
    let reply = agent.request(
        &mut s,
        "initialize",
        json!({"protocolVersion": "2025-06-18", "capabilities": {},
               "clientInfo": {"name": "test", "version": "1"}}),
    );
    assert_eq!(reply["result"]["protocolVersion"], "2025-06-18");
    assert_eq!(reply["result"]["serverInfo"]["name"], "imp");
    writeln!(
        agent.stream,
        "{}",
        json!({"jsonrpc": "2.0", "method": "notifications/initialized"})
    )
    .unwrap();
    (s, agent)
}

#[test]
fn off_unless_enabled() {
    let mut s = server("");
    assert_eq!(s.eval("*mcp-listener*").unwrap(), "#false");
}

#[test]
fn lists_tools_and_reads_buffers() {
    let (mut s, mut agent) = session("read", "one\ntwo\nthree\n");
    let tools = agent.request(&mut s, "tools/list", json!({}));
    let names: Vec<&str> = tools["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    for want in [
        "list_buffers",
        "read_buffer",
        "edit_buffer",
        "open_file",
        "save_buffer",
        "get_cursor",
        "set_cursor",
        "search",
        "run_command",
        "ex_command",
        "diagnostics",
        "eval_scheme",
    ] {
        assert!(names.contains(&want), "{want} missing from {names:?}");
    }
    assert!(tools["result"]["tools"][1]["inputSchema"]["properties"]["start_line"].is_object());

    let (text, error) = agent.call(&mut s, "read_buffer", json!({}));
    assert!(!error);
    assert!(
        text.ends_with("     1\tone\n     2\ttwo\n     3\tthree"),
        "{text}"
    );
    let (text, _) = agent.call(
        &mut s,
        "read_buffer",
        json!({"start_line": 2, "end_line": 2}),
    );
    assert!(text.ends_with("     2\ttwo"), "{text}");
    let (text, _) = agent.call(&mut s, "list_buffers", json!({}));
    assert!(text.contains("current"), "{text}");
    let (text, error) = agent.call(&mut s, "read_buffer", json!({"buffer": "nope"}));
    assert!(error);
    assert!(text.contains("no buffer nope"), "{text}");
}

#[test]
fn edits_are_undoable_changes() {
    let (mut s, mut agent) = session("edit", "alpha\nbeta\ngamma\n");
    let (text, error) = agent.call(
        &mut s,
        "edit_buffer",
        json!({"old_text": "beta", "new_text": "BETA"}),
    );
    assert!(!error, "{text}");
    assert_eq!(s.text(), "alpha\nBETA\ngamma\n");
    assert!(s.status().starts_with("agent: edited"));
    // Whole lines, and inserting before a line.
    agent.call(
        &mut s,
        "edit_buffer",
        json!({"start_line": 3, "end_line": 3, "text": "delta\nepsilon"}),
    );
    assert_eq!(s.text(), "alpha\nBETA\ndelta\nepsilon\n");
    agent.call(
        &mut s,
        "edit_buffer",
        json!({"start_line": 1, "end_line": 0, "text": "first"}),
    );
    assert_eq!(s.text(), "first\nalpha\nBETA\ndelta\nepsilon\n");
    // Ambiguous text is refused.
    let (text, error) = agent.call(
        &mut s,
        "edit_buffer",
        json!({"old_text": "a", "new_text": "b"}),
    );
    assert!(error);
    assert!(text.contains("occurs"), "{text}");
    // The user undoes one edit at a time.
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "alpha\nBETA\ndelta\nepsilon\n");
    type_keys(&mut s, "u");
    assert_eq!(s.text(), "alpha\nBETA\ngamma\n");
}

#[test]
fn files_cursor_search_and_commands() {
    let (mut s, mut agent) = session("files", "");
    let path = temp_path("mcp-file.txt");
    std::fs::write(&path, "hello there\nhello again\nbye\n").unwrap();
    let (text, error) = agent.call(
        &mut s,
        "open_file",
        json!({"path": path.display().to_string()}),
    );
    assert!(!error, "{text}");
    assert!(text.contains("mcp-file.txt"), "{text}");

    let (text, _) = agent.call(&mut s, "search", json!({"pattern": "hel\\+o"}));
    assert_eq!(text, "1: hello there\n2: hello again");

    agent.call(&mut s, "set_cursor", json!({"line": 2, "column": 7}));
    let (text, _) = agent.call(&mut s, "get_cursor", json!({}));
    assert!(text.contains("line 2, column 7"), "{text}");
    assert!(text.contains("mode normal"), "{text}");

    agent.call(&mut s, "ex_command", json!({"command": ":%s/hello/hi/"}));
    agent.call(&mut s, "save_buffer", json!({}));
    assert_eq!(
        std::fs::read_to_string(&path).unwrap(),
        "hi there\nhi again\nbye\n"
    );
    let (text, _) = agent.call(&mut s, "ex_command", json!({"command": "ls"}));
    assert!(text.contains("mcp-file.txt"), "{text}");

    let (text, error) = agent.call(&mut s, "run_command", json!({"name": "no-such"}));
    assert!(error, "{text}");
    let (text, _) = agent.call(&mut s, "run_command", json!({}));
    assert!(text.contains("find-file"), "{text}");

    let (text, error) = agent.call(&mut s, "eval_scheme", json!({"code": "(+ 1 2)"}));
    assert!(!error);
    assert_eq!(text, "3");
    let (_, error) = agent.call(&mut s, "eval_scheme", json!({"code": "(car '())"}));
    assert!(error);
}

#[test]
fn bad_requests_get_errors() {
    let (mut s, mut agent) = session("errors", "");
    let reply = agent.request(&mut s, "no/such", json!({}));
    assert_eq!(reply["error"]["code"], -32601);
    let reply = agent.request(&mut s, "tools/call", json!({"name": "nope"}));
    assert_eq!(reply["error"]["code"], -32602);
    let reply = agent.request(&mut s, "ping", json!({}));
    assert_eq!(reply["result"], json!({}));
}
