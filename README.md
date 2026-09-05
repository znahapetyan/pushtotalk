# Talk — AI dictation for macOS

Click into any text field, press a hotkey, talk, and your words are transcribed
by an AI speech model, cleaned up by Claude, and typed into the field. A
menu-bar replacement for the Mac's built-in dictation.

```
hotkey ▸ record mic ▸ transcribe (Groq/OpenAI Whisper) ▸ clean up (Claude) ▸ paste into focused field
```

- **System-wide** — works in any app, any text field (global Carbon hotkey).
- **Pick your mic** — pin Talk to one microphone so connecting AirPods can't
  move dictation off your built-in mic.
- **Cloud transcription** — Groq `whisper-large-v3-turbo` (fast, cheap) or OpenAI.
- **AI cleanup** — Claude Haiku 4.5 fixes punctuation/filler/grammar so it reads
  like you typed it. Optional; turn it off for the raw transcript.
- **No external dependencies** — native Swift + AVFoundation. No ffmpeg, no Python.

## 1. Build

Requires the Xcode Command Line Tools (`xcode-select --install`). No full Xcode
or Apple Developer account needed.

```sh
./build.sh
```

This produces `Talk.app` (ad-hoc signed).

## 2. Add your API keys

Create `~/.talk/config.json` (or run the app and choose **Open config file…** from
its menu):

```json
{
  "provider": "groq",
  "groqApiKey": "gsk_…",
  "anthropicApiKey": "sk-ant-…",
  "cleanup": true
}
```

- **Groq key** (transcription): free tier at <https://console.groq.com/keys>.
- **Anthropic key** (cleanup): <https://console.anthropic.com>. Optional — omit
  it (or set `"cleanup": false`) to type the raw transcript.
- To use OpenAI for transcription instead: `"provider": "openai"` and
  `"openaiApiKey": "sk-…"`.

See `config.example.json` for all options (including changing the hotkey).

## 3. Run & grant permissions

```sh
open Talk.app
```

A microphone icon appears in the menu bar. The first run asks for two
permissions:

1. **Microphone** — prompted automatically the first time you record.
2. **Accessibility** — required so Talk can paste into other apps. Approve the
   prompt, or add `Talk.app` manually under **System Settings → Privacy &
   Security → Accessibility** and toggle it on.

## 4. Use it

By default Talk uses the **fn (🌐 Globe) key** as **push-to-talk**:

1. Click into any text field.
2. **Hold fn** and speak — the icon turns red.
3. **Release fn**. Talk transcribes, cleans up, and types the text into the field.

The menu-bar icon shows state: `mic` (ready) → red `mic.fill` (recording) →
`waveform` (transcribing). Errors appear briefly in the menu.

> **Avoid fn conflicts:** macOS may bind the fn key to emoji/dictation. Open
> **System Settings → Keyboard → "Press 🌐 key to"** and set it to **Do Nothing**
> so holding fn doesn't also pop the emoji picker or system dictation.

## Changing the hotkey

In `~/.talk/config.json`:

- **fn push-to-talk (default):** `"hotKeyKey": "fn"` — hold to record, release to send.
- **Modifier combo (toggle):** set both fields, e.g.
  ```json
  "hotKeyModifiers": ["control", "option", "command"],
  "hotKeyKey": "space"
  ```
  Press once to start recording, press again to stop. Modifiers:
  `command`, `option`, `control`, `shift`. Keys: `space`, `a`–`z`, `0`–`9`,
  `f1`–`f12`, `return`, `tab`, `escape`.

After editing, **Reload config** from the menu (or quit and reopen).

## Choosing a microphone

Menu-bar menu → **Microphone**. Pick a device and Talk records from *that* device
from then on, even when macOS moves its own input somewhere else — which is what
happens every time AirPods connect. The choice survives quitting, restarting, and
unplugging the device: it is saved by CoreAudio device UID in `~/.talk/state.json`,
so it re-attaches to the same physical mic on reconnect.

- **System default** follows macOS the way Talk did before there was a picker.
  The menu shows which device that currently is.
- A pinned device that isn't plugged in shows as **(not connected)**. If you press
  the hotkey while it's away, Talk **refuses to record** and says so rather than
  quietly using another mic — silently switching is the bug the picker exists to
  fix, so falling back would defeat it. Plug the device back in, or pick another.
- **Bluetooth mics** (AirPods and friends) put the headset into call mode while
  recording, which drops music to phone quality for those few seconds. macOS gives
  apps no way around it. Pinning the built-in mic avoids it entirely — and at
  48 kHz it also feeds Whisper better audio than a Bluetooth headset does.

A default can be pre-set with `"microphone"` in `~/.talk/config.json` (a device
name, a UID, or `"system"`), but a choice made in the menu wins from then on.
`rm ~/.talk/state.json` hands control back to the config file.

## Improving accuracy

If words come out wrong, in rough order of impact:

- **Model** — `"transcriptionModel": "whisper-large-v3"` (default) is the most
  accurate. `whisper-large-v3-turbo` is faster but less accurate.
- **Language hint** — set `"language"` to what you speak (`"en"`, `"es"`, …). A
  fixed language stops the model from guessing and mis-hearing.
