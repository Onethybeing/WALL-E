# WALL-E

A digital pet agent that lives on your phone: animated eyes with camera-based
face tracking, a voice (speaks and listens), and a tool-using LLM brain with
full shell access via Termux — alarms, reminders, web search, photo/location
awareness, and a self-authoring skills system so it can "learn" new
multi-step routines over time.

## Architecture

```
┌──────────────────────────────┐   HTTP    ┌──────────────────────────────┐
│   app/  (Flutter)            │  (local,  │   brain/  (Python, Termux)   │
│   The face: animated eyes,   │◄─────────►│   The mind: agent loop,      │
│   camera, mood, GPS          │ loopback) │   tools, memory, skills      │
└──────────────────────────────┘           └──────────────────────────────┘
```

- **`app/`** — Flutter app. Draws the eyes (blink, look-around, mood-driven
  expressions), does camera-based face tracking, and runs a tiny local HTTP
  server (`lib/bridge_server.dart`) so the brain can ask it for a photo or
  GPS fix -- this exists because Termux:API's own Camera/Location commands
  are broken on a sideloaded (non-Play-Store) install, and routing through
  loopback also sidesteps any Wi-Fi-level device isolation.
- **`brain/`** — Python, runs inside Termux on the phone. The actual agent:
  a Hermes-style tool-calling loop against Gemini (or swappable to Nemotron),
  a `tools.py` registry (bash, web search, alarms, reminders, photo/location/
  weather, speak/listen, skills), sqlite memory, and a skills system modeled
  on OpenClaw's pattern (markdown `SKILL.md` files, injected by name+description,
  full content loaded on demand -- the agent can author new ones itself).

## Setup

**Toolchain:** Flutter SDK, Android SDK (NDK included, for camera/mlkit
plugins), JDK 17, and a phone with Termux + Termux:API installed.

```bash
# App
cd app
flutter pub get
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk

# Brain (push to the phone's Termux, or run locally for development)
cd brain
pip install -r requirements.txt
cp settings.example.json settings.json   # fill in your own API key
python agent.py
```

Get a free Gemini API key at <https://aistudio.google.com/apikey> (used for
chat, TTS, STT, and vision -- no separate keys needed). `settings.json` is
gitignored; `llm_provider` can be switched to `nemotron` if you have a
working NVIDIA NIM API key instead.

## Status

Core loop, tools, memory, skills, voice (speak/listen), and camera/location
bridge are built and verified working end-to-end on a real device. Wake-word
detection is implemented but currently disabled (see `app/lib/wake_word.dart`
-- blocked on an upstream dependency conflict in `porcupine_flutter`).
