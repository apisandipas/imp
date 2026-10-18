"""Drive the imp binary through a pty and save the screen as a PNG.

usage: shot.py BINARY OUT.png COLSxROWS ARGS KEYS...
  ARGS and KEYS as in drive.py (ARGS joined with "|", "" for none; each
  KEYS argument is written raw, then output settles). Colors are drawn as
  the terminal would, on a One Dark-like default background, with the
  cursor outlined. Set FONT_DIR to a directory with JetBrainsMono-Regular,
  -Bold and -Italic .ttf files. Needs pyte and pillow:
  nix-shell -p 'python3.withPackages(p:[p.pyte p.pillow])' --run "python3 -I tools/shot.py ..."
HOME is a temp dir, so no user config loads (set SHOT_INIT to a file to
use it as init.scm).
"""
import os, pty, sys, time, fcntl, termios, struct, select, tempfile, shutil
import pyte
from PIL import Image, ImageDraw, ImageFont

binary, out, size, args, *chunks = sys.argv[1:]
cols, rows = (int(n) for n in size.split("x"))
home = tempfile.mkdtemp()
if os.environ.get("SHOT_INIT"):
    os.makedirs(os.path.join(home, "imp"))
    shutil.copy(os.environ["SHOT_INIT"], os.path.join(home, "imp", "init.scm"))
pid, fd = pty.fork()
if pid == 0:
    env = dict(os.environ, HOME=home, XDG_CONFIG_HOME=home, TERM="xterm-256color", COLORTERM="truecolor")
    env.pop("IMP_RUNTIME", None)
    os.execve(binary, [binary] + [a for a in args.split("|") if a], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
screen = pyte.Screen(cols, rows)
stream = pyte.ByteStream(screen)

def pump(t=0.5):
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                stream.feed(os.read(fd, 65536))
            except OSError:
                return

pump(1.2)
for c in chunks:
    os.write(fd, c.encode().decode("unicode_escape").encode())
    pump()

FG, BG = (171, 178, 191), (40, 44, 52)
ANSI = {"black": (40, 44, 52), "red": (224, 108, 117), "green": (152, 195, 121), "brown": (229, 192, 123),
        "yellow": (229, 192, 123), "blue": (97, 175, 239), "magenta": (198, 120, 221), "cyan": (86, 182, 194),
        "white": (171, 178, 191), "brightblack": (92, 99, 112), "brightred": (224, 108, 117),
        "brightgreen": (152, 195, 121), "brightyellow": (229, 192, 123), "brightblue": (97, 175, 239),
        "brightmagenta": (198, 120, 221), "brightcyan": (86, 182, 194), "brightwhite": (220, 223, 228)}

def color(name, default):
    if name == "default":
        return default
    if name in ANSI:
        return ANSI[name]
    try:
        return tuple(int(name[i:i + 2], 16) for i in (0, 2, 4))
    except ValueError:
        return default

font_dir = os.environ["FONT_DIR"]
fonts = {k: ImageFont.truetype(os.path.join(font_dir, f"JetBrainsMono-{k}.ttf"), 15) for k in ("Regular", "Bold", "Italic")}
cw, ch = 9, 19
img = Image.new("RGB", (cols * cw, rows * ch), BG)
draw = ImageDraw.Draw(img)
for y in range(rows):
    for x in range(cols):
        c = screen.buffer[y][x]
        fg, bg = color(c.fg, FG), color(c.bg, BG)
        if c.reverse:
            fg, bg = bg, fg
        draw.rectangle([x * cw, y * ch, (x + 1) * cw - 1, (y + 1) * ch - 1], fill=bg)
        if c.data.strip():
            font = fonts["Bold" if c.bold else "Italic" if c.italics else "Regular"]
            draw.text((x * cw, y * ch + 1), c.data, font=font, fill=fg)
        if c.underscore:
            draw.line([x * cw, (y + 1) * ch - 2, (x + 1) * cw - 1, (y + 1) * ch - 2], fill=fg)
cx, cy = screen.cursor.x, screen.cursor.y
draw.rectangle([cx * cw, cy * ch, (cx + 1) * cw - 1, (cy + 1) * ch - 1], outline=(255, 255, 255))
img.save(out)
os.write(fd, b"\x1b:qa!\r")
pump(0.2)
