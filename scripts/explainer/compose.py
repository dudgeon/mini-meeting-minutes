"""Turns a capture into the explainer video: a camera flies over the app's real screen, with a title,
feature captions, the keys being pressed, the saved minutes and an end card.

The window is drawn at three times the normal size and seen through a perspective camera, so text
stays sharp close up. Every time below is anchored to the narration's lines, the keys capture.py
pressed, or what the app did (when it told the speakers apart, when it saved), so a new capture
with slightly different timing still lines up.
"""

import bisect
import json
import math
import multiprocessing
import pickle
import subprocess
import sys
import wave
from pathlib import Path

import imageio_ffmpeg
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import terminal_render  # noqa: E402
from record_demo import Emulator  # noqa: E402

W, H, FPS = 1920, 1080, 30
SCALE = 3                     # the window is drawn at three times the normal size
RECORDING = 4.0               # video time when recording starts (after the title and the consent step)
NARRATION = RECORDING + 0.04  # the replay, and so the narration, starts with recording

INK, MUTED = (236, 235, 231), (154, 152, 147)
ACCENT, LAVENDER, PANEL = (217, 119, 87), (184, 155, 217), (25, 25, 24)  # the app's own colors

SF = "/System/Library/Fonts/SFNS.ttf"
SF_MONO = "/System/Library/Fonts/SFNSMono.ttf"
MENLO = "/System/Library/Fonts/Menlo.ttc"


def sf(size, weight=400):
    font = ImageFont.truetype(SF, size)
    font.set_variation_by_axes([100, max(17, min(96, size)), 400, weight])  # width, optical size, grade, weight
    return font


def sf_mono(size, weight=400):
    font = ImageFont.truetype(SF_MONO, size)
    font.set_variation_by_axes([294, max(294, weight)])
    return font


def smooth(x):
    x = min(1.0, max(0.0, x))
    return x * x * (3 - 2 * x)


def ease_out(x):
    x = min(1.0, max(0.0, x))
    return 1 - (1 - x) ** 3


def ramp(t, start, end):
    """0 before `start`, 1 after `end`, eased in between."""
    return smooth((t - start) / (end - start)) if end > start else float(t >= start)


def shown(t, start, end, fade_in=0.3, fade_out=0.25):
    return min(ramp(t, start, start + fade_in), 1 - ramp(t, end - fade_out, end))


# ---------------------------------------------------------------- the capture and its timeline

SYNC_END = "\x1b[?2026l"  # the app wraps each screen update in synchronized output


def screen_text(grid, rows, columns):
    return "\n".join("".join(cell[0] for cell in grid[row][columns]) for row in rows)


def load_capture(work):
    """The capture, the screens the app drew, and when (monotonic seconds) it drew each one."""
    with open(work / "capture.pkl", "rb") as handle:
        capture = pickle.load(handle)
    emulator, times, pending = Emulator(), [], ""
    for moment, text in capture["stream"]:
        pending += text
        cut = pending.rfind(SYNC_END)
        if cut < 0:
            continue
        cut += len(SYNC_END)
        before = len(emulator.frames)
        emulator.feed(pending[:cut])
        pending = pending[cut:]
        times += [moment] * (len(emulator.frames) - before)
    return capture, emulator.frames, times


