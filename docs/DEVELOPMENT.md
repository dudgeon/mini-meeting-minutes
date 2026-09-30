# Development

## Build, test, check

```sh
git clone https://github.com/dudgeon/mini-meeting-minutes && cd mini-meeting-minutes
./mmm doctor                                   # builds on first run, then checks everything
swift build --disable-keychain                 # debug build
swift test --disable-keychain                  # tests; see the note below
python3 scripts/e2e_check.py                   # a synthetic call through the whole pipeline
MMM_DEBUG=1 ./mmm transcribe --room a.wav      # diagnostics: utterances (unredacted), windows, timings
```

- **Rebuilding.** `./mmm` rebuilds itself whenever the sources change.
- **`--disable-keychain`** stops SwiftPM blocking on a keychain prompt while it fetches packages.
- **Testing with only the Command Line Tools.** `swift test` needs the testing plugin's path:
  `swift test --disable-keychain -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`.
- **The end-to-end check** speaks a scripted call with macOS voices. It checks that lines land on
  the right channels, that speakers are told apart, that the call's echo isn't transcribed twice,
  and that everything the redactor can do works (`--redact all`).

## Diagnostics

`MMM_DEBUG=1` writes to stderr:

- **Each utterance:** its text before redaction, and how long recognition took.
- **Readings in progress:** the partial recognition of a sentence still being spoken.
- **Each speaker window:** how long diarization and the voice embeddings took, and how each speaker
  turn matched the speakers heard so far.
- **Redaction:** how long it took.
- **Echo removal:** its total time, when the meeting ends.
- **When recording live:** how far behind the meeting each update reached the screen.

It never includes audio. When you record with it, send stderr to a file, because it would scribble
over the screen:

```sh
MMM_DEBUG=1 ./mmm 2>/tmp/mmm-debug.log
```

## Replays: the live path without devices

```sh
./mmm record --replay-room a.wav --replay-remote b.wav [--replay-speed 4]
```

These hidden options feed files through exactly what a live recording uses, screen included,
without touching capture devices or permissions. Press **Space**, then **Y**, to start, as in a
real meeting.

The installer honors `MMM_REPO`, `MMM_BRANCH` and `MMM_HOME` for testing.

## The README animation

`scripts/record_demo.py` records `docs/demo.gif`:

1. It speaks a short scripted call with macOS voices into a temporary folder.
2. It replays the call through `mmm` in a pseudo-terminal, pressing keys on a schedule.
3. It renders every frame with `scripts/terminal_render.py`.

The synthetic audio is deleted afterwards, and if a run is killed, the next run clears its leftovers.

```sh
python3 -m venv /tmp/demo-venv && /tmp/demo-venv/bin/pip install pillow
/tmp/demo-venv/bin/python scripts/record_demo.py                          # docs/demo.gif
/tmp/demo-venv/bin/python scripts/record_demo.py --size 80x24 --stills /tmp/stills   # PNGs instead
/tmp/demo-venv/bin/python scripts/record_demo.py --minutes /tmp/out       # also keep the minutes
```

## Long meetings

`scripts/long_meeting_check.py` plays a synthetic meeting (two voices in the room, two on the call)
through `mmm` faster than real time. It samples the app's memory every 5 seconds and prints:
- memory per quarter hour of meeting, and the peak;
- how far speaker labels trailed the audio.

The defaults (2 hours at 8×) take about 15 minutes.

```sh
python3 scripts/long_meeting_check.py
python3 scripts/long_meeting_check.py --hours 0.5 --speed 4
```

## The explainer video

`scripts/explainer/make.py` makes a one-minute 1080p explainer: two narrators (the Samantha and
Daniel voices) take turns introducing the app while the real app transcribes them.

1. `narration.py` speaks the script into one track.
2. `capture.py` replays that track through `mmm` as the room microphone, in a pseudo-terminal. It
   presses keys on cue (consent, naming, a note, stop) and timestamps everything the app draws.
3. `compose.py` flies a 3D camera over the screen, drawn at 3× by `terminal_render.py`. It adds a
   title, feature captions, the keys pressed, the saved minutes and an end card.

Every shot is anchored to a narration line, a key press, or something the app did, such as telling
the speakers apart or saving. A new capture therefore lines up by itself. The synthetic speech lives
in a temporary folder that's deleted afterwards.

```sh
python3 -m venv /tmp/explainer-venv && /tmp/explainer-venv/bin/pip install pillow numpy imageio-ffmpeg
/tmp/explainer-venv/bin/python scripts/explainer/make.py      # ~/Movies/Mini Meeting Minutes explainer.mp4
/tmp/explainer-venv/bin/python scripts/explainer/make.py --work /tmp/explainer     # keep the capture…
/tmp/explainer-venv/bin/python scripts/explainer/make.py --work /tmp/explainer --reuse --still 21.9   # …to iterate
```

## Privacy guards in the tests

- **`NoAudioOnDiskTests`** fails if the sources ever write audio files or use FluidAudio's
  file-based functions, which spill audio into temporary files.
- **Redaction tests** cover the default categories, company names (kept), and the words-to-keep
  list.
- **The recording flow is tested too:** consent is required before recording starts, and new
  minutes never overwrite existing ones.

## Code layout

| Path | What |
|---|---|
| `Sources/MinutesCore/Capture/` | Microphone (AVAudioEngine) and system audio (Core Audio process tap) capture |
| `Sources/MinutesCore/Pipeline/` | The meeting session, per-channel pipeline, echo removal, speaker embedding and matching |
| `Sources/MinutesCore/Redaction/` | Redaction, and the first-name list |
| `Sources/MinutesCore/Transcript/` | Turns, notes and the markdown minutes |
| `Sources/MinutesCore/Models/` | Finding, joining and checking the vendored models |
| `Sources/mmm/` | The command line, first-run setup, and the meeting loop (`Record.swift`) |
| `Sources/mmm/Screen/` | The screen: the sidebar and synthwave looks, drawing, visualizers and input |
| `Models/` | Vendored Core ML models; see [Models/README.md](../Models/README.md) |
| `install.sh` | The one-line installer |
| `scripts/` | `e2e_check.py` (the end-to-end check), plus maintainer tools: `vendor_models.py` (models), `generate_first_names.py` (the name list), `record_demo.py` with `terminal_render.py` (the README animation), `explainer/` (the explainer video), and `long_meeting_check.py` (memory over a long meeting) |

Built on [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0), pinned to a
main-branch commit that includes LocalVQE support.
