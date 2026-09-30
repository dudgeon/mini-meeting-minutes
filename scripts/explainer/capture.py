"""Runs the real app on a pseudo-terminal with the narration as its microphone, presses keys in time
with the script, and records everything the app draws, with timestamps, into capture.pkl."""

import codecs
import fcntl
import json
import os
import pickle
import pty
import select
import struct
import termios
import time

COLUMNS, ROWS = 120, 42  # the size the Desktop shortcut opens Terminal at


def record(work, app):
    """Replays `work`/narration.wav through `app` (the mmm launcher) and saves `work`/capture.pkl."""
    lines = json.loads((work / "timeline.json").read_text())
    minutes = work / "Minutes"
    minutes.mkdir(exist_ok=True)
    for old in minutes.glob("*.md"):
        old.unlink()
    stream, keys = [], []  # (monotonic time, text drawn), (monotonic time, badge)
    moments = {}  # when things without a key of their own happened
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")

    pid, fd = pty.fork()
    if pid == 0:
        os.execve(str(app), [str(app), "record", "--replay-room", str(work / "narration.wav"), "--replay-remote",
                             str(work / "call.wav"), "--title", "Demo", "--output", f"{minutes}/"],
                  {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": os.environ["HOME"], "TERM": "xterm-256color",
                   "COLORTERM": "truecolor"})
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLUMNS, 0, 0))

    def pump(seconds):
        end = time.monotonic() + seconds
        while (remaining := end - time.monotonic()) > 0:
            ready, _, _ = select.select([fd], [], [], min(remaining, 0.01))
            if ready:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    return
                if not data:
                    return
                stream.append((time.monotonic(), decoder.decode(data)))

    def drawn(since=0):
        return "".join(text for _, text in stream[since:])

    def wait_for(marker, since=0, timeout=120):
        deadline = time.monotonic() + timeout
        while marker not in drawn(since):
            if time.monotonic() > deadline:
                raise SystemExit(f"the app never showed {marker!r}")
            pump(0.05)

    def press(text, spacing=0.1, badge=None):
        """Types `text`; `badge` is the key shown on screen for it."""
        if badge:
            keys.append((time.monotonic(), badge))
        for key in text:
            os.write(fd, key.encode())
            pump(spacing)

    wait_for("Ready")
    pump(0.8)
    press(" ", badge="space")
    pump(1.4)
    start = time.monotonic()
    press("y", 0, badge="Y")

    def until(narration_time):
        pump(max(0.0, start + narration_time - time.monotonic()))

    until(lines[5]["end"] + 0.25)
    press("/name", 0.07)                                          # name the speakers
    press("\r", 0.35, badge="/name")
    press("Sam\r", 0.11)
    press("Dan\r", 0.11)
    press("\x1b", 0.2)                                            # esc, in case there are more
    until(lines[6]["end"] + 0.1)
    moments["note"] = time.monotonic()                            # an inline note: just typing
    press("Send the explainer to the team", 0.07)
    press("\r", 0.1, badge="return")
    until(lines[7]["end"] + 0.3)
    press("/stop", 0.07)                                          # stop and save
    mark = len(stream)
    press("\r", 0, badge="/stop")
    wait_for("Who was speaking?", mark)
    pump(0.6)
    press("\r", 0.45, badge="return")                             # keep both names
    press("\r", 0.1, badge="return")
    wait_for("new recording", mark)
    pump(2)
    press("q", 0)
    pump(3)
    os.waitpid(pid, 0)
    if not list(minutes.glob("*.md")):
        raise SystemExit("the app saved no minutes")
    with open(work / "capture.pkl", "wb") as handle:
        pickle.dump({"stream": stream, "keys": keys, "moments": moments, "start": start}, handle)