class Timeline:
    """When things happen, in seconds of video."""

    def __init__(self, work, capture, grids, times):
        self.offset = RECORDING - capture["start"]
        lines = json.loads((work / "timeline.json").read_text())
        self.line = [(NARRATION + line["start"], NARRATION + line["end"]) for line in lines]
        # Keys: one badge for presses of the same key in quick succession.
        self.badges = []
        for moment, label in capture["keys"]:
            moment += self.offset
            if self.badges and self.badges[-1][0] == label and moment - self.badges[-1][1][-1] < 0.6:
                self.badges[-1][1].append(moment)
            else:
                self.badges.append((label, [moment]))
        presses = [(label, moments[0]) for label, moments in self.badges]
        returns = [moment for label, moment in presses if label == "return"]
        self.space = next(moment for label, moment in presses if label == "space")
        self.consented = next(moment for label, moment in presses if label == "Y")
        self.naming = next(moment for label, moment in presses if label == "N")
        self.note_opened, self.note_added = returns[0], returns[1]
        self.stop = next(moment for label, moment in presses if label == "Q")

        def first(found):
            return next(moment + self.offset for grid, moment in zip(grids, times) if found(grid))

        self.identified = first(lambda grid: "Room 1" in screen_text(grid, range(3, 36), slice(34, 120)))
        self.saved = first(lambda grid: "new recording" in screen_text(grid, range(len(grid)), slice(None)))
        # The last line, saying the name, plays over the end card.
        self.closing = self.saved + 5.1
        self.closing_line = lines[-1]
        self.duration = self.closing + (lines[-1]["end"] - lines[-1]["start"]) + 1.3

        line, saved = self.line, self.saved
        self.captions = [
            (self.space - 0.15, self.consented + 0.55, "Confirms consent before recording"),
            (line[0][0] + 0.4, line[0][1] + 0.1, "Live transcription, right on your Mac"),
            (line[1][0], line[1][1] + 0.1, "Runs in your terminal · 100% private and local"),
            (line[2][0], line[2][1] + 0.13, "Never saves audio"),
            (line[3][0], line[3][1] + 0.2, "Open source"),
            (self.identified + 0.1, line[4][1] + 0.25, "Speaker identification"),
            (line[5][0] + 0.05, line[6][0] + 1.95, "Name the speakers"),
            (line[6][0] + 2.15, self.note_added + 0.25, "Inline notes"),
            (self.note_added + 0.45, saved + 0.8, "Saved as Markdown"),
        ]
        # The camera: (time, x, y, width, yaw, pitch). x and y are the point it looks at, in pixels
        # of the window image (cell (column, row) starts at 36 + 27 column, 108 + 57 row); width is
        # how many of those pixels fill the frame. Yaw and pitch turn the window, in degrees.
        self.camera = [
            (1.0, 1656, 1400, 9000, -26, 20),                         # flying in
            (self.space + 0.2, 1690, 1300, 5200, -3, 2),              # the whole window
            (self.consented - 0.1, 1950, 1800, 3500, 0, 0),           # the consent question
            (self.consented + 0.3, 1950, 1800, 3450, 0, 0),
            (self.consented + 1.6, 2115, 660, 2650, 0, 0),            # the words, as they arrive
            (line[0][1] + 0.06, 2115, 670, 2550, 1, -0.5),
            (line[1][0] + 1.0, 1656, 1260, 4950, -5, 3),              # "runs in your terminal"
            (line[1][1] - 0.25, 1656, 1240, 4750, -3, 2),
            (line[2][0] + 0.4, 1640, 860, 3400, 0, 0.5),              # "never saves audio", by the privacy list
            (line[2][1] + 0.08, 1640, 860, 3350, 0, 0),
            (line[3][0] + 0.83, 2080, 690, 2500, 0, 0),
            (self.identified, 2080, 690, 2400, 0, 0),                 # the speakers, told apart
            (self.identified + 1.2, 1656, 740, 3500, -2, 1),
            (line[5][0], 1560, 760, 3150, -3, 2),
            (self.naming - 0.45, 2000, 1750, 3300, 0, 0),
            (self.naming + 0.35, 2115, 1950, 2800, 0, 0),             # naming them
            (self.naming + 1.35, 2115, 1950, 2800, 0, 0),
            (self.naming + 2.55, 1656, 760, 3500, -1, 1),             # the names everywhere
            (self.note_opened - 0.7, 1760, 900, 3350, 0, 0),
            (self.note_opened + 0.4, 2115, 1900, 2850, 0, 0),         # a note, typed, then in the transcript
            (self.stop - 0.8, 2115, 1920, 2950, 0, 0),
            (self.stop + 0.3, 1656, 1260, 4900, 0, 0),                # stop, keep the names, saved
            (saved + 0.2, 1650, 1950, 3300, 0, 0),
            (saved + 1.1, 1650, 1950, 3300, 0, 0),
            (saved + 2.2, 3050, 1260, 5800, 20, 4),                   # aside, for the minutes file
            (saved + 4.9, 3250, 1260, 6200, 25, 6),
            (saved + 5.9, 3400, 1300, 8500, 34, 10),
        ]

    def view(self, t):
        points = self.camera
        if t <= points[0][0]:
            return points[0][1:]
        for a, b in zip(points, points[1:]):
            if t <= b[0]:
                k = smooth((t - a[0]) / (b[0] - a[0]))
                x, y = a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k
                width = math.exp(math.log(a[3]) + (math.log(b[3]) - math.log(a[3])) * k)
                return x, y, width, a[4] + (b[4] - a[4]) * k, a[5] + (b[5] - a[5]) * k
        return points[-1][1:]

    def window_alpha(self, t):
        return ramp(t, 0.95, 1.5) * (1 - ramp(t, self.saved + 4.75, self.saved + 5.35))


FOCAL = (W / 2) / math.tan(math.radians(30) / 2)  # a 30° lens


