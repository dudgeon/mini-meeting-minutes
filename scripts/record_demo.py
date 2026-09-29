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
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
from e2e_check import synthesize_call  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "docs" / "demo.gif"
COLUMNS, ROWS = 100, 24
CELL_W, CELL_H, TITLE_H = 9, 19, 30
FRAME_STEP = 3  # the screen redraws about every 150 ms; keep every third frame...
FRAME_MS = 110  # ...and play them back about four times faster than real time
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


def parse_frames(screen):
    """Splits the recorded output into frames (each starts with cursor-home) and replays the
    escape sequences mmm uses into a grid of (character, color, bold, dim) cells."""
    frames = []
    for chunk in screen.split("\x1b[H")[1:]:
        chunk = chunk.split("\x1b[?1049l")[0]
        grid = [[(" ", None, False, False)] * COLUMNS for _ in range(ROWS)]
        x = y = 0
        color, bold, dim = None, False, False
        position = 0
        while position < len(chunk):
            char = chunk[position]
            if char == "\x1b":
                match = re.match(r"\x1b\[([0-9;?]*)([A-Za-z])", chunk[position:])
                if not match:
                    position += 1
                    continue
                params, command = match.groups()
                if command == "m":
                    codes = [int(code) for code in params.split(";") if code.isdigit()] or [0]
                    index = 0
                    while index < len(codes):
                        code = codes[index]
                        if code == 0:
                            color, bold, dim = None, False, False
                        elif code == 1:
                            bold = True
                        elif code == 2:
                            dim = True
                        elif 30 <= code <= 37:
                            color = ANSI.get(code - 30, FOREGROUND)
                        elif code == 38 and index + 2 < len(codes) and codes[index + 1] == 5:
                            color = xterm_256(codes[index + 2])
                            index += 2
                        index += 1
                elif command == "K" and y < ROWS:
                    for column in range(x, COLUMNS):
                        grid[y][column] = (" ", None, False, False)
                position += len(match.group(0))
                continue
            if char == "\r":
                x = 0
            elif char == "\n":
                x, y = 0, y + 1
            elif y < ROWS and x < COLUMNS:
                grid[y][x] = (char, color, bold, dim)
                x += 1
            position += 1
        frames.append(grid)
    return frames


def render(grid):
    width, height = COLUMNS * CELL_W + 24, ROWS * CELL_H + TITLE_H + 12
    image = Image.new("RGB", (width, height), BACKGROUND)
    draw = ImageDraw.Draw(image)
    draw.rectangle([0, 0, width, TITLE_H], fill=(33, 38, 45))
    for index, dot in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        draw.ellipse([14 + index * 20, 10, 26 + index * 20, 22], fill=dot)
    draw.text((width / 2, TITLE_H / 2), "Mini Meeting Minutes", font=FONT, fill=(139, 148, 158), anchor="mm")
    top, left = TITLE_H + 6, 12
    for row, cells in enumerate(grid):
        for column, (char, color, bold, dim) in enumerate(cells):
            if char == " ":
                continue
            fg = color or FOREGROUND
            if dim:
                fg = tuple(int(c * 0.55 + b * 0.45) for c, b in zip(fg, BACKGROUND))
            x0, y0 = left + column * CELL_W, top + row * CELL_H
            if char in "▁▂▃▄▅▆▇█":
                eighths = "▁▂▃▄▅▆▇█".index(char) + 1
                draw.rectangle([x0, y0 + CELL_H * (8 - eighths) / 8, x0 + CELL_W - 1, y0 + CELL_H - 1], fill=fg)
            elif char == "─":
                draw.line([x0, y0 + CELL_H // 2, x0 + CELL_W, y0 + CELL_H // 2], fill=fg)
            else:
                draw.text((x0 + CELL_W / 2, y0 + CELL_H / 2 + 1), char, font=BOLD if bold else FONT, fill=fg,
                          anchor="mm")
    return image


def main():
    subprocess.run([str(ROOT / "mmm"), "--version"], check=True, capture_output=True)  # build first
    with tempfile.TemporaryDirectory(prefix="mmm-demo-") as scratch:
        scratch = Path(scratch)
        room, remote = synthesize_call(scratch, "meeting-room.wav", "meeting-call.wav")
        typescript = scratch / "screen.txt"
        command = (f"stty rows {ROWS} cols {COLUMNS}; exec '{ROOT / 'mmm'}' record --replay-room '{room}' "
                   f"--replay-remote '{remote}' --no-names --title 'Planning review' --output '{scratch}/'")
        subprocess.run(
            ["script", "-q", str(typescript), "/bin/bash", "-c", command],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, check=True,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(Path.home()), "TERM": "xterm-256color"})
        screen = typescript.read_text(errors="replace")

    frames = parse_frames(screen)
    kept = frames[::FRAME_STEP] + [frames[-1]]
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
