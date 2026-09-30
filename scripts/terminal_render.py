"""Draws a grid of terminal cells as an image, the way a modern macOS terminal would.

Used by record_demo.py. Block elements, box-drawing lines, braille and a few symbols are drawn as
shapes (as terminals do, so they join up seamlessly); other characters come from Menlo, falling
back to Arial Unicode for the ones Menlo lacks. `set_scale` draws everything larger, for crisp
close-ups.
"""

import math

from PIL import Image, ImageDraw, ImageFont

MENLO = "/System/Library/Fonts/Menlo.ttc"
ARIAL_UNICODE = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"
TERMINAL_BACKGROUND = (13, 17, 23)


def set_scale(scale):
    """Sizes everything for `scale` times the normal cell size (9 × 19 pixels)."""
    global S, CELL_W, CELL_H, TITLE_H, FONT, BOLD, FALLBACK
    S = scale
    CELL_W, CELL_H, TITLE_H = 9 * scale, 19 * scale, 30 * scale
    FONT = ImageFont.truetype(MENLO, 15 * scale, index=0)
    BOLD = ImageFont.truetype(MENLO, 15 * scale, index=1)
    FALLBACK = ImageFont.truetype(ARIAL_UNICODE, 14 * scale)


set_scale(1)

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


def _width(pixels):
    """A line width, in pixels at the normal size."""
    return max(1, round(pixels * S))


def _missing(font, char):
    """True when `font` would draw its placeholder box for `char`."""
    key = (id(font), char)
    if key not in _missing_cache:
        def glyph(c):
            size = int(font.size * 2)
            image = Image.new("L", (size, size), 0)
            ImageDraw.Draw(image).text((size // 7, size // 7), c, font=font, fill=255)
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
        draw.arc(bounds, start, start + 90, fill=fg, width=_width(1))
        draw.line([(cx + sx * r, cy), ends["r" if sx > 0 else "l"]], fill=fg, width=_width(1))
        draw.line([(cx, cy + sy * r), ends["d" if sy > 0 else "u"]], fill=fg, width=_width(1))
        return
    gap = 2 * S  # between the two lines of double box drawing
    if char in "╔╗╚╝":
        sx = 1 if char in "╔╚" else -1
        sy = 1 if char in "╔╗" else -1
        edge_x = x0 + CELL_W if sx > 0 else x0
        edge_y = y0 + CELL_H if sy > 0 else y0
        for offset in (-gap, gap):
            corner = (cx - sx * offset, cy - sy * offset)
            draw.line([(corner[0], edge_y), corner, (edge_x, corner[1])], fill=fg, width=_width(1))
        return
    for arm, weight in BOX[char].items():
        end = ends[arm]
        if weight == 3:
            for offset in (-gap, gap):
                if arm in "lr":
                    draw.line([(cx, cy + offset), (end[0], cy + offset)], fill=fg, width=_width(1))
                else:
                    draw.line([(cx + offset, cy), (cx + offset, end[1])], fill=fg, width=_width(1))
        else:
            draw.line([(cx, cy), end], fill=fg, width=_width(1 if weight == 1 else 3))


def _symbol(draw, x0, y0, char, fg):
    cx, cy = x0 + CELL_W / 2, y0 + CELL_H / 2
    u = S  # one pixel at the normal size
    if char == "●":
        draw.ellipse([cx - 3.5 * u, cy - 3.5 * u, cx + 3.5 * u, cy + 3.5 * u], fill=fg)
    elif char == "○":
        draw.ellipse([cx - 3.5 * u, cy - 3.5 * u, cx + 3.5 * u, cy + 3.5 * u], outline=fg, width=_width(1))
    elif char in "✻✶✢✳✽":
        points = 6 if char in "✻✶✽" else 4
        for k in range(points):
            angle = math.pi * k / points
            dx, dy = 4.5 * u * math.cos(angle), 4.5 * u * math.sin(angle)
            draw.line([(cx - dx, cy - dy), (cx + dx, cy + dy)], fill=fg, width=_width(2 if char == "✽" else 1))
    elif char == "■":
        draw.rectangle([cx - 3.5 * u, cy - 3.5 * u, cx + 3.5 * u, cy + 3.5 * u], fill=fg)
    elif char in "▮▯":
        draw.rectangle([cx - 2 * u, cy - 5 * u, cx + 2 * u, cy + 5 * u], fill=fg if char == "▮" else None, outline=fg,
                       width=_width(1))
    elif char == "❚":
        draw.rectangle([cx - 1.5 * u, y0 + 4 * u, cx + 1.5 * u, y0 + CELL_H - 5 * u], fill=fg)
    elif char in "▶▸":
        s = (4 if char == "▶" else 3) * u
        draw.polygon([(cx - s + u, cy - s), (cx + s, cy), (cx - s + u, cy + s)], fill=fg)
    elif char == "❯":
        draw.line([(cx - 2 * u, cy - 4 * u), (cx + 2 * u, cy), (cx - 2 * u, cy + 4 * u)], fill=fg, width=_width(2))
    elif char == "▲":
        draw.polygon([(cx, cy - 4 * u), (cx + 4 * u, cy + 3 * u), (cx - 4 * u, cy + 3 * u)], fill=fg)
    elif char == "▼":
        draw.polygon([(cx - 4 * u, cy - 3 * u), (cx + 4 * u, cy - 3 * u), (cx, cy + 4 * u)], fill=fg)
    elif char == "◆":
        draw.polygon([(cx, cy - 4 * u), (cx + 4 * u, cy), (cx, cy + 4 * u), (cx - 4 * u, cy)], fill=fg)
    elif char == "✓":
        draw.line([(cx - 4 * u, cy), (cx - u, cy + 3 * u), (cx + 4 * u, cy - 4 * u)], fill=fg, width=_width(2))
    elif char == "░":
        step = 3 * S
        for py in range(y0, y0 + CELL_H, step):
            for px in range(x0 + (py // step) % 2 * S, x0 + CELL_W, step):
                draw.rectangle([px, py, px + S - 1, py + S - 1], fill=fg)
    elif 0x2800 <= ord(char) <= 0x28FF:
        bits = ord(char) - 0x2800
        dots = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (0, 3), (1, 3)]
        for bit, (dx, dy) in enumerate(dots):
            if bits >> bit & 1:
                px, py = x0 + (2.5 + dx * 4) * u, y0 + (3 + dy * 4) * u
                draw.ellipse([px - u, py - u, px + u, py + u], fill=fg)
    else:
        return False
    return True


def render(grid, title="Mini Meeting Minutes"):
    """`grid` is rows of (char, fg, bg, bold) cells, colors as RGB tuples."""
    rows, columns = len(grid), len(grid[0])
    width, height = columns * CELL_W + 24 * S, rows * CELL_H + TITLE_H + 12 * S
    image = Image.new("RGB", (width, height), TERMINAL_BACKGROUND)
    draw = ImageDraw.Draw(image)
    draw.rectangle([0, 0, width, TITLE_H], fill=(33, 38, 45))
    for index, dot in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        draw.ellipse([(14 + index * 20) * S, 10 * S, (26 + index * 20) * S, 22 * S], fill=dot)
    draw.text((width / 2, TITLE_H / 2), title, font=FONT, fill=(139, 148, 158), anchor="mm")
    top, left = TITLE_H + 6 * S, 12 * S
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
                draw.text((x0 + CELL_W / 2, y0 + CELL_H / 2 + S), char, font=font, fill=fg, anchor="mm")
    return image
