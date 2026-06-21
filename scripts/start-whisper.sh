#!/bin/bash
# Start Talk's local Whisper server (for "provider": "local" mode).
# Leave this running in a terminal while you use local transcription, or install
# the LaunchAgent (see scripts/com.talk.whisper.plist) to run it automatically.
exec /opt/homebrew/bin/whisper-server \
  -m "$HOME/.talk/models/ggml-large-v3-turbo.bin" \
  --host 127.0.0.1 --port 8080
