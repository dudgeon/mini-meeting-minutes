"""The explainer's script, spoken by two voices into one track, with when each line starts and ends.

The track plays as the room microphone during the capture. A silent track stands in for the call.

Voices, best first (the approach of github.com/dudgeon/reqs-as-theory-building):
- `openrouter`: Gemini text-to-speech through OpenRouter, with a direction for each voice. Needs
  OPENROUTER_API_KEY.
- `kokoro`: Kokoro-82M, a small neural voice model run on this Mac. Needs the `kokoro` package
  (Python 3.10 to 3.12); the model downloads once.
- `say`: macOS's built-in voices, if nothing better is installed. Robotic.

Each line is synthesized on its own, trimmed of silence and brought to the same loudness, so the
two voices match.
"""

import json
import os
import subprocess
import sys
import tempfile
import time
import wave

import numpy as np

RATE = 48000
HER, HIM = "her", "him"
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

# Who speaks in each engine. The Kokoro pair scored best in a test through the app's own
# recognizer (no words missed) and speak at the same pace, about 171 words a minute.
VOICES = {
    "openrouter": {HER: "Sulafat", HIM: "Achird"},
    "kokoro": {HER: "af_heart", HIM: "am_fenrir"},
    "say": {HER: "Samantha", HIM: "Daniel"},
}
KOKORO_SPEED = 0.92  # about 180 words a minute: unhurried, like a conversation
OPENROUTER_MODEL = "google/gemini-3.8-flash-tts"
STYLE = (
    "Two friendly colleagues showing a small app they like: warm, relaxed and conversational, lightly upbeat, "
    "natural pauses, never salesy or announcer-like.")


def engine_available(name):
    if name == "openrouter":
        return bool(os.environ.get("OPENROUTER_API_KEY"))
    if name == "kokoro":
        try:
            import kokoro  # noqa: F401
            return True
        except ImportError:
            return False
    return name == "say"


def best_engine():
    return next(name for name in ("openrouter", "kokoro", "say") if engine_available(name))


def resample(audio, rate):
    if rate == RATE:
        return audio
    from math import gcd

    from scipy.signal import resample_poly
    divisor = gcd(rate, RATE)
    return resample_poly(audio, RATE // divisor, rate // divisor).astype(np.float32)


_kokoro = {}


def speak_kokoro(text, voice):
    from kokoro import KPipeline
    language = "b" if voice.startswith("b") else "a"  # British or American English
    if language not in _kokoro:
        _kokoro[language] = KPipeline(lang_code=language, repo_id="hexgrad/Kokoro-82M")
    parts = [r.audio.numpy() for r in _kokoro[language](text, voice=voice, speed=KOKORO_SPEED, split_pattern=None)
             if r.audio is not None]
    return resample(np.concatenate(parts), 24000)


def speak_openrouter(text, voice):
    import urllib.request
    body = {
        "model": OPENROUTER_MODEL, "input": text, "voice": voice, "response_format": "mp3",
        "provider": {"options": {
            "google-ai-studio": {"speech_metadata": {"style": STYLE}},
            "google-vertex": {"speech_metadata": {"style": STYLE}},
        }},
    }
    base = os.environ.get("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1").rstrip("/")
    request = urllib.request.Request(
        base + "/audio/speech", data=json.dumps(body).encode(), method="POST",
        headers={"Authorization": f"Bearer {os.environ['OPENROUTER_API_KEY']}", "Content-Type": "application/json",
                 "HTTP-Referer": "https://github.com/dudgeon/mini-meeting-minutes", "X-Title": "Mini Meeting Minutes"})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                mp3 = response.read()
            break
        except Exception as error:  # rate limits and server hiccups: try again, a little later
            if attempt == 3:
                raise SystemExit(f"OpenRouter text-to-speech failed: {error}")
            time.sleep(2 ** (attempt + 1))
    return decode(mp3, ".mp3")


def speak_say(text, voice):
    with tempfile.TemporaryDirectory(prefix="mmm-say-") as folder:
        path = os.path.join(folder, "line.wav")
        subprocess.run(["say", "-v", voice, "-o", path, f"--data-format=LEI16@{RATE}", text], check=True)
        with wave.open(path, "rb") as handle:
            samples = np.frombuffer(handle.readframes(handle.getnframes()), np.int16)
    return samples.astype(np.float32) / 32768


def decode(data, suffix):
    """Audio of any format to mono float samples at RATE, with ffmpeg."""
    import imageio_ffmpeg
    with tempfile.TemporaryDirectory(prefix="mmm-tts-") as folder:
        source = os.path.join(folder, "line" + suffix)
        with open(source, "wb") as handle:
            handle.write(data)
        raw = subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), "-v", "error", "-i", source, "-ac", "1", "-ar", str(RATE),
                              "-f", "f32le", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.float32).copy()


