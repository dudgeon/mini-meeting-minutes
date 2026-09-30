#!/usr/bin/env python3
"""Checks how mmm holds up over a long meeting: memory, and whether speaker labels keep pace.

Maintainer tool. A synthetic meeting (two voices in the room and two on the call, with macOS
voices) is played through `mmm record` in a pseudo-terminal, faster than real time, while the
app's physical memory footprint is sampled every 5 seconds. At the end it prints memory per
quarter hour of meeting and how far speaker labels trailed the audio. The audio lives in a
temporary folder that's deleted afterwards.

    python3 scripts/long_meeting_check.py              # 2 hours, played at 8x (about 15 minutes)
    python3 scripts/long_meeting_check.py --hours 0.5 --speed 4
"""

import argparse
import array
import codecs
import fcntl
import os
import pty
import random
import re
import select
import shutil
import signal
import statistics
import struct
import subprocess
import sys
import tempfile
import termios
import time
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RATE = 16000
VOICES = {"room": ["Samantha", "Daniel"], "remote": ["Karen", "Fred"]}
TOPICS = ["giraffe", "lantern", "harbor", "violin", "meteor", "cactus", "pelican", "marble", "glacier", "tunnel",
          "orchard", "compass", "falcon", "velvet", "canyon", "rocket", "saddle", "walnut", "beacon", "anchor"]
TEMPLATES = ["I think the {w} project needs another week before we can call it done.",
             "Can we talk about the {w} budget? The numbers look off to me.",
             "The {w} team shipped the first version yesterday and feedback has been good.",
             "My worry with {w} is that we are adding scope faster than we can test it.",
             "Let's park {w} for now and come back to it next quarter.",
             "For {w}, the main risk is the migration, not the interface."]


def five_minutes(scratch):
    """About five minutes of back-and-forth among four voices, as room and call tracks."""
    rng = random.Random(7)
    speakers = [(channel, voice) for channel, voices in VOICES.items() for voice in voices]
    clips, last = [], None
    for index in range(60):
        channel, voice = rng.choice([s for s in speakers if s != last])
        last = (channel, voice)
        path = scratch / "line.wav"
        text = rng.choice(TEMPLATES).format(w=TOPICS[index % len(TOPICS)])
        subprocess.run(["say", "-v", voice, "-o", str(path), f"--data-format=LEI16@{RATE}", text], check=True)
        with wave.open(str(path), "rb") as handle:
            samples = array.array("h")
            samples.frombytes(handle.readframes(handle.getnframes()))
        path.unlink()
        clips.append((channel, samples, int(rng.uniform(0.3, 1.2) * RATE)))
    total = sum(len(samples) + gap for _, samples, gap in clips)
    tracks = {"room": array.array("h", [0]) * total, "remote": array.array("h", [0]) * total}
    position = 0
    for channel, samples, gap in clips:
        tracks[channel][position:position + len(samples)] = samples
        position += len(samples) + gap
    return tracks, total / RATE


def footprint(pid):
    """The process's physical memory footprint in MB, as Activity Monitor counts it."""
    output = subprocess.run(["footprint", str(pid)], capture_output=True, text=True).stdout
    match = re.search(r"Footprint: ([\d.]+) (KB|MB|GB)", output)
    if not match:
        return None
    value, unit = float(match.group(1)), match.group(2)
    return value / 1024 if unit == "KB" else value * 1024 if unit == "GB" else value


