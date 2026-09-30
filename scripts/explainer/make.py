#!/usr/bin/env python3
"""Makes the explainer video: two narrators (macOS voices) introduce Mini Meeting Minutes while the
real app transcribes them, and a camera flies over its screen.

Maintainer tool. The narration is played through `mmm record` in a pseudo-terminal, as the room
microphone, with keys pressed on cue; every screen the app draws is captured, then composed into a
1080p video with the narration as its soundtrack. The narration is synthetic speech in a temporary
folder that's deleted afterwards (unless you keep the work folder).

Needs Pillow, NumPy and imageio-ffmpeg, and the Samantha and Daniel voices:
    python3 -m venv /tmp/explainer-venv
    /tmp/explainer-venv/bin/pip install pillow numpy imageio-ffmpeg
    /tmp/explainer-venv/bin/python scripts/explainer/make.py      # ~/Movies/Mini Meeting Minutes explainer.mp4

To adjust the look without recording again, keep the work folder, then compose from it:
    /tmp/explainer-venv/bin/python scripts/explainer/make.py --work /tmp/explainer
    /tmp/explainer-venv/bin/python scripts/explainer/make.py --work /tmp/explainer --reuse --still 21.9 50.5
"""

import argparse
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import capture  # noqa: E402
import compose  # noqa: E402
import narration  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT = Path.home() / "Movies" / "Mini Meeting Minutes explainer.mp4"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="where to write the video")
    parser.add_argument("--work", type=Path, help="keep the narration, capture and minutes in this folder")
    parser.add_argument("--reuse", action="store_true", help="compose from the capture already in --work")
    parser.add_argument("--still", type=float, nargs="+", metavar="SECONDS",
                        help="save stills of these moments in the work folder instead of a video")
    parser.add_argument("--workers", type=int, default=os.cpu_count() or 4)
    arguments = parser.parse_args()
    if arguments.reuse and not arguments.work:
        parser.error("--reuse needs --work")

    # Temporary work folders left by a run that was killed outright are removed here.
    for leftover in Path(tempfile.gettempdir()).glob("mmm-explainer-*"):
        shutil.rmtree(leftover, ignore_errors=True)
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, lambda *_: sys.exit(1))
    temporary = None
    if arguments.work:
        work = arguments.work.resolve()
        work.mkdir(parents=True, exist_ok=True)
    else:
        temporary = tempfile.TemporaryDirectory(prefix="mmm-explainer-")
        work = Path(temporary.name)
    try:
        started = time.monotonic()
        if not arguments.reuse:
            subprocess.run([str(ROOT / "mmm"), "--version"], check=True, capture_output=True)  # build first
            lines = narration.speak(work)
            print(f"narration: {len(lines)} lines, {lines[-1]['end']:.0f} s; capturing the app in real time…")
            capture.record(work, ROOT / "mmm")
        if arguments.still:
            compose.render_stills(work, arguments.still, work)
            print(f"stills in {work}")
            return
        duration = compose.render_video(work, arguments.out.expanduser(), arguments.workers)
        print(f"wrote {arguments.out} ({duration:.1f} s of video) in {time.monotonic() - started:.0f} s")
    finally:
        if temporary:
            temporary.cleanup()


if __name__ == "__main__":
    main()
