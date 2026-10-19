#!/usr/bin/env python3
"""A scripted language server for tests/lsp.rs.

It understands just enough LSP to exercise the client: it keeps each
document's text, reports every occurrence of the word "bad" as an error,
and answers hover, definition (the first occurrence of the word),
references (every occurrence), rename (every occurrence), formatting
(strips trailing spaces), code actions ("bad" -> "good", and a command
that makes the server send workspace/applyEdit) and completion.

With $FAKE_LSP_PULL set it doesn't push diagnostics but answers
textDocument/diagnostic, as TypeScript 7's server does; after a save it
also reports "meh" and asks the client to pull again.

Positions are UTF-32 when the client offers it (Python indexes code
points), as imp does. Every message received is appended to the file named
by $FAKE_LSP_LOG, if set, one JSON object per line.
"""

import json
import os
import re
import sys

docs = {}
log_path = os.environ.get("FAKE_LSP_LOG")
pull = bool(os.environ.get("FAKE_LSP_PULL"))
flagged = ["bad"]


def read_message():
    length = None
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        line = line.decode().strip()
        if not line:
            break
        name, _, value = line.partition(":")
        if name.lower() == "content-length":
            length = int(value)
    body = sys.stdin.buffer.read(length)
    return json.loads(body)


def send(msg):
    msg["jsonrpc"] = "2.0"
    body = json.dumps(msg).encode()
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    sys.stdout.buffer.flush()


def words(text, word=None):
    """(line, start, end, word) for each word, or each occurrence of `word`."""
    out = []
    for n, line in enumerate(text.split("\n")):
        for m in re.finditer(r"\w+", line):
            if word is None or m.group() == word:
                out.append((n, m.start(), m.end(), m.group()))
    return out


def rng(line, start, end):
    return {"start": {"line": line, "character": start}, "end": {"line": line, "character": end}}


def word_at(uri, pos):
    for line, start, end, word in words(docs[uri]):
        if line == pos["line"] and start <= pos["character"] <= end:
            return word
    return None


def diagnostics(uri):
    return [
        {"range": rng(l, s, e), "severity": 1, "source": "fake", "message": "%s word" % w}
        for w in flagged for l, s, e, _ in words(docs[uri], w)
    ]


def publish(uri):
    if not pull:
        send({"method": "textDocument/publishDiagnostics",
              "params": {"uri": uri, "diagnostics": diagnostics(uri)}})


def handle(msg):
    method = msg.get("method")
    params = msg.get("params") or {}
    mid = msg.get("id")
    reply = lambda result: send({"id": mid, "result": result})

    if method == "initialize":
        offered = params["capabilities"].get("general", {}).get("positionEncodings", [])
        reply({"capabilities": {
            "positionEncoding": "utf-32" if "utf-32" in offered else "utf-16",
            "textDocumentSync": 1,
            "hoverProvider": True,
            "definitionProvider": True,
            "referencesProvider": True,
            "renameProvider": True,
            "documentFormattingProvider": True,
            "codeActionProvider": True,
            "completionProvider": {"triggerCharacters": ["."]},
            "executeCommandProvider": {"commands": ["fake.insertHi"]},
            **({"diagnosticProvider": {"interFileDependencies": False,
                                       "workspaceDiagnostics": False}} if pull else {}),
        }})
    elif method == "textDocument/didOpen":
        doc = params["textDocument"]
        docs[doc["uri"]] = doc["text"]
        publish(doc["uri"])
    elif method == "textDocument/didChange":
        uri = params["textDocument"]["uri"]
        docs[uri] = params["contentChanges"][-1]["text"]
        publish(uri)
    elif method == "textDocument/diagnostic":
        reply({"kind": "full", "items": diagnostics(params["textDocument"]["uri"])})
    elif method == "textDocument/didSave" and pull:
        flagged.append("meh")
        send({"id": 2000, "method": "workspace/diagnostic/refresh"})
    elif method == "textDocument/hover":
        word = word_at(params["textDocument"]["uri"], params["position"])
        reply({"contents": {"kind": "markdown",
                            "value": "```rust\nfn %s()\n```\nThe %s function." % (word, word)}}
              if word else None)
    elif method == "textDocument/definition":
        uri = params["textDocument"]["uri"]
        word = word_at(uri, params["position"])
        hits = words(docs[uri], word) if word else []
        reply({"uri": uri, "range": rng(*hits[0][:3])} if hits else None)
    elif method == "textDocument/references":
        uri = params["textDocument"]["uri"]
        word = word_at(uri, params["position"])
        reply([{"uri": uri, "range": rng(l, s, e)} for l, s, e, _ in words(docs[uri], word)])
    elif method == "textDocument/rename":
        uri = params["textDocument"]["uri"]
        word = word_at(uri, params["position"])
        edits = [{"range": rng(l, s, e), "newText": params["newName"]}
                 for l, s, e, _ in words(docs[uri], word)]
        reply({"changes": {uri: edits}})
    elif method == "textDocument/formatting":
        uri = params["textDocument"]["uri"]
        lines = docs[uri].split("\n")
        edits = [{"range": rng(n, len(line.rstrip()), len(line)), "newText": ""}
                 for n, line in enumerate(lines) if line != line.rstrip()]
        reply(edits)
    elif method == "textDocument/codeAction":
        uri = params["textDocument"]["uri"]
        actions = [{"title": "Insert hi", "command": "fake.insertHi", "arguments": [uri]}]
        line = params["range"]["start"]["line"]
        for l, s, e, _ in words(docs[uri], "bad"):
            if l == line:
                actions.insert(0, {"title": "Replace bad with good", "kind": "quickfix",
                                   "edit": {"changes": {uri: [{"range": rng(l, s, e),
                                                               "newText": "good"}]}}})
                break
        reply(actions)
    elif method == "workspace/executeCommand":
        uri = params["arguments"][0]
        send({"id": 1000, "method": "workspace/applyEdit",
              "params": {"edit": {"changes": {uri: [{"range": rng(0, 0, 0), "newText": "hi\n"}]}}}})
        reply(None)
    elif method == "textDocument/completion":
        reply({"isIncomplete": False, "items": [
            {"label": "alpha", "detail": "fn alpha()"},
            {"label": "alphabet", "kind": 6},
            {"label": "beta"},
            {"label": "snip", "insertTextFormat": 2, "insertText": "snip(${1:x}, $2)$0"},
        ]})
    elif method == "shutdown":
        reply(None)
    elif method == "exit":
        sys.exit(0)
    elif mid is not None and method is not None:
        send({"id": mid, "error": {"code": -32601, "message": "unhandled " + method}})


while True:
    msg = read_message()
    if msg is None:
        break
    if log_path:
        with open(log_path, "a") as f:
            f.write(json.dumps(msg) + "\n")
    handle(msg)
