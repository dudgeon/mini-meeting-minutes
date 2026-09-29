"""Renders the ten live-screen mockups and a contact sheet into docs/redesigns/.

    python3 -m venv /tmp/mockups && /tmp/mockups/bin/pip install pillow
    /tmp/mockups/bin/python docs/redesigns/source/render_all.py

Each design draws on a 120 × 40 character grid using only what a truecolor terminal can show:
text, box drawing, and half-block pixel art. Fonts come from macOS.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import designs_claude  # noqa: E402
import designs_cyber  # noqa: E402
import designs_other  # noqa: E402
from tuikit import render  # noqa: E402

GROUPS = [
    ("Claude-ish", [("01", "terracotta", "Terracotta", "Claude Code, dark"),
                    ("02", "parchment", "Parchment", "claude.ai, light"),
                    ("03", "sidebar", "Sidebar", "two quiet panes")]),
    ("Cyberpunk", [("04", "synthwave", "Synthwave", "sunset over a neon grid"),
                   ("05", "netrunner", "Netrunner", "an intercept log"),
                   ("06", "gridrunner", "Gridrunner", "light-cycle turn trails")]),
    ("Somewhere else", [("07", "broadsheet", "The Minutes", "a broadsheet newspaper"),
                        ("08", "tapedeck", "Tape Deck", "a cassette recorder"),
                        ("09", "pocket", "Pocket", "a handheld game console"),
                        ("10", "notebook", "Notebook", "ruled paper, sticky notes")]),
]


def contact_sheet(paths, scale=0.4, columns=4, gutter=24, margin=40):
    menlo = "/System/Library/Fonts/Menlo.ttc"
    heading = ImageFont.truetype(menlo, 26, index=1)
    label = ImageFont.truetype(menlo, 17, index=1)
    small = ImageFont.truetype(menlo, 15, index=0)
    first = Image.open(next(iter(paths.values())))
    tw, th = int(first.width * scale), int(first.height * scale)
    section = 40 + th + 56
    width = margin * 2 + columns * tw + (columns - 1) * gutter
    sheet = Image.new("RGB", (width, 100 + len(GROUPS) * section + 10), (22, 22, 26))
    draw = ImageDraw.Draw(sheet)
    draw.text((margin, 34), "mmm — ten directions for the live screen", font=heading, fill=(236, 234, 228))
    y = 100
    for group, designs in GROUPS:
        draw.text((margin, y), group.upper(), font=label, fill=(217, 119, 87))
        draw.line([(margin, y + 28), (width - margin, y + 28)], fill=(60, 60, 66))
        for column, (number, name, title, blurb) in enumerate(designs):
            x = margin + column * (tw + gutter)
            thumb = Image.open(paths[name]).convert("RGB").resize((tw, th), Image.LANCZOS)
            sheet.paste(thumb, (x, y + 40))
            caption = f"{number}  {title}"
            draw.text((x, y + 48 + th), caption, font=label, fill=(236, 234, 228))
            draw.text((x + draw.textlength(caption, font=label) + 12, y + 50 + th), blurb,
                      font=small, fill=(150, 148, 142))
        y += section
    return sheet


def main():
    paths = {}
    for _, designs in GROUPS:
        for number, name, _, _ in designs:
            module = next(m for m in (designs_claude, designs_cyber, designs_other) if hasattr(m, name))
            paths[name] = os.path.join(OUT, f"{number}-{name}.png")
            render(getattr(module, name)(), paths[name], "mmm")
            print("rendered", os.path.relpath(paths[name]))
    contact_sheet(paths).save(os.path.join(OUT, "contact-sheet.png"))
    print("rendered", os.path.relpath(os.path.join(OUT, "contact-sheet.png")))


if __name__ == "__main__":
    main()
