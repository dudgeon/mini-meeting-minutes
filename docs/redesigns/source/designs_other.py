"""Four designs that go somewhere else entirely."""
import math

from PIL import Image, ImageDraw

from data import *
from tuikit import Grid, W, H, mix, pixel_text, rgb, wrap

BODONI = "/System/Library/Fonts/Supplemental/Bodoni 72.ttc"
SILOM = "/System/Library/Fonts/Supplemental/Silom.ttf"


def broadsheet():
    """A newspaper: masthead, dateline, columns of verbatim statements, blacked-out redactions."""
    paper, ink, ink2, faint, red = "#f2ecdf", "#1c1a17", "#5a554c", "#b9b1a1", "#a4161a"
    g = Grid(paper, ink)
    bars = lambda kind, raw: ("█" * len(raw), ink, None, None)

    g.text(2, 0, "VOL. I  ·  NO. 14", ink2)
    g.ctext(0, W, 0, "TUESDAY, SEPTEMBER 29, 2026", ink2, None, "bold")
    g.rtext(117, 0, "LATE EDITION  ·  FREE", ink2)
    g.hline(0, 1, W, ink)
    masthead = pixel_text("The Minutes", BODONI, 15, ink, index=2)
    g.pixels((W - masthead.width) // 2, 2, masthead)
    g.hline(0, 9, W, ink, "═")
    g.ctext(0, W, 10, "PLANNING REVIEW  ·  RECORDED ON THIS MAC  ·  14 MIN 32 SEC  ·  NO AUDIO RETAINED", ink2)
    g.hline(0, 11, W, ink)
    g.ctext(0, W, 12, "IN THEIR OWN WORDS: THE PLANNING REVIEW, AS IT WAS SAID", ink, None, "bold")

    top, bottom = 14, 36
    columns = [2, 41]
    g.vline(39, top, bottom - top + 1, faint)
    g.vline(78, top, bottom - top + 1, faint)

    lines = []
    for key, time, said in LINES:
        for index, line in enumerate(wrap(f"{LABEL[key].upper()} — {said} ({time})", 35)):
            lines.append((index == 0, line, False))
        lines.append((False, "", False))
    key, time, said = PENDING
    for index, line in enumerate(wrap(f"{LABEL[key].upper()} — {said}", 35)):
        lines.append((index == 0, line, True))
    rows = bottom - top + 1
    lines = lines[-2 * rows:]
    while not lines[0][0]:
        lines.pop(0)
    for index, (lead, line, live) in enumerate(lines):
        x, y = columns[index // rows], top + index % rows
        color = ink2 if live else ink
        if lead:
            label, rest = line.split(" — ", 1)
            g.text(x, y, label, ink, None, "bold")
            rich(g, x + len(label), y, " — " + rest, color, None, bars)
        else:
            rich(g, x, y, line, color, None, bars)
    last = len(lines) - 1
    g.text(columns[last // rows] + len(lines[-1][1]) + 1, top + last % rows, "● LIVE", red, None, "bold")

    def sidebox(y, h, title):
        g.box(80, y, 38, h, ink, "light")
        g.ctext(80, 38, y, f" {title} ", ink, None, "bold")

    sidebox(top, 8, "WHO SPOKE")
    for index, (key, label, channel, share, talk) in enumerate(SPEAKERS):
        y = top + 2 + index
        g.text(82, y, label, ink)
        filled = round(share / 0.4 * 14)
        g.text(92, y, "█" * filled, ink)
        g.text(92 + filled, y, "░" * (14 - filled), faint)
        g.rtext(115, y, f"{round(share * 100)}%", ink2)
    g.text(82, top + 6, "Share of talking time", ink2, None, "italic")

    sidebox(23, 6, "CONDITIONS")
    for index, (label, level, seed) in enumerate([("Microphone", LEVELS["mic"], 1), ("System audio", LEVELS["sys"], 2)]):
        g.text(82, 24 + index, label, ink)
        bars_now = spectrum(12, seed, level + 0.3)
        g.text(96, 24 + index, "".join(" ▁▂▃▄▅▆▇"[min(7, int(v * 8))] for v in bars_now), ink)
        g.rtext(115, 24 + index, "live", red)
    g.text(82, 26, f"{BUFFER} seconds of audio in memory,", ink2, None, "italic")
    g.text(82, 27, "then gone. Echo removed.", ink2, None, "italic")

    sidebox(30, 7, "INDEX")
    for index, (label, key) in enumerate([("Pause", "SPACE"), ("Stop & print", "Q"), ("Name the speakers", "N"),
                                          ("Next edition (skin)", "K"), ("All shortcuts", "?")]):
        y = 31 + index
        g.text(82, y, label, ink)
        g.text(83 + len(label), y, "." * (31 - len(label) - len(key)), faint)
        g.rtext(115, y, key, ink, None, "bold")

    g.hline(0, 37, W, ink)
    g.text(2, 38, "● RECORDING  14:32", red, None, "bold")
    g.ctext(0, W, 38, "Blacked out so far: 1 name · 1 email · 1 phone number", ink2, None, "italic")
    g.rtext(117, 38, "PAGE A1", ink2)
    return g


def tapedeck():
    """A Braun-style cassette recorder: VU meters, a cassette window, piano-key transport."""
    body, panel, dark, mid, orange, green, cream, black = (
        "#e7e4dd", "#d7d3c9", "#2a2a28", "#77746c", "#ee5a24", "#5e9e5a", "#f6f0dc", "#151514")
    g = Grid(body, dark)

    g.text(2, 0, "mmm", dark, None, "bold")
    g.text(6, 0, "MM-1   CASSETTE MINUTES RECORDER", mid)
    g.rtext(117, 0, "POWER", mid)
    g.put(110, 0, "●", green)

    def meter(x, y, level, label):
        w, h = 27, 16
        face = Image.new("RGBA", (w, h), rgb(cream) + (255,))
        draw = ImageDraw.Draw(face)
        draw.rectangle([0, 0, w - 1, h - 1], outline=rgb(dark))
        pivot = (w // 2, h + 3)
        for step in range(0, 101, 5):
            angle = math.radians(150 - step * 1.2)
            r1, r2 = 13, 15 if step % 20 == 0 else 14
            color = rgb(orange) if step > 75 else rgb(dark)
            draw.line([(pivot[0] + r1 * math.cos(angle), pivot[1] - r1 * math.sin(angle)),
                       (pivot[0] + r2 * math.cos(angle), pivot[1] - r2 * math.sin(angle))], fill=color)
        angle = math.radians(150 - level * 120)
        draw.line([pivot, (pivot[0] + 15 * math.cos(angle), pivot[1] - 15 * math.sin(angle))], fill=rgb(black))
        g.pixels(x, y, face)
        g.text(x + 1, y, "-20", mid, cream)
        g.text(x + 12, y, "0", dark, cream, "bold")
        g.text(x + 22, y, "+3", orange, cream, "bold")
        g.ctext(x, w, y + 8, label, dark, None, "bold")

    meter(3, 2, LEVELS["mic"], "MIC")
    meter(32, 2, LEVELS["sys"], "SYSTEM")

    cw, ch = 56, 26
    cassette = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
    draw = ImageDraw.Draw(cassette)
    draw.rounded_rectangle([0, 0, cw - 1, ch - 1], 3, fill=rgb("#3b3b39"))
    draw.rectangle([4, 2, cw - 5, 9], fill=rgb(cream))
    draw.rectangle([4, 8, cw - 5, 9], fill=rgb(orange))
    draw.rounded_rectangle([12, 12, cw - 13, 22], 2, fill=rgb("#1b1b1a"))
    for cx, tape in [(19, 6), (36, 3)]:
        draw.ellipse([cx - tape, 17 - tape, cx + tape, 17 + tape], fill=rgb("#5b3a22"))
        draw.ellipse([cx - 2, 15, cx + 2, 19], fill=rgb("#e9e6df"))
        draw.point((cx, 17), fill=rgb("#1b1b1a"))
    draw.line([(19, 17 + 6), (36, 17 + 3)], fill=rgb("#5b3a22"))
    for sx, sy in [(2, 23), (cw - 3, 23), (2, 1), (cw - 3, 1)]:
        draw.point((sx, sy), fill=rgb("#9a9892"))
    g.pixels(61, 1, cassette)
    g.text(66, 2, "A", orange, cream, "bold")
    g.text(69, 2, "PLANNING REVIEW · 29.09.26", dark, cream, "bold")

    keys = [("● REC", True), ("❚❚ PAUSE", False), ("■ STOP", False), ("✎ LABEL", False), ("◐ THEME", False)]
    x = 3
    for label, pressed in keys:
        face = orange if pressed else "#f5f3ef"
        g.fill(x, 16, 13, 2, face)
        g.ctext(x, 13, 16, label, "#ffffff" if pressed else dark, face, "bold")
        g.hline(x, 18, 13, "#b95024" if pressed else "#c7c3b9", "▀", body)
        x += 15
    g.text(84, 16, "COUNTER", mid)
    for index, digit in enumerate("0872"):
        g.fill(93 + index * 3, 16, 2, 2, black)
        g.put(93 + index * 3, 16, digit, "#fafafa", black, "bold")
    g.text(106, 16, "RESET", mid)
    g.put(112, 16, "○", mid)

    g.fill(2, 20, 116, 17, cream)
    g.hline(2, 20, 116, orange, "▀", body)
    g.text(4, 21, "SIDE A — PLANNING REVIEW — RECORDING", orange, cream, "bold")
    g.rtext(115, 21, "J-CARD", mid, cream)
    token = lambda kind, raw: (raw, orange, cream, "bold")
    y = 23
    for key, time, said in LINES[-6:]:
        lines = wrap(said, 82)
        g.text(4, y, time, mid, cream)
        g.text(11, y, LABEL[key].upper(), dark, cream, "bold")
        for index, line in enumerate(lines):
            rich(g, 22, y + index, line, dark, cream, token)
        y += len(lines)
    key, time, said = PENDING
    g.put(2, y, "▶", orange, cream)
    g.text(4, y, time, orange, cream, "bold")
    g.text(11, y, LABEL[key].upper(), dark, cream, "bold")
    pending = wrap(said, 82)
    for index, line in enumerate(pending):
        g.text(22, y + index, line, mid, cream)
    g.put(23 + len(pending[-1]), y + len(pending) - 1, "▍", orange, cream)

    g.text(2, 38, "ECHO CANCEL", mid)
    g.put(14, 38, "●", green)
    g.text(16, 38, "ON    PII FILTER", mid)
    g.put(33, 38, "●", green)
    g.text(35, 38, "ON    AUDIO TO TAPE: NEVER — MINUTES ONLY", mid)
    g.rtext(117, 38, "SPACE pause · Q stop · N label", mid)
    return g


def pocket():
    """A handheld game console on its side: four shades of green, an RPG party and a dialogue box."""
    body, shade, groove, navy, frame, etched = "#cbc8c2", "#b7b3ac", "#9e9a93", "#2f2c4f", "#5d5c70", "#6b6782"
    s0, s1, s2, s3 = "#0f380f", "#306230", "#8bac0f", "#9bbc0f"  # darkest to lightest
    magenta, shine, deep, slate = "#9a2257", "#c2457d", "#6d1740", "#8f8b86"
    g = Grid(body, navy)

    g.text(3, 0, "◀OFF · REC▶", groove, None, "bold")
    g.hline(0, 1, W, shade, "▔")

    # The screen surround, with the rounded bottom-right corner.
    fx, fy, fw, fh = 19, 2, 82, 30
    surround = Image.new("RGBA", (fw, fh * 2), (0, 0, 0, 0))
    draw = ImageDraw.Draw(surround)
    draw.rounded_rectangle([0, 0, fw - 1, fh * 2 - 1], 2, fill=rgb(frame))
    corner = 14
    draw.rectangle([fw - corner, fh * 2 - corner, fw - 1, fh * 2 - 1], fill=(0, 0, 0, 0))
    draw.pieslice([fw - 2 * corner, fh * 2 - 2 * corner, fw - 1, fh * 2 - 1], 0, 90, fill=rgb(frame))
    g.pixels(fx, fy, surround)
    g.hline(26, 3, 12, magenta, "━", frame)
    g.text(39, 3, "DOT MATRIX WITH STEREO SOUND", "#d9d6e8", frame)
    g.hline(68, 3, 26, "#3c4ea0", "━", frame)
    g.put(22, 14, "●", "#ff2a3a", frame)
    g.text(21, 15, "REC", "#d9d6e8", frame)

    lx, ly, lw, lh = 26, 5, 68, 24
    g.fill(lx, ly, lw, lh, s3)
    g.pixels(lx + 1, ly + 1, pixel_text("MINUTES", SILOM, 10, s0))
    right = lx + lw - 2
    g.rtext(right, ly + 1, "● REC 14:32", s0, s3, "bold")
    g.rtext(right, ly + 2, "PLANNING REVIEW", s1, s3)
    for index, (label, level) in enumerate([("MIC", LEVELS["mic"]), ("SYS", LEVELS["sys"])]):
        lit = round(level * 6)
        g.rtext(right, ly + 3 + index, "■" * lit + "□" * (6 - lit), s0, s3)
        g.text(right - 9, ly + 3 + index, label, s1, s3)

    top = ly + 6
    g.box(lx + 1, top, lw - 2, 7, s0, "light", s3)
    g.text(lx + 3, top, " PARTY ", s0, s3, "bold")
    for index, (key, label, channel, share, talk) in enumerate(SPEAKERS):
        y = top + 1 + index
        g.text(lx + 3, y, label.upper(), s0, s3, "bold")
        g.text(lx + 14, y, f"LV{round(share * 40):>2}", s1, s3)
        g.text(lx + 20, y, "HP", s0, s3, "bold")
        filled = round(share / 0.4 * 20)
        g.text(lx + 23, y, "█" * filled, s0, s3)
        g.text(lx + 23 + filled, y, "█" * (20 - filled), s2, s3)
        g.text(lx + 45, y, talk, s0, s3)
        g.text(lx + 51, y, "ROOM" if channel == "room" else "CALL", s1, s3)
    g.text(lx + 3, top + 5, "TALK TIME IS HP. NO AUDIO IS SAVED.", s1, s3)

    token = lambda kind, raw: (raw, s3, s0, "bold")
    y = top + 7
    for key, time, said in LINES[-2:]:
        lines = wrap(f"{LABEL[key].upper()}: {said}", lw - 4)
        for index, line in enumerate(lines):
            rich(g, lx + 2, y + index, line, s1, s3, token)
        y += len(lines)
    g.box(lx + 1, y, lw - 2, 6, s0, "double", s3)
    key, time, said = PENDING
    name = LABEL[key].upper() + ":"
    pending = wrap(f"{name} {said}", lw - 6)
    g.text(lx + 3, y + 1, name, s0, s3, "bold")
    g.text(lx + 3 + len(name), y + 1, pending[0][len(name):], s0, s3)
    for index, line in enumerate(pending[1:3]):
        g.text(lx + 3, y + 2 + index, line, s0, s3)
    g.put(lx + lw - 4, y + 4, "▼", s0, s3)

    pad = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    draw = ImageDraw.Draw(pad)
    draw.ellipse([0, 0, 15, 15], fill=rgb(shade))
    draw.rectangle([6, 1, 9, 14], fill=rgb("#2b2b2b"))
    draw.rectangle([1, 6, 14, 9], fill=rgb("#2b2b2b"))
    draw.line([(6, 1), (9, 1)], fill=rgb("#555555"))
    draw.line([(1, 6), (5, 6)], fill=rgb("#555555"))
    draw.line([(10, 6), (14, 6)], fill=rgb("#555555"))
    draw.rectangle([7, 7, 8, 8], fill=rgb("#3d3d3d"))
    g.pixels(1, 13, pad)
    g.ctext(1, 16, 22, "SCROLL", navy, None, "bold")

    buttons = Image.new("RGBA", (19, 16), (0, 0, 0, 0))
    draw = ImageDraw.Draw(buttons)
    b, a = (5, 10), (14, 5)
    draw.line([b, a], fill=rgb(shade), width=11)
    for cx, cy in (b, a):
        draw.ellipse([cx - 5, cy - 5, cx + 5, cy + 5], fill=rgb(shade))
    for cx, cy in (b, a):
        draw.ellipse([cx - 4, cy - 4, cx + 3, cy + 3], fill=rgb(magenta))
        draw.point([(cx - 2, cy - 3), (cx - 3, cy - 2), (cx - 1, cy - 3), (cx - 3, cy - 1)], fill=rgb(shine))
        draw.point([(cx + 2, cy + 2), (cx + 1, cy + 3), (cx + 3, cy + 1)], fill=rgb(deep))
    g.pixels(101, 13, buttons)
    for x, label, hint in [(106, "B", "PAUSE"), (115, "A", "NAME")]:
        g.put(x, 21, label, navy, None, "bold")
        g.ctext(x - 3, 7, 22, hint, etched)

    g.text(19, 33, "mmm", navy, None, "bolditalic")
    g.text(23, 33, "POCKET", navy, None, "bolditalic")
    g.text(19, 34, "on-device minutes · no audio saved", etched)

    pill = Image.new("RGBA", (7, 2), (0, 0, 0, 0))
    draw = ImageDraw.Draw(pill)
    draw.line([(1, 0), (6, 0)], fill=rgb(slate))
    draw.line([(0, 1), (5, 1)], fill=rgb(slate))
    for x, label, hint in [(52, "SELECT", "skin"), (64, "START", "stop & save")]:
        g.pixels(x, 36, pill)
        g.ctext(x - 3, 13, 37, label, navy, None, "bold")
        g.ctext(x - 3, 13, 38, hint, etched)

    grille = Image.new("RGBA", (16, 18), (0, 0, 0, 0))
    draw = ImageDraw.Draw(grille)
    for index in range(6):
        draw.line([(index * 3, 17), (index * 3 + 6, 0)], fill=rgb(groove))
    g.pixels(102, 30, grille)
    return g


def notebook():
    """Ruled paper with a red margin line, speakers in colored pens, and sticky notes."""
    paper, rule, margin, ink, pencil = "#fbf9f2", "#cfdcea", "#e58a8a", "#2c2c2c", "#9a978f"
    pens = {"R1": "#2f5597", "R2": "#3a7d44", "X1": "#b3362f", "X2": "#6a4c93"}
    g = Grid(paper, ink)

    for x in range(3, W, 6):
        g.put(x, 0, "○", "#c9c4b6")
    for y in range(2, 38, 2):
        g.hline(0, y, W, rule, "─")
    g.vline(9, 1, 38, margin)
    g.vline(10, 1, 38, margin)
    g.text(12, 1, TITLE, ink, None, "bold")
    g.text(12 + len(TITLE) + 1, 1, "— Tuesday 29 September, from 14:03", pencil, None, "italic")

    token = lambda kind, raw: (raw.lower().strip("[]").join("[]"), "#c47a00", "#fff4c2", None)
    y = 3
    for key, time, said in LINES[-6:]:
        text = f"{LABEL[key]}: {said}"
        lines = wrap(text, 72)
        g.text(2, y, time, pencil, None, "italic")
        for index, line in enumerate(lines):
            if index == 0:
                g.text(12, y, LABEL[key] + ":", pens[key], None, "bold")
                rich(g, 13 + len(LABEL[key]), y, line[len(LABEL[key]) + 1:], ink, None, token)
            else:
                rich(g, 12, y + index * 2, line, ink, None, token)
        y += len(lines) * 2
    key, time, said = PENDING
    g.text(2, y, "now", "#d9534f", None, "italic")
    lines = wrap(f"{LABEL[key]}: {said}", 72)
    for index, line in enumerate(lines):
        g.text(12, y + index * 2, line, pencil, None, "italic")
    g.put(13 + len(lines[-1]), y + (len(lines) - 1) * 2, "▍", pens[key])

    def sticky(x, y, w, h, color, shadow):
        g.fill(x, y, w, h, color)
        g.vline(x + w, y + 1, h, shadow, "▌", paper)
        g.hline(x + 1, y + h, w, shadow, "▀", paper)

    sticky(87, 2, 30, 14, "#fff1a6", "#e3d58a")
    g.text(89, 3, "who's talking", ink, "#fff1a6", "bold")
    for index, (key, label, channel, share, talk) in enumerate(SPEAKERS):
        y = 5 + index * 2
        g.put(89, y, "●", pens[key], "#fff1a6")
        g.text(91, y, label, ink, "#fff1a6")
        g.rtext(114, y, f"{round(share * 100)}%", pencil, "#fff1a6")
        g.hline(91, y + 1, round(share / 0.4 * 22), pens[key], "━", "#fff1a6")
    g.text(89, 14, "● rec 14:32", "#d9534f", "#fff1a6", "bold")

    sticky(89, 19, 28, 9, "#ffd8df", "#e8b9c3")
    g.text(91, 20, "privacy", ink, "#ffd8df", "bold")
    for index, line in enumerate(["no audio saved", "names & numbers hidden", "echo removed"]):
        g.text(91, 22 + index, "✓ " + line, "#3a7d44" if index == 0 else ink, "#ffd8df")
    g.text(91, 26, "23s of audio in memory", pencil, "#ffd8df", "italic")

    g.text(12, 38, "space pause  ·  q stop & save  ·  n name speakers  ·  t theme", pencil, None, "italic")
    return g
