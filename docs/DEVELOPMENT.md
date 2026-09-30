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
| `scripts/` | `e2e_check.py` (the end-to-end check), plus maintainer tools: `vendor_models.py` (models), `generate_first_names.py` (the name list), and `record_demo.py` with `terminal_render.py` (the README animation) |

Built on [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0), pinned to a
main-branch commit that includes LocalVQE support.
