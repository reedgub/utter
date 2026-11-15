# Utter

System-wide dictation for macOS. Hold a key, talk, let go: your words appear at the
cursor in whatever app you are in, transcribed by Whisper and cleaned up by an LLM.

- **Hold to talk** on `fn` (or any key you choose). Release and the text is inserted.
- **Double-tap for hands-free.** Recording continues with nothing held; tap once more to
  finish. Every recording stops itself after 5 minutes (configurable).
- **Esc cancels**: it drops the recording, or kills a transcription that is already
  running. Esc is only observed, never swallowed, so it still reaches your app.
- **Local or cloud transcription**: whisper.cpp on your Mac (offline), or the Groq / OpenAI
  Whisper API if you set a key. If the cloud is unreachable, it falls back to the local model.
- **Cleanup pass**: removes filler words and false starts, fixes punctuation and casing.
  Groq, OpenAI, Anthropic, or a local Ollama model. Optional.
- **Inserts at the cursor** using pasteboard + ⌘V (or simulated typing). The transcript stays
  on the clipboard so you can paste it again, unless you ask for your old clipboard back.
- **A small floating pill** shows that it is listening, in which mode, with a level meter.
- **An app window** for settings, API keys, permissions and on/off. Close it and Utter keeps
  running in the menu bar; open Utter again (or use the menu bar icon) to bring it back.
- **Fast local transcription**: the model stays loaded in a background whisper-server, so a
  dictation does not wait for it to load.
- No accounts, no telemetry, no analytics. With the local model and `cleanup = "off"` or
  `"ollama"`, nothing leaves your Mac.

## Requirements

