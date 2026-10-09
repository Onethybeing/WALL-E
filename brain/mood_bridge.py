"""Push the agent's current activity to the Flutter app's eyes, so they can
visually react (thinking/searching/speaking/taking a photo) while the brain
works -- the reverse direction of the photo/location bridge in tools.py.

Fire-and-forget by design: if the bridge isn't reachable (e.g. running
agent.py on a plain Windows/dev machine with no Flutter app attached), this
silently no-ops rather than raising, matching the tolerant style used
elsewhere in this codebase (see tools.py's analyze_photo/get_location).
"""

import requests

BRIDGE_BASE = "http://127.0.0.1:8099"

# Valid states the Flutter side (main.dart's Mood enum) knows how to render.
VALID_STATES = {"idle", "listening", "thinking", "searching", "speaking", "taking_photo", "error"}


def set_mood(state: str) -> None:
    if state not in VALID_STATES:
        raise ValueError(f"Unknown mood state {state!r}; expected one of {VALID_STATES}")
    try:
        requests.post(f"{BRIDGE_BASE}/mood", json={"state": state}, timeout=2)
    except Exception:
        pass
