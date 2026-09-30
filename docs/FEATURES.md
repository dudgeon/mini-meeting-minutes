# Features

Everything Mini Meeting Minutes does, and the kinds of meetings it works in. For how each part
keeps your meeting private, see [Privacy and security](PRIVACY-AND-SECURITY.md).

## Works in all kinds of meetings

- **In person.** One microphone, several people. Voices are told apart, so people in the room get
  their own labels (Room 1, Room 2 and so on) that you can then name.
- **Online.** Whatever your Mac plays is the call side: Zoom, Google Meet, Microsoft Teams,
  FaceTime, Slack huddles, a phone call through your Mac, or any other app. No bots join the
  meeting and there's nothing to install in the meeting app.
- **Hybrid.** The room and the call are recorded together as separate channels, so people on
  different sides never get mixed up.
- **Speakers or headphones.** On speakers, the call's voices reach your microphone as well. Echo
  removal takes them out, so each sentence is transcribed once. On headphones it simply has nothing
  to do.
- **With or without a microphone.** With no microphone, the call is recorded, and a microphone you
  plug in partway through is picked up. You can also record just one side, with `--no-mic` or
  `--no-system`.
- **Bluetooth headsets.** The microphone is started before the system audio, so a headset that
  switches modes when its microphone opens doesn't cut off the call audio.
- **Long meetings.** However long a meeting runs, no more than about 30 seconds of audio per
  channel is held at once. Speakers stay consistent across hours of conversation.
- **Any window size.** The screen adapts to windows from 50×12 characters up, down to the standard
  80×24.
- **Many languages.** The speech recognizer handles English and 24 other European languages. Name
  redaction, when switched on, is tuned for English.

## Recording

- **Ready when you are.** The app opens without recording. The level meters are already live, so
  you can check that your microphone and the call are heard before anything is recorded.
- **Everyone agrees first.** Pressing **Space** asks you to confirm that everyone taking part knows
  the conversation is being recorded and transcribed, and agrees. Recording starts when you press
  **Y**, and the minutes note when you confirmed.
- **For focused sessions.** The confirmation also says what the app is meant for: sessions where
  everyone has agreed to a transcript, such as user research or stakeholder interviews. It adds
  that company policy may not allow recording routine meetings.
- **Pause and resume** with **/pause**. Paused audio is dropped, not held for later.
- **Stop** with **/stop**, **Ctrl-C** or by closing the window. The minutes are saved either way.
- **Another meeting straight after.** When the minutes are saved, press **Space** to set up the
  next one. The models stay loaded, so there's no wait.

## Transcription

- **Words appear as people speak.** A sentence in progress shows up within a second or two, and is
  refined when the speaker pauses.
- **Word for word.** The speech recognizer, Parakeet, turns sound into words. It doesn't summarize,
  paraphrase or invent: the minutes are what was said.
- **Timestamps** on every paragraph and note, counted from when you started recording.

## Who said what

- **Speakers told apart by voice**, separately for the room and the call ("Room 1", "Remote 2").
- **Labels arrive quickly:** a couple of seconds after someone pauses, and within about 15 to 30
  seconds even in non-stop conversation.
- **Checked again at the end.** When the meeting ends, every speaker is re-checked against the whole
  meeting, which fixes labels that drifted.
- **Name speakers** any time with **/name**, or when the meeting ends: the app shows something each
  person said to help you tell who's who. Names follow the right person even if labels change at
  the end. Giving two labels the same name combines them.
- **Talk time.** See each speaker's share of the talking, as it happens.

## Notes

- **Write notes during the meeting.** Just type, and press **Return** to add the note (**Esc**
  drops it). The box grows as you type, up to 1,000 characters, and pasting works.
- **Typing can't set off a command.** During a meeting commands start with a slash, so a note like
  "quick question: please pause" stays a note.
- **In the right place.** A note goes into the transcript at the moment you started typing, and
  never splits someone's paragraph: one typed while someone was talking comes right after what they
  said.
- **In the minutes as quotes**, with their own timestamps, exactly as you typed them.
- **Never lost.** A note still being typed when the recording stops is kept.

## Privacy

- **Private.** Everything runs on your Mac, with no network connections and no audio ever written
  to disk. The full trust model is in [Privacy and security](PRIVACY-AND-SECURITY.md).
