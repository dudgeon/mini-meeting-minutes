# How it works

```
microphone ──► echo removal ──┐        (the call's audio is the echo reference)
system audio ─────────────────┤
                              ▼  per channel
      voice activity ──► speech recognition ──► words with timestamps (shown at once)
              │
              └► 15–30 s window ──► who spoke when ──► a voice embedding per segment
                                                               │
                meeting-wide speaker matching ◄────────────────┘
                              │
                              ▼
                words → speakers → redaction → minutes (markdown)
```

## The pieces

**Two channels.**

- The microphone is the room and the Mac's system audio is the call. The call side is captured
  with a Core Audio process tap, so it hears any app without joining the meeting.
- Each channel is transcribed and diarized (split by speaker) separately, so labels read "Room 1"
  or "Remote 2", and people on different sides never get mixed up.

**Echo removal.**

- When the call plays through your speakers, its voices reach the microphone too. Left alone, every
  remote sentence would also be transcribed as a room speaker.
- [LocalVQE](https://github.com/localai-org/LocalVQE) takes them out, using the captured call audio
  as the reference.

**Voice activity and recognition.**

- [Silero VAD](https://github.com/snakers4/silero-vad) finds where speech starts and stops, cutting
  it into utterances of up to 14 seconds.
- [Parakeet](https://huggingface.co/moondream/parakeet-redux) turns each utterance into words with
  timestamps. It's a transducer, not a language model, which makes it far less prone to inventing
  text.
- While someone is still talking, the utterance so far is recognized about every 1.5 seconds, so
  words appear as they're spoken. The whole utterance is recognized again when the speaker pauses.

**Who spoke when.**

- Audio collects in a rolling window of each channel. The window closes at the first pause after 15
  seconds, after 2 seconds of silence, or at 30 seconds whatever happens.
- The pyannote community-1 pipeline then works out who spoke when within the window.
- Each speaker turn gets its own voice embedding (a numeric fingerprint of the voice) from the
  WeSpeaker model.
- The embeddings are matched against the speakers heard so far, so labels stay consistent across a
  long meeting without keeping any audio. Once a window is done, its audio is released.

**The end of the meeting.**

- Everything still in progress is finished. Then every speaker turn in the meeting is checked
  against each speaker's overall voice, which fixes labels that drifted. The check takes time in
  proportion to the meeting's length, not its square.
- Names given during the meeting move with the voices they belong to.

**Recordings you already have** take the same path, read from the file as fast as the Mac allows.
The readings of unfinished sentences are skipped, since each sentence is complete moments later
anyway.

**Redaction** runs on each passage before it's shown or saved:

- patterns for ID, card and account numbers (on by default);
- when switched on, Apple's name recognizer with a 20,000-name first-name list, data detectors for
  phone numbers and street addresses, and patterns for emails, spoken and misheard forms included.

**The minutes** are rewritten after each window and each note, and finalized at the end. See
[Features](FEATURES.md#the-minutes) for what's in them.

## Models

All four models run on device through Core ML and ship in [`Models/`](../Models/README.md)
(about 260 MB). None of them are generative.

| Model | Job | Size |
|---|---|---|
| Parakeet Redux | Speech recognition, English and 24 other European languages | 220 MB |
| pyannote community-1 with WeSpeaker | Speaker segmentation and voice embeddings | 22 MB |
| Silero VAD | Voice activity | 1 MB |
| LocalVQE | Echo removal and noise suppression | 20 MB |

## Speed

The work itself is quick. These timings are from a three-voice test meeting (one person in the
room, two on the call) on an M6 Mac mini:

| Step | Time |
|---|---|
| Recognizing a 5–8 second utterance | 60–100 ms (the first one is slower, about 0.9 s, so the models are warmed up before you start) |
| Working out who spoke in a window | 60–210 ms |
| Voice embeddings for a window | 4–12 ms |
| Redaction of a passage | about 1 ms |
| Echo removal, for 49 seconds of audio | 0.1 s in all |
| Transcribing a 49-second recording from files, including loading the models | 3.8 s, using about 610 MB of memory |

A recording you already have is read at about 75 times real time: a 3-minute voice memo took
2.5 seconds.

## Memory

Measured with a 2-hour synthetic meeting played through the app, sampling its memory every 5
seconds:

- **About 630 MB at the peak, while the models load.** The same peak shows up in a 5-minute
  meeting, so it doesn't grow with length.
- **250–480 MB while recording, and flat.** The median rose only from about 361 MB to about
  374 MB between minute 15 and minute 120.
- **Speaker labels kept pace throughout,** trailing the audio by the same 3–4 seconds at the end as
  at the start.

What's held stays small:
- **Audio:** at most about 30 seconds per channel, while its speakers are worked out. The screen
  shows how much.
- **What grows with the meeting:** the text, and one voice fingerprint (about 1 KB) per speaker
  turn. That's a megabyte or two an hour.

The one way memory could climb is a Mac too slow to keep up: audio would queue in memory while it
waits. The [roadmap](ROADMAP.md#running-well-on-smaller-macs) caps that queue.

What you see on screen is shaped mostly by waiting on purpose, not by computing:

- **Words appear within a second or two** of being spoken, and are refined within a second of the
  speaker pausing.
- **Who said them follows a couple of seconds after a pause**, and within about 15 to 30 seconds
  even in non-stop conversation. That's how long the speaker analysis waits, so it has enough of
  each voice to go on.

Smaller Macs have less headroom. [The roadmap](ROADMAP.md) has the plan for making sure the app
keeps up on them. `MMM_DEBUG=1` shows the timing of every step (see
[Development](DEVELOPMENT.md)).