def homography(x, y, width, yaw, pitch):
    """Maps window-image pixels to output pixels, for a camera looking at (x, y)."""
    distance = FOCAL * width / W
    a, b = math.radians(yaw), math.radians(pitch)
    turn = np.array([[math.cos(a), 0, math.sin(a)], [0, 1, 0], [-math.sin(a), 0, math.cos(a)]])
    tilt = np.array([[1, 0, 0], [0, math.cos(b), -math.sin(b)], [0, math.sin(b), math.cos(b)]])
    world_to_camera = (turn @ tilt).T
    shift = -world_to_camera @ np.array([x, y, 0.0]) + np.array([0, 0, distance])
    lens = np.array([[FOCAL, 0, W / 2], [0, FOCAL, H / 2], [0, 0, 1]])
    return lens @ np.column_stack([world_to_camera[:, 0], world_to_camera[:, 1], shift])


# ---------------------------------------------------------------- drawing helpers

def supersampled(size, draw_at, factor=4):
    """An RGBA image of `size`, drawn by `draw_at(draw, factor)` at `factor` times and reduced."""
    big = Image.new("RGBA", (size[0] * factor, size[1] * factor), (0, 0, 0, 0))
    draw_at(ImageDraw.Draw(big), factor)
    return big.resize(size, Image.LANCZOS)


def asterisk(size, color, stroke):
    """The ✻ mark, `size` pixels across."""
    def draw_at(draw, f):
        c, r = size * f / 2, size * f / 2 - stroke * f
        for k in range(6):
            angle = math.pi * k / 6 + math.pi / 2
            dx, dy = r * math.cos(angle), r * math.sin(angle)
            draw.line([(c - dx, c - dy), (c + dx, c + dy)], fill=color + (255,), width=round(stroke * f))
        for k in range(12):  # round ends
            angle = math.pi * k / 6 + math.pi / 2
            px, py = c + r * math.cos(angle), c + r * math.sin(angle)
            draw.ellipse([px - stroke * f / 2, py - stroke * f / 2, px + stroke * f / 2, py + stroke * f / 2],
                         fill=color + (255,))
    return supersampled((size, size), draw_at)


def rounded_mask(size, radius, factor=4):
    big = Image.new("L", (size[0] * factor, size[1] * factor), 0)
    ImageDraw.Draw(big).rounded_rectangle([0, 0, size[0] * factor - 1, size[1] * factor - 1], radius * factor, fill=255)
    return big.resize(size, Image.LANCZOS)


def shadowed(image, radius, blur, offset, opacity, margin):
    """`image` (RGBA) with rounded corners and a soft shadow, on a transparent canvas `margin` wider."""
    w, h = image.size
    mask = rounded_mask((w, h), radius)
    canvas = Image.new("RGBA", (w + 2 * margin, h + 2 * margin), (0, 0, 0, 0))
    shadow = Image.new("L", canvas.size, 0)
    shadow.paste(mask.point(lambda v: int(v * opacity)), (margin, margin + offset))
    canvas.putalpha(shadow.filter(ImageFilter.GaussianBlur(blur)))
    body = image.copy()
    body.putalpha(Image.fromarray((np.asarray(mask, np.float32) * np.asarray(image.getchannel("A"), np.float32)
                                   / 255).astype(np.uint8)))
    canvas.alpha_composite(body, (margin, margin))
    return canvas


# ---------------------------------------------------------------- the terminal window

TITLE = "mmm — 120×42"
MARGIN = 340  # around the window in the stage image, for its shadow
RADIUS = 30