def trim_and_level(audio, target_db=-20.0):
    """Trims the silence around a line, fades its edges, and brings its speech to `target_db` RMS,
    so every line, from either voice, sits at the same loudness."""
    window = int(0.01 * RATE)
    frames = audio[: len(audio) // window * window].reshape(-1, window)
    envelope = np.abs(frames).max(axis=1)
    if not len(envelope) or envelope.max() <= 0:
        return audio
    active = np.where(envelope > envelope.max() * 10 ** (-40 / 20))[0]
    start = max(0, active[0] * window - int(0.03 * RATE))
    end = min(len(audio), (active[-1] + 1) * window + int(0.09 * RATE))
    audio = audio[start:end].astype(np.float32).copy()
    frames = audio[: len(audio) // window * window].reshape(-1, window)
    rms = np.sqrt((frames ** 2).mean(axis=1))
    voiced = rms[rms > rms.max() * 10 ** (-30 / 20)]
    level = 20 * np.log10(np.sqrt((voiced ** 2).mean()) + 1e-9)
    audio *= 10 ** ((target_db - level) / 20)
    fade_in, fade_out = int(0.005 * RATE), int(0.04 * RATE)
    audio[:fade_in] *= np.linspace(0, 1, fade_in)
    audio[-fade_out:] *= np.linspace(1, 0, fade_out)
    peak = np.abs(audio).max()
    return audio * (0.98 / peak) if peak > 0.98 else audio


SPEAKERS = {"openrouter": speak_openrouter, "kokoro": speak_kokoro, "say": speak_say}


def speak(work, engine=None):
    """Writes narration.wav, call.wav (silence) and timeline.json into `work`. Returns the timeline."""
    engine = engine or best_engine()
    if not engine_available(engine):
        raise SystemExit(f"The {engine} voices aren't available here.")
    voices = VOICES[engine]
    track = [np.zeros(int(LEAD * RATE), np.float32)]
    position = LEAD
    timeline = []
    for who, text, gap in LINES:
        clip = trim_and_level(SPEAKERS[engine](text, voices[who]))
        timeline.append({"voice": voices[who], "text": text, "start": round(position, 3),
                         "end": round(position + len(clip) / RATE, 3)})
        track += [clip, np.zeros(int(gap * RATE), np.float32)]
        position += (len(clip) + int(gap * RATE)) / RATE
    samples = np.clip(np.concatenate(track), -1, 1)
    for name, data in [("narration.wav", samples), ("call.wav", np.zeros_like(samples))]:
        with wave.open(str(work / name), "wb") as handle:
            handle.setnchannels(1)
            handle.setsampwidth(2)
            handle.setframerate(RATE)
            handle.writeframes((data * 32767).astype(np.int16).tobytes())
    (work / "timeline.json").write_text(json.dumps({"engine": engine, "lines": timeline}, indent=1))
    words = sum(len(text.split()) for _, text, _ in LINES)
    speech = sum(line["end"] - line["start"] for line in timeline)
    print(f"voices: {engine} ({voices[HER]} and {voices[HIM]}), {words / speech * 60:.0f} words a minute",
          file=sys.stderr)
    return timeline
