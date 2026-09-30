#!/usr/bin/env python3
"""End-to-end check: a synthetic call through `mmm transcribe`, verified against what was said.

Uses macOS `say` voices: one person in the room, two remote participants whose voices also leak
into the microphone as speaker echo. Checks that each line lands on the right channel, that the
remote speakers are told apart, that the echo doesn't reappear as a room speaker, and that the
email, phone number and name are redacted. The audio lives in a temporary directory and is
deleted afterwards.

Usage: python3 scripts/e2e_check.py    (standard library only; exits non-zero on failure)
"""

import array
import re
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RATE = 16000
SCRIPT = [
    ("room", "Samantha", "Good morning everyone. Let's get started with the quarterly planning review."),
    ("remote", "Daniel", "Thanks. Before we begin, I spoke with Marcus Chen about the budget, and he said we are about ten percent over on infrastructure."),
    ("room", "Samantha", "That is concerning. Can you send me the full breakdown? My email is jane dot doe at example dot com."),
    ("remote", "Karen", "I can help with that. You can also call me at four one five, five five five, zero one three two if anything is unclear."),
    ("remote", "Daniel", "Great. The vendor contract is up for renewal on the first of November, so we need a decision by next week."),
    ("remote", "Karen", "I would suggest we get two competing quotes before we commit to another three year term with the same vendor."),
    ("room", "Samantha", "Agreed. Let's schedule a follow up meeting for Thursday and review the revised numbers then."),
]
# Words distinctive to each line, used to find where it landed in the minutes.
KEYS = ["quarterly planning", "infrastructure", "full breakdown", "anything is unclear", "vendor contract",
        "competing quotes", "follow-up meeting"]
LEAKS = ["example", "0132", "Marcus", "Chen"]


def read(path):
    with wave.open(str(path), "rb") as handle:
        samples = array.array("h")
        samples.frombytes(handle.readframes(handle.getnframes()))
        return samples


def write(path, samples):
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        clipped = array.array("h", (max(-32768, min(32767, int(v))) for v in samples))
        handle.writeframes(clipped.tobytes())


def synthesize_call(directory, room_name="room.wav", remote_name="remote.wav"):
    """Speaks SCRIPT with `say` voices into two tracks in `directory`: the room microphone
    (with the call leaking in as speaker echo) and the call's system audio. Returns their paths."""
    directory = Path(directory)
    clips = []
    for index, (_, voice, text) in enumerate(SCRIPT):
        path = directory / f"line-{index}.wav"
        subprocess.run(["say", "-v", voice, "-o", str(path), "--data-format=LEI16@16000", text], check=True)
        clips.append(read(path))
        path.unlink()

    gap = int(0.8 * RATE)
    total = sum(len(clip) + gap for clip in clips)
    room = [0.0] * total
    remote = [0.0] * total
    position = 0
    for (channel, _, _), clip in zip(SCRIPT, clips):
        target = room if channel == "room" else remote
        for offset, value in enumerate(clip):
            target[position + offset] += value
        position += len(clip) + gap
    # Laptop speakers: the remote side reaches the microphone 25 ms later, 10 dB down, with reflections.
    for delay_ms, gain in [(25, 0.32), (37, 0.12), (52, 0.07), (80, 0.04)]:
        delay = delay_ms * RATE // 1000
        for index in range(total - delay):
            room[index + delay] += gain * remote[index]
    write(directory / room_name, room)
    write(directory / remote_name, remote)
    return directory / room_name, directory / remote_name


def main():
    with tempfile.TemporaryDirectory(prefix="mmm-e2e-") as scratch:
        room, remote = synthesize_call(scratch)
        result = subprocess.run(
            [str(ROOT / "mmm"), "transcribe", "--room", str(room), "--remote", str(remote), "--stdout",
             "--redact", "all"],  # everything the redactor can do, not just the default
            capture_output=True, text=True, check=True)
    minutes = result.stdout

    paragraphs = re.findall(r"\*\*(.+?)\*\* · [\d:]+  \n(.+)", minutes)
    failures = []
    speakers_for_voice = {}
    for (channel, voice, _), key in zip(SCRIPT, KEYS):
        found = [speaker for speaker, text in paragraphs if key in text]
        if not found:
            failures.append(f"line with '{key}' is missing")
            continue
        if not all(speaker.startswith("Room" if channel == "room" else "Remote") for speaker in found):
            failures.append(f"'{key}' ({voice}) attributed to {found}; expected the {channel} channel only")
        speakers_for_voice.setdefault(voice, set()).update(found)
    labels = [next(iter(v)) for v in speakers_for_voice.values() if len(v) == 1]
    if len(set(labels)) != len(speakers_for_voice):
        failures.append(f"speakers not told apart: {speakers_for_voice}")
    for leak in LEAKS:
        if leak in minutes:
            failures.append(f"'{leak}' was not redacted")

    if failures:
        print(minutes)
        print("FAILED:\n  " + "\n  ".join(failures))
        sys.exit(1)
    print(f"OK: {len(SCRIPT)} lines on the right channels, {len(speakers_for_voice)} speakers told apart, "
          "no echo duplicates, PII redacted")


if __name__ == "__main__":
    main()