class Window:
    """The captured screens as a macOS window with a shadow, premultiplied, ready for the camera."""

    def __init__(self):
        terminal_render.set_scale(SCALE)
        terminal_render.TERMINAL_BACKGROUND = PANEL  # the padding matches the app's background
        self.title_font = sf(39, 590)
        self.base = None
        self.cache = {}

    def _setup(self, size):
        w, h = size
        self.mask = rounded_mask(size, RADIUS)
        canvas = (w + 2 * MARGIN, h + 2 * MARGIN)
        wide, close = Image.new("L", canvas, 0), Image.new("L", canvas, 0)
        wide.paste(self.mask, (MARGIN, MARGIN + 60))
        close.paste(self.mask, (MARGIN, MARGIN + 12))
        shadow = (np.asarray(wide.filter(ImageFilter.GaussianBlur(70)), np.float32) * 0.62
                  + np.asarray(close.filter(ImageFilter.GaussianBlur(14)), np.float32) * 0.35)
        self.base = Image.new("RGBA", canvas, (0, 0, 0, 0))
        self.base.putalpha(Image.fromarray(np.clip(shadow, 0, 255).astype(np.uint8)))

    def terminal(self, grid):
        image = terminal_render.render(grid, title="")
        draw = ImageDraw.Draw(image, "RGBA")
        title_h, s = terminal_render.TITLE_H, SCALE
        draw.rectangle([0, 0, image.width, title_h - 1], fill=(41, 41, 39))
        draw.line([(0, title_h - 2), (image.width, title_h - 2)], fill=(17, 17, 16), width=3)
        for index, dot in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
            draw.ellipse([(14 + index * 20) * s, 9 * s, (26 + index * 20) * s, 21 * s], fill=dot)
        draw.text((image.width / 2, title_h / 2), TITLE, font=self.title_font, fill=(160, 158, 152), anchor="mm")
        draw.rounded_rectangle([1, 1, image.width - 2, image.height - 2], RADIUS, outline=(255, 255, 255, 30),
                               width=3)
        return image

    def stage(self, index, grid, glint=None):
        """Mipmap levels of the window and its shadow (RGBa); `glint` (0–1) sweeps a light across it."""
        key = (index, glint)
        if key in self.cache:
            return self.cache[key]
        term = self.terminal(grid)
        if self.base is None:
            self._setup(term.size)
        if glint is not None:
            w, h = term.size
            ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
            centre = -900 + glint * (w + 2400)
            band = np.exp(-(((xs + 0.45 * ys) - centre) / 150) ** 2) * math.sin(math.pi * glint) * 0.11
            del xs, ys
            rgb = np.asarray(term, np.float32) + band[..., None] * np.array([255, 226, 205], np.float32)
            term = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8))
            del rgb, band
        term = term.convert("RGBA")
        term.putalpha(self.mask)
        stage = self.base.copy()
        stage.alpha_composite(term, (MARGIN, MARGIN))
        levels = [stage.convert("RGBa")]
        if len(self.cache) > 3:
            self.cache.clear()
        self.cache[key] = levels
        return levels

    @staticmethod
    def level(levels, n):
        while len(levels) <= n:
            levels.append(levels[-1].reduce(2))
        return levels[n]


def project(levels, view):
    """The window seen through the camera: a premultiplied float array (H, W, 4)."""
    to_output = homography(*view) @ np.array([[1, 0, -MARGIN], [0, 1, -MARGIN], [0, 0, 1]], float)
    back = np.linalg.inv(to_output)
    # How many stage pixels an output pixel covers mid-frame picks the mipmap level (blending two).
    points = np.array([[W / 2, H / 2, 1], [W / 2 + 1, H / 2, 1], [W / 2, H / 2 + 1, 1]]).T
    mapped = back @ points
    mapped = mapped[:2] / mapped[2]
    jacobian = np.column_stack([mapped[:, 1] - mapped[:, 0], mapped[:, 2] - mapped[:, 0]])
    detail = max(0.0, math.log2(max(math.sqrt(abs(np.linalg.det(jacobian))), 1e-6)) - 0.35)
    low = min(int(detail), 4)
    blend = 0.0 if low >= 4 else detail - low

    def sample(n):
        inverse = np.linalg.inv(to_output @ np.diag([2.0 ** n, 2.0 ** n, 1.0]))
        coefficients = tuple((inverse / inverse[2, 2]).flatten()[:8])
        image = Window.level(levels, n).transform((W, H), Image.PERSPECTIVE, coefficients, Image.BICUBIC)
        return np.asarray(image, np.float32)

    result = sample(low)
    if blend > 0.03:
        result = result * (1 - blend) + sample(low + 1) * blend
    return result


# ---------------------------------------------------------------- the set

def backdrop():
    """A dark, faintly warm background, a little larger than the frame so it can drift."""
    pad = 120
    h, w = H + 2 * pad, W + 2 * pad
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    top, bottom = np.array([24, 24, 27], np.float32), np.array([11, 11, 13], np.float32)
    image = top + (bottom - top) * (ys / h)[..., None]

    def glow(cx, cy, radius, color, strength):
        return np.exp(-((xs - cx) ** 2 + (ys - cy) ** 2) / radius ** 2)[..., None] * np.array(color, np.float32) * strength

    image += glow(w * 0.22, h * 0.95, 900, ACCENT, 0.16)
    image += glow(w * 0.86, h * 0.05, 800, LAVENDER, 0.09)
    image += np.random.default_rng(7).uniform(-1.2, 1.2, image.shape[:2])[..., None]  # against banding
    return np.clip(image, 0, 255), pad


