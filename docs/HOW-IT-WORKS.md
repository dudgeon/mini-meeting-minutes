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

- Everything still in progress is finished, and every speaker turn in the meeting is compared with
  every other, which fixes labels that drifted.
- Names given during the meeting move with the voices they belong to.

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

What you see on screen is shaped mostly by waiting on purpose, not by computing:

- **Words appear within a second or two** of being spoken, and are refined within a second of the
  speaker pausing.
- **Who said them follows a couple of seconds after a pause**, and within about 15 to 30 seconds
  even in non-stop conversation. That's how long the speaker analysis waits, so it has enough of
  each voice to go on.

Smaller Macs have less headroom. [The roadmap](ROADMAP.md) has the plan for making sure the app
keeps up on them. `MMM_DEBUG=1` shows the timing of every step (see
[Development](DEVELOPMENT.md)).
