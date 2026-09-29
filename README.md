# Mini Meeting Minutes

Mini Meeting Minutes writes down what was said in your meetings, and who said it, entirely on
your Mac. It listens to the people in the room and to the people on your call, then saves the
conversation as text, with names, email addresses, phone numbers and other personal details
blanked out.

- **Private.** Nothing leaves your Mac and the audio is never saved. Only the written minutes are.
- **Word for word.** No AI summaries: the minutes are exactly what was said.

```markdown
**Room 1** · 00:00:17
That is concerning. Can you send me the full breakdown? My email is [EMAIL].

**Remote 2** · 00:00:24
I can help with that. You can also call me at [PHONE] if anything is unclear.
```

## Install

You need a Mac with Apple silicon (M1 or newer) running macOS 15 or newer. Installing takes about
10 minutes, once.

1. Open **Terminal**: press **⌘ Space**, type **Terminal**, and press **Return**.
2. Copy this line, paste it into Terminal with **⌘ V**, and press **Return**:

   ```
   curl -fsSL https://raw.githubusercontent.com/dudgeon/mini-meeting-minutes/main/install.sh | bash
   ```

3. If a window asks to install the **command line developer tools**, click **Install**, then
   **Agree**. The installer waits for them and carries on by itself.
4. When Terminal says **All set!**, you're done. You can close Terminal.

## Record a meeting

1. Double-click **Mini Meeting Minutes** on your Desktop.
2. The first time, your Mac asks whether **Terminal** may use the microphone and record system
   audio. Click **Allow** both times.
3. When the meeting is over, press **Q**. Type a name for each speaker (or press **Return** to
   skip them), then press **Return** once more to open your minutes.

Your minutes are saved in the **Minutes** folder inside **Documents**.

## Something not right?

- **People on the call are missing.** Open **System Settings › Privacy & Security › Screen &
  System Audio Recording** and turn on **Terminal** under **System Audio Recording Only**. Then
  quit Terminal (**⌘ Q**) and start again.
- **People in the room are missing.** Open **System Settings › Privacy & Security › Microphone**
  and turn on **Terminal**.
- **One person appears as two speakers.** Give both the same name when you stop, and they're
  combined.

**To update**, paste the install line into Terminal again.
**To uninstall**, paste this line instead. Your minutes are kept.

```
curl -fsSL https://raw.githubusercontent.com/dudgeon/mini-meeting-minutes/main/install.sh | bash -s -- --uninstall
```

---

*Everything below is extra detail; you don't need it to use Mini Meeting Minutes.*

## Using it from Terminal

After installing, open a new Terminal window and type `mmm`, optionally with options:

```sh
mmm                                  # microphone + system audio
mmm --title "Roadmap review"         # title for the file name and heading
mmm --no-mic                         # a call on headphones: remote side only
mmm --no-system                      # an in-person meeting: room only
mmm --output ~/Notes/                # a folder, or a file name ending in .md
mmm doctor                           # check the models, permissions and microphones
```

While recording, the screen shows the live transcript. New speech appears within a few seconds;
speaker labels usually follow within 30 seconds, once that stretch of audio has been analyzed.
Press **p** to pause (audio is dropped, not buffered) and **q** or Ctrl-C to stop.

When you stop, `mmm` re-examines every speaker across the whole meeting, which can renumber a few
labels, then asks you to name each speaker, showing something they said. The minutes are written
to `~/Documents/Minutes/` and kept up to date during the meeting, so a crash loses at most the
last minute or so.

| Option | Effect |
|---|---|
| `--redact <list>` | What to redact: `all` (default), `none`, or a comma-separated list of `name`, `email`, `phone`, `address`, `id`, `card`, `account`, `ip`. |
| `--no-echo-cancel` | Skip echo cancellation. It's only needed when the call plays through speakers; with headphones you can turn it off. |
| `--mic-device <uid>` | Use a specific microphone. `mmm doctor` lists them. |
| `--no-names` | Don't ask for speaker names at the end. |