def wordmark(layer, draw, centre_y, size):
    """✻ Mini Meeting Minutes, centred."""
    font = sf(size, 700)
    title = "Mini Meeting Minutes"
    mark = asterisk(int(size * 0.77), ACCENT, size * 0.075)
    gap = int(size * 0.3)
    x = (W - (mark.width + gap + font.getlength(title))) / 2
    layer.alpha_composite(mark, (int(x), int(centre_y - mark.height / 2)))
    draw.text((x + mark.width + gap, centre_y), title, font=font, fill=INK, anchor="lm")


def title_card():
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    wordmark(layer, draw, H / 2 - 60, 104)
    draw.text((W / 2, H / 2 + 50), "Live meeting transcripts, right in your terminal", font=sf(40), fill=MUTED,
              anchor="mm")
    box = layer.getbbox()
    return layer.crop(box), box[:2]


def end_card():
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    wordmark(layer, draw, H / 2 - 110, 96)
    font, dot = sf(42, 500), "  ·  "
    pillars = ["Private", "Local", "Open source", "Never saves audio"]
    x = (W - sum(font.getlength(p) for p in pillars) - font.getlength(dot) * (len(pillars) - 1)) / 2
    for index, pillar in enumerate(pillars):
        draw.text((x, H / 2 + 20), pillar, font=font, fill=INK, anchor="lm")
        x += font.getlength(pillar)
        if index < len(pillars) - 1:
            draw.text((x, H / 2 + 20), dot, font=font, fill=ACCENT, anchor="lm")
            x += font.getlength(dot)
    draw.text((W / 2, H / 2 + 118), "github.com/dudgeon/mini-meeting-minutes", font=sf_mono(32, 450), fill=MUTED,
              anchor="mm")
    return layer


def caption_chip(text):
    font = sf(31, 600)
    height, pad, dot, margin = 64, 26, 12, 30
    width = int(pad + dot + 16 + font.getlength(text) + pad)

    def draw_at(draw, f):
        draw.rounded_rectangle([margin * f, margin * f, (margin + width) * f, (margin + height) * f], height * f / 2,
                               fill=(20, 20, 19, 222), outline=(255, 255, 255, 30), width=f * 2)
        cx, cy = (margin + pad + dot / 2) * f, (margin + height / 2) * f
        draw.ellipse([cx - dot * f / 2, cy - dot * f / 2, cx + dot * f / 2, cy + dot * f / 2], fill=ACCENT + (255,))
    chip = supersampled((width + 2 * margin, height + 2 * margin), draw_at)
    out = Image.new("RGBA", chip.size, (0, 0, 0, 0))
    shadow = Image.new("RGBA", chip.size, (0, 0, 0, 0))
    shadow.putalpha(chip.getchannel("A").point(lambda v: int(v * 0.5)).filter(ImageFilter.GaussianBlur(12)))
    out.alpha_composite(shadow, (0, 6))
    out.alpha_composite(chip)
    ImageDraw.Draw(out).text((margin + pad + dot + 16, margin + height / 2 + 1), text, font=font, fill=INK, anchor="lm")
    return out, margin


def keycap(label, pressed, glow):
    """A key, `pressed` 0–1 (how far down), ringed in the accent color by `glow` 0–1."""
    font = sf(30, 600)
    height, margin = 76, 40
    width = max(height, int(font.getlength(label) + 48))
    travel = 6 * pressed

    def draw_at(draw, f):
        x0, y0 = margin * f, margin * f
        for ring in range(3 if glow > 0 else 0):
            grow = (6 + ring * 5) * f
            draw.rounded_rectangle([x0 - grow, y0 - grow + travel * f, x0 + width * f + grow,
                                    y0 + (height + 8) * f + grow], (16 + ring * 5) * f,
                                   outline=ACCENT + (int(150 * glow / (ring + 1)),), width=3 * f)
        draw.rounded_rectangle([x0, y0 + 8 * f, x0 + width * f, y0 + (height + 8) * f], 16 * f,
                               fill=(150, 148, 142, 255))
        draw.rounded_rectangle([x0, y0 + travel * f, x0 + width * f, y0 + (height + travel) * f], 16 * f,
                               fill=(242, 241, 237, 255), outline=(255, 255, 255, 255), width=f)
    cap = supersampled((width + 2 * margin, height + 8 + 2 * margin), draw_at)
    out = Image.new("RGBA", cap.size, (0, 0, 0, 0))
    shadow = Image.new("RGBA", cap.size, (0, 0, 0, 0))
    shadow.putalpha(cap.getchannel("A").point(lambda v: int(v * 0.45)).filter(ImageFilter.GaussianBlur(14)))
    out.alpha_composite(shadow, (0, 8))
    out.alpha_composite(cap)
    ImageDraw.Draw(out).text((margin + width / 2, margin + travel + height / 2 + 1), label, font=font,
                             fill=(38, 38, 36), anchor="mm")
    return out, margin, width


