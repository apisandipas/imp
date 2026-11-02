#!/usr/bin/env python3
"""Docstrings for runtime/*.scm: list what lacks one, and insert them.

  tools/docstrings.py missing [FILE...]       definitions without a docstring,
                                              and options without a comment
  tools/docstrings.py convert [FILE...]       turn the ;; comment above each
                                              function into its docstring
  tools/docstrings.py insert FILE DOCS.json   add docstrings from {name: text}

A docstring goes first in the body of (define (name ...) ...) or in the
lambda of (define-command! 'name (lambda (count) ...)), continuation lines
lined up under its first character (help.scm strips that indentation).
An option, made with define-option! or another define-...-option! form,
has no body: its documentation is the ;; comment right above it, which
describe-option shows. Written for imp's runtime, not as a general
Scheme reader.
"""

import json
import re
import sys
from pathlib import Path

DELIMS = set(" \t\n()[]\";")


def scan(text):
    """Matching close for each open bracket, and the offsets in strings."""
    match, stack, in_string = {}, [], set()
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == ";":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            in_string.update(range(i + 1, j))
            i = j + 1
            continue
        if c == "#" and text[i + 1 : i + 2] == "\\":
            i += 3
            while i < n and text[i] not in DELIMS:
                i += 1
            continue
        if c in "([":
            stack.append(i)
        elif c in ")]":
            match[stack.pop()] = i
        i += 1
    return match, in_string


def skip_blank(text, i):
    while i < len(text):
        if text[i].isspace():
            i += 1
        elif text[i] == ";":
            while i < len(text) and text[i] != "\n":
                i += 1
        else:
            break
    return i


def skip_form(text, i, match):
    if text[i] in "([":
        return match[i] + 1
    if text[i] in "'`,":
        return skip_form(text, i + 1, match)
    if text[i] == '"':
        j = i + 1
        while text[j] != '"':
            j += 2 if text[j] == "\\" else 1
        return j + 1
    if text[i] == "#" and text[i + 1] == "\\":
        i += 3
    while i < len(text) and text[i] not in DELIMS:
        i += 1
    return i


def token(text, i):
    j = i
    while j < len(text) and text[j] not in DELIMS:
        j += 1
    return text[i:j]


class Definition:
    def __init__(self, name, start, head, body, form, end):
        self.name = name    # what it defines
        self.start = start  # offset of its "(" at the start of a line
        self.head = head    # offset just after its name and arguments
        self.body = body    # offset of the first form of the body
        self.form = form    # offset of the form whose body it is
        self.end = end      # offset of its closing bracket

    def docstring(self, text):
        """Whether the body already starts with a docstring."""
        if text[self.body] != '"':
            return False
        after = skip_blank(text, skip_form(text, self.body, {}))
        return text[after] not in ")]"


def definitions(text):
    """Top-level functions, and commands defined with a lambda."""
    match, _ = scan(text)
    found = []
    for m in re.finditer(r"^\((define|define-command!)[ \n]", text, re.M):
        start = m.start()
        at = skip_blank(text, skip_form(text, start + 1, match))
        if m.group(1) == "define":
            if text[at] != "(":
                continue
            name = token(text, at + 1)
            form, head = start, at
        else:
            name = token(text, at + 1)
            at = skip_blank(text, skip_form(text, at, match))
            if text[at] != "(" or token(text, skip_blank(text, at + 1)) != "lambda":
                continue
            form = at
            head = skip_blank(text, skip_form(text, skip_blank(text, at + 1), match))
        head = skip_form(text, head, match)
        body = skip_blank(text, head)
        if text[body] in ")]":
            continue  # no body to document
        found.append(Definition(name, start, head, body, form, match[start]))
    return found


def line_start(text, i):
    return text.rfind("\n", 0, i) + 1


def column(text, i):
    return i - line_start(text, i)


def literal(doc, indent):
    """`doc` as a string literal, continuation lines `indent` deep."""
    escaped = doc.replace("\\", "\\\\").replace('"', '\\"')
    lines = escaped.split("\n")
    return '"' + "\n".join(
        [lines[0]] + [(" " * indent + l) if l.strip() else "" for l in lines[1:]]
    ) + '"'


