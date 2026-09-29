"""Three designs in the spirit of Claude's own interfaces."""
from data import *
from tuikit import Grid, W, H, mix, wrap


def terracotta():
    """Claude Code, dark: a welcome box, ⏺ entries with ⎿ results, a spinner line and a prompt box."""
    bg, text, dim, faint = "#1f1e1d", "#e9e6df", "#8f8b82", "#55524b"
    accent, green = "#d97757", "#8fb37a"
    colors = {"R1": "#d97757", "R2": "#b89bd9", "X1": "#6fb3b8", "X2": "#d9b25f"}
    g = Grid(bg, text)
    token = lambda kind, raw: (raw, accent, None, None)

    g.box(1, 1, 74, 7, accent, "rounded")
    g.text(3, 2, "✻", accent)
    g.text(5, 2, "Mini Meeting Minutes", text, style="bold")
    g.text(4, 4, "Planning review · recording since 14:03 · everything stays on this Mac", dim)
    g.text(4, 6, "minutes: ", dim)
    g.text(13, 6, FILE, text)

    g.text(79, 2, "Speakers", text, style="bold")
    for index, (key, label, channel, share, talk) in enumerate(SPEAKERS):
        y = 3 + index
        g.text(82, y, "●", colors[key])
        g.text(84, y, label, text)
        filled = round(share / 0.4 * 12)
        g.text(94, y, "█" * filled, colors[key])
        g.text(94 + filled, y, "░" * (12 - filled), faint)
        g.rtext(111, y, f"{round(share * 100)}%", dim)
        g.rtext(118, y, talk, dim)

    y = 9
    for key, time, said in LINES[-5:]:
        g.text(1, y, "⏺", colors[key])
        g.text(3, y, LABEL[key], text, style="bold")
        g.text(4 + len(LABEL[key]), y, f"· {time}", dim)
        lines = wrap(said, 104)
        for index, line in enumerate(lines):
            g.text(3, y + 1 + index, "⎿" if index == 0 else " ", faint)
            rich(g, 6, y + 1 + index, line, text, None, token)
        y += len(lines) + 2
    key, time, said = PENDING
    g.text(1, y, "⏺", colors[key])
    g.text(3, y, LABEL[key], text, style="bold")
    g.text(4 + len(LABEL[key]), y, f"· {time} · speaking", dim)
    g.text(3, y + 1, "⎿", faint)
    g.text(6, y + 1, said, dim)
    g.text(7 + len(said), y + 1, "▍", accent)

    g.text(1, 33, "✻", accent)
    g.text(3, 33, "Transcribing…", accent)
    g.text(17, 33, "(14m 32s · 23s of audio in memory · mic ▃▅▇▅ · system ▂▃▅▂ · esc to stop)", dim)
    g.box(0, 34, W, 3, faint, "rounded")
    g.text(2, 35, ">", text)
    g.text(4, 35, "Name a speaker, or try /pause, /stop, /theme", faint)
    g.text(2, 37, "? for shortcuts", dim)
    mode = "⏵⏵ redaction on · echo cancel on (shift+tab to cycle)"
    g.rtext(117, 37, mode, dim)
    g.text(118 - len(mode), 37, "⏵⏵", accent)
    return g


def parchment():
    """claude.ai, light: a warm cream page, message cards with speaker accents, a composer box."""
    bg, card, text, dim, faint = "#f4f2ea", "#fdfcf8", "#2b2926", "#7a776f", "#d7d3c7"
    accent, chip = "#c96442", "#e9e6db"
    colors = {"R1": "#c96442", "R2": "#8a6fb5", "X1": "#3f8f8a", "X2": "#b0862a"}
    g = Grid(bg, text)
    token = lambda kind, raw: (raw, accent, "#f5e3da", "bold")
    left, width = 12, 96

    g.text(left, 1, "✻", accent)
    g.text(left + 2, 1, "Mini Meeting Minutes", text, style="bold")
    g.text(left + 23, 1, "· " + TITLE, dim)
    g.rtext(left + width - 1, 1, "● Recording  14:32", accent)
    g.text(left + width - 18, 1, "●", accent)
    g.hline(left, 2, width, faint)

    x = left
    for key, label, channel, share, talk in SPEAKERS:
        pill = f" ● {label}  {round(share * 100)}% "
        g.put(x, 3, "▐", chip, bg)
        g.text(x + 1, 3, pill, text, chip)
        g.put(x + 2, 3, "●", colors[key], chip)
        g.put(x + 1 + len(pill), 3, "▌", chip, bg)
        x += len(pill) + 4

    y = 5
    for key, time, said in LINES[-4:]:
        lines = wrap(said, width - 6)
        g.fill(left, y, width, len(lines) + 2, card)
        g.vline(left, y, len(lines) + 2, colors[key], "▎", card)
        g.text(left + 3, y, LABEL[key], colors[key], card, "bold")
        g.rtext(left + width - 2, y, time, dim, card)
        for index, line in enumerate(lines):
            rich(g, left + 3, y + 1 + index, line, text, card, token)
        y += len(lines) + 3
    key, time, said = PENDING
    lines = wrap(said, width - 6)
    g.fill(left, y, width, len(lines) + 2, card)
    g.vline(left, y, len(lines) + 2, colors[key], "▎", card)
    g.text(left + 3, y, LABEL[key], colors[key], card, "bold")
    g.text(left + 4 + len(LABEL[key]), y, "is speaking…", dim, card, "italic")
    for index, line in enumerate(lines):
        g.text(left + 3, y + 1 + index, line, dim, card)
    g.put(left + 4 + len(lines[-1]), y + len(lines), "▍", accent, card)

    g.box(left, 32, width, 5, faint, "rounded", bg=card)
    g.text(left + 3, 33, "Name a speaker…", dim, card)
    for label, x in [("Pause", left + width - 21), ("Stop & save", left + width - 14)]:
        g.put(x - 1, 35, "▐", chip, card)
        g.text(x, 35, label, text, chip)
        g.put(x + len(label), 35, "▌", chip, card)
    g.text(left + 3, 35, "✻", accent, card)
    g.text(left + 5, 35, "Parakeet · on device · 23s of audio in memory", dim, card)
    g.ctext(0, W, 38, "Audio stays on this Mac and is never saved. Only the minutes are.", dim)
    return g