# ---------------------------------------------------------------- the saved minutes

PAPER, PAPER_INK, PAPER_MUTED = (250, 249, 246), (44, 43, 40), (163, 160, 153)
PAPER_ACCENT, PAPER_LAVENDER, PAPER_GREEN = (196, 96, 60), (122, 88, 176), (72, 120, 60)
CARD_W, CARD_H, CARD_TITLE = 820, 900, 50


def styled_lines(markdown):
    """Each line of the minutes as (char, color, bold) cells, colored the way an editor would."""
    lines = []
    speakers = {}
    for raw in markdown.rstrip("\n").split("\n"):
        text = raw.rstrip()
        cells = []
        quote = text.startswith(">")
        if text.startswith("# "):
            lines.append([("#", PAPER_MUTED, True), (" ", PAPER_INK, False)]
                         + [(c, PAPER_ACCENT, True) for c in text[2:]])
            continue
        if text == "---":
            lines.append([(c, PAPER_MUTED, False) for c in text])
            continue
        if quote:
            cells.append((">", PAPER_GREEN, True))
            text = text[1:]
        elif text.startswith("- "):
            cells.append(("-", PAPER_MUTED, False))
            text = text[1:]
        turn = "·" in text and text.startswith("**")  # **Name** · 00:00:00
        for index, part in enumerate(text.split("**")):
            bold = index % 2 == 1
            if index > 0:
                cells += [("*", PAPER_MUTED, False)] * 2
            color = PAPER_GREEN if quote else PAPER_INK
            if bold and turn and index == 1:
                color = speakers.setdefault(part, [PAPER_ACCENT, PAPER_LAVENDER][len(speakers) % 2])
            for char in part:
                faint = turn and not bold
                cells.append((char, PAPER_MUTED if faint else color, bold))
        lines.append(cells)
    return lines


def wrapped(cells, columns):
    if len(cells) <= columns:
        return [cells]
    indent = 2 if cells[0][0] in "->" else 0
    rows = []
    while len(cells) > columns:
        cut = columns
        while cut > columns // 2 and cells[cut][0] != " ":
            cut -= 1
        rows.append(cells[:cut])
        cells = [(" ", PAPER_INK, False)] * indent + cells[cut + 1:]
    return rows + [cells]


class Minutes:
    """The saved minutes, in an editor window that scrolls."""

    def __init__(self, path):
        regular, bold = ImageFont.truetype(MENLO, 17, index=0), ImageFont.truetype(MENLO, 17, index=1)
        advance, line, pad_x, pad_y = regular.getlength("M"), 25, 30, 22
        columns = int((CARD_W - 2 * pad_x) / advance)
        rows = [row for cells in styled_lines(path.read_text()) for row in wrapped(cells, columns)]
        self.content = Image.new("RGBA", (CARD_W, pad_y * 2 + line * len(rows)), PAPER + (255,))
        draw = ImageDraw.Draw(self.content)
        for r, cells in enumerate(rows):
            for c, (char, color, is_bold) in enumerate(cells):
                if char != " ":
                    draw.text((pad_x + c * advance, pad_y + r * line + line / 2), char,
                              font=bold if is_bold else regular, fill=color, anchor="lm")
        self.chrome = Image.new("RGBA", (CARD_W, CARD_H), PAPER + (255,))
        draw = ImageDraw.Draw(self.chrome)
        draw.rectangle([0, 0, CARD_W, CARD_TITLE - 1], fill=(236, 234, 229))
        draw.line([(0, CARD_TITLE - 1), (CARD_W, CARD_TITLE - 1)], fill=(214, 211, 204), width=1)
        for index, dot in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
            draw.ellipse([20 + index * 22, 18, 34 + index * 22, 32], fill=dot)
        draw.text((CARD_W / 2, CARD_TITLE / 2), path.name, font=sf(18, 590), fill=(90, 88, 84), anchor="mm")
        self.max_scroll = max(0, self.content.height - (CARD_H - CARD_TITLE))
        self.cache = {}

    def frame(self, scroll):
        scroll = int(round(scroll))
        if scroll not in self.cache:
            card = self.chrome.copy()
            card.paste(self.content.crop((0, scroll, CARD_W, scroll + CARD_H - CARD_TITLE)), (0, CARD_TITLE))
            self.cache = {scroll: shadowed(card, 14, 26, 18, 0.55, 70)}
        return self.cache[scroll]


