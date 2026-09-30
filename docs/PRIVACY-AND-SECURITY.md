# Privacy and security

Mini Meeting Minutes is meant to be something you can run in a sensitive meeting without a second
thought. This page is its trust model: what it does with the sound and words it handles, what it
never does, how that's enforced, and what's still up to you.

## In short

- **Everything runs on your Mac.** Speech recognition, telling speakers apart, echo removal and
  redaction are all done by models and Apple frameworks running on your Mac's own chips. There are
  no servers, accounts, subscriptions or analytics.
- **It makes no network connections.** The speech models ship inside this repository and are
  loaded from disk. The app has no networking code, and the one library that could download
  models has that switched off.
- **Audio is never written to disk.** Sound stays in memory only as long as it takes to transcribe
  it and work out who spoke (about 30 seconds at most), then it's discarded.
- **Only the minutes are kept**, as a plain text file in a folder you choose.
- **Everyone has to agree first.** Before each recording the app asks you to confirm that everyone
  taking part knows it's being recorded and transcribed, and agrees.
- **Sensitive numbers are blanked out** before anything is shown or saved. More kinds of personal
  details can be blanked out on request.
- **Nothing is hidden.** Every line of code, and every model with its license, is in this
  repository.

## Local inference only

Four models do the work, all vendored in [`Models/`](../Models/README.md) (about 260 MB) and run
through Apple's Core ML:

| Model | Job |
|---|---|
| Parakeet Redux | Speech recognition |
| Silero VAD | Finding where speech starts and stops |
| pyannote community-1 with WeSpeaker embeddings | Telling voices apart |
| LocalVQE | Removing the call's voices from the microphone when you use speakers |

Redaction uses Apple's on-device NaturalLanguage and data-detector frameworks and a list of first
names compiled into the app.

None of these models are generative: nothing writes text of its own, summarizes, or "fills in"
what it thinks was said. The speech recognizer is a transducer, which maps sound to words and is
far less prone to inventing text than the large language models behind many transcription
services.

**Network.** At runtime the app makes no network requests. Its code contains no networking, and it
turns off the model downloader in FluidAudio, the speech toolkit it's built on
(`ModelHub.offlineMode = true` in `Sources/MinutesCore/Models/ModelLoader.swift`). Only installing
and building need the internet: to download this repository from GitHub and its Swift packages. If
you want to see for yourself, a firewall such as LuLu or Little Snitch, or macOS's `nettop`, will
show that `mmm` opens no connections.

## What's kept, where, and for how long

| What | Where | How long |
|---|---|---|
| Audio being transcribed | Memory only | A fraction of a second in the capture buffers, then up to about 30 seconds per channel while its speakers are worked out |
| Audio before you start recording | Memory only | Used for the level meters, then dropped. None of it reaches the transcriber |
| Paused audio | Nowhere | Dropped as it arrives, never buffered |
| Text not yet attributed to a speaker | Memory only | Seconds, until its speakers are worked out |
| Voice embeddings (numeric voice fingerprints, not audio) | Memory only | Until the meeting ends; never saved |
| Your minutes | A markdown file in `Documents/Minutes` (or where you choose) | Yours to keep, move or delete |
| Words to keep (optional, for name redaction) | `Documents/Minutes/Words to keep.txt`, only if you create it | Yours |
| Diagnostics | Only on screen, only if you set `MMM_DEBUG` | Not saved |

## Audio: never on disk

**Where audio lives.** Only in memory:

1. The capture buffers, a fraction of a second.
2. The stretch waiting for speaker analysis, at most about 30 seconds per channel. The screen shows
   how much, as "_N_s of audio in memory".
3. The visualizers' last eighth of a second.

Each piece is released as soon as it has been processed. All of it goes when the app quits,
crashes or is killed, so there's never a leftover file to clean up.

**How that's enforced.**

- The app's code contains nothing that writes audio.
- FluidAudio has file-based functions that spill audio into temporary files. The app only uses its
  in-memory ones.
- A test (`Tests/MinutesCoreTests/NoAudioOnDiskTests.swift`) fails if audio-file writing or any of
  FluidAudio's file-based functions ever appear in the code.

**Honest caveats.**

- **Swap.** Under heavy memory pressure macOS can move memory into its swap files on disk. On
  Apple silicon Macs, swap is encrypted with keys that are thrown away at restart, so it can't be
  read back afterwards.
- **Your own recordings.** Recordings you open (with **O**, by dragging one onto the window, or
  from the command line) are only read, never changed, copied or deleted. They're decoded in memory
  like live audio, a few seconds at a time. Before transcribing one, the app asks you to confirm that
  everyone in it knew it was being recorded and agreed.
- **Other software.** The app can't stop anything else from recording: your meeting app's own
  recording feature, other apps with microphone access, or other people's devices.

## The written minutes

- **Updated as it goes.** The minutes file is rewritten each time a stretch of speech is
  attributed and whenever you add a note, so a crash loses at most the last half-minute or so.
- **Finished on exit.** Closing the window or quitting Terminal finishes the meeting the same way
  **/stop** does: the minutes are finalized and saved, just without the naming step. If you're
  already naming the speakers, the names typed so far are kept.
