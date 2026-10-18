"""Report unbalanced brackets in a Scheme file, aware of strings, #\\x chars and ; comments."""
import sys
src = open(sys.argv[1]).read()
stack = []; i = 0; line = 1; top_start = None
pairs = {')': '(', ']': '['}
while i < len(src):
    c = src[i]
    if c == '\n': line += 1
    if c == ';':
        while i < len(src) and src[i] != '\n': i += 1
        continue
    if c == '"':
        i += 1
        while src[i] != '"':
            if src[i] == '\\': i += 1
            if src[i] == '\n': line += 1
            i += 1
        i += 1; continue
    if src.startswith('#\\', i):
        j = i + 3
        while j < len(src) and src[j].isalpha() and src[i+2].isalpha(): j += 1
        i = j; continue
    if c in '([':
        if not stack: top_start = line
        stack.append((c, line))
    elif c in ')]':
        if not stack:
            print(f"line {line}: unexpected {c}"); sys.exit(1)
        o, l = stack.pop()
        if o != pairs[c]:
            print(f"line {line}: {c} closes {o} from line {l}"); sys.exit(1)
    i += 1
if stack: print("unclosed:", stack[-3:])
else: print("balanced")
