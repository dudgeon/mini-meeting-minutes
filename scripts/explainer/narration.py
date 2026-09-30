"""The explainer's script, spoken by two macOS voices into one track, with when each line starts and ends.

The track plays as the room microphone during the capture. A silent track stands in for the call.
"""

import array
import json
import subprocess
import wave

RATE = 44100
HER, HIM = "Samantha", "Daniel"
LEAD = 0.35  # silence before the first word
# (voice, text, silence after). capture.py presses keys when lines end, and compose.py anchors the
# camera and captions to the lines, so lines can be reworded without retiming anything by hand.
LINES = [
    (HER, "Hi! This is Mini Meeting Minutes, transcribing us live, right on this Mac.", 0.35),
    (HIM, "It runs in your terminal, and it's one hundred percent private and local.", 0.35),
    (HER, "It never saves audio. Just the words.", 0.35),
    (HIM, "And it's open source, so you can check every line.", 2.8),  # time for the app to tell us apart
    (HER, "Oh, look! It just worked out which of us is which.", 0.4),
    (HIM, "This is speaker identification. To put our names on the notes, just type slash name.", 1.7),
    (HER, "Now I'm Sam, and he's Dan. Need to remember something? Just type it, as a quick inline note.", 1.0),
    (HIM, "When you're done, type slash stop, and your minutes are saved as a markdown file.", 3.2),
    (HER, "Mini Meeting Minutes. Private, local, and open source.", 1.0),  # moved to the end card
]


def speak(work):
    """Writes narration.wav, call.wav (silence) and timeline.json into `work`."""
    samples = array.array("h", [0] * int(LEAD * RATE))
    timeline = []
    for index, (voice, text, gap) in enumerate(LINES):
        path = work / f"line-{index}.wav"
        subprocess.run(["say", "-v", voice, "-o", str(path), f"--data-format=LEI16@{RATE}", text], check=True)
        with wave.open(str(path), "rb") as handle:
            clip = array.array("h")
            clip.frombytes(handle.readframes(handle.getnframes()))
        path.unlink()
        start = len(samples) / RATE
        samples.extend(clip)
        timeline.append({"voice": voice, "text": text, "start": round(start, 3), "end": round(len(samples) / RATE, 3)})
        samples.extend([0] * int(gap * RATE))
    for name, data in [("narration.wav", samples), ("call.wav", array.array("h", [0] * len(samples)))]:
        with wave.open(str(work / name), "wb") as handle:
            handle.setnchannels(1)
            handle.setsampwidth(2)
            handle.setframerate(RATE)
            handle.writeframes(data.tobytes())
    (work / "timeline.json").write_text(json.dumps(timeline, indent=1))
    return timeline