- **Never overwritten.** New minutes never replace existing ones. If a file name is already taken,
  the new file gets a number.
- **Plain text.** Anyone who can read your files can read your minutes. Treat them like any
  sensitive document: keep FileVault on, and think before you share or sync them.
- **Diagnostics.** Setting `MMM_DEBUG=1` prints diagnostics to the terminal, including the words
  heard before redaction. It's for troubleshooting only, and nothing is saved.

## Redaction

Redaction blanks out sensitive strings on your Mac, before any text is shown on screen or saved.

**On by default:**

| What | Becomes | Found by |
|---|---|---|
| US Social Security numbers | `[ID]` | The 123-45-6789 pattern |
| Payment card numbers | `[CARD]` | 13–19 digits that pass the card checksum |
| Account numbers | `[ACCOUNT]` | International bank account numbers (IBANs), and any run of 8 or more digits |

**Off unless you ask**, with `--redact` (see [Using it from Terminal](USAGE.md)):

| What | Becomes |
|---|---|
| People's names | `[NAME]` |
| Email addresses, including spoken forms like "jane dot doe at example dot com" | `[EMAIL]` |
| Phone numbers, including spoken digits | `[PHONE]` |
| Street addresses | `[ADDRESS]` |
| IP addresses | `[IP]` |

**With name redaction on:**

- It uses a list of about 20,000 first names, together with Apple's name recognizer for full names
  and context.
- Company and product names are kept. The recognizer alone often mistakes them for people, so a
  name it finds must include a known first name or follow a title such as "Dr.".
- Brand names that are also first names ("Chase", "Morgan") are judged by context.
- You can list words never to treat as names, such as your company and its products: pass them to
  `--keep`, or put them in `Documents/Minutes/Words to keep.txt`.

**Things redaction deliberately leaves alone:**

- Your notes and the names you give speakers are saved exactly as you typed them.
- Organization and place names are kept.

**Redaction is best effort.** The speech recognizer can mishear a number in a way the patterns
don't recognize. A recording stopped halfway through a number can leave part of it behind.
Uncommon names can slip through name redaction. Read your minutes before you share them.

## Consent

Before each recording, the app asks you to confirm that everyone taking part, in the room and on
the call, knows the conversation is being recorded and transcribed, and agrees. Nothing is
recorded until you press **Y**, and the minutes note when you confirmed it.

The wording follows the strictest standard in the United States, all-party consent, which about a
dozen states apply (California among them). It covers transcripts too, even though no audio is
kept. If someone joins later, tell them as well. Laws differ between places and situations, and
this isn't legal advice.

The same screen says what the app is meant for:
- targeted use, in focused sessions where everyone has agreed to a transcript, such as user
  research or stakeholder interviews;
- not recording routine meetings by default, which your company's policy may prohibit.

Check with your risk advisors before using it.

## Permissions

- **Who gets them.** macOS grants the microphone and system audio permissions to the app that runs
  `mmm`: Terminal when you use the Desktop shortcut. A permission granted to a terminal covers
  everything you run in it.
- **Keeping them contained.** If that matters to you, keep a separate terminal app just for Mini
  Meeting Minutes, or turn the permissions off between meetings. Both are in **System Settings ›
  Privacy & Security** (**Microphone**, and **Screen & System Audio Recording › System Audio
  Recording Only**).
- **When the microphone is on.** The microphone is open whenever the app's screen is open,
  including before you start recording, so that the level meters work. That audio feeds the meters
  and is then dropped. macOS's orange microphone indicator in the menu bar reflects this.
- **Only what's needed.** The app asks for nothing else: no files beyond your minutes, no contacts,
  no calendar and no screen contents.

## Supply chain and integrity

- **Open source.** The app is released under the MIT license. It depends on
  [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0), pinned to one exact
  commit, and Apple's swift-argument-parser, pinned in `Package.resolved`.
- **Checked models.** The models come with a manifest of SHA-256 checksums. Files split to fit
  GitHub's size limits are checked when they're joined on first run, and `mmm doctor` checks every
  model file.
- **Built on your Mac.** The installer downloads this repository from GitHub over HTTPS and builds
  it with Apple's own compiler. It never asks for an administrator password. Two downloads aren't
  source code:
  - Apple's command line developer tools, from Apple, if you don't have them.
  - A prebuilt text-normalization library that FluidAudio declares (NemoTextProcessing).
    Apple's Swift package manager fetches it during the build and checks it against a pinned
    checksum. The app switches that feature off, and none of the library's code ends up in it.

## Threat model

**What it's designed to protect against:**

- Meeting audio or transcripts reaching a cloud service or any other computer.
- Audio lingering on disk after a meeting.
- Recording before everyone has agreed: the app waits for Space, then for your confirmation.
- Losing minutes to a crash or a closed window.
- Social Security, card and account numbers ending up in minutes you share.

**What it doesn't protect against:**

- Malware on your Mac, or someone else with access to your user account: they can read your
  minutes like any other file.
- A compromised terminal app or operating system.
- Other people recording the meeting on their own devices, or your meeting app's own recordings.
- Names and other personal details you haven't asked it to redact, and anything redaction misses.

## Reporting a vulnerability

See [SECURITY.md](../SECURITY.md).
