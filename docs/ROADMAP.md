# Roadmap

## Running well on smaller Macs

Mini Meeting Minutes should keep up on the least powerful Mac it supports (an M1 MacBook Air with
8 GB of memory), on battery, while a video call runs alongside it.

### Where it stands

On an M6 Mac mini:

- **Speed.** The pipeline runs about 30 times faster than real time. Recognizing an utterance
  takes 60–100 ms, working out who spoke in a window 60–210 ms, and redaction about 1 ms.
- **Memory.** It peaks at about 630 MB while the models load, then holds at 250–480 MB. That
  stayed flat through a 2-hour meeting, with labels keeping pace throughout (see
  [How it works](HOW-IT-WORKS.md#memory)).

What makes a smaller Mac a risk:

- **One step at a time.** Both channels and echo removal are processed in sequence. If one slow
  step runs long, everything behind it waits.
- **No backpressure.** The queue between capture and processing is unbounded. A Mac that falls
  behind would build up audio in memory, and the delay would keep growing.
- **Models compete for memory.** A video call app takes 1–2 GB and keeps the processor and GPU
  busy, so the models compete for both.

### The plan

1. **Measure.**
   - **A benchmark.** Add `mmm bench`: it replays a long synthetic meeting as fast as possible and
     reports each step's speed, how far behind the screen gets, peak memory and energy.
   - **Live health.** Show processing lag, memory and thermal state in the diagnostics.
   - **Test on the real hardware:** an M1 Air with 8 GB, on battery, in a video call.
   - **Simulate the rest:** throttle a fast Mac with `taskpolicy`, run a CPU load alongside,
     squeeze its memory with `memory_pressure`, and switch on Low Power Mode.
2. **Never fall behind silently.**
   - **Track the lag.** Measure how far processing is behind capture, and cap the queue at about a
     minute of audio.
   - **Step back as it grows:** stop the readings of unfinished sentences, lengthen the speaker
     windows, then pause echo removal with a clear suggestion to use headphones.
   - **Last resort:** drop audio with a visible warning, never silently.
3. **Overlap work across channels.** One channel's speaker analysis shouldn't hold up the other's
   speech recognition. The models are shared, so this needs care.
4. **Use memory carefully.**
   - **Where each model runs.** Measure each model's footprint on the Neural Engine, GPU and
     processor, and pick per Mac. The Neural Engine spares GPU memory.
   - **Under memory pressure** (which macOS reports), free what can be freed, shorten the windows
     and warn.
   - **If a model fails to load**, say so plainly and suggest closing other apps, rather than
     crashing.
5. **Mind heat and battery.** When the Mac runs hot or is in Low Power Mode:
   - draw the screen at 10 frames a second instead of 20;
   - freeze synthwave mode's animation;
   - read unfinished sentences less often.
6. **Start faster.** The first run on a slower Mac can spend a while preparing the models. Show
   progress while it does, and keep the prepared models between runs.

### When it's done

On an M1 MacBook Air with 8 GB, on battery, during a video call:

- words on screen within 3 seconds;
- speakers within 35 seconds, even in non-stop conversation;
- memory under 1 GB;
- a 2-hour meeting with no dropped audio;
- a screen that stays responsive.

## A prebuilt, signed app (paused)

Today the installer builds the app on each Mac, which needs Apple's developer tools and a few
minutes. Shipping it prebuilt, in a disk image, would take installing down to about a minute. It's
on hold; this is what it would take.

**What Apple requires**

- **Membership and a certificate.** An Apple Developer Program membership, and its **Developer ID
  Application** certificate, with its private key, to sign the app. A **Developer ID Installer**
  certificate as well, for an installer package rather than a disk image.
- **Hardened runtime** when signing, with the `com.apple.security.device.audio-input` entitlement so
  the microphone still works.
- **Notarization.**
  - Apple scans the signed build (`xcrun notarytool submit --wait`), and the ticket is then
    stapled on (`xcrun stapler staple`).
  - A bare command-line tool can't carry a ticket, so it ships inside a signed disk image or
    package. Notarizing and stapling that outermost container covers everything in it.
- **The tools are already here.** This Mac has `codesign`, `notarytool`, `stapler` and `hdiutil`
  with just the command line tools: no Xcode needed.

**The certificates**

- **Reuse the ones the Duo project has.** In Keychain Access, export the Developer ID Application
  certificate *with its private key* as a password-protected .p12. Move it privately, and never
  into the repository.
- **Notarizing needs its own credentials:** an App Store Connect API key (issuer ID, key ID and
  .p8 file) suits automation best. An Apple ID with an app-specific password also works.
- **Better still, keep them in GitHub.** Store them as GitHub Actions secrets, and a release
  workflow can do the rest:
  - import the .p12 into a temporary keychain;
  - build, sign and notarize each tagged release, then publish it.

  The certificate then never needs to sit on a laptop. Apple allows 75 notarizations a day, plenty
  for releases.

**To decide when it resumes**

- **A tool in a disk image, or a real app?**
  - A signed command-line tool still runs inside Terminal, so macOS still asks permission for
    Terminal, not for Mini Meeting Minutes.
  - For permissions of its own, and for a menu bar icon or a global hotkey, the capture has to run
    in a process that belongs to a signed app bundle. That bundle needs its own usage explanations:
    `NSMicrophoneUsageDescription`, and `NSAudioCaptureUsageDescription` for system audio.
  - It could be a small helper that captures and hands audio to the screen in Terminal, in memory,
    or a full app with a window of its own.
- **Updates.** The one-line installer can stay the updater either way; a full app could use Sparkle.
- **Building from source stays an option**, for anyone who wants to build what they can read.

## Other enhancements

**Faster and more accurate**

- **Speakers at once.** Match each finished utterance against the voices heard so far, show the
  likely speaker straight away, and confirm it when the speaker analysis catches up.
- **Your vocabulary.** Teach the recognizer your people's names, products and jargon, so they're
  spelled right.
- **Overlapping speech.** Mark it or split it, rather than giving it all to whoever's loudest.

**Less to do by hand**

- **Remember voices** across meetings, so regulars are named automatically. It would be off unless
  you opt in, with voice fingerprints stored locally and easy to delete: they're biometric data.
- **Names and titles from your calendar**, looked up on your Mac.
- **Suggest recording** when a Zoom, Meet or Teams call starts.

**Around the minutes**

- **Highlights:** one key to mark a moment as important.
- **A list of past minutes** on the start screen, to open, search or delete.
- **Review redactions before saving:** see what was blanked out, and restore what you want to keep.
  This needs the original words kept in memory until you save.
- **Export** to the clipboard, plain text, Word, PDF or Apple Notes.
- **Optional automatic deletion** of minutes after a set time.

**Trust and reach**

- **A prebuilt, signed app**, planned [above](#a-prebuilt-signed-app-paused). Permissions would
  then belong to Mini Meeting Minutes itself rather than to Terminal: a narrower grant, and the way
  to a menu bar icon and a global hotkey.
- **Continuous integration.** Build, test and run the end-to-end check on every change.
- **Other languages.** Language detection, the interface in the recognizer's other 24 languages,
  and name redaction beyond English.
- **Accessibility.** A high-contrast look, and a plain mode that prints the transcript line by line
  for screen readers.
