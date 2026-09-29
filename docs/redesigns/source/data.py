"""The meeting every mockup shows, so the designs are easy to compare."""
import math
import random
import re

TITLE = "Planning review"
DATE = "Tuesday 29 September 2026"
ELAPSED = "00:14:32"
FILE = "~/Documents/Minutes/2026-09-29 1403 Planning review.md"
BUFFER = 23  # seconds of audio in memory

# key, label, channel, share of talk, talk time
SPEAKERS = [
    ("R1", "Room 1", "room", 0.38, "5:31"),
    ("R2", "Room 2", "room", 0.12, "1:45"),
    ("X1", "Remote 1", "remote", 0.31, "4:30"),
    ("X2", "Remote 2", "remote", 0.19, "2:46"),
]
LABEL = {key: label for key, label, *_ in SPEAKERS}
CHANNEL = {key: channel for key, _, channel, *_ in SPEAKERS}

LINES = [
    ("R1", "13:05", "Good morning everyone. Let's get started with the quarterly planning review."),
    ("X1", "13:12", "Thanks. Before we begin, I spoke with [NAME] about the budget, and he said we are about 10% "
                    "over on infrastructure this quarter."),
    ("R1", "13:22", "That is concerning. Can you send me the full breakdown? My email is [EMAIL]."),
    ("X2", "13:29", "I can help with that. You can also call me at [PHONE] if anything is unclear."),
    ("X1", "13:37", "Great, the vendor contract is up for renewal on 1 November, so we need a decision by next week "
                    "at the latest."),
    ("X2", "13:46", "I would suggest we get two competing quotes before we commit to another three-year term with "
                    "the same vendor."),
    ("R2", "13:52", "Agreed. Let's schedule a follow-up for Thursday, and I'll bring the revised numbers."),
    ("X1", "13:59", "Will do. I'll also loop in the finance team so they can review the forecast before Thursday."),
    ("R1", "14:07", "Perfect. Next item is the onboarding flow; customer interviews say setup takes far too long."),
]
PENDING = ("X2", "14:25", "We could ship a guided setup wizard in about six weeks if we start soon, but the data "
                          "pipeline")
LEVELS = {"mic": 0.62, "sys": 0.44}

TOKEN = re.compile(r"\[(NAME|EMAIL|PHONE)\]")


def spectrum(count, seed, energy=1.0):
    rng = random.Random(seed)
    values = []
    for band in range(count):
        base = energy * (0.85 - band / count * 0.55)
        values.append(max(0.05, min(1.0, base + 0.25 * math.sin(band * 1.3 + seed) + 0.15 * rng.random())))
    return values


def timeline(slots, seed=5):
    """Who talked in each of `slots` equal slices of the meeting so far (None for silence)."""
    rng = random.Random(seed)
    order = [key for key, *_ in LINES]
    out, current = [], order[0]
    for slot in range(slots):
        r = rng.random()
        if r < 0.18:
            out.append(None)
            continue
        if r > 0.8:
            current = rng.choice([key for key, *_ in SPEAKERS])
        out.append(current)
    return out


def rich(grid, x, y, text, fg, bg, token, style=None, limit=None):
    """Writes text, drawing [NAME]/[EMAIL]/[PHONE] with `token(kind, raw) -> (text, fg, bg, style)`."""
    column, position = x, 0
    end = x + limit if limit else None
    for match in TOKEN.finditer(text):
        segment = text[position:match.start()]
        grid.text(column, y, segment, fg, bg, style)
        column += len(segment)
        shown, tfg, tbg, tstyle = token(match.group(1), match.group(0))
        grid.text(column, y, shown, tfg, tbg, tstyle)
        column += len(shown)
        position = match.end()
    grid.text(column, y, text[position:], fg, bg, style, limit=None if end is None else max(0, end - column))
    return column + len(text[position:])