# ---------------------------------------------------------------- one frame

class Composer:
    def __init__(self, work, span=None):
        self.capture, self.grids, self.times = load_capture(work)
        self.timeline = Timeline(work, self.capture, self.grids, self.times)
        if span:  # keep only the screens this part of the video shows
            first, last = self.capture_index(span[0]), self.capture_index(span[1])
            self.grids = [grid if first <= i <= last else None for i, grid in enumerate(self.grids)]
        self.window = Window()
        self.backdrop, self.pad = backdrop()
        self.title = title_card()
        self.end = end_card()
        self.chips = {text: caption_chip(text) for _, _, text in self.timeline.captions}
        self.minutes = Minutes(next((work / "Minutes").glob("*.md")))

    def capture_index(self, t):
        moment = t - self.timeline.offset
        return max(0, min(len(self.times) - 1, bisect.bisect_right(self.times, moment) - 1))

    def movement(self, t):
        """How far, in output pixels, the picture moves in one frame at `t`."""
        view = self.timeline.view
        move = homography(*view(t + 0.5 / FPS)) @ np.linalg.inv(homography(*view(t - 0.5 / FPS)))
        corners = np.array([[0, 0, 1], [W, 0, 1], [0, H, 1], [W, H, 1], [W / 2, H / 2, 1]], float).T
        moved = move @ corners
        return float(np.max(np.hypot(*(moved[:2] / moved[2] - corners[:2]))))

    def render(self, t):
        timeline = self.timeline
        index = self.capture_index(t)
        glint = None
        if timeline.identified <= t <= timeline.identified + 0.65:
            glint = round((t - timeline.identified) / 0.65, 3)
        x, y = timeline.view(t)[:2]
        dx = int(np.clip(-(x - 1656) * 0.04, -self.pad, self.pad))  # the background drifts a little
        dy = int(np.clip(-(y - 1260) * 0.04, -self.pad, self.pad))
        frame = self.backdrop[self.pad + dy:self.pad + dy + H, self.pad + dx:self.pad + dx + W].copy()
        alpha = timeline.window_alpha(t)
        if alpha > 0:
            levels = self.window.stage(index, self.grids[index], glint)
            move = self.movement(t)
            samples = 1 if move < 5 else min(5, 1 + math.ceil(move / 7))  # motion blur for fast moves
            offsets = [(k + 0.5) / samples - 0.5 for k in range(samples)]
            layer = sum(project(levels, timeline.view(t + o * 0.5 / FPS)) for o in offsets) / samples
            frame = frame * (1 - layer[..., 3:] * alpha / 255) + layer[..., :3] * alpha
        image = Image.fromarray(np.clip(frame, 0, 255).astype(np.uint8)).convert("RGBA")
        self.overlays(image, t)
        fade = ramp(t, 0.0, 0.45) * (1 - ramp(t, timeline.duration - 0.6, timeline.duration - 0.05))
        return np.clip(np.asarray(image.convert("RGB"), np.float32) * fade, 0, 255).astype(np.uint8)

    def overlays(self, image, t):
        timeline, saved = self.timeline, self.timeline.saved
        # The title rises and shrinks as the window arrives, then fades.
        a = shown(t, 0.0, 1.75, 0.5, 0.45)
        if a > 0:
            k = smooth((t - 0.55) / 0.7)
            layer, (_, top) = self.title
            scale = 1 - 0.42 * k
            centre_y = (1 - k) * (top + layer.height / 2) + k * 118
            if scale < 0.999:
                layer = layer.resize((round(layer.width * scale), round(layer.height * scale)), Image.LANCZOS)
            self.paste(image, layer, a, (W / 2 - layer.width / 2, centre_y - layer.height / 2))
        # The minutes file slides in beside the window, scrolls, and leaves.
        arrive, leave = ease_out((t - saved - 1.15) / 0.95), ramp(t, saved + 4.7, saved + 5.3)
        if arrive > 0 and leave < 1:
            card = self.minutes.frame(self.minutes.max_scroll * ramp(t, saved + 2.5, saved + 4.7))
            x = 1030 - 70 + (1 - arrive) * 1100 + leave * 260
            y = (H - CARD_H) / 2 - 70 + (1 - arrive) * 40
            self.paste(image, card, min(arrive * 1.6, 1) * (1 - leave), (x, y))
        a = ramp(t, saved + 5.25, saved + 5.9)
        if a > 0:
            self.paste(image, self.end, a, (0, 18 * (1 - a)))
        for start, end, text in timeline.captions:
            a = shown(t, start, end, 0.35, 0.25)
            if a > 0:
                chip, margin = self.chips[text]
                self.paste(image, chip, a, (64 - margin, H - 128 - margin + 14 * (1 - a)))
        for label, presses in timeline.badges:
            a = shown(t, presses[0] - 0.3, presses[-1] + 1.15, 0.2, 0.3)
            if a <= 0:
                continue
            pressed = max([0.0] + [1 - abs(t - (p + 0.06)) / 0.14 for p in presses if p - 0.02 <= t <= p + 0.2])
            glow = max([0.0] + [1 - (t - p) / 0.7 for p in presses if t >= p])
            cap, margin, width = keycap(label, pressed, glow)
            self.paste(image, cap, a, (W - 64 - width - margin, H - 148 - margin + 10 * (1 - a)))

    @staticmethod
    def paste(image, layer, alpha, at):
        if alpha < 1:
            layer = layer.copy()
            layer.putalpha(layer.getchannel("A").point(lambda v: int(v * alpha)))
        x, y = int(round(at[0])), int(round(at[1]))
        left, top = max(0, -x), max(0, -y)
        right, bottom = min(layer.width, image.width - x), min(layer.height, image.height - y)
        if right > left and bottom > top:
            image.alpha_composite(layer.crop((left, top, right, bottom)), (x + left, y + top))


