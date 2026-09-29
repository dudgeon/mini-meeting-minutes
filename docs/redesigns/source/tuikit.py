"""A tiny terminal-cell renderer for TUI mockups.

Everything drawn is a grid of one-column cells with a foreground, background and style (bold or
italic), so each mockup can be reproduced in a real truecolor terminal. Block elements,
box-drawing lines and a few symbols are drawn as shapes, the way modern terminals draw them;
other glyphs come from Menlo, falling back to Arial Unicode.
"""
from PIL import Image, ImageDraw, ImageFont

W, H = 120, 40
CW, CH = 9, 19
MENLO = "/System/Library/Fonts/Menlo.ttc"
FONTS = {
    None: ImageFont.truetype(MENLO, 15, index=0),
    "bold": ImageFont.truetype(MENLO, 15, index=1),
    "italic": ImageFont.truetype(MENLO, 15, index=2),
    "bolditalic": ImageFont.truetype(MENLO, 15, index=3),
}
FALLBACK = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Unicode.ttf", 14)
_MISSING = {}


def _glyph(font, ch):
    image = Image.new("L", (28, 28), 0)
    ImageDraw.Draw(image).text((4, 4), ch, font=font, fill=255)
    return image.tobytes()


def _missing(font, ch):
    """True when `font` would draw its placeholder box for `ch`."""
    key = (id(font), ch)
    if key not in _MISSING:
        _MISSING[key] = _glyph(font, ch) == _glyph(font, chr(0xE000))
    return _MISSING[key]


def rgb(value):
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def mix(a, b, amount):
    a, b = rgb(a) if isinstance(a, str) else a, rgb(b) if isinstance(b, str) else b
    return "#%02x%02x%02x" % tuple(int(x * (1 - amount) + y * amount) for x, y in zip(a, b))


def wrap(text, width):
    lines, line = [], ""
    for word in text.split():
        if line and len(line) + 1 + len(word) > width:
            lines.append(line)
            line = word
        else:
            line = f"{line} {word}" if line else word
    return lines + ([line] if line else [])


