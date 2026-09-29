#!/usr/bin/env python3
"""Records docs/demo.gif, the README animation of mmm's live screen.

Maintainer tool. A short synthetic call (macOS `say` voices: one person in the room, two on the
call, with speaker echo) is played through `mmm record` in a pseudo-terminal, exactly as a live
recording would be, and every frame the app drew is rendered into a GIF. The audio lives in a
temporary directory and is deleted afterwards.

Needs Pillow:
    python3 -m venv /tmp/demo-venv && /tmp/demo-venv/bin/pip install pillow
    /tmp/demo-venv/bin/python scripts/record_demo.py
"""

import re
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
from e2e_check import synthesize_call  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "docs" / "demo.gif"
COLUMNS, ROWS = 120, 42  # the size the Desktop shortcut opens Terminal at
CELL_W, CELL_H, TITLE_H = 9, 19, 30
FRAME_STEP = 8  # the screen draws every ~50 ms; keep every eighth frame...
FRAME_MS = 100  # ...and play them back about four times faster than real time
FINAL_HOLD_MS = 4000

FONT = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 15, index=0)
BOLD = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 15, index=1)
BACKGROUND, FOREGROUND = (13, 17, 23), (201, 209, 217)
ANSI = {1: (255, 123, 114), 2: (126, 231, 135), 3: (227, 179, 65)}  # red, green, yellow