def insert(text, docs):
    """`text` with docstrings for the definitions named in `docs`."""
    defs = [d for d in definitions(text) if d.name in docs and not d.docstring(text)]
    _, in_string = scan(text)
    for d in sorted(defs, key=lambda d: d.start, reverse=True):
        doc = docs[d.name].strip("\n")
        body_line = line_start(text, d.body)
        inline = text[body_line : d.body].strip() != ""
        if inline:
            # The body starts on the head's line: it moves to a line of its
            # own, and the lines after it move with it.
            # A lambda on the definition's line moves to a line of its own.
            moved = d.form != d.start and line_start(text, d.form) == d.start
            indent = 4 if moved else column(text, d.form) + 2
            delta = indent - column(text, d.body)
            rest_start = text.find("\n", d.body)
            if rest_start == -1 or rest_start > d.end:
                rest_start = d.end
            rest = text[rest_start : d.end]
            shifted = []
            offset = rest_start
            for part in rest.split("\n"):
                start_of_line = offset
                offset += len(part) + 1
                if start_of_line == rest_start or start_of_line in in_string or not part.strip():
                    shifted.append(part)
                    continue
                current = len(part) - len(part.lstrip(" "))
                shifted.append(" " * max(0, current + delta) + part.lstrip(" "))
            head = text[: d.body].rstrip(" ")
            if moved:
                head = text[: d.form].rstrip(" ") + "\n  " + text[d.form : d.body].rstrip(" ")
            text = (
                head
                + "\n" + " " * indent + literal(doc, indent + 1)
                + "\n" + " " * indent + text[d.body : rest_start]
                + "\n".join(shifted)
                + text[d.end :]
            )
        else:
            # First in the body: above any comment that opens it.
            at = text.find("\n", d.head) + 1
            indent = column(text, d.body)
            text = text[:at] + " " * indent + literal(doc, indent + 1) + "\n" + text[at:]
    return text


def comment_docs(text):
    """The ;; comment block right above each definition, and where it is."""
    lines = text.split("\n")
    starts = {}
    offset = 0
    for i, l in enumerate(lines):
        starts[offset] = i
        offset += len(l) + 1
    found = {}
    for d in definitions(text):
        n = starts[d.start]
        first = n
        while first > 0 and lines[first - 1].startswith(";;") and not lines[first - 1].startswith(";;;"):
            first -= 1
        if first == n:
            continue
        body = []
        for l in lines[first:n]:
            l = l[2:]
            body.append(l[1:] if l.startswith(" ") else l)
        found[d.name] = ("\n".join(body).rstrip(), first, n)
    return found


def convert(text):
    found = comment_docs(text)
    docs = {name: doc for name, (doc, _, _) in found.items() if doc.strip()}
    text = insert(text, docs)
    # Then drop the comments, now docstrings. Insertion only adds lines
    # below each comment, so find them again.
    lines = text.split("\n")
    drop = set()
    for name, (doc, first, n) in comment_docs(text).items():
        if name in docs:
            drop.update(range(first, n))
    return "\n".join(l for i, l in enumerate(lines) if i not in drop)


OPTION = re.compile(r"^\(define-[a-z-]*option! '([^\s()]+)", re.M)


def undocumented_options(text):
    """(line, name) of each option with no ; comment on the line above."""
    lines = text.split("\n")
    found = []
    for m in OPTION.finditer(text):
        n = text.count("\n", 0, m.start())
        if n == 0 or not lines[n - 1].startswith(";"):
            found.append((n + 1, m.group(1)))
    return found


def files(args):
    return [Path(a) for a in args] or sorted(
        list(Path("runtime").glob("*.scm")) + list(Path("packages").glob("*/*.scm"))
    )


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "missing":
        for f in files(args):
            text = f.read_text()
            for d in definitions(text):
                if not d.docstring(text):
                    print(f"{f}:{text.count(chr(10), 0, d.start) + 1}: {d.name}")
            for line, name in undocumented_options(text):
                print(f"{f}:{line}: option {name}")
    elif cmd == "convert":
        for f in files(args):
            f.write_text(convert(f.read_text()))
    elif cmd == "insert":
        f = Path(args[0])
        f.write_text(insert(f.read_text(), json.loads(Path(args[1]).read_text())))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