- **Sensitive numbers blanked out:** US Social Security numbers, payment card numbers and account
  numbers become `[ID]`, `[CARD]` and `[ACCOUNT]` before anything is shown or saved.
- **More on request:** names, email addresses (including spoken ones), phone numbers, street
  addresses and IP addresses, with `--redact`.
- **Company names stay.** With name redaction on, company and product names are kept, and you can
  list words that should never be taken for names.

## The minutes

- **Plain markdown files** in **Documents › Minutes**, named by date, time and title. They open in
  TextEdit, Notes, Obsidian, VS Code, or anything else that reads text.
- **A short header:** title, date, length, which audio was recorded, the speakers, what was
  redacted, and when you confirmed that everyone agreed.
- **Paragraphs by speaker, with timestamps**, and your notes in place as quotes.
- **Kept up to date during the meeting**, so a crash loses at most the last half-minute or so.
- **Never overwrite each other:** if a name is taken, the new file gets a number.

## Recordings you already have

- **Voice memos and other recordings.** There are three ways to open one:
  - press **O** and choose it;
  - drag it onto the window;
  - run `mmm recording.m4a`.

  Most audio and video files work: m4a (including Voice Memos' .m4a and .qta), mp3, wav, aiff,
  caf, mp4 and mov.
- **Like a meeting, sped up.** The recording goes through the same pipeline as a live meeting, as
  fast as the Mac allows:
  - words and speaker labels fly by;
  - a progress bar and the speed show how far along it is;
  - on the Mac it was developed on, a 3-minute memo took 2.5 seconds (about 75 times real time).
- **Everything else works as in a meeting:** naming speakers, notes, pausing, or stopping early
  and keeping what's done.
- **Dated from the recording itself,** and titled with its name (a voice memo's own title is
  used).
- **Consent first:** you confirm that everyone in the recording knew and agreed, and the minutes
  say so.
- **Only read,** never changed, copied or deleted.
- **Separate room and call tracks** of the same meeting are combined with `mmm transcribe`.

## The screen

- **Sidebar**, the default, in the style of Claude's apps: a quiet sidebar with the status, clock,
  speakers and talk time, live levels for the microphone and the call, privacy checks and keys,
  beside a transcript that reads like a conversation.
- **Synthwave mode** (**/look**, or **K** before a meeting): a pixel-art sunset over a neon grid, whose city skyline is a live
  spectrum analyzer, with the microphone left of the sun and the call to the right.
- **Visualizers** (**/visual**, or **V** before a meeting): spectrum, waveform or off.
- **Keyboard and mouse:** every key and command is listed on screen and clickable, and the mouse
  wheel scrolls. During a meeting, typing a slash lists the commands; before and after one, single
  keys do things, and **?** shows them all.
- **Scroll back** through the transcript while recording continues, and jump back to the newest
  line with **End**.
- **After saving**, the finished minutes stay on screen: **Return** opens them, **R** shows them in
  Finder, **Space** starts another meeting and **Q** quits.
- **Adapts to the window.** Narrow windows drop the sidebar, synthwave mode's picture shrinks with
  the window, and too-small windows say so, while recording carries on.
- **Terminal colors.** It uses full color in terminals that support it (including macOS Terminal)
  and falls back to 256 colors elsewhere.

## Reliability

- **Saved as it goes, and finished on the way out.** The minutes are finalized when you type
  **/stop**, press Ctrl-C, close the window or quit Terminal, even while speakers are being named.
- **Microphone changes are handled.** Switch microphones mid-meeting, say to AirPods, and
  recording carries on with the new one.
- **Warnings where you'll see them.** If the call side stays silent while other apps are playing
  sound, which usually means a missing permission, the screen says so and explains the fix.
- **Warmed up in advance.** The models warm up while the app waits for you to start, so the first
  words appear promptly.

## Installing and upkeep

- **One line to install** and a Desktop shortcut to start. No administrator password, no developer
  knowledge. See the [README](../README.md).
- **Self-contained.** Every model ships in this repository, so nothing is downloaded when the app
  runs.
- **`mmm doctor`** checks macOS, the models (every file against its checksum), permissions and
  microphones.
- **Updating and uninstalling** are one line each. Uninstalling keeps your minutes.
