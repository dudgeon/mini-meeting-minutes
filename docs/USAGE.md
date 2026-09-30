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
mmm doctor                           # check the models, permissions and microphones
mmm transcribe --room mic.m4a --remote call.m4a   # recordings you already have
```

## A meeting, step by step

1. **Ready.** The app opens without recording. The meters show what the microphone and the call
   are hearing.
2. **Space, then Y.** The app asks you to confirm that everyone taking part knows the
   conversation is being recorded and transcribed, and agrees. **Y** starts recording, **N** goes
   back.
3. **Recording.**
   - Words appear as people speak, and who said them follows a couple of seconds after a pause.
   - Add notes with **Return**, name speakers with **N**, and pause with **Space**.
4. **Q to stop.**
   - Everything still in progress is finished, and every speaker is re-checked across the whole
     meeting.
   - The app then asks you to name each speaker, showing something they said. **Return** moves on,
     and **Esc** finishes.
5. **Saved.** The finished minutes stay on screen:
   - **Return** opens them;
   - **R** shows them in Finder;
   - **Space** starts another meeting;
   - **Q** quits.

Closing the window or quitting Terminal also stops and saves the meeting, just without the naming
step.

## Keys

| Key | Does |
|---|---|
| **Space** | Start recording (after you confirm everyone has agreed); then pause or resume. Paused audio is dropped, not buffered |
| **Return** | Write a note; **Return** again adds it, **Esc** cancels |
| **Q** or Ctrl-C | Stop and save |
| **N** | Name the speakers, any time |
| **V** | Switch the visualizer: spectrum, waveform, off |
| **K** | Switch between the sidebar and synthwave mode |
| **↑ ↓**, Page Up/Down, mouse wheel | Scroll the transcript; **F** jumps back to the newest line |
| **?** | All the shortcuts |

The keys listed on screen are clickable too. Because the screen takes mouse clicks, hold
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
| `--mic-device <uid>` | Use a specific microphone. `mmm doctor` lists them |
| `--no-names` | Don't ask for speaker names at the end |
| `--skin <name>` | Start in `sidebar` (the default) or `synthwave` mode |

## Transcribing recordings you already have

```sh
mmm transcribe --room mic.m4a --remote call.m4a
mmm transcribe --remote zoom-recording.m4a --stdout
```

Your recordings are only read, never changed. `--title`, `--output`, `--redact`, `--keep`,
`--no-names` and `--no-echo-cancel` work here too, and `--stdout` prints the minutes instead of
saving them.

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
