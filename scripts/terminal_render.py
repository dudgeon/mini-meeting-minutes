"""Draws a grid of terminal cells as an image, the way a modern macOS terminal would.

Used by record_demo.py. Block elements, box-drawing lines, braille and a few symbols are drawn as
shapes (as terminals do, so they join up seamlessly); other characters come from Menlo, falling
back to Arial Unicode for the ones Menlo lacks.
"""

import math

from PIL import Image, ImageDraw, ImageFont

CELL_W, CELL_H, TITLE_H = 9, 19, 30
MENLO = "/System/Library/Fonts/Menlo.ttc"
FONT = ImageFont.truetype(MENLO, 15, index=0)
BOLD = ImageFont.truetype(MENLO, 15, index=1)
FALLBACK = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Unicode.ttf", 14)
TERMINAL_BACKGROUND = (13, 17, 23)

# Block elements, as fractions of the cell: left, top, right, bottom.
BLOCKS = {"█": (0, 0, 1, 1), "▀": (0, 0, 1, .5), "▄": (0, .5, 1, 1), "▌": (0, 0, .5, 1), "▐": (.5, 0, 1, 1),
          "▔": (0, 0, 1, 1 / 8), "▏": (0, 0, 1 / 8, 1), "▕": (7 / 8, 0, 1, 1), "▎": (0, 0, 2 / 8, 1),
          "▍": (0, 0, 3 / 8, 1), "▋": (0, 0, 5 / 8, 1), "▊": (0, 0, 6 / 8, 1), "▉": (0, 0, 7 / 8, 1)}
for _eighth in range(1, 8):
    BLOCKS[" ▁▂▃▄▅▆▇"[_eighth]] = (0, 1 - _eighth / 8, 1, 1)

# Box drawing: the arms of each character and their weight (1 light, 2 heavy, 3 double).
BOX = {}
for _chars, _weight in [("─│┌┐└┘├┤┬┴┼", 1), ("━┃┏┓┗┛┣┫┳┻╋", 2), ("═║╔╗╚╝╠╣╦╩╬", 3)]:
    for _char, _arms in zip(_chars, ["lr", "ud", "rd", "ld", "ur", "ul", "udr", "udl", "lrd", "lru", "udlr"]):
        BOX[_char] = {arm: _weight for arm in _arms}
ROUNDED = {"╭": "rd", "╮": "ld", "╰": "ur", "╯": "ul"}
_missing_cache = {}


def _missing(font, char):
    """True when `font` would draw its placeholder box for `char`."""
    key = (id(font), char)
    if key not in _missing_cache:
        def glyph(c):
            image = Image.new("L", (28, 28), 0)
            ImageDraw.Draw(image).text((4, 4), c, font=font, fill=255)
            return image.tobytes()
        _missing_cache[key] = glyph(char) == glyph(chr(0xE000))
    return _missing_cache[key]


def _box(draw, x0, y0, char, fg):
    cx, cy = x0 + CELL_W // 2, y0 + CELL_H // 2
    ends = {"l": (x0, cy), "r": (x0 + CELL_W, cy), "u": (cx, y0), "d": (cx, y0 + CELL_H)}
    if char in ROUNDED:
        arms = ROUNDED[char]
        r = CELL_W // 2
        sx = 1 if "r" in arms else -1
        sy = 1 if "d" in arms else -1
        bounds = [min(cx, cx + 2 * sx * r), min(cy, cy + 2 * sy * r), max(cx, cx + 2 * sx * r), max(cy, cy + 2 * sy * r)]
        start = {"rd": 180, "ld": 270, "ur": 90, "ul": 0}[arms]
        draw.arc(bounds, start, start + 90, fill=fg, width=1)
        draw.line([(cx + sx * r, cy), ends["r" if sx > 0 else "l"]], fill=fg)
        draw.line([(cx, cy + sy * r), ends["d" if sy > 0 else "u"]], fill=fg)
        return
    if char in "╔╗╚╝":
        sx = 1 if char in "╔╚" else -1
        sy = 1 if char in "╔╗" else -1
        edge_x = x0 + CELL_W if sx > 0 else x0
        edge_y = y0 + CELL_H if sy > 0 else y0
        for offset in (-2, 2):
            corner = (cx - sx * offset, cy - sy * offset)
            draw.line([(corner[0], edge_y), corner, (edge_x, corner[1])], fill=fg)
        return
    for arm, weight in BOX[char].items():
        end = ends[arm]
        if weight == 3:
            for offset in (-2, 2):
                if arm in "lr":
                    draw.line([(cx, cy + offset), (end[0], cy + offset)], fill=fg)
                else:
                    draw.line([(cx + offset, cy), (cx + offset, end[1])], fill=fg)
        else:
            draw.line([(cx, cy), end], fill=fg, width=1 if weight == 1 else 3)


