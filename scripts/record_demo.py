#!/usr/bin/env python3
"""Records docs/demo.gif, the README animation of mmm's live screen.

Maintainer tool. A short synthetic call (macOS `say` voices: one person in the room, two on the
call, with speaker echo) is played through `mmm record` in a pseudo-terminal, exactly as a live
recording would be, and every frame the app drew is rendered into a GIF. The audio lives in a
temporary directory and is deleted afterwards.

Needs Pillow:
    python3 -m venv /tmp/demo-venv && /tmp/demo-venv/bin/pip install pillow
    /tmp/demo-venv/bin/python scripts/record_demo.py

To check the screen at another size without touching the GIF, save stills instead:
    /tmp/demo-venv/bin/python scripts/record_demo.py --size 80x24 --stills /tmp/stills
"""

import argparse
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from e2e_check import synthesize_call  # noqa: E402
from terminal_render import TERMINAL_BACKGROUND, render  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "docs" / "demo.gif"
COLUMNS, ROWS = 120, 42  # the size the Desktop shortcut opens Terminal at
FRAME_STEP = 8  # the screen draws every ~50 ms; keep every eighth frame...
FRAME_MS = 100  # ...and play them back about four times faster than real time
FINAL_HOLD_MS = 4000

BACKGROUND, FOREGROUND = TERMINAL_BACKGROUND, (201, 209, 217)
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


# Keys pressed during the demo, by seconds after the screen appears: Space, then Y to confirm that
# everyone has agreed to the recording, a note ("\r" is Return), then synthwave mode for a while,
# and back to the sidebar.
KEYS = [(2, " "), (4, "y"), (12, "\rAsk finance for the infrastructure breakdown\r"), (24, "k"), (38, "k")]
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
    wait_for(typescript, "Ready")
    start = time.time()
    for at, keys in KEYS:
        time.sleep(max(0, start + at - time.time()))
        for key in keys:
            process.stdin.write(key.encode())
            process.stdin.flush()
            time.sleep(0.07)
    wait_for(typescript, "Who was speaking?")
    time.sleep(1.2)
    for name in NAMES:
        for char in name + "\r":
            process.stdin.write(char.encode())
            process.stdin.flush()
            time.sleep(0.12)
        time.sleep(0.6)
    wait_for(typescript, "new recording")  # the saved screen
    time.sleep(3)
    process.stdin.write(b"q")
    process.stdin.flush()


def main():
    global COLUMNS, ROWS
    parser = argparse.ArgumentParser(description="Records docs/demo.gif, the README animation.")
    parser.add_argument("--size", default=f"{COLUMNS}x{ROWS}", help="terminal size (default %(default)s)")
    parser.add_argument("--stills", type=Path, metavar="FOLDER",
                        help="save a PNG of the screen every few seconds here, instead of writing the GIF")
    parser.add_argument("--minutes", type=Path, metavar="FOLDER",
                        help="keep the minutes the demo meeting produces in FOLDER/Minutes")
    arguments = parser.parse_args()
    COLUMNS, ROWS = (int(n) for n in arguments.size.lower().split("x"))

    # The demo's audio (synthetic voices) lives in a temporary folder that's deleted afterwards, even
    # if the run is stopped; folders left by a run that was killed outright are removed here.
    for leftover in Path(tempfile.gettempdir()).glob("mmm-demo-*"):
        shutil.rmtree(leftover, ignore_errors=True)
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, lambda *_: sys.exit(1))
    subprocess.run([str(ROOT / "mmm"), "--version"], check=True, capture_output=True)  # build first
    with tempfile.TemporaryDirectory(prefix="mmm-demo-") as scratch:
        scratch = Path(scratch)
        room, remote = synthesize_call(scratch, "meeting-room.wav", "meeting-call.wav")
        typescript = scratch / "screen.txt"
        minutes = (arguments.minutes or scratch) / "Minutes"  # named like the real folder, as the screen shows it
        minutes.mkdir(parents=True, exist_ok=True)
        command = (f"stty rows {ROWS} cols {COLUMNS}; exec '{ROOT / 'mmm'}' record --replay-room '{room}' "
                   f"--replay-remote '{remote}' --title 'Planning review' --output '{minutes}/'")
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
                   if "who was speaking?" in "".join(cell[0] for row in grid for cell in row).lower()), len(frames))
    if arguments.stills:
        arguments.stills.mkdir(parents=True, exist_ok=True)
        picks = sorted({*range(0, len(frames), 80), min(naming, len(frames) - 1), len(frames) - 1})
        for index in picks:
            render(frames[index]).save(arguments.stills / f"frame-{index:05d}.png")
        print(f"saved {len(picks)} stills of {len(frames)} frames to {arguments.stills}")
        return
    kept = frames[:naming:FRAME_STEP] + frames[naming::2] + [frames[-1]]
    rendered = [render(grid) for grid in kept]
    # One palette for every frame, built from a spread of frames, so colors never shift.
    samples = rendered[:: max(1, len(rendered) // 6)] + [rendered[-1]]
    montage = Image.new("RGB", (rendered[0].width, rendered[0].height * len(samples)))
    for index, frame in enumerate(samples):
        montage.paste(frame, (0, index * frame.height))
    palette = montage.quantize(colors=256, dither=Image.Dither.NONE)
    images = [frame.quantize(palette=palette, dither=Image.Dither.NONE) for frame in rendered]
    durations = [FRAME_MS] * (len(images) - 1) + [FINAL_HOLD_MS]
    OUTPUT.parent.mkdir(exist_ok=True)
    images[0].save(OUTPUT, save_all=True, append_images=images[1:], duration=durations, loop=0, optimize=True)
    print(f"wrote {OUTPUT.relative_to(ROOT)}: {len(images)} frames from {len(frames)}, "
          f"{OUTPUT.stat().st_size / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