# ---------------------------------------------------------------- output

def encode(job):
    work, first, last, path = job
    composer = Composer(work, (first / FPS, last / FPS))
    command = [imageio_ffmpeg.get_ffmpeg_exe(), "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
               "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
               "-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p", "-c:v", "libx264", "-preset", "slow",
               "-crf", "16", "-tune", "animation", "-threads", "2", "-colorspace", "bt709", "-color_primaries", "bt709",
               "-color_trc", "bt709", "-color_range", "tv", str(path)]
    process = subprocess.Popen(command, stdin=subprocess.PIPE)
    for number in range(first, last):
        process.stdin.write(composer.render(number / FPS).tobytes())
    process.stdin.close()
    if process.wait() != 0:
        raise RuntimeError(f"ffmpeg failed on {path}")
    return path


def soundtrack(work, timeline, path):
    """The narration, with its last line moved to the end card."""
    with wave.open(str(work / "narration.wav"), "rb") as handle:
        rate = handle.getframerate()
        voice = np.frombuffer(handle.readframes(handle.getnframes()), np.int16).astype(np.float32)
    closing = timeline.closing_line["start"]
    cut = int((closing - 1.2) * rate)  # in the pause before the last line
    track = np.zeros(int(timeline.duration * rate), np.float32)
    for clip, at in [(voice[:cut], NARRATION), (voice[cut:], timeline.closing - (closing - cut / rate))]:
        start = int(round(at * rate))
        end = min(len(track), start + len(clip))
        track[start:end] += clip[:end - start]
    stereo = np.repeat(np.clip(track, -32768, 32767).astype(np.int16)[:, None], 2, axis=1)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(2)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        handle.writeframes(stereo.tobytes())


def render_video(work, out, workers):
    capture, grids, times = load_capture(work)
    timeline = Timeline(work, capture, grids, times)
    del capture, grids, times
    total = int(round(timeline.duration * FPS))
    bounds = [round(total * k / workers) for k in range(workers + 1)]
    jobs = [(work, bounds[k], bounds[k + 1], work / f"part-{k:02d}.mp4") for k in range(workers)]
    with multiprocessing.get_context("spawn").Pool(workers) as pool:
        parts = pool.map(encode, jobs, chunksize=1)
    listing = work / "parts.txt"
    listing.write_text("".join(f"file '{p}'\n" for p in parts))
    audio = work / "soundtrack.wav"
    soundtrack(work, timeline, audio)
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), "-v", "error", "-y", "-f", "concat", "-safe", "0",
                    "-i", str(listing), "-i", str(audio), "-map", "0:v", "-map", "1:a", "-c:v", "copy",
                    "-bsf:v", "h264_metadata=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1",
                    "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "-shortest", str(out)], check=True)
    for path in [audio, listing, *parts]:
        path.unlink()
    return timeline.duration


def render_stills(work, moments, folder):
    composer = Composer(work)
    folder.mkdir(parents=True, exist_ok=True)
    for moment in moments:
        Image.fromarray(composer.render(moment)).save(folder / f"still-{moment:05.2f}.png")