def _symbol(draw, x0, y0, char, fg):
    cx, cy = x0 + CELL_W / 2, y0 + CELL_H / 2
    if char == "●":
        draw.ellipse([cx - 3.5, cy - 3.5, cx + 3.5, cy + 3.5], fill=fg)
    elif char == "○":
        draw.ellipse([cx - 3.5, cy - 3.5, cx + 3.5, cy + 3.5], outline=fg)
    elif char in "✻✶✢✳✽":
        points = 6 if char in "✻✶✽" else 4
        for k in range(points):
            angle = math.pi * k / points
            dx, dy = 4.5 * math.cos(angle), 4.5 * math.sin(angle)
            draw.line([(cx - dx, cy - dy), (cx + dx, cy + dy)], fill=fg, width=2 if char == "✽" else 1)
    elif char == "■":
        draw.rectangle([cx - 3.5, cy - 3.5, cx + 3.5, cy + 3.5], fill=fg)
    elif char in "▮▯":
        draw.rectangle([cx - 2, cy - 5, cx + 2, cy + 5], fill=fg if char == "▮" else None, outline=fg)
    elif char == "❚":
        draw.rectangle([cx - 1.5, y0 + 4, cx + 1.5, y0 + CELL_H - 5], fill=fg)
    elif char in "▶▸":
        s = 4 if char == "▶" else 3
        draw.polygon([(cx - s + 1, cy - s), (cx + s, cy), (cx - s + 1, cy + s)], fill=fg)
    elif char == "❯":
        draw.line([(cx - 2, cy - 4), (cx + 2, cy), (cx - 2, cy + 4)], fill=fg, width=2)
    elif char == "▲":
        draw.polygon([(cx, cy - 4), (cx + 4, cy + 3), (cx - 4, cy + 3)], fill=fg)
    elif char == "▼":
        draw.polygon([(cx - 4, cy - 3), (cx + 4, cy - 3), (cx, cy + 4)], fill=fg)
    elif char == "◆":
        draw.polygon([(cx, cy - 4), (cx + 4, cy), (cx, cy + 4), (cx - 4, cy)], fill=fg)
    elif char == "✓":
        draw.line([(cx - 4, cy), (cx - 1, cy + 3), (cx + 4, cy - 4)], fill=fg, width=2)
    elif char == "░":
        for py in range(y0, y0 + CELL_H, 3):
            for px in range(x0 + (py // 3) % 2, x0 + CELL_W, 3):
                draw.point((px, py), fill=fg)
    elif 0x2800 <= ord(char) <= 0x28FF:
        bits = ord(char) - 0x2800
        dots = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (0, 3), (1, 3)]
        for bit, (dx, dy) in enumerate(dots):
            if bits >> bit & 1:
                px, py = x0 + 2.5 + dx * 4, y0 + 3 + dy * 4
                draw.ellipse([px - 1, py - 1, px + 1, py + 1], fill=fg)
    else:
        return False
    return True


def render(grid, title="Mini Meeting Minutes"):
    """`grid` is rows of (char, fg, bg, bold) cells, colors as RGB tuples."""
    rows, columns = len(grid), len(grid[0])
    width, height = columns * CELL_W + 24, rows * CELL_H + TITLE_H + 12
    image = Image.new("RGB", (width, height), TERMINAL_BACKGROUND)
    draw = ImageDraw.Draw(image)
    draw.rectangle([0, 0, width, TITLE_H], fill=(33, 38, 45))
    for index, dot in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        draw.ellipse([14 + index * 20, 10, 26 + index * 20, 22], fill=dot)
    draw.text((width / 2, TITLE_H / 2), title, font=FONT, fill=(139, 148, 158), anchor="mm")
    top, left = TITLE_H + 6, 12
    for row, cells in enumerate(grid):
        for column, (char, fg, bg, bold) in enumerate(cells):
            x0, y0 = left + column * CELL_W, top + row * CELL_H
            if bg != TERMINAL_BACKGROUND:
                draw.rectangle([x0, y0, x0 + CELL_W - 1, y0 + CELL_H - 1], fill=bg)
            if char == " ":
                continue
            if char in BLOCKS:
                a, b, c, d = BLOCKS[char]
                draw.rectangle([x0 + a * CELL_W, y0 + b * CELL_H, x0 + c * CELL_W - 1, y0 + d * CELL_H - 1], fill=fg)
            elif char in BOX or char in ROUNDED:
                _box(draw, x0, y0, char, fg)
            elif not _symbol(draw, x0, y0, char, fg):
                font = BOLD if bold else FONT
                if _missing(font, char):
                    font = FALLBACK
                draw.text((x0 + CELL_W / 2, y0 + CELL_H / 2 + 1), char, font=font, fill=fg, anchor="mm")
    return image
