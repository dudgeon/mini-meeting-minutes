"""The explainer's soundtrack: the narration, a quiet music bed that dips while anyone speaks, and a
few small sound effects on what happens on screen. Everything is synthesized here: no audio files.

The music and effects follow pipeline/mix.py in github.com/dudgeon/reqs-as-theory-building.
"""

import numpy as np
from scipy.signal import butter, istft, sosfilt, stft

RATE = 48000
NOTE_D = 293.66  # D4
PENTATONIC = [0, 2, 4, 7, 9, 12, 14, 16, 19, 21]  # D major pentatonic, in semitones
_noise = np.random.default_rng(11)


def hz(semitones):
    return NOTE_D * 2 ** (semitones / 12)


def decay(n, tau):
    return np.exp(-np.arange(n) / (tau * RATE))


def tone(f, seconds, tau=None, partials=((1, 1.0),), f_end=None):
    n = int(seconds * RATE)
    t = np.arange(n) / RATE
    if f_end is None:
        phase = 2 * np.pi * f * t
    else:  # an exponential glide
        k = np.log(f_end / f) / seconds
        phase = 2 * np.pi * f * (np.exp(k * t) - 1) / k
    y = sum(a * np.sin(phase * m) for m, a in partials)
    if tau:
        y = y * decay(n, tau)
    attack = min(n, int(0.004 * RATE))
    y[:attack] *= np.linspace(0, 1, attack)
    return y


def band_noise(seconds, low, high):
    return sosfilt(butter(2, [low, high], btype="band", fs=RATE, output="sos"),
                   _noise.standard_normal(int(seconds * RATE)))


def sweep_noise(seconds, f0, f1, width=0.8):
    """Noise whose spectral peak glides from f0 to f1."""
    n = int(seconds * RATE) + 1024
    f, _, spectrum = stft(_noise.standard_normal(n), RATE, nperseg=1024)
    centre = np.exp(np.linspace(np.log(f0), np.log(f1), spectrum.shape[1]))
    mask = np.exp(-((np.log(np.maximum(f, 20))[:, None] - np.log(centre)[None, :]) ** 2) / (2 * width ** 2))
    _, y = istft(spectrum * mask, RATE, nperseg=1024)
    return y[: int(seconds * RATE)]


def swell(y, attack=0.3):
    """Rises for `attack` of its length, then falls away."""
    a = max(1, int(len(y) * attack))
    return y * np.concatenate([np.sin(np.linspace(0, np.pi / 2, a)) ** 2,
                               np.cos(np.linspace(0, np.pi / 2, len(y) - a)) ** 2])


def peak(y, level):
    top = np.abs(y).max()
    return y * (level / top) if top > 0 else y


def effect(kind, gain=1.0, seconds=0.5, note=0):
    if kind == "click":  # a key pressed
        return peak(tone(1300, 0.05, 0.008) + band_noise(0.05, 2500, 7000) * decay(int(0.05 * RATE), 0.004), 0.12 * gain)
    if kind == "typing":
        n = int(seconds * RATE)
        y = np.zeros(n)
        t = 0.0
        while t < seconds - 0.05:
            i = int(t * RATE)
            key = band_noise(0.03, 1800, 5000) * decay(int(0.03 * RATE), 0.005) * _noise.uniform(0.5, 1)
            y[i:i + len(key)] += key[: n - i]
            t += _noise.uniform(0.06, 0.12)
        return peak(y, 0.05 * gain)
    if kind == "whoosh":
        return peak(swell(sweep_noise(seconds, 250, 2200), 0.55), 0.08 * gain)
    if kind == "chime":
        f = hz(PENTATONIC[note % len(PENTATONIC)] + 12)
        y = tone(f, 2.2, 0.7, ((1, 1), (2.76, 0.25), (5.4, 0.08))) + 0.35 * tone(f * 2, 2.2, 0.35)
        return peak(y, 0.07 * gain)
    raise ValueError(kind)


CHORDS = {  # semitones from D4, bass first
    "D": [-12, 0, 4, 7, 11, 16], "Bm": [-15, -3, 2, 6, 9, 14], "G": [-17, -5, 2, 7, 11, 14],
    "Asus": [-19, -7, 2, 4, 9, 14],
}


def music_bed(seconds):
    """Soft sine-pad chords, D–Bm–G–Asus, six seconds each with slow cross-fades, low-passed."""
    n = int(seconds * RATE)
    left, right = np.zeros(n), np.zeros(n)
    t = np.arange(n) / RATE
    start, k = 0.0, 0
    while start < seconds:
        chord = CHORDS[["D", "Bm", "G", "Asus"][k % 4]]
        a, b = start - 1.5, start + 6 + 1.5
        i0, i1 = max(0, int(a * RATE)), min(n, int(b * RATE))
        tt = t[i0:i1]
        envelope = np.sin(np.clip((tt - a) / 2.2, 0, 1) * np.clip((b - tt) / 2.2, 0, 1) * np.pi / 2) ** 2
        for j, semitones in enumerate(chord):
            f = hz(semitones)
            amplitude = (0.5 if j == 0 else 0.26) / (1 + 0.15 * j)
            for side, cents, phase in ((left, -4, 0.0), (right, 4, 1.3)):
                ff = f * 2 ** (cents / 1200)
                wobble = 1 + 0.002 * np.sin(2 * np.pi * 0.13 * tt + phase + j)
                side[i0:i1] += amplitude * envelope * (
                    np.sin(2 * np.pi * ff * wobble * tt + phase + j) + 0.12 * np.sin(4 * np.pi * ff * tt + phase))
        start, k = start + 6, k + 1
    low = butter(2, 1800, btype="low", fs=RATE, output="sos")
    return np.stack([sosfilt(low, left), sosfilt(low, right)], axis=1)


def mix(voice, events):
    """The narration (mono, at RATE), the music bed, and `events` of (seconds, kind, options) as a
    stereo float track. Loudness is set when the video is encoded."""
    n = len(voice)
    music = music_bed(n / RATE)
    music *= 10 ** (-36 / 20) / (np.sqrt((music ** 2).mean()) + 1e-12)  # about 15 LU under the voice
    # Dip under speech, fade in and out.
    speaking = np.convolve(np.abs(voice), np.ones(int(0.05 * RATE)) / int(0.05 * RATE), mode="same") > 0.01
    smooth = int(0.35 * RATE)
    duck = np.convolve(np.where(speaking, 0.55, 1.0), np.ones(smooth) / smooth, mode="same")
    fade = np.clip(np.arange(n) / (1.2 * RATE), 0, 1) * np.clip((n - np.arange(n)) / (2.0 * RATE), 0, 1)
    music *= (duck * fade)[:, None]
    effects = np.zeros(n)
    for at, kind, options in events:
        y = effect(kind, **options)
        i = int(at * RATE)
        if 0 <= i < n:
            effects[i:i + len(y)] += y[: n - i]
    track = music + (voice + effects)[:, None]
    top = np.abs(track).max()
    return track * (0.95 / top) if top > 0.95 else track