def play(scratch, length, speed):
    """Plays the meeting through the app; returns memory samples, the diagnostics and the peak."""
    minutes = scratch / "Minutes"
    minutes.mkdir()
    log_path = scratch / "diagnostics.log"
    log = open(log_path, "w")
    pid, fd = pty.fork()
    if pid == 0:
        os.dup2(log.fileno(), 2)
        os.execve(str(ROOT / "mmm"), [str(ROOT / "mmm"), "record", "--replay-room", str(scratch / "room.wav"),
                                       "--replay-remote", str(scratch / "remote.wav"), "--replay-speed", str(speed),
                                       "--title", "Long meeting", "--output", f"{minutes}/"],
                  {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": os.environ["HOME"], "TERM": "xterm-256color",
                   "MMM_DEBUG": "1"})
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 42, 120, 0, 0))
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
    recent = []

    def pump(seconds):
        end = time.monotonic() + seconds
        while (remaining := end - time.monotonic()) > 0:
            ready, _, _ = select.select([fd], [], [], min(remaining, 0.05))
            if ready:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    return False
                if not data:
                    return False
                recent.append(decoder.decode(data))
                del recent[:-50]
        return True

    def showing(marker):
        return marker in "".join(recent[-20:])

    while not showing("Ready"):
        pump(0.1)
    pump(1)
    os.write(fd, b" ")
    pump(1)
    os.write(fd, b"y")
    started, samples, peak = time.monotonic(), [], ""
    stage, last_sample = "recording", -5.0
    while True:
        alive = pump(0.5)
        now = time.monotonic() - started
        if now - last_sample >= 5 and stage == "recording":
            last_sample = now
            samples.append((min(now * speed, length), footprint(pid)))
        if stage == "recording" and showing("Who was speaking?"):
            stage = "naming"
            os.write(fd, b"\x1b")
        if stage in ("recording", "naming") and showing("new recording"):
            stage = "saved"
            summary = subprocess.run(["vmmap", "--summary", str(pid)], capture_output=True, text=True).stdout
            peak = next((line for line in summary.splitlines() if "footprint (peak)" in line.lower()), "")
            samples.append((length, footprint(pid)))
            os.write(fd, b"q")
        if not alive:
            break
    os.waitpid(pid, 0)
    log.close()
    return samples, log_path.read_text(errors="replace"), peak


def report(samples, diagnostics, peak, speed):
    print(f"{'meeting':>13}  {'samples':>7}  {'lowest':>6}  {'median':>6}  {'highest':>7}  (memory, MB)")
    buckets = {}
    for position, megabytes in samples:
        if megabytes:
            buckets.setdefault(int(position // 900), []).append(megabytes)
    for bucket in sorted(buckets):
        values = buckets[bucket]
        print(f"{bucket * 15:4d}–{bucket * 15 + 15:3d} min  {len(values):7d}  {min(values):6.0f}  "
              f"{statistics.median(values):6.0f}  {max(values):7.0f}")
    print(peak.strip())
    # "shown at T: … the last ending X s earlier": T is wall-clock seconds, the turn's end is in
    # meeting time, so at N times real time the labels trail the audio by (N - 1) T + X seconds.
    lags = {}
    for match in re.finditer(r"shown at ([\d.]+): \d+ turns, the last ending (-?[\d.]+) s earlier", diagnostics):
        wall, earlier = float(match.group(1)), float(match.group(2))
        lags.setdefault(int(wall * speed // 900), []).append((speed - 1) * wall + earlier)
    for bucket in sorted(lags):
        values = lags[bucket]
        print(f"{bucket * 15:4d}–{bucket * 15 + 15:3d} min: speaker labels trail the audio by "
              f"{statistics.median(values):.1f} s (at most {max(values):.1f} s)")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--hours", type=float, default=2.0, help="how long the meeting is")
    parser.add_argument("--speed", type=float, default=8.0, help="how many times faster than real time to play it")
    arguments = parser.parse_args()
    for leftover in Path(tempfile.gettempdir()).glob("mmm-long-meeting-*"):
        shutil.rmtree(leftover, ignore_errors=True)
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, lambda *_: sys.exit(1))
    subprocess.run([str(ROOT / "mmm"), "--version"], check=True, capture_output=True)  # build first
    with tempfile.TemporaryDirectory(prefix="mmm-long-meeting-") as scratch:
        scratch = Path(scratch)
        tracks, seconds = five_minutes(scratch)
        repeats = max(1, round(arguments.hours * 3600 / seconds))
        for name, samples in tracks.items():
            with wave.open(str(scratch / f"{name}.wav"), "wb") as handle:
                handle.setnchannels(1)
                handle.setsampwidth(2)
                handle.setframerate(RATE)
                for _ in range(repeats):
                    handle.writeframes(samples.tobytes())
        length = repeats * seconds
        print(f"A {length / 3600:.1f}-hour meeting, played at {arguments.speed:g}x "
              f"(about {length / arguments.speed / 60:.0f} minutes)…", flush=True)
        samples, diagnostics, peak = play(scratch, length, arguments.speed)
        report(samples, diagnostics, peak, arguments.speed)


if __name__ == "__main__":
    main()