To transcribe recordings you already have (they're only read, never changed):

```sh
mmm transcribe --room mic.m4a --remote call.m4a
mmm transcribe --remote zoom-recording.m4a --stdout
```

### Permissions

macOS grants the microphone and system audio permissions to the app that runs `mmm`: Terminal
when you use the Desktop shortcut, or whichever terminal you type `mmm` in (iTerm, Ghostty, …).
Some terminals, including iTerm, never show the system audio prompt; add them by hand under
**Screen & System Audio Recording › System Audio Recording Only**. Granting a permission to a
terminal grants it to everything you run in that terminal.

macOS doesn't report a missing system audio permission; it just delivers silence. `mmm` warns you
when system audio stays silent while other apps are playing sound.

### What the installer does

It checks your Mac, installs Apple's command line developer tools if needed (they include Swift,
which builds the app), downloads this repository to `~/Applications/mini-meeting-minutes`, builds
it, and verifies the speech models. Then it puts the **Mini Meeting Minutes** shortcut on your
Desktop and the `mmm` command in `~/.local/bin`, adding that folder to your `PATH` in
`~/.zprofile`. Nothing needs an administrator password. The log is at
`~/Library/Logs/mini-meeting-minutes-install.log`.

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
- **Self-contained.** Every model ships in this repository (about 260 MB), so nothing is
  downloaded at runtime.

### What is and isn't kept

| Data | Where | How long |
|---|---|---|
| Audio | Memory only | Seconds to about a minute per channel (the current diarization window), then released |
| Unredacted text | Memory only | Until its window is attributed and redacted |
| Voice embeddings (numeric voice fingerprints) | Memory only | Until `mmm` exits, to keep labels consistent |
| Minutes | The markdown file | Yours to keep; redacted before writing |

No audio is ever written to disk, nor is unredacted text unless you pass `--redact none`. The app
makes no network requests: FluidAudio's model downloader is switched off. Installing and building
need the network to fetch the repository and Swift packages.

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
git clone https://github.com/dudgeon/mini-meeting-minutes && cd mini-meeting-minutes
./mmm doctor                                   # builds on first run, then checks everything
swift build --disable-keychain                 # debug build
swift test --disable-keychain                  # tests; see the note below
python3 scripts/e2e_check.py                   # a synthetic call through the whole pipeline
MMM_DEBUG=1 ./mmm transcribe --room a.wav      # print utterances (unredacted), windows, speaker matching
```

`./mmm` rebuilds itself whenever the sources change. `--disable-keychain` stops SwiftPM from
blocking on a keychain prompt while it fetches packages. With only the Command Line Tools
installed, `swift test` needs the testing plugin's path:
`swift test --disable-keychain -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`.

`mmm record --replay-room a.wav --replay-remote b.wav [--replay-speed 4]` (hidden options) plays
files through the live path, including the screen, without touching capture devices or
permissions. The installer honors `MMM_REPO`, `MMM_BRANCH` and `MMM_HOME` for testing.

| Path | What |
|---|---|
| `Sources/MinutesCore/Capture/` | Microphone (AVAudioEngine) and system audio (Core Audio process tap) capture |
| `Sources/MinutesCore/Pipeline/` | Session, per-channel pipeline, echo cancellation, speaker embedding and matching |
| `Sources/MinutesCore/Redaction/` | PII redaction |
| `Sources/MinutesCore/Transcript/` | Turns and the markdown document |
| `Sources/mmm/` | Command line, first-run setup and live screen |
| `Models/` | Vendored Core ML models; see [Models/README.md](Models/README.md) |
| `install.sh` | The one-line installer |
| `scripts/` | `e2e_check.py` (end-to-end check with `say` voices); maintainer tools `vendor_models.py` (models) and `generate_first_names.py` (name list) |

Built on [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0), pinned to a
main-branch commit that includes LocalVQE support.

## License

The code is available under the [MIT license](LICENSE). The models in `Models/` are third-party
works under their own licenses (CC-BY-4.0, MIT and Apache-2.0); see
[Models/README.md](Models/README.md) for each license, attribution and citations.