def sidebar():
    """A two-pane Claude-style layout: a quiet sidebar of status, a conversation-like transcript."""
    bg, side, text, dim, faint = "#191918", "#222220", "#ecebe7", "#9a9893", "#3a3935"
    accent, green, live = "#d97757", "#8fb37a", "#2a2825"
    colors = {"R1": "#e08a6a", "R2": "#b89bd9", "X1": "#6fb3b8", "X2": "#d9b25f"}
    g = Grid(bg, text)
    token = lambda kind, raw: (raw, "#f2c4ae", "#3b2a22", None)

    g.fill(0, 0, 32, H, side)
    g.text(2, 1, "✻", accent, side)
    g.text(4, 1, "mmm", text, side, "bold")
    g.text(8, 1, "mini meeting minutes", dim, side)
    g.text(2, 3, "●", accent, side)
    g.text(4, 3, "Recording", text, side, "bold")
    g.rtext(29, 3, "14:32", text, side, "bold")
    g.text(4, 4, TITLE, dim, side)

    def section(y, label):
        g.text(2, y, label, dim, side, "bold")

    section(7, "SPEAKERS")
    for index, (key, label, channel, share, talk) in enumerate(SPEAKERS):
        y = 8 + index * 2
        g.text(2, y, "●", colors[key], side)
        g.text(4, y, label, text, side)
        g.rtext(29, y, f"{round(share * 100)}%", dim, side)
        filled = round(share / 0.4 * 26)
        g.hline(4, y + 1, filled, colors[key], "━", side)
        g.hline(4 + filled, y + 1, 26 - filled, faint, "─", side)

    section(17, "LISTENING TO")
    for index, (label, level, seed) in enumerate([("mic", LEVELS["mic"], 1), ("system", LEVELS["sys"], 2)]):
        g.text(4, 18 + index, label, text, side)
        bars = spectrum(16, seed, level + 0.3)
        g.text(12, 18 + index, "".join(" ▁▂▃▄▅▆▇"[min(7, int(v * 8))] for v in bars), accent, side)

    section(21, "PRIVACY")
    for index, line in enumerate(["no audio saved", "names and numbers hidden", "speaker echo removed"]):
        g.text(2, 22 + index, "✓", green, side)
        g.text(4, 22 + index, line, text, side)
    g.text(4, 25, "23s of audio in memory", dim, side)

    section(28, "KEYS")
    for index, (key, label) in enumerate([("space", "pause"), ("q", "stop and save"), ("n", "name speakers"),
                                          ("t", "theme"), ("?", "all shortcuts")]):
        g.text(4, 29 + index, key, accent, side)
        g.text(11, 29 + index, label, dim, side)

    g.text(35, 1, "Minutes", dim)
    g.text(43, 1, "›", faint)
    g.text(45, 1, "2026-09-29 1403 Planning review.md", text)
    g.rtext(117, 1, "saved just now", dim)
    g.hline(34, 2, 85, faint)

    y = 4
    for key, time, said in LINES[-5:]:
        lines = wrap(said, 78)
        g.vline(35, y, len(lines) + 1, colors[key], "▎")
        g.text(37, y, LABEL[key], colors[key], style="bold")
        g.rtext(117, y, time, dim)
        for index, line in enumerate(lines):
            rich(g, 37, y + 1 + index, line, text, None, token)
        y += len(lines) + 2
    key, time, said = PENDING
    lines = wrap(said, 76)
    g.fill(34, y - 1, 85, len(lines) + 3, live)
    g.vline(35, y, len(lines) + 1, colors[key], "▎", live)
    g.text(37, y, LABEL[key], colors[key], live, "bold")
    g.text(38 + len(LABEL[key]), y, "✻ speaking…", accent, live)
    for index, line in enumerate(lines):
        g.text(37, y + 1 + index, line, dim, live)
    g.put(38 + len(lines[-1]), y + len(lines), "▍", accent, live)

    g.box(34, 35, 85, 3, faint, "rounded")
    g.text(36, 36, ">", text)
    g.text(38, 36, "Rename Remote 2…", faint)
    g.rtext(116, 36, "esc to stop", faint)
    return g
