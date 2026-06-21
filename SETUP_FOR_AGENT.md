# Talk — Setup Instructions (for an AI coding agent)

You are setting up **Talk**, a native macOS menu-bar AI dictation app, on this
Mac. **This folder is the complete source.** Build it, then help the user
configure and run it. Full details are in `README.md`; this file is the
execution checklist.

## What it does
The user holds a hotkey (default: **fn**), speaks, releases → the speech is
transcribed (cloud Groq/OpenAI Whisper, or on-device whisper.cpp) and typed into
whatever text field is focused. Optional cleanup pass with Claude.

Swift + AppKit/AVFoundation, no external runtime deps. Built with Swift Package
Manager and bundled into an ad-hoc-signed `.app`.

---

## 0. Prerequisites
- macOS, Apple Silicon or Intel. (`uname -m`)
- Xcode Command Line Tools (provides Swift). Check `swift --version`; if missing:
  ```sh
  xcode-select --install
  ```

## 1. Place the project
Move this folder to a working location, e.g. `~/code/talk`. Run all commands
below from the project root.

## 2. Build
```sh
./build.sh
```
This runs `swift build -c release`, assembles `Talk.app`, and ad-hoc code-signs
it. Output: `Talk.app` in the project root. If the build fails, fix the reported
Swift errors and re-run — there are no external dependencies to install.

## 3. Configure `~/.talk/config.json`
The app reads `~/.talk/config.json` (NOT a file in this folder). API keys are
**intentionally not bundled** — get them from the user.

- **If the user copied their `config.json` from the other Mac:** put it at
  `~/.talk/config.json` and skip to step 5.
- **Otherwise** create it from the template and ask the user for keys:
  ```sh
  mkdir -p ~/.talk
  cp config.example.json ~/.talk/config.json
  # then edit ~/.talk/config.json (see config.example.json for all options)
  ```

Minimum for **cloud** mode (simplest, recommended to start). `config.json` is
plain JSON (no comments):
```json
{
  "provider": "groq",
  "groqApiKey": "gsk_...",
  "anthropicApiKey": "sk-ant-...",
  "cleanup": false
}
```
- `provider`: `"groq"` or `"openai"` (cloud) or `"local"` (on-device).
- `groqApiKey`: cloud transcription key — https://console.groq.com/keys (free tier).
- `anthropicApiKey`: optional Claude cleanup key — https://console.anthropic.com.
- `cleanup`: `true` = Claude tidies punctuation/filler (needs the Anthropic key);
  `false` = type the raw transcript.

## 4. (Optional) Local on-device transcription
Only if the user wants `"provider": "local"` (private, free, offline):
```sh
brew install whisper-cpp
mkdir -p ~/.talk/models
curl -L -o ~/.talk/models/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```
The app **starts and stops the whisper server itself** when it launches/quits in
local mode — no LaunchAgent or manual step needed. (For translation in local
mode, the full `ggml-large-v3.bin` is required — turbo can't translate.)

## 5. Run & grant permissions
```sh
open Talk.app
```
A microphone icon appears in the menu bar. Three permission notes:
1. **Gatekeeper:** ad-hoc signed (no Apple Developer account), so the first open
   may be blocked ("cannot verify developer"). Fix: right-click `Talk.app` →
   **Open**, or **System Settings → Privacy & Security → Open Anyway**.
2. **Microphone:** prompted on first dictation — Allow.
3. **Accessibility (required):** the app types into other apps by synthesizing
   ⌘V, which needs Accessibility trust. Approve the prompt, or **System Settings
   → Privacy & Security → Accessibility** → enable **Talk**. **If dictation
   transcribes but nothing gets typed, this is almost always the cause** (the
   app falls back to putting the text on the clipboard and says so in the menu).

## 6. Use it
- Default hotkey: **hold fn**, speak, release. (Configurable — README.md →
  "Changing the hotkey".)
- The menu-bar icon shows state; its menu has **Source** (provider + whether the
  local server is running), a **Language** picker, a **Translate to English**
  toggle, **Open/Reload config**, and **Quit**.

---

## Gotchas to remember
- **Rebuilding re-signs the app**, which can reset its Accessibility grant —
  re-enable "Talk" under System Settings → Accessibility if typing stops working
  after a rebuild.
- **API keys are not machine-bound** — the same Groq/Anthropic keys work here.
- **`Source: ... NOT running`** in local mode means whisper-cpp isn't installed
  or `whisperModelPath` is wrong (see config / step 4).
- The app is a menu-bar (accessory) app — no Dock icon, no window. Everything is
  in the menu-bar icon's menu.

Full reference and config options: **README.md** in this folder.
