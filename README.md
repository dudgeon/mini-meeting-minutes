# mini-meeting-minutes

Local meeting minutes for Apple silicon Macs. `mmm` listens to the room (your microphone) and your
call (system audio), transcribes both on device, works out who said what, removes personal
information, and writes the result as markdown.

- **Private.** Everything runs on your Mac. Audio is processed in memory and never written to disk.
  Only the minutes are saved, and nothing is sent anywhere.
- **Verbatim.** No summaries and no generative models: the minutes are what was said, attributed to
  speakers.
- **Self-contained.** Every model ships in this repository (about 260 MB), so nothing is downloaded
  at runtime.

```markdown
**Room 1** · 00:00:17
That is concerning. Can you send me the full breakdown? My email is [EMAIL].

**Remote 2** · 00:00:24
I can help with that. You can also call me at [PHONE] if anything is unclear.
```

## Requirements

- An Apple silicon Mac (M2 or later recommended) running macOS 15 or later.
- Swift 6.2 or later: Xcode 26+, or just the Command Line Tools (`xcode-select --install`).

## Getting started

```sh
git clone https://github.com/dudgeon/mini-meeting-minutes
cd mini-meeting-minutes
./mmm doctor        # builds on first run (a few minutes), then checks models and permissions
./mmm               # start recording; press q to stop and save
```

`./mmm` rebuilds itself when the sources change. To put it on your `PATH`, symlink the script, for
example `ln -s "$PWD/mmm" /usr/local/bin/mmm`.

### Permissions

The first recording asks your terminal app (Terminal, iTerm, Ghostty, …) for two permissions, since
macOS grants them to the app that runs `mmm`:

- **Microphone**: System Settings › Privacy & Security › Microphone.
- **System Audio Recording**: System Settings › Privacy & Security › Screen & System Audio
  Recording › **System Audio Recording Only**. Some terminals (iTerm) don't show a prompt; add them
  there by hand.

macOS doesn't report a missing system audio permission. It just delivers silence, so `mmm` warns
you when system audio stays silent while other apps are playing sound. Granting a permission to
your terminal grants it to everything you run in that terminal.

## Using it

### Record a meeting

```sh
./mmm                                  # microphone + system audio
./mmm --title "Roadmap review"         # title for the file name and heading
./mmm --no-mic                         # a call on headphones: remote side only
./mmm --no-system                      # an in-person meeting: room only
./mmm --output ~/Notes/                # a directory, or a path ending in .md
```

While recording, the screen shows the live transcript. New speech appears within a few seconds;
speaker labels usually follow within 30 seconds, once that stretch of audio has been diarized.
Press **p** to pause (audio is dropped, not buffered) and **q** or Ctrl-C to stop.

When you stop, `mmm` re-examines every speaker across the whole meeting, which can renumber a few
labels, then asks you to name each speaker, showing something they said. Press Enter to keep a
label. Giving two labels the same name merges them. The minutes are written to
`~/Documents/Minutes/` by default and kept up to date during the meeting, so a crash loses at most
the last minute or so.

### Options

| Option | Effect |
|---|---|
| `--redact <list>` | What to redact: `all` (default), `none`, or a comma-separated list of `name`, `email`, `phone`, `address`, `id`, `card`, `account`, `ip`. |
| `--no-echo-cancel` | Skip echo cancellation. It's only needed when the call plays through speakers; with headphones you can turn it off. |
| `--mic-device <uid>` | Use a specific input. `./mmm doctor` lists devices and their UIDs. |
| `--no-names` | Don't ask for speaker names at the end. |

### Transcribe existing recordings

```sh
./mmm transcribe --room mic.m4a --remote call.m4a
./mmm transcribe --remote zoom-recording.m4a --stdout
```

This runs files through the same pipeline, much faster than real time. Files are only read.

## How it works

```
microphone ──► echo cancellation ──┐        (system audio is the echo reference)
system audio ──────────────────────┤
                                   ▼  per channel
           voice activity ──► speech recognition ──► words with timestamps
                   │
                   └► 30–60 s window ──► diarization ──► voice embedding per segment
                                                               │
                meeting-wide speaker matching ◄────────────────┘
                                   │
                                   ▼
                     words → speakers → PII redaction → markdown
```

