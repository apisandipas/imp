"""Drive the imp binary through a pty and print the screen it draws.

usage: drive.py BINARY ARGS KEYS...
  ARGS is imp's arguments joined with "|" (e.g. "file.txt" or
  "--connect|--socket|/tmp/s.sock"). Each KEYS argument is written raw
  (escapes like \x1b and \r work), then output is allowed to settle.
Prints the final screen; cells with a non-default background are marked
'#' on the line below. Needs pyte:
  nix-shell -p 'python3.withPackages(p:[p.pyte])' --run "python3 -I tools/drive.py ..."
HOME is a temp dir, so no user config loads.
"""
import os, pty, sys, time, fcntl, termios, struct, select, tempfile
import pyte

binary, path, *chunks = sys.argv[1:]
cols, rows = 60, 12
home = tempfile.mkdtemp()
pid, fd = pty.fork()
if pid == 0:
    env = dict(os.environ, HOME=home, XDG_CONFIG_HOME=home, TERM="xterm-256color")
    env.pop("IMP_RUNTIME", None)
    os.execve(binary, [binary] + path.split("|"), env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
screen = pyte.Screen(cols, rows)
stream = pyte.ByteStream(screen)

def pump(t=0.4):
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                stream.feed(os.read(fd, 65536))
            except OSError:
                return

pump(1.0)
for c in chunks:
    os.write(fd, c.encode().decode("unicode_escape").encode())
    pump()
for y in range(rows):
    line = "".join(screen.buffer[y][x].data for x in range(cols)).rstrip()
    marks = "".join("#" if screen.buffer[y][x].bg != "default" or screen.buffer[y][x].reverse else " " for x in range(cols)).rstrip()
    print(f"{line}\n{marks}" if marks else line)
print("cursor", screen.cursor.x, screen.cursor.y)
try:
    os.kill(pid, 9)
except ProcessLookupError:
    pass
