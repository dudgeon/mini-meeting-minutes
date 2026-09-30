# Using it from Terminal

The Desktop shortcut is all most people need. This page covers everything else: the `mmm`
command, its keys and options, permissions, and what the installer does.

## Commands

After installing, open a new Terminal window and type `mmm`, optionally with options:

```sh
mmm                                  # record: the microphone and system audio
mmm --title "Roadmap review"         # a title for the file name and heading
mmm --no-mic                         # a call on headphones: the call side only
mmm --no-system                      # an in-person meeting: the room only
mmm --output ~/Notes/                # a folder, or a file name ending in .md
mmm --redact all                     # blank out names, emails and more, too
mmm "Team sync.m4a"                  # transcribe a recording you already have, like a voice memo
mmm doctor                           # check the models, permissions and microphones
mmm transcribe --room mic.m4a --remote call.m4a   # separate room and call recordings
```

## A meeting, step by step

1. **Ready.** The app opens without recording. The meters show what the microphone and the call
   are hearing.
2. **Space, then Y.** The app asks you to confirm that everyone taking part knows the
   conversation is being recorded and transcribed, and agrees. **Y** starts recording, **N** goes
   back.
3. **Recording.**
   - Words appear as people speak, and who said them follows a couple of seconds after a pause.
   - To add a note, just type it and press **Return**.
   - **Space** pauses and resumes whenever you're not typing a note. **F8** does too, even
     partway through a note.
   - Other commands start with a slash, so a note can never set one off: **/name** names the
     speakers.
4. **/stop to finish** (or **Ctrl-C**).
   - Everything still in progress is finished, and every speaker is re-checked across the whole
     meeting.
   - The app then asks you to name each speaker, showing something they said. **Return** moves on,
     and **Esc** finishes.
5. **Saved.** The finished minutes stay on screen, and their full path is on the clipboard:
   - **Return** opens them;
   - **C** copies the path again, and **T** copies the whole transcript (the minutes, as markdown);
   - **R** shows them in Finder;
   - **Space** starts another meeting;
   - **O** transcribes a recording instead;
   - **Q** quits.

Closing the window or quitting Terminal also stops and saves the meeting, just without the naming
step.

## Keys and commands

**During a meeting**, the box at the bottom takes notes, and commands start with a slash, so no
sentence you type can stop or change the meeting by accident. Space pauses, since a note never
starts with one:

| Type | Does |
|---|---|
| Anything | A note. **Return** adds it where you started typing, **Esc** drops it |
| **Space** or **F8** | Pause, or resume. Paused audio is dropped, not buffered. Space does this when no note is being typed; F8 any time. Typing **/pause** works too |
| **/stop** | Stop and save. **Ctrl-C** does the same |
| **/name** | Name the speakers, any time |
| **/mic** | Choose another microphone. Recording carries on with it |
| **/copy** | Copy the transcript so far to the clipboard, as markdown |
| **/look** | Switch between the sidebar and synthwave mode |
| **/visual** | Switch the visualizer: spectrum, waveform, off |
| **/help** | All the commands |

Typing a slash lists the commands; **Return** runs the one that fits, and **Tab** completes its
name. **↑ ↓**, Page Up/Down and the mouse wheel scroll the transcript, and **End** jumps back to
the newest line.

On a Mac keyboard, **F8** is the ⏯ key. Hold **fn** as you press it, or macOS gives it to Music
instead. To make it work without **fn**, turn on *Use F1, F2, etc. keys as standard function
keys* in System Settings › Keyboard › Keyboard Shortcuts › Function Keys.

**Before a meeting starts**, and once its minutes are saved, single keys do things:

| Key | Does |
|---|---|
| **Space** | Start recording, after you confirm everyone has agreed. On the saved screen: another meeting |
| **O** | Transcribe a recording instead. Dragging one onto the window does the same |
| **M** | Choose the microphone, if there's more than one: the Mac's default, or a particular one. The choice is remembered for next time |
| **Q** | Quit |
| **Return** | On the saved screen: open the minutes (**R** shows them in Finder, **C** copies their path again, **T** the whole transcript) |
| **K**, **V**, **?** | Switch the look, the visualizer, and show all the keys |

The keys and commands listed on screen are clickable too. Because the screen takes mouse clicks, hold
**⌥ Option** to select text with the mouse. Narrow windows hide the sidebar, and synthwave mode's
picture shrinks with the window.

## Notes

- **Where they go.** A note lands in the transcript at the moment you started typing, right after
  whatever was being said.