- **Two channels.** The microphone is the *room* and system audio is the *remote* side. Each
  channel is transcribed and diarized separately, so labels read "Room 1" or "Remote 2".
- **Echo cancellation** ([LocalVQE](https://github.com/localai-org/LocalVQE)) removes
  remote voices that reach the microphone through your speakers, using the captured system audio as
  the reference. Without it, every remote sentence would also be transcribed as a room speaker.
- **Speech recognition** is [Parakeet](https://huggingface.co/moondream/parakeet-redux), a
  transducer model rather than a language model, which makes it far less prone to inventing text.
  It covers English and 24 other European languages. Voice activity detection
  ([Silero](https://github.com/snakers4/silero-vad)) cuts speech into utterances.
- **Diarization** runs the pyannote community-1 pipeline on rolling 30–60 second windows. Each
  diarized segment then gets its own voice embedding. Speakers are matched across windows by voice,
  and at the end every segment is re-clustered together, so labels stay consistent across a
  multi-hour meeting without keeping audio.
- **Redaction** runs on device: Apple's named-entity recognizer and a 20,000-name first-name list
  for names, data detectors for phone numbers and street addresses, and patterns for emails, ID,
  card, account and IP numbers. The patterns include spoken and misrecognized forms such as "jane
  dot doe at example dot com" or "415. 555, 0132". Organization and place names are kept.

### What is and isn't kept

| Data | Where | How long |
|---|---|---|
| Audio | Memory only | Seconds to about a minute per channel (the current diarization window), then released |
| Unredacted text | Memory only | Until its window is attributed and redacted |
| Voice embeddings (numeric voice fingerprints) | Memory only | Until `mmm` exits, to keep labels consistent |
| Minutes | The markdown file | Yours to keep; redacted before writing |

No audio is ever written to disk, nor is unredacted text unless you pass `--redact none`. The app
makes no network requests.
FluidAudio's model downloader is switched off. Building needs the network to fetch Swift packages.

## Limitations

- **Speaker labels are anonymous and per channel.** `mmm` distinguishes voices; it doesn't know
  who anyone is until you name them. People sharing one microphone are separated by voice, which
  is harder than separating people on different channels.
- **Overlapping speech** is attributed to whoever dominates it.
- **Redaction is best effort.** Misrecognized names ("Praya" for Priya) and surnames on their own
  can slip through. Read the minutes before sharing them.
- **Echo cancellation is beta** upstream. If remote voices still show up as room speakers, wear
  headphones or use `--no-mic`.
- Name redaction is tuned for English.

## Development

```sh
swift build --disable-keychain                 # debug build
swift test --disable-keychain                  # tests; see the note below
MMM_DEBUG=1 ./mmm transcribe --room a.wav      # print utterances (unredacted), windows, speaker matching
```

With only the Command Line Tools installed, `swift test` needs the testing plugin's path:
`swift test --disable-keychain -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`.

`mmm record --replay-room a.wav --replay-remote b.wav [--replay-speed 4]` (hidden options) plays
files through the live path, including the screen, without touching capture devices or
permissions.

| Path | What |
|---|---|
| `Sources/MinutesCore/Capture/` | Microphone (AVAudioEngine) and system audio (Core Audio process tap) capture |
| `Sources/MinutesCore/Pipeline/` | Session, per-channel pipeline, echo cancellation, speaker embedding and matching |
| `Sources/MinutesCore/Redaction/` | PII redaction |
| `Sources/MinutesCore/Transcript/` | Turns and the markdown document |
| `Sources/mmm/` | Command line and live screen |
| `Models/` | Vendored Core ML models; see [Models/README.md](Models/README.md) |
| `scripts/` | Maintainer tools: `vendor_models.py` (models), `generate_first_names.py` (name list) |

Built on [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0), pinned to a
main-branch commit that includes LocalVQE support. Model licenses and attribution are in
[Models/README.md](Models/README.md).
