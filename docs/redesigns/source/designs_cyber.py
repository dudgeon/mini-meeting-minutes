"""Three designs that keep the neon, cyberpunk direction."""
import math
import random
import zlib

from PIL import Image, ImageDraw

from data import *
from tuikit import Grid, W, H, mix, pixel_text, rgb, wrap

FUTURA = "/System/Library/Fonts/Supplemental/Futura.ttc"
IMPACT = "/System/Library/Fonts/Supplemental/Impact.ttf"
SILOM = "/System/Library/Fonts/Supplemental/Silom.ttf"


def _lerp(stops, t):
    t = max(0.0, min(1.0, t))
    span = (len(stops) - 1) * t
    index = min(int(span), len(stops) - 2)
    a, b = rgb(stops[index]), rgb(stops[index + 1])
    local = span - index
    return tuple(int(x + (y - x) * local) for x, y in zip(a, b))


def synthwave():
    """A sunset over a neon grid, where the city skyline is the live spectrum analyzer."""
    night, panel, cyan, pink, yellow, text, dim = (
        "#0d0221", "#12032c", "#00f0ff", "#ff2e88", "#ffe45e", "#f3e9ff", "#8a6fb8")
    colors = {"R1": pink, "R2": "#ff9f1c", "X1": cyan, "X2": "#b18cff"}
    g = Grid(night, text)

    art_w, art_h, horizon = W, 38, 24
    art = Image.new("RGBA", (art_w, art_h))
    draw = ImageDraw.Draw(art)
    for y in range(horizon):
        draw.line([(0, y), (art_w, y)], fill=_lerp(["#07011a", "#240a4d", "#6e1566", "#e0457b"], y / horizon))
    stars = random.Random(3)
    for _ in range(18):
        draw.point((stars.randrange(art_w), stars.randrange(horizon - 14)), fill=(255, 230, 255))
    cx, cy, r = art_w // 2, 21, 11
    for y in range(cy - r, horizon):
        if y > cy - 4 and (y - cy) % 3 == 2:
            continue  # the sun's stripes
        half = math.sqrt(max(r * r - (y - cy) ** 2, 0))
        draw.line([(cx - half, y), (cx + half, y)], fill=_lerp(["#fff38a", "#ffb01f", "#ff3d8b"], (y - cy + r) / (r * 1.5)))
    for index, level in enumerate(spectrum(30, 7, 1.0)):
        if 11 <= index <= 18:
            continue  # leave the sun in view
        x0, h = index * 4, int(2 + level * 9)
        draw.rectangle([x0, horizon - h, x0 + 3, horizon - 1], fill=(24, 5, 48))
        draw.line([(x0, horizon - h), (x0 + 3, horizon - h)], fill=rgb(pink if index % 4 else cyan))
        for wy in range(horizon - h + 2, horizon - 1, 2):
            if (index * 5 + wy) % 4 == 0:
                draw.point((x0 + 1 + wy % 2, wy), fill=rgb(yellow))
    draw.rectangle([0, horizon, art_w, art_h], fill=(13, 2, 33))
    vanish = horizon - 6
    for k in range(-8, 9):
        bottom_x = cx + k * 12
        horizon_x = cx + (bottom_x - cx) * (horizon - vanish) / (art_h - vanish)
        draw.line([(horizon_x, horizon), (bottom_x, art_h)], fill=(150, 40, 220))
    for offset in (1, 3, 6, 9, 13):
        draw.line([(0, horizon + offset), (art_w, horizon + offset)], fill=(230, 40, 140) if offset > 3 else (150, 25, 110))
    draw.line([(0, horizon), (art_w, horizon)], fill=(255, 113, 206))
    g.pixels(0, 0, art)

    title = pixel_text("MINUTES", IMPACT, 13, lambda y, h: _lerp(["#ffffff", "#9ff8ff", cyan, pink], y / h),
                       spacing=2)
    g.pixels((W - title.width) // 2, 1, title)

    y = 19
    g.fill(0, y, W, 1, "#1a0536")
    g.text(2, y, "▶ REC", pink, "#1a0536", "bold")
    g.text(9, y, ELAPSED, yellow, "#1a0536", "bold")
    x = 20
    for label, level in [("MIC", LEVELS["mic"]), ("SYS", LEVELS["sys"])]:
        g.text(x, y, label, dim, "#1a0536")
        lit = round(level * 10)
        g.text(x + 4, y, "▮" * lit, cyan if label == "SYS" else pink, "#1a0536")
        g.text(x + 4 + lit, y, "▯" * (10 - lit), "#3a1a66", "#1a0536")
        x += 17
    g.text(56, y, f"{BUFFER}s IN MEMORY", yellow, "#1a0536")
    g.text(73, y, "PII ✓  ECHO ✓", cyan, "#1a0536")
    g.rtext(117, y, "MINI MEETING MINUTES", text, "#1a0536", "bold")

    g.fill(1, 21, W - 2, 16, panel)
    token = lambda kind, raw: (raw, night, yellow, "bold")
    row = 22
    for key, time, said in LINES[-4:]:
        lines = wrap(said, 92)
        g.text(3, row, LABEL[key].upper(), colors[key], panel, "bold")
        g.text(3, row + 1, time, dim, panel)
        for index, line in enumerate(lines):
            rich(g, 16, row + index, line, text, panel, token)
        row += max(len(lines), 2) + 1
    key, time, said = PENDING
    g.text(3, row, LABEL[key].upper(), colors[key], panel, "bold")
    g.text(3, row + 1, "LIVE", pink, panel, "bold")
    for index, line in enumerate(wrap(said, 92)):
        g.text(16, row + index, line, dim, panel)
    g.put(16 + len(wrap(said, 92)[-1]) + 1, row + len(wrap(said, 92)) - 1, "█", cyan, panel)

    x = 2
    for key, label in [("SPACE", "PAUSE"), ("Q", "STOP & SAVE"), ("N", "NAME"), ("V", "VISUALS"), ("K", "SKIN")]:
        g.text(x, 38, key, night, yellow, "bold")
        g.text(x + len(key) + 1, 38, label, pink, None, "bold")
        x += len(key) + len(label) + 4
    return g


def netrunner():
    """A cyberdeck HUD: acid yellow, hard edges, an intercept log with censor bars."""
    bg, panel, yellow, dim_yellow, red, cyan, text, ghost = (
        "#0a0a0c", "#111116", "#fcee0a", "#6f6a0a", "#ff003c", "#00f0ff", "#e6f7f7", "#2b2a10")
    ids = {"R1": "RM_01", "R2": "RM_02", "X1": "NC_01", "X2": "NC_02"}
    g = Grid(bg, text)

    g.fill(0, 0, 46, 1, yellow)
    g.text(1, 0, "MINI_MEETING_MINUTES // V0.1", bg, yellow, "bold")
    g.put(46, 0, "◤", yellow, bg)
    g.text(49, 0, "OPERATOR: LOCAL // NETWORK: OFFLINE", dim_yellow)
    g.rtext(118, 0, "● REC 00:14:32", red, None, "bold")
    for x in range(W):
        g.put(x, 1, "━" if (x // 7) % 5 else " ", dim_yellow)

    def panel_frame(x, y, w, h, title):
        g.fill(x, y, w, h, panel)
        g.put(x, y, "◤", yellow, bg)
        g.hline(x + 1, y, w - 2, dim_yellow, "━", panel)
        g.put(x + w - 1, y + h - 1, "◢", yellow, bg)
        g.hline(x + 1, y + h - 1, w - 2, dim_yellow, "━", panel)
        g.text(x + 2, y, f" {title} ", yellow, panel, "bold")

    panel_frame(1, 3, 42, 9, "//AUDIO_FEED")
    for index, (label, color, seed) in enumerate([("MIC", yellow, 11), ("SYS", cyan, 12)]):
        g.text(3, 5 + index * 2, label, color, panel, "bold")
        rng = random.Random(seed)
        dots = "".join(chr(0x2800 + rng.choice([0x40, 0x04, 0x02, 0x01, 0x06, 0x44, 0x24, 0x12, 0x09, 0x80, 0xC0])) for _ in range(33))
        g.text(8, 5 + index * 2, dots, color, panel)
    g.text(3, 9, "BUFFER", dim_yellow, panel)
    g.text(10, 9, "▰" * 9 + "▱" * 15, yellow, panel)
    g.text(35, 9, "23.4s", yellow, panel, "bold")

    panel_frame(1, 13, 42, 9, "//SPEAKER_ID")
    for index, (key, label, channel, share, talk) in enumerate(SPEAKERS):
        y = 15 + index
        color = yellow if channel == "room" else cyan
        g.text(3, y, ids[key], color, panel, "bold")
        filled = round(share / 0.4 * 18)
        g.text(9, y, "▐" + "█" * filled + "░" * (18 - filled) + "▌", color, panel)
        g.text(30, y, f"{round(share * 100):>2}%", text, panel)
        g.text(35, y, f"0x{zlib.crc32(key.encode()) % 0xFFFF:04X}", dim_yellow, panel)
    g.text(3, 20, "4 SIGNATURES · 2 LOCAL · 2 REMOTE", dim_yellow, panel)

    panel_frame(1, 23, 42, 8, "//PRIVACY")
    for index, (label, value, color) in enumerate([
        ("AUDIO_RETENTION", "NULL", yellow), ("PII_FILTER", "ACTIVE", cyan), ("ECHO_SUPPRESS", "ACTIVE", cyan),
        ("UPLINK", "NONE", yellow)]):
        g.text(3, 25 + index, label.ljust(29, "."), dim_yellow, panel)
        g.text(32, 25 + index, value, color, panel, "bold")

    rng = random.Random(4)
    for y in range(32, 37):
        line = f"0x{0x7F3A00 + y * 16:06X}  " + " ".join(f"{rng.randrange(256):02X}" for _ in range(10))
        g.text(2, y, line, ghost)

    panel_frame(45, 3, 74, 34, "//INTERCEPT_LOG")
    token = lambda kind, raw: ("▓" * len(raw), red, None, None)
    y = 5
    for key, time, said in LINES[-6:]:
        color = yellow if CHANNEL[key] == "room" else cyan
        g.text(47, y, f"[{time}:{(y * 7) % 60:02d}]", dim_yellow, panel)
        g.text(58, y, ids[key], color, panel, "bold")
        g.text(64, y, ">>", red, panel)
        for index, line in enumerate(wrap(said, 49)):
            rich(g, 67, y + index, line, text, panel, token)
        y += len(wrap(said, 49)) + 1
    key, time, said = PENDING
    g.text(47, y, "[14:25:03]", dim_yellow, panel)
    g.text(58, y, ids[key], cyan, panel, "bold")
    g.text(64, y, ">>", red, panel)
    lines = wrap(said, 49)
    for index, line in enumerate(lines):
        g.text(67, y + index, line, cyan, panel)
    g.put(68 + len(lines[-1]), y + len(lines) - 1, "█", red, panel)
    g.text(67, y + len(lines), "▲ DECRYPTING SIGNAL", red, panel, "bold")

    x = 0
    for key, label in [("Q", "JACK_OUT"), ("SPACE", "SUSPEND"), ("N", "TAG_SPEAKER"), ("V", "SCAN_MODE"),
                       ("K", "RESKIN")]:
        segment = f" [{key}] {label} "
        g.text(x, 38, segment, bg, yellow, "bold")
        g.put(x + len(segment), 38, "◤", yellow, bg)
        x += len(segment) + 2
    return g


def gridrunner():
    """Light-cycle lines on a black grid: the conversation as one trail weaving between speakers."""
    bg, cyan, cyan_dim, orange, orange_dim, white, grid_line = (
        "#01060b", "#18e0ff", "#0a4d5a", "#ff8a1c", "#5a2c08", "#e8fbff", "#0a1820")
    lanes = {"R1": cyan, "R2": "#7df3ff", "X1": orange, "X2": "#ffc27a"}
    g = Grid(bg, white)
    for y in range(H):
        for x in range(W):
            if x % 12 == 0 and y % 2 == 0:
                g.put(x, y, "┊", grid_line)

    g.text(2, 1, "M I N I  //  M E E T I N G  //  M I N U T E S", white, None, "bold")
    g.rtext(117, 1, "ELAPSED  00:14:32", orange, None, "bold")
    g.hline(0, 2, W, cyan, "━")
    g.hline(0, 3, W, cyan_dim, "▔")

    g.text(2, 5, "TURN TRAILS", cyan_dim, None, "bold")
    top, left, right = 7, 14, 116
    order = ["R1", "R2", "X1", "X2"]
    for index, key in enumerate(order):
        y = top + index * 2
        g.text(2, y, LABEL[key].upper(), lanes[key], None, "bold")
        g.hline(left, y, right - left, grid_line, "┈")
    slots = timeline(right - left, seed=9)
    previous = None
    for offset, key in enumerate(slots):
        x = left + offset
        if key is None:
            previous = None
            continue
        y = top + order.index(key) * 2
        if previous and previous != key:
            y0 = top + order.index(previous) * 2
            for yy in range(min(y0, y) + 1, max(y0, y)):
                g.put(x, yy, "┃", mix(lanes[previous], lanes[key], 0.5))
            g.put(x, y0, "┛" if y0 < y else "┓", lanes[previous])
            g.put(x, y, "┏" if y0 < y else "┗", lanes[key])
        else:
            g.put(x, y, "━", lanes[key])
        previous = key
    g.put(right, top + 6, "◆", white)
    g.text(left, top + 8, "0:00", cyan_dim)
    g.rtext(right, top + 8, "14:32", cyan_dim)

    g.hline(0, 17, W, cyan_dim, "─")
    token = lambda kind, raw: (raw, bg, orange, "bold")
    y = 19
    for key, time, said in LINES[-5:]:
        lines = wrap(said, 88)
        g.text(2, y, time, cyan_dim)
        g.text(9, y, LABEL[key].upper(), lanes[key], None, "bold")
        g.text(19, y, "›", lanes[key])
        for index, line in enumerate(lines):
            rich(g, 21, y + index, line, white, None, token)
        y += len(lines)
        g.hline(9, y, 100, grid_line, "┈")
        y += 1
    key, time, said = PENDING
    g.text(2, y, "LIVE", orange, None, "bold")
    g.text(9, y, LABEL[key].upper(), lanes[key], None, "bold")
    g.text(19, y, "›", lanes[key])
    pending = wrap(said, 86)
    for index, line in enumerate(pending):
        g.text(21, y + index, line, cyan)
    g.put(22 + len(pending[-1]), y + len(pending) - 1, "▌", white)

    for column, (label, level, color) in enumerate([("MIC", LEVELS["mic"], cyan), ("SYS", LEVELS["sys"], orange)]):
        x = 112 + column * 4
        g.text(x, 18, label, color, None, "bold")
        for row in range(14):
            lit = row < level * 14
            g.put(x + 1, 33 - row, "█" if lit else "░", color if lit else mix(color, bg, 0.8))

    g.hline(0, 35, W, cyan_dim, "━")
    g.text(2, 36, "IDENTITY FILTER", cyan_dim)
    g.text(18, 36, "ON", cyan, None, "bold")
    g.text(24, 36, "ECHO FILTER", cyan_dim)
    g.text(36, 36, "ON", cyan, None, "bold")
    g.text(42, 36, "MEMORY", cyan_dim)
    g.text(49, 36, "▕" + "█" * 12 + "░" * 18 + "▏", cyan)
    g.text(82, 36, "23s", orange, None, "bold")
    x = 2
    for key, label in [("SPACE", "HOLD"), ("Q", "DEREZ & SAVE"), ("N", "IDENTIFY"), ("K", "RECOLOR")]:
        g.text(x, 38, key, bg, cyan, "bold")
        g.text(x + len(key) + 1, 38, label, cyan)
        x += len(key) + len(label) + 4
    return g