def xterm_256(index):
    if index < 16:
        return ANSI.get(index % 8, FOREGROUND)
    if index < 232:
        index -= 16
        levels = [0, 95, 135, 175, 215, 255]
        return levels[index // 36], levels[index // 6 % 6], levels[index % 6]
    gray = 8 + (index - 232) * 10
    return gray, gray, gray


class Emulator:
    """Just enough of a terminal to replay what mmm draws: cursor moves, colors (truecolor and
    256), erases, and synchronized updates, which mark where each frame ends."""

    def __init__(self):
        self.blank = (" ", FOREGROUND, BACKGROUND, False)
        self.grid = [[self.blank] * COLUMNS for _ in range(ROWS)]
        self.x = self.y = 0
        self.fg, self.bg, self.bold = FOREGROUND, BACKGROUND, False
        self.frames = []

    def sgr(self, codes):
        index = 0
        while index < len(codes):
            code = codes[index]
            if code == 0:
                self.fg, self.bg, self.bold = FOREGROUND, BACKGROUND, False
            elif code == 1:
                self.bold = True
            elif code == 22:
                self.bold = False
            elif 30 <= code <= 37:
                self.fg = ANSI.get(code - 30, FOREGROUND)
            elif code == 39:
                self.fg = FOREGROUND
            elif code == 49:
                self.bg = BACKGROUND
            elif code in (38, 48) and index + 1 < len(codes):
                if codes[index + 1] == 2 and index + 4 < len(codes):
                    color = tuple(codes[index + 2:index + 5])
                    index += 4
                elif codes[index + 1] == 5 and index + 2 < len(codes):
                    color = xterm_256(codes[index + 2])
                    index += 2
                else:
                    color = FOREGROUND
                if code == 38:
                    self.fg = color
                else:
                    self.bg = color
            index += 1

    def feed(self, text):
        position = 0
        while position < len(text):
            char = text[position]
            if char == "\x1b":
                osc = re.match(r"\x1b\][^\x07]*\x07", text[position:])
                if osc:
                    position += len(osc.group(0))
                    continue
                match = re.match(r"\x1b\[([0-9;?<]*)([A-Za-z])", text[position:])
                if not match:
                    position += 1
                    continue
                params, command = match.groups()
                position += len(match.group(0))
                if params.startswith("?"):
                    if params == "?2026" and command == "l":
                        self.frames.append([row[:] for row in self.grid])
                    continue
                numbers = [int(n) for n in params.split(";") if n.isdigit()]
                if command == "m":
                    self.sgr(numbers or [0])
                elif command == "H":
                    self.y = (numbers[0] - 1) if numbers else 0
                    self.x = (numbers[1] - 1) if len(numbers) > 1 else 0
                elif command == "J" and numbers[:1] == [2]:
                    self.grid = [[(" ", self.fg, self.bg, False)] * COLUMNS for _ in range(ROWS)]
                elif command == "K" and self.y < ROWS:
                    for column in range(self.x, COLUMNS):
                        self.grid[self.y][column] = (" ", self.fg, self.bg, False)
                continue
            if char == "\r":
                self.x = 0
            elif char == "\n":
                self.x, self.y = 0, min(ROWS - 1, self.y + 1)
            elif 0 <= self.y < ROWS and 0 <= self.x < COLUMNS:
                self.grid[self.y][self.x] = (char, self.fg, self.bg, self.bold)
                self.x = min(COLUMNS - 1, self.x + 1) if self.x < COLUMNS - 1 else COLUMNS
            position += 1


# Characters a terminal draws as shapes rather than font glyphs, as fractions of the cell.
BLOCKS = {"█": (0, 0, 1, 1), "▀": (0, 0, 1, .5), "▄": (0, .5, 1, 1), "▌": (0, 0, .5, 1), "▐": (.5, 0, 1, 1),
          "▔": (0, 0, 1, 1 / 8), "▏": (0, 0, 1 / 8, 1), "▕": (7 / 8, 0, 1, 1), "▆": (0, 2 / 8, 1, 1)}
for eighth in range(1, 8):
    BLOCKS[" ▁▂▃▄▅▆▇"[eighth]] = (0, 1 - eighth / 8, 1, 1)


def draw_cell(draw, x0, y0, char, fg):
    w, h = CELL_W, CELL_H
    if char in BLOCKS:
        a, b, c, d = BLOCKS[char]
        draw.rectangle([x0 + a * w, y0 + b * h, x0 + c * w - 1, y0 + d * h - 1], fill=fg)
    elif char == "░":
        for py in range(y0, y0 + h, 3):
            for px in range(x0 + (py // 3) % 2, x0 + w, 3):
                draw.point((px, py), fill=fg)
    elif char == "═":
        draw.line([x0, y0 + h // 2 - 2, x0 + w, y0 + h // 2 - 2], fill=fg)
        draw.line([x0, y0 + h // 2 + 2, x0 + w, y0 + h // 2 + 2], fill=fg)
    elif char == "┃":
        draw.rectangle([x0 + w // 2 - 1, y0, x0 + w // 2, y0 + h], fill=fg)
    elif char == "●":
        draw.ellipse([x0 + 1, y0 + h / 2 - 4, x0 + w - 2, y0 + h / 2 + 3], fill=fg)
    elif char == "■":
        draw.rectangle([x0 + 1, y0 + h / 2 - 4, x0 + w - 2, y0 + h / 2 + 3], fill=fg)
    elif char == "❚":
        draw.rectangle([x0 + 2, y0 + 4, x0 + w - 3, y0 + h - 5], fill=fg)
    elif char == "◆":
        cx, cy = x0 + w / 2, y0 + h / 2
        draw.polygon([(cx, cy - 4), (cx + 4, cy), (cx, cy + 4), (cx - 4, cy)], fill=fg)
    elif char in "▼▸":
        cx, cy = x0 + w / 2, y0 + h / 2
        points = [(cx - 4, cy - 3), (cx + 4, cy - 3), (cx, cy + 4)] if char == "▼" else [
            (cx - 3, cy - 4), (cx + 4, cy), (cx - 3, cy + 4)]
        draw.polygon(points, fill=fg)
    else:
        return False
    return True


def render(grid, bold_font=BOLD):
    width, height = COLUMNS * CELL_W + 24, ROWS * CELL_H + TITLE_H + 12
    image = Image.new("RGB", (width, height), BACKGROUND)
    draw = ImageDraw.Draw(image)
    draw.rectangle([0, 0, width, TITLE_H], fill=(33, 38, 45))
    for index, dot in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        draw.ellipse([14 + index * 20, 10, 26 + index * 20, 22], fill=dot)
    draw.text((width / 2, TITLE_H / 2), "Mini Meeting Minutes", font=FONT, fill=(139, 148, 158), anchor="mm")
    top, left = TITLE_H + 6, 12
    for row, cells in enumerate(grid):
        for column, (char, fg, bg, bold) in enumerate(cells):
            x0, y0 = left + column * CELL_W, top + row * CELL_H
            if bg != BACKGROUND:
                draw.rectangle([x0, y0, x0 + CELL_W - 1, y0 + CELL_H - 1], fill=bg)
            if char == " " or draw_cell(draw, x0, y0, char, fg):
                continue
            draw.text((x0 + CELL_W / 2, y0 + CELL_H / 2 + 1), char, font=bold_font if bold else FONT, fill=fg,
                      anchor="mm")
    return image


# Keys pressed during the demo, by seconds after the screen appears: show the oscilloscope, then
# the spectrum again, and the synthwave skin for a while.
KEYS = [(20, "v"), (26, "v"), (26.3, "v"), (31, "k"), (40, "k")]
NAMES = ["Samantha", "Daniel", "Karen"]


def wait_for(path, text, timeout=180):
    """Waits until `text` shows up in the recorded screen output."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.exists() and text in path.read_text(errors="replace"):
            return
        time.sleep(0.1)
    raise TimeoutError(f"{text!r} never appeared on screen")


def type_keys(process, typescript):
    wait_for(typescript, "MINI·MEETING·MINUTES")
    start = time.time()
    for at, key in KEYS:
        time.sleep(max(0, start + at - time.time()))
        process.stdin.write(key.encode())
        process.stdin.flush()
    wait_for(typescript, "SPEAKING")  # the renderer only redraws changed cells, so match a fragment
    time.sleep(1.2)
    for name in NAMES:
        for char in name + "\r":
            process.stdin.write(char.encode())
            process.stdin.flush()
            time.sleep(0.12)
        time.sleep(0.6)


def main():
    subprocess.run([str(ROOT / "mmm"), "--version"], check=True, capture_output=True)  # build first
    with tempfile.TemporaryDirectory(prefix="mmm-demo-") as scratch:
        scratch = Path(scratch)
        room, remote = synthesize_call(scratch, "meeting-room.wav", "meeting-call.wav")
        typescript = scratch / "screen.txt"
        command = (f"stty rows {ROWS} cols {COLUMNS}; exec '{ROOT / 'mmm'}' record --replay-room '{room}' "
                   f"--replay-remote '{remote}' --title 'Planning review' --output '{scratch}/'")
        process = subprocess.Popen(
            ["script", "-q", str(typescript), "/bin/bash", "-c", command],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(Path.home()), "TERM": "xterm-256color",
                 "COLORTERM": "truecolor"})
        typist = threading.Thread(target=type_keys, args=(process, typescript), daemon=True)
        typist.start()
        if process.wait(timeout=300) != 0:
            raise SystemExit("mmm record failed")
        screen = typescript.read_text(errors="replace")

    emulator = Emulator()
    emulator.feed(screen)
    frames = emulator.frames
    # Four times real time while recording; real time once the naming dialog opens.
    naming = next((index for index, grid in enumerate(frames)
                   if "WHO WAS SPEAKING?" in "".join(cell[0] for row in grid for cell in row)), len(frames))
    kept = frames[:naming:FRAME_STEP] + frames[naming::2] + [frames[-1]]
    rendered = [render(grid) for grid in kept]
    # One palette for every frame, built from a spread of frames, so colors never shift.
    samples = rendered[:: max(1, len(rendered) // 6)] + [rendered[-1]]
    montage = Image.new("RGB", (rendered[0].width, rendered[0].height * len(samples)))
    for index, frame in enumerate(samples):
        montage.paste(frame, (0, index * frame.height))
    palette = montage.quantize(colors=128, dither=Image.Dither.NONE)
    images = [frame.quantize(palette=palette, dither=Image.Dither.NONE) for frame in rendered]
    durations = [FRAME_MS] * (len(images) - 1) + [FINAL_HOLD_MS]
    OUTPUT.parent.mkdir(exist_ok=True)
    images[0].save(OUTPUT, save_all=True, append_images=images[1:], duration=durations, loop=0, optimize=True)
    print(f"wrote {OUTPUT.relative_to(ROOT)}: {len(images)} frames from {len(frames)}, "
          f"{OUTPUT.stat().st_size / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