- **Custom vocabulary** — put names, jargon, acronyms, and preferred spellings in
  `"transcriptionPrompt"`, e.g. `"Versionstory, Kubernetes, gRPC, Zakar"`. The
  model biases toward those.
- **Mic & environment** — pin the mic you want under **Microphone** in the menu so
  macOS can't move it out from under you. A close headset mic beats the far-field
  built-in one in a noisy room, though a Bluetooth headset is recorded in call mode
  and is often *worse* than the 48 kHz built-in mic; reduce background noise; raise
  **System Settings → Sound → Input** volume; speak at a steady pace.
- **Cleanup model** — `"anthropicModel": "claude-sonnet-4-6"` fixes more
  transcription errors from context than Haiku (a bit slower/pricier).

Audio is recorded losslessly (16-bit mono PCM), so compression isn't a factor.

## Local (on-device) transcription

Run Whisper on your Mac instead of in the cloud — private (your audio never
leaves the machine), free, and offline. Cleanup still uses Claude.

**Switch to local:** set `"provider": "local"` in `~/.talk/config.json` and
**Reload config**. Switch back any time with `"provider": "groq"`. Your Groq key
stays in the file, so flipping back is one word.

This needs a local Whisper server running. Setup (one time):

```sh
brew install whisper-cpp
mkdir -p ~/.talk/models
curl -L -o ~/.talk/models/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

**Talk starts the Whisper server itself** when it launches in local mode, and
stops it when you quit — no extra setup. The first launch takes ~15 s to load
the model (the menu's *Source* line shows "NOT running" until it's ready, then
"running"); after that, clips transcribe in well under a second on Apple Silicon
(GPU-accelerated). Talk auto-detects the server at `/opt/homebrew/bin/whisper-server`
and the model above — override with `"whisperServerPath"` / `"whisperModelPath"`
in the config if yours differ.

Want the server to run independently of Talk (e.g. always-on, even when Talk is
closed)? An optional LaunchAgent and a manual-start script are in `scripts/`. If
a server is already running on the port, Talk reuses it instead of starting its
own. Logs: `~/.talk/whisper-server.log`.

## Translation (speak another language → English text)

Whisper can translate speech in any language **to English** (English-only target —
it can't go English→other). Menu-bar menu → check **Translate to English**;
optionally set **Language** to your source (e.g. Armenian) for a better result.
Speak, and English text is typed in. The *Source* line shows `· Translate→EN`
while it's on.

- **Cloud (Groq/OpenAI):** works — uses the `/audio/translations` endpoint with
  `whisper-large-v3` (auto-upgraded from turbo when translating).
- **Local:** translation needs the **full `large-v3`** model — the default
  `large-v3-turbo` can only transcribe, so "translate" silently stays in the
  source language. Download `ggml-large-v3.bin` and point `whisperModelPath` at
  it for local translation.
- Quality for lower-resource languages (e.g. Armenian) is decent but not perfect.

## How it works

| File | Responsibility |
|------|----------------|
| `HotKey.swift` | System-wide hotkey via Carbon `RegisterEventHotKey` (no extra permissions, doesn't leak keystrokes). |
| `AudioDevices.swift` | CoreAudio input-device enumeration and UID lookup — the stable id a pinned mic is remembered by. |
| `AppState.swift` | `~/.talk/state.json` — the settings Talk writes itself (the chosen mic), separate from the hand-edited config. |
| `AudioRecorder.swift` | Mic capture to 16 kHz mono 16-bit WAV via AVAudioEngine, pinned to the chosen input device. |
| `Transcriber.swift` | Multipart upload to Groq/OpenAI Whisper endpoint. |
| `Cleaner.swift` | Anthropic Messages API (`claude-haiku-4-5`) cleanup. |
| `Paster.swift` | Clipboard + synthesized ⌘V via `CGEvent`. |
| `AppDelegate.swift` | Menu bar UI + state machine wiring it together. |

## Notes & limitations

- **Privacy**: audio is sent to your transcription provider, and the transcript
  to Anthropic (if cleanup is on). API keys live only in `~/.talk/config.json`
  on your machine.
- **Clipboard**: Talk briefly uses the clipboard to paste, then restores your
  previous clipboard contents.
- **Files**: `~/.talk/config.json` is yours to edit and Talk only reads it.
  `~/.talk/state.json` is written by Talk (currently just the chosen microphone) —
  copy it alongside the config when moving to another Mac, or leave it out to
  start on the system default.
- **GUI launch & keys**: launched as `Talk.app`, the app reads keys from
  `~/.talk/config.json` (GUI apps don't inherit your shell environment). Running
  the raw binary from a terminal also honors `GROQ_API_KEY` / `OPENAI_API_KEY` /
  `ANTHROPIC_API_KEY`.
- **Re-granting permissions**: rebuilding re-signs the bundle. If macOS stops
  recognizing the permission after a rebuild, remove and re-add `Talk.app` in
  System Settings, or reset with:
  ```sh
  tccutil reset Microphone com.example.talk
  tccutil reset Accessibility com.example.talk
  ```