class Grid:
    def __init__(self, bg, fg="#ffffff", width=W, height=H):
        self.width, self.height = width, height
        self.cells = [[[" ", fg, bg, None] for _ in range(width)] for _ in range(height)]

    def put(self, x, y, ch, fg=None, bg=None, style=None):
        if 0 <= x < self.width and 0 <= y < self.height:
            cell = self.cells[y][x]
            cell[0] = ch
            if fg:
                cell[1] = fg
            if bg:
                cell[2] = bg
            cell[3] = style

    def bg_at(self, x, y):
        return self.cells[y][x][2]

    def text(self, x, y, string, fg=None, bg=None, style=None, limit=None):
        for i, ch in enumerate(string):
            if limit is not None and i >= limit:
                break
            self.put(x + i, y, ch, fg, bg, style)
        return x + min(len(string), limit if limit is not None else len(string))

    def rtext(self, right, y, string, fg=None, bg=None, style=None):
        """Right-aligned: the last character lands in column `right`."""
        self.text(right - len(string) + 1, y, string, fg, bg, style)

    def ctext(self, x, w, y, string, fg=None, bg=None, style=None):
        self.text(x + max(0, (w - len(string)) // 2), y, string, fg, bg, style)

    def fill(self, x, y, w, h, bg, ch=" ", fg=None):
        for yy in range(y, y + h):
            for xx in range(x, x + w):
                self.put(xx, yy, ch, fg or bg, bg)

    def hline(self, x, y, w, fg, ch="─", bg=None):
        for xx in range(x, x + w):
            self.put(xx, y, ch, fg, bg)

    def vline(self, x, y, h, fg, ch="│", bg=None):
        for yy in range(y, y + h):
            self.put(x, yy, ch, fg, bg)

    def box(self, x, y, w, h, fg, style="light", bg=None, title=None, title_fg=None, title_style="bold"):
        chars = {
            "light": "┌┐└┘─│", "rounded": "╭╮╰╯─│", "heavy": "┏┓┗┛━┃", "double": "╔╗╚╝═║",
        }[style]
        if bg:
            self.fill(x + 1, y + 1, w - 2, h - 2, bg)
        tl, tr, bl, br, horizontal, vertical = chars
        self.put(x, y, tl, fg, bg)
        self.put(x + w - 1, y, tr, fg, bg)
        self.put(x, y + h - 1, bl, fg, bg)
        self.put(x + w - 1, y + h - 1, br, fg, bg)
        self.hline(x + 1, y, w - 2, fg, horizontal, bg)
        self.hline(x + 1, y + h - 1, w - 2, fg, horizontal, bg)
        self.vline(x, y + 1, h - 2, fg, vertical, bg)
        self.vline(x + w - 1, y + 1, h - 2, fg, vertical, bg)
        if title:
            self.text(x + 2, y, f" {title} ", title_fg or fg, bg, title_style)

    def pixels(self, x, y, image):
        """Blits an RGBA image drawn two pixels per cell vertically; transparent pixels keep the
        cell's background."""
        image = image.convert("RGBA")
        for row in range(image.height // 2):
            for column in range(image.width):
                cx, cy = x + column, y + row
                if not (0 <= cx < self.width and 0 <= cy < self.height):
                    continue
                under = self.bg_at(cx, cy)
                top, bottom = image.getpixel((column, row * 2)), image.getpixel((column, row * 2 + 1))
                top = "#%02x%02x%02x" % top[:3] if top[3] > 127 else under
                bottom = "#%02x%02x%02x" % bottom[:3] if bottom[3] > 127 else under
                if top == bottom:
                    self.put(cx, cy, " ", top, top)
                else:
                    self.put(cx, cy, "▀", top, bottom)


def pixel_text(text, font_path, size, color, height=None, spacing=0, index=0):
    """Rasterizes text at a tiny size with no antialiasing, for blitting as half-block pixel art.
    `color` is a color or a function of the pixel row."""
    font = ImageFont.truetype(font_path, size, index=index)
    left, top, right, bottom = font.getbbox(text)
    width = right - left + spacing * max(len(text) - 1, 0)
    height = height or (bottom - top + 1)
    height += height % 2
    mask = Image.new("1", (width + 2, height), 0)
    draw = ImageDraw.Draw(mask)
    draw.fontmode = "1"
    if spacing:
        x = -left
        for ch in text:
            draw.text((x, -top), ch, font=font, fill=1)
            x += font.getlength(ch) + spacing
    else:
        draw.text((-left, -top), text, font=font, fill=1)
    image = Image.new("RGBA", mask.size, (0, 0, 0, 0))
    for py in range(mask.height):
        c = color(py, mask.height) if callable(color) else color
        c = rgb(c) if isinstance(c, str) else c
        for px in range(mask.width):
            if mask.getpixel((px, py)):
                image.putpixel((px, py), c + (255,))
    return image


# ── Rendering ──────────────────────────────────────────────────────────────────────────────

BLOCKS = {"█": (0, 0, 1, 1), "▀": (0, 0, 1, .5), "▄": (0, .5, 1, 1), "▌": (0, 0, .5, 1), "▐": (.5, 0, 1, 1),
          "▔": (0, 0, 1, 1 / 8), "▏": (0, 0, 1 / 8, 1), "▕": (7 / 8, 0, 1, 1), "▎": (0, 0, 2 / 8, 1),
          "▍": (0, 0, 3 / 8, 1), "▊": (0, 0, 6 / 8, 1), "▋": (0, 0, 5 / 8, 1), "▉": (0, 0, 7 / 8, 1)}
for _e in range(1, 8):
    BLOCKS[" ▁▂▃▄▅▆▇"[_e]] = (0, 1 - _e / 8, 1, 1)

# Box drawing: which arms each character has, and their weight (1 light, 2 heavy, 3 double).
BOX = {}
for _chars, _weight in [("─│┌┐└┘├┤┬┴┼", 1), ("━┃┏┓┗┛┣┫┳┻╋", 2), ("═║╔╗╚╝╠╣╦╩╬", 3)]:
    for _ch, _arms in zip(_chars, ["lr", "ud", "rd", "ld", "ur", "ul", "udr", "udl", "lrd", "lru", "udlr"]):
        BOX[_ch] = {arm: _weight for arm in _arms}
ROUNDED = {"╭": "rd", "╮": "ld", "╰": "ur", "╯": "ul"}


def _box(draw, x0, y0, ch, fg):
    cx, cy = x0 + CW // 2, y0 + CH // 2
    ends = {"l": (x0, cy), "r": (x0 + CW, cy), "u": (cx, y0), "d": (cx, y0 + CH)}
    if ch in ROUNDED:
        arms = ROUNDED[ch]
        r = CW // 2
        sx = 1 if "r" in arms else -1
        sy = 1 if "d" in arms else -1
        ox, oy = cx + sx * r, cy + sy * r
        box = [min(cx, cx + 2 * sx * r), min(cy, cy + 2 * sy * r), max(cx, cx + 2 * sx * r), max(cy, cy + 2 * sy * r)]
        start = {"rd": 180, "ld": 270, "ur": 90, "ul": 0}[arms]
        draw.arc(box, start, start + 90, fill=fg, width=1)
        draw.line([(ox, cy), ends[arms[0] if arms[0] in "lr" else arms[1]]], fill=fg)
        draw.line([(cx, oy), ends["d" if "d" in arms else "u"]], fill=fg)
        return
    if ch in "╔╗╚╝":
        # Double corners: two nested L shapes.
        sx = 1 if ch in "╔╚" else -1
        sy = 1 if ch in "╔╗" else -1
        edge_x = x0 + CW if sx > 0 else x0
        edge_y = y0 + CH if sy > 0 else y0
        for offset in (-2, 2):
            corner = (cx - sx * offset, cy - sy * offset)
            draw.line([(corner[0], edge_y), corner, (edge_x, corner[1])], fill=fg)
        return
    for arm, weight in BOX[ch].items():
        end = ends[arm]
        if weight == 3:
            for offset in (-2, 2):
                if arm in "lr":
                    draw.line([(cx, cy + offset), (end[0], cy + offset)], fill=fg)
                else:
                    draw.line([(cx + offset, cy), (cx + offset, end[1])], fill=fg)
        else:
            draw.line([(cx, cy), end], fill=fg, width=1 if weight == 1 else 3)


def _symbol(draw, x0, y0, ch, fg):
    cx, cy = x0 + CW / 2, y0 + CH / 2
    if ch in "●⏺":
        r = 3.5 if ch == "●" else 3
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=fg)
    elif ch == "○":
        draw.ellipse([cx - 3.5, cy - 3.5, cx + 3.5, cy + 3.5], outline=fg)
    elif ch == "◉":
        draw.ellipse([cx - 4, cy - 4, cx + 4, cy + 4], outline=fg)
        draw.ellipse([cx - 2, cy - 2, cx + 2, cy + 2], fill=fg)
    elif ch in "✻✢✳✶":
        import math
        points = 6 if ch in "✻✶" else 4
        for k in range(points):
            angle = math.pi * k / points
            dx, dy = 4.5 * math.cos(angle), 4.5 * math.sin(angle)
            draw.line([(cx - dx, cy - dy), (cx + dx, cy + dy)], fill=fg, width=1)
    elif ch == "⎿":
        draw.line([(cx - 2, y0 + 2), (cx - 2, cy + 1), (x0 + CW, cy + 1)], fill=fg)
    elif ch == "■":
        draw.rectangle([cx - 3.5, cy - 3.5, cx + 3.5, cy + 3.5], fill=fg)
    elif ch == "□":
        draw.rectangle([cx - 3.5, cy - 3.5, cx + 3.5, cy + 3.5], outline=fg)
    elif ch == "❚":
        draw.rectangle([cx - 1.5, y0 + 4, cx + 1.5, y0 + CH - 5], fill=fg)
    elif ch in "▶▸":
        s = 4 if ch == "▶" else 3
        draw.polygon([(cx - s + 1, cy - s), (cx + s, cy), (cx - s + 1, cy + s)], fill=fg)
    elif ch == "⏵":
        draw.polygon([(cx - 2, cy - 3), (cx + 3, cy), (cx - 2, cy + 3)], fill=fg)
    elif ch == "◀":
        draw.polygon([(cx + 3, cy - 4), (cx - 4, cy), (cx + 3, cy + 4)], fill=fg)
    elif ch == "▲":
        draw.polygon([(cx, cy - 4), (cx + 4, cy + 3), (cx - 4, cy + 3)], fill=fg)
    elif ch == "▼":
        draw.polygon([(cx - 4, cy - 3), (cx + 4, cy - 3), (cx, cy + 4)], fill=fg)
    elif ch in "◆◇":
        points = [(cx, cy - 4), (cx + 4, cy), (cx, cy + 4), (cx - 4, cy)]
        draw.polygon(points, fill=fg if ch == "◆" else None, outline=fg)
    elif ch in "◢◣◤◥":
        corners = {"◢": [(x0 + CW, y0), (x0 + CW, y0 + CH), (x0, y0 + CH)],
                   "◣": [(x0, y0), (x0 + CW, y0 + CH), (x0, y0 + CH)],
                   "◤": [(x0, y0), (x0 + CW, y0), (x0, y0 + CH)],
                   "◥": [(x0, y0), (x0 + CW, y0), (x0 + CW, y0 + CH)]}
        draw.polygon(corners[ch], fill=fg)
    elif ch in "╱╲":
        a, b = ((x0, y0 + CH), (x0 + CW, y0)) if ch == "╱" else ((x0, y0), (x0 + CW, y0 + CH))
        draw.line([a, b], fill=fg)
    elif ch in "┈┄":
        step = 3 if ch == "┈" else 5
        for px in range(int(x0), int(x0 + CW), step):
            draw.line([(px, cy), (px + (0 if ch == "┈" else 2), cy)], fill=fg)
    elif ch == "✓":
        draw.line([(cx - 4, cy), (cx - 1, cy + 3), (cx + 4, cy - 4)], fill=fg, width=2)
    elif 0x2800 <= ord(ch) <= 0x28FF:
        bits = ord(ch) - 0x2800
        dots = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (0, 3), (1, 3)]
        for bit, (dx, dy) in enumerate(dots):
            if bits >> bit & 1:
                px, py = x0 + 2.5 + dx * 4, y0 + 3 + dy * 4
                draw.ellipse([px - 1, py - 1, px + 1, py + 1], fill=fg)
    else:
        return False
    return True


def render(grid, path=None, title="Terminal"):
    bar = 30
    image = Image.new("RGB", (grid.width * CW + 24, grid.height * CH + bar + 12), (30, 30, 34))
    draw = ImageDraw.Draw(image)
    draw.rectangle([0, 0, image.width, bar], fill=(44, 44, 50))
    for index, dot in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        draw.ellipse([14 + index * 20, 10, 26 + index * 20, 22], fill=dot)
    draw.text((image.width / 2, bar / 2), title, font=FONTS[None], fill=(150, 150, 160), anchor="mm")
    top, left = bar + 6, 12
    draw.rectangle([left, top, left + grid.width * CW - 1, top + grid.height * CH - 1], fill=grid.cells[0][0][2])
    for row, cells in enumerate(grid.cells):
        for column, (ch, fg, bg, style) in enumerate(cells):
            x0, y0 = left + column * CW, top + row * CH
            draw.rectangle([x0, y0, x0 + CW - 1, y0 + CH - 1], fill=bg)
            if ch == " ":
                continue
            if ch in BLOCKS:
                a, b, c, d = BLOCKS[ch]
                draw.rectangle([x0 + a * CW, y0 + b * CH, x0 + c * CW - 1, y0 + d * CH - 1], fill=fg)
                continue
            if ch == "░":
                for py in range(y0, y0 + CH, 3):
                    for px in range(x0 + (py // 3) % 2, x0 + CW, 3):
                        draw.point((px, py), fill=fg)
                continue
            if ch in BOX or ch in ROUNDED:
                _box(draw, x0, y0, ch, fg)
                continue
            if _symbol(draw, x0, y0, ch, fg):
                continue
            font = FONTS[style if style in FONTS else None]
            if _missing(font, ch):
                font = FALLBACK
            draw.text((x0 + CW / 2, y0 + CH / 2 + 1), ch, font=font, fill=fg, anchor="mm")
    if path:
        image.save(path)
    return image