- macOS 13 Ventura or later. Apple Silicon recommended for local transcription speed.
- Swift 5.9+ (Xcode 15+ or the Command Line Tools: `xcode-select --install`).
- For local transcription: [whisper.cpp](https://github.com/ggml-org/whisper.cpp) via Homebrew.

## Install

```bash
git clone <this repo> utter && cd utter
brew install whisper-cpp          # provides whisper-cli (with Metal acceleration)
make model                        # downloads ggml-small.en.bin (~466 MB) to ~/.config/utter/models
make install                      # builds Utter.app, copies it to /Applications and opens it
```

For better accuracy at the cost of speed, use the medium model:

```bash
make model MODEL=medium.en        # ~1.5 GB
```

and set `local_model = "medium.en"` in the settings file. Use `small` / `medium`
(without `.en`) for languages other than English.

On first launch Utter opens its window, writes `~/.config/utter/config.toml` and
`~/.config/utter/.env`, and asks for the permissions below.

To update later: `git pull && make install`.

## Permissions

macOS will not let an app hear a global hotkey, record audio or type into other apps
until you allow it. Utter needs three permissions. All are in **System Settings →
Privacy & Security**, and the menu bar icon has a **Permissions** submenu that shows
which are granted and opens the right pane.

| Permission | Why Utter needs it | Where |
|---|---|---|
| **Microphone** | To record while you dictate. macOS asks the first time. | Privacy & Security → Microphone |
| **Accessibility** | To watch the hotkey in every app, to keep a chord hotkey's key from also being typed, and to send ⌘V (or keystrokes) into the focused app. | Privacy & Security → Accessibility |
| **Input Monitoring** | To receive keyboard events from other apps. On recent macOS versions keyboard event taps need this in addition to Accessibility. | Privacy & Security → Input Monitoring |

To grant Accessibility and Input Monitoring: open the pane, click **+**, choose
`/Applications/Utter.app` (or switch on its toggle if it is already listed). Utter notices
within a couple of seconds; you do not need to relaunch. The menu bar icon shows a
warning triangle until everything needed is granted.

### fn / globe key settings

If you use the default `fn` hotkey, stop macOS from also acting on it:

1. **System Settings → Keyboard → "Press 🌐 key to"** → **Do Nothing**. Otherwise holding fn
   opens the emoji picker or switches input source.
2. **System Settings → Keyboard → Dictation → Shortcut** → anything other than
   "Press 🌐 Twice" (or turn Apple Dictation off). Otherwise double-tapping fn starts
   Apple's dictation alongside Utter's hands-free mode.

### Keeping permissions across rebuilds

macOS ties Accessibility and Input Monitoring to the app's code signature. `make install`
signs ad-hoc by default, and an ad-hoc signature changes on every build, so **after a
rebuild the toggles still look on but no longer apply**. Two fixes:

- **Use a stable signing identity (recommended if you are changing the code).** In
  Keychain Access choose *Keychain Access → Certificate Assistant → Create a
  Certificate…*, name it `Utter Dev`, Identity Type *Self Signed Root*, Certificate Type
  *Code Signing*. Then build with it:

  ```bash
  SIGN_IDENTITY="Utter Dev" make install
  ```

  Grant the permissions once; they survive later builds signed the same way.

- **Or reset and re-grant after each rebuild:**

  ```bash
  tccutil reset Accessibility dev.utter.Utter
  ```

  ```bash
  tccutil reset ListenEvent dev.utter.Utter
  ```

## Using it

| Action | What happens |
|---|---|
| Hold the hotkey, speak, release | Transcribes and inserts at the cursor |
| Double-tap the hotkey | Hands-free recording starts (orange dot in the pill) |
| Tap the hotkey again | Hands-free recording stops and is inserted |
| Esc while recording | Recording is thrown away |
| Esc while transcribing | Transcription is killed; nothing is inserted |
| Hotkey + another key (e.g. fn+Delete) | Treated as a shortcut; the recording is dropped |
| A single short tap | Ignored |

You can keep typing during a hands-free session. Recordings that are pure silence are
skipped rather than sent to Whisper (Whisper tends to "hear" *Thank you.* in silence).

The pill sits at the bottom of the screen your pointer is on. It never takes focus or
clicks, so the app you are dictating into stays active.

## The window

Opening Utter shows a window with an on/off switch, your hotkey, the transcription and
cleanup choices, API key fields, permission status, and how long the last dictation took.
Changes save immediately. Closing the window does not quit Utter: it keeps running in the
menu bar, ready for the hotkey. To get the window back, open Utter again from Finder,
Spotlight or Launchpad, or choose **Open Utter…** from the menu bar icon. **Quit Utter** is
in the window, the menu bar menu, and ⌘Q.

## Speed

Each dictation shows its timing in the window and the menu, for example
`6.2 s of audio · whisper (loaded) 0.7 s · cleanup 0.5 s`, so you can see which step is slow.

- **Keep the model loaded** (`local_engine = "server"`, the default). Utter runs
  `whisper-server` in the background with the model in memory and warms it up at launch.
  Without it (`"cli"`), every dictation loads the model and sets up the GPU again first. The
  cost is memory: about 0.5 GB for small, 1.5 GB for medium.
- **Fast decoding** (`beam_size = 1`, the default) makes one pass instead of trying 5
  candidates. "Thorough" in the window (`beam_size = 5`) is slightly more accurate and slower.
- **Model size**: `small.en` is several times faster than `medium.en`. On an Intel Mac,
  stay on small or use Groq.
- **Groq** (`transcriber = "groq"`) is usually the fastest option of all, if you are online.
- **Cleanup** adds one LLM round trip. Groq is the quickest; set `cleanup = "off"` to skip it.

whisper-server's output goes to `~/.config/utter/whisper-server.log`.

## Settings

Everything can be changed in the window. It all lives in `~/.config/utter/config.toml`. Open it from the menu bar icon
(**Open Settings File**) and choose **Reload Settings** after editing. Problems in the
file are listed at the top of the menu; the app keeps the default for any value it
cannot read. The generated file documents every option. The main ones:

```toml
hotkey = "fn"                  # or "right_option", "right_command", "ctrl+option+space", "f5", ...
max_recording_seconds = 300    # the hands-free safety stop

transcriber = "local"          # "local" | "groq" | "openai" | "auto"
local_model = "small.en"       # or "medium.en", or a path to any ggml .bin
language = "en"                # or "auto"
vocabulary = "Kubernetes, gRPC, Wispr"   # spelling hints for Whisper and the cleanup model

cleanup = "auto"               # "auto" | "groq" | "openai" | "anthropic" | "ollama" | "off"
cleanup_model = ""             # empty = provider default

insert_method = "paste"        # or "type"
restore_clipboard = false      # true puts your previous clipboard back after inserting
```

Hotkey notes:

- Modifier-only keys (`fn`, `right_option`, …) are never swallowed, so a right-⌘ hotkey
  still works as ⌘ in shortcuts: pressing another key while it is held cancels dictation.
- Chords (`ctrl+option+space`) are swallowed so the space is not typed. Letter keys refer
  to the physical key position on a US layout.
- A bare letter is refused (it would stop you typing that letter), and Esc is reserved.

### API keys

Keys go in `~/.config/utter/.env` (created with mode 600, open it from the menu):

```bash
GROQ_API_KEY=gsk_...
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
```

With `transcriber = "auto"`, Groq is used if its key is set, then OpenAI, then the local
model. With `cleanup = "auto"`, the first of Groq, OpenAI, Anthropic with a key is used;
with no key, the raw transcript is inserted. Each key is only ever sent to its own provider.

Default cleanup models: Groq `llama-3.3-70b-versatile`, OpenAI `gpt-4.1-mini`, Anthropic
`claude-haiku-5-5`, Ollama `llama3.1:8b`. Override with `cleanup_model`.

### Fully offline cleanup

Install [Ollama](https://ollama.com), `ollama pull llama3.1:8b`, and set `cleanup = "ollama"`.

### How cleanup stays safe

The transcript is sent inside `<transcript>` tags with instructions to treat it as text,
never as a request. If the model's answer comes back much longer than what you said (it
answered your question instead of cleaning it up), is empty, or times out
(`cleanup_timeout_seconds`), the raw transcript is inserted instead and the pill says so.
Your words are never lost to a cleanup failure.

## Privacy

- No accounts, no telemetry, no update checks, no analytics.
- Audio is held in memory, written to a temporary WAV only for whisper-cli, and deleted
  straight after.
- Network requests happen only to the transcription and cleanup providers you configure.
- Transcripts are not logged. Diagnostics go to the macOS unified log:

  ```bash
  log stream --predicate 'subsystem == "dev.utter.Utter"'
  ```

## Troubleshooting

- **Nothing happens when I hold fn.** Check the Permissions submenu. If everything shows ✓
  but it still does not react after a rebuild, see *Keeping permissions across rebuilds*.
- **The hotkey is ignored in a password field.** macOS Secure Input blocks all keyboard
  monitoring while a password field (or an app like 1Password or Terminal's *Secure
  Keyboard Entry*) has focus. This is by design.
- **The text is transcribed but not inserted.** Accessibility is missing, or the target app
  blocks synthetic paste. Try `insert_method = "type"`.
- **"whisper-cli not found" / "whisper-server not found".** `brew install whisper-cpp`
  (it provides both), or set `whisper_cli` to its path.
- **Transcription is slow.** Check the timing line in the window, then see *Speed*.
- **"No model at …".** `make model` (or `make model MODEL=medium.en`).
- **Launch at Login fails.** It only works for an app in `/Applications`; use `make install`.

## Development

```bash
make test       # unit tests for the core logic
make run        # build build/Utter.app and launch it
```

The code is split so the logic that matters can be tested without a Mac's UI:

- `Sources/UtterCore` (Foundation only, unit-tested)
  - `DictationMachine.swift`: the hold / double-tap / hands-free / Esc / auto-stop behaviour
    as a pure state machine. Timers are effects carrying tokens, so a stale timer can never
    touch a newer session.
  - `HotkeyDetector.swift`, `Hotkey.swift`: turning raw key events into press/release,
    left vs right modifiers, chord matching, what gets swallowed.
  - `Config.swift`, `DotEnv.swift`, `Backends.swift`: settings, keys, provider selection.
  - `CloudClients.swift`, `LocalWhisper.swift`, `Cleanup.swift`, `Audio.swift`: requests,
    whisper-cli arguments, transcript filtering, the cleanup guard, WAV encoding.
- `Sources/Utter` (AppKit app)
  - `EventTap.swift`: the CGEvent tap. `AudioRecorder.swift`: AVAudioEngine → 16 kHz mono.
  - `Pipeline.swift`: transcribe → clean up, cancellable, timed. `Inserter.swift`: paste or type.
  - `WhisperServer.swift`: the resident whisper-server process (start, health check, warm-up,
    restart on settings change, cleanup of a leftover process).
  - `MainWindow.swift`: the SwiftUI window. `Pill.swift`, `MenuBar.swift`, `Permissions.swift`,
    `AppController.swift`.
- `scripts/make-icon.py` draws the app icon.

## License

MIT
