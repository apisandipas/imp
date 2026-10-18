#!/usr/bin/env python3
"""A scripted debug adapter for tests/dap.rs.

It "runs" the program named in launch's `source`: execution starts at
line 1 and stops at each breakpoint in turn (lines are 1-based, as the
client asks). `next` and `stepIn` go one line on, `stepOut` returns to the
caller frame's line. Past the last breakpoint, continue ends the program.
Every request is appended to $FAKE_DAP_LOG, if set, one JSON object a line.
"""

import json
import os
import sys

log_path = os.environ.get("FAKE_DAP_LOG")
seq = 0
source = None      # the file being "debugged"
breakpoints = []   # lines in it
line = 0           # where it is stopped, 0 before it starts


def read_message():
    length = None
    while True:
        header = sys.stdin.buffer.readline()
        if not header:
            return None
        header = header.decode().strip()
        if not header:
            break
        name, _, value = header.partition(":")
        if name.lower() == "content-length":
            length = int(value)
    return json.loads(sys.stdin.buffer.read(length))


def send(msg):
    global seq
    seq += 1
    msg["seq"] = seq
    body = json.dumps(msg).encode()
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    sys.stdout.buffer.flush()


def event(name, body=None):
    send({"type": "event", "event": name, "body": body or {}})


def stop_at(new_line, reason):
    global line
    line = new_line
    event("stopped", {"reason": reason, "threadId": 1, "allThreadsStopped": True})


def run_on():
    """Continue to the next breakpoint after the current line, or exit."""
    later = [b for b in sorted(breakpoints) if b > line]
    if later:
        stop_at(later[0], "breakpoint")
    else:
        event("output", {"category": "stdout", "output": "program done\n"})
        event("exited", {"exitCode": 0})
        event("terminated")


def handle(msg):
    global source, breakpoints
    command = msg.get("command")
    args = msg.get("arguments") or {}

    def respond(body=None, success=True, message=None):
        reply = {"type": "response", "request_seq": msg["seq"], "command": command,
                 "success": success, "body": body or {}}
        if message:
            reply["message"] = message
        send(reply)

    if command == "initialize":
        respond({"supportsConfigurationDoneRequest": True, "supportsEvaluateForHovers": True})
        event("initialized")
    elif command == "launch":
        source = args["source"]
        respond()
    elif command == "setBreakpoints":
        breakpoints = [b["line"] for b in args.get("breakpoints", [])]
        respond({"breakpoints": [{"verified": True, "line": b} for b in breakpoints]})
    elif command == "setExceptionBreakpoints":
        respond()
    elif command == "configurationDone":
        respond()
        run_on()
    elif command == "threads":
        respond({"threads": [{"id": 1, "name": "main"}]})
    elif command == "stackTrace":
        respond({"stackFrames": [
            {"id": 1, "name": "inner", "source": {"path": source}, "line": line, "column": 1},
            {"id": 2, "name": "main", "source": {"path": source}, "line": 1, "column": 1},
        ], "totalFrames": 2})
    elif command == "scopes":
        respond({"scopes": [{"name": "Locals", "variablesReference": 10, "expensive": False}]})
    elif command == "variables":
        if args["variablesReference"] == 10:
            respond({"variables": [
                {"name": "x", "value": str(line * 10), "variablesReference": 0},
                {"name": "items", "value": "list(2)", "variablesReference": 11},
            ]})
        else:
            respond({"variables": [{"name": "[0]", "value": "'a'", "variablesReference": 0}]})
    elif command == "evaluate":
        respond({"result": "value of " + args["expression"], "variablesReference": 0})
    elif command == "continue":
        respond({"allThreadsContinued": True})
        run_on()
    elif command in ("next", "stepIn"):
        respond()
        stop_at(line + 1, "step")
    elif command == "stepOut":
        respond()
        stop_at(1, "step")
    elif command == "disconnect":
        respond()
        event("terminated")
        sys.exit(0)
    else:
        respond(success=False, message="unsupported: " + str(command))


while True:
    msg = read_message()
    if msg is None:
        break
    if log_path:
        with open(log_path, "a") as f:
            f.write(json.dumps(msg) + "\n")
    handle(msg)
