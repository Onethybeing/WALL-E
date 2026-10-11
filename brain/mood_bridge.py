"""Push the agent's current activity to the Flutter app's eyes, so they can
visually react (thinking/searching/speaking/taking a photo) while the brain
works -- the reverse direction of the photo/location bridge in tools.py.

Fire-and-forget by design: if the bridge isn't reachable (e.g. running
agent.py on a plain Windows/dev machine with no Flutter app attached), this
silently no-ops rather than raising, matching the tolerant style used
elsewhere in this codebase (see tools.py's analyze_photo/get_location).
"""

import threading

import requests

BRIDGE_BASE = "http://127.0.0.1:8099"

# Valid states the Flutter side (main.dart's Mood enum) knows how to render.
VALID_STATES = {"idle", "listening", "thinking", "searching", "speaking", "taking_photo", "error"}

# Set by agent.py's POST /stop handler (a second tap while the brain is
# mid-turn, see main.dart's _triggerVoiceTurn) and polled cooperatively from
# a few checkpoints -- tools.speak() skips playback if already set, and
# run_voice_turn's conversation-hop loop breaks early. There's no way to
# interrupt a call already blocked inside requests.post() (an in-flight LLM
# or TTS request), so a tap mid-network-call only takes effect once that
# call returns -- but it does immediately stop audio actually playing.
stop_requested = threading.Event()


def set_mood(state: str) -> None:
    if state not in VALID_STATES:
        raise ValueError(f"Unknown mood state {state!r}; expected one of {VALID_STATES}")
    try:
        requests.post(f"{BRIDGE_BASE}/mood", json={"state": state}, timeout=2)
    except Exception:
        pass