- **In the saved minutes**, notes appear as quotes with their own timestamps:

  ```markdown
  > **Note** · 00:00:21
  > Ask finance for the breakdown before Friday
  ```

- **Exactly as typed.** Notes are saved as you typed them: redaction applies only to what people
  said.

## Options for `mmm` (recording)

| Option | Effect |
|---|---|
| `--title <text>` | A title for the file name and heading |
| `--output <path>` | A folder, or a file name ending in `.md`. The default is `~/Documents/Minutes`. Existing minutes are never overwritten: a taken name gets a number |
| `--redact <list>` | What to blank out: `all`, `none`, or a comma-separated list of `name`, `email`, `phone`, `address`, `id`, `card`, `account`, `ip`. The default is `id,card,account` |
| `--keep <words>` | With `name` redaction on: words never to take for names, such as your company and its products. They add to any listed in `Documents/Minutes/Words to keep.txt`, one per line |
| `--no-mic` | Don't capture the microphone |
| `--no-system` | Don't capture system audio |
| `--no-echo-cancel` | Skip echo removal. It's only needed when the call plays through speakers; on headphones you can turn it off |
| `--mic-device <uid>` | Use a specific microphone. `mmm doctor` lists them; pressing **M** is easier |
| `--no-names` | Don't ask for speaker names at the end |
| `--skin <name>` | Start in `sidebar` (the default) or `synthwave` mode |

## Transcribing recordings you already have

There are three ways to open a recording:
- press **O** on the ready or saved screen and choose it;
- drag it onto the window;
- run `mmm "Team sync.m4a"`.

Most audio and video files work:
- m4a, including Voice Memos' recordings (.m4a and .qta);
- mp3, wav, aiff and caf;
- mp4 and mov.

For a voice memo, drag it from Voice Memos to your desktop first.

1. **Consent.** The app asks you to confirm that everyone in the recording knew it was being
   recorded, and agreed. **Y** starts, **N** goes back.
2. **A sped-up meeting.** The recording goes through the same steps as a live meeting, as fast as
   the Mac can go:
   - words appear as they're recognized, then who said them;
   - a progress bar and the speed show how far along it is;
   - an hour-long recording takes about a minute on a recent Mac.

   Typing adds a note at that point in the recording, **Space** pauses, **/name** names speakers,
   and **/stop** stops early and keeps what's been transcribed.
3. **Saved.** The minutes are dated from the recording and titled with its name (a voice memo's
   own title is used).

The recording is only read, never changed, copied or deleted. `--title`, `--output`, `--redact`,
`--keep` and `--no-names` work here too.

For a meeting recorded as separate room and call tracks, `mmm transcribe` combines them, removing
the call's echo from the room track:

```sh
mmm transcribe --room mic.m4a --remote call.m4a
mmm transcribe --remote zoom-recording.m4a --stdout
```

`--no-echo-cancel` turns echo removal off, and `--stdout` prints the minutes instead of saving
them.

## Permissions

- **Who they belong to.** macOS grants the microphone and system audio permissions to the app that
  runs `mmm`: Terminal when you use the Desktop shortcut, or whichever terminal you type `mmm` in
  (iTerm, Ghostty and so on).
- **Adding a terminal by hand.** Some terminals, including iTerm, never show the system audio
  prompt. Add them yourself under **System Settings › Privacy & Security › Screen & System Audio
  Recording › System Audio Recording Only**.
- **What a permission covers.** Granting a permission to a terminal grants it to everything you
  run in that terminal. See [Privacy and security](PRIVACY-AND-SECURITY.md#permissions).
- **Silence instead of an error.** macOS doesn't report a missing system audio permission; it just
  delivers silence. `mmm` warns you when system audio stays silent while other apps are playing
  sound.
- **No microphone?** The call is recorded, and a microphone connected later is picked up. If macOS
  hasn't asked about the microphone before, it asks then.

## What the installer does

1. **Checks.** It checks your Mac, and installs Apple's command line developer tools if they're
   missing. They include Swift, which builds the app.
2. **Downloads and builds.** It downloads this repository to `~/Applications/mini-meeting-minutes`,
   builds it, and checks the speech models.
3. **Sets up.** It puts the **Mini Meeting Minutes** shortcut on your Desktop and the `mmm` command
   in `~/.local/bin`, adding that folder to your `PATH` in `~/.zprofile`.

Nothing needs an administrator password. The log is at
`~/Library/Logs/mini-meeting-minutes-install.log`.

- **Updating:** run the install line again.
- **Uninstalling:** add `-s -- --uninstall` to the install line, as shown in the
  [README](../README.md). Your minutes are kept.
