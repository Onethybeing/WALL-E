"""Tools the agent is allowed to call. Each tool is a plain Python function
plus a JSON-schema-ish description the model sees in the system prompt.

Keep this list short and sharp — every tool here is something the model
might misuse, so bash especially should only ever run on a device you own.
"""

import json
import os
import platform
import re
import shlex
import subprocess
import tempfile
import time
from pathlib import Path

import requests

import memory
import mood_bridge
import settings
import skills
import vision
import voice

BASH_TIMEOUT_SECONDS = 30
MAX_OUTPUT_CHARS = 4000
MIC_MAX_SECONDS = 15  # hard cap so a silent mic can't hang forever -- see mic_listen




def bash(command: str) -> str:
    """Run a shell command on this device and return its output."""
    try:
        result = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=BASH_TIMEOUT_SECONDS,
        )
        output = (result.stdout or "") + (result.stderr or "")
        output = output.strip() or "(no output)"
        return output[:MAX_OUTPUT_CHARS]
    except subprocess.TimeoutExpired:
        return f"Command timed out after {BASH_TIMEOUT_SECONDS}s."
    except Exception as e:
        return f"Error running command: {e}"


def _web_search_firecrawl(query: str) -> str:
    key = settings.load()["firecrawl_api_key"] or os.environ.get("FIRECRAWL_API_KEY")
    if not key:
        raise RuntimeError("Set firecrawl_api_key in settings.json, or export FIRECRAWL_API_KEY")
    resp = requests.post(
        "https://api.firecrawl.dev/v2/search",
        headers={"Authorization": f"Bearer {key}"},
        json={"query": query, "limit": 5},
        timeout=20,
    )
    resp.raise_for_status()
    results = resp.json().get("data", {}).get("web", [])
    if not results:
        return "No results found for that query."
    lines = []
    for r in results:
        desc = " ".join(r.get("description", "").split())  # collapse to one line, strip markdown noise
        if len(desc) > 200:
            desc = desc[:200].rsplit(" ", 1)[0] + "..."
        lines.append(f"- {r.get('title', '')}: {desc} ({r.get('url', '')})")
    return "\n".join(lines)


def _web_search_ddg(query: str) -> str:
    """Basic, keyless web search using DuckDuckGo's instant-answer API --
    only covers Wikipedia-style topic abstracts, not general queries (see
    GitHub issue #11). Kept as a no-key fallback.
    """
    resp = requests.get(
        "https://api.duckduckgo.com/",
        params={"q": query, "format": "json", "no_html": 1, "skip_disambig": 1},
        timeout=10,
    )
    data = resp.json()
    abstract = data.get("AbstractText")
    if abstract:
        return abstract
    related = data.get("RelatedTopics", [])
    snippets = [r["Text"] for r in related if isinstance(r, dict) and r.get("Text")]
    if snippets:
        return "\n".join(snippets[:3])
    return "No quick answer found for that query."


def web_search(query: str) -> str:
    """Search the web. Uses Firecrawl's /search API if a key is configured
    (real general web results), falling back to DuckDuckGo's keyless
    instant-answer API otherwise (Wikipedia-style topics only).
    """
    mood_bridge.set_mood("searching")
    try:
        if settings.load()["firecrawl_api_key"] or os.environ.get("FIRECRAWL_API_KEY"):
            return _web_search_firecrawl(query)
        return _web_search_ddg(query)
    except Exception as e:
        return f"Search failed: {e}"
    finally:
        mood_bridge.set_mood("idle")


def _play_audio(path: str) -> None:
    """Play a wav file. Windows uses the built-in SoundPlayer for dev testing;
    on the phone (Termux) this should use `termux-media-player play <path>`.
    """
    if platform.system() == "Windows":
        subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-Command",
                f'(New-Object Media.SoundPlayer "{path}").PlaySync()',
            ],
            check=False,
        )
    else:
        subprocess.run(["termux-media-player", "play", path], check=False)


def speak(text: str) -> str:
    """Say something out loud through the speaker."""
    mood_bridge.set_mood("speaking")
    try:
        out_path = str(Path(tempfile.gettempdir()) / f"walle_speak_{int(time.time())}.wav")
        voice.speak(text, out_path)
        _play_audio(out_path)
        return f"(spoke): {text}"
    finally:
        mood_bridge.set_mood("idle")


def mic_listen(seconds: int | None = None) -> str:
    """Record from the microphone and transcribe it, stopping automatically
    once the user stops talking (voice-activity detection) instead of
    always recording a fixed duration -- faster turnaround, and avoids both
    clipping long utterances and padding short ones with dead air.

    `seconds`, if given, is used as a hard cap instead of MIC_MAX_SECONDS;
    the default is pure VAD-driven (recording ends ~1s after speech stops).

    Routed through the Flutter app's own mic recording (bridge_server.dart's
    /listen) rather than termux-microphone-record: `adb shell cmd appops get
    com.termux.api` shows RECORD_AUDIO capped at AppOps mode "foreground" at
    the *uid* level on this device/ROM (confirmed not overridable per-package
    either), which silently hands back empty/zeroed audio instead of
    erroring -- termux-microphone-record "succeeds" while actually capturing
    nothing. This app's own RECORD_AUDIO AppOps is a healthy "allow" by
    contrast (same root cause and same fix pattern as analyze_photo and
    get_location before it).
    """
    max_seconds = seconds or MIC_MAX_SECONDS
    mood_bridge.set_mood("listening")
    try:
        try:
            resp = requests.get(
                f"{BRIDGE_BASE}/listen",
                params={"max_seconds": max_seconds},
                timeout=max_seconds + 10,
            )
            resp.raise_for_status()
        except Exception as e:
            return f"mic_listen failed: could not reach the app's mic bridge ({e})"

        rec_path = str(Path(tempfile.gettempdir()) / f"walle_listen_{int(time.time())}.wav")
        Path(rec_path).write_bytes(resp.content)

        try:
            return voice.transcribe(rec_path)
        except Exception as e:
            # A transcription-API failure (bad request, no internet, etc) is
            # exactly as "mic_listen failed" to the caller as a recording
            # failure -- run_voice_turn already knows how to react to that
            # prefix with a friendly fallback instead of silently crashing.
            return f"mic_listen failed: transcription error: {e}"
        finally:
            Path(rec_path).unlink(missing_ok=True)
    finally:
        mood_bridge.set_mood("idle")


def remember(key: str, value: str) -> str:
    """Save a fact for later (e.g. a user preference or something learned)."""
    return memory.remember(key, value)


def recall(query: str) -> str:
    """Look up previously remembered facts matching a query."""
    return memory.recall(query)


def _require_termux(tool_name: str) -> str | None:
    """Shared guard for tools that only make sense on the phone. Returns an
    error string if we're not on Termux/Android, or None if it's fine to proceed.
    """
    if platform.system() == "Windows":
        return f"{tool_name} is only implemented for Termux/Android right now."
    return None


def set_alarm(hour: int, minute: int, label: str = "") -> str:
    """Set a real system alarm via the phone's clock app (not a cron job --
    this survives even if Termux itself gets killed in the background).

    Routed through the Flutter app's own SET_ALARM intent (see
    bridge_server.dart's /alarm + MainActivity.kt) rather than firing it
    from Termux directly, because Termux's manifest doesn't declare the
    com.android.alarm.permission.SET_ALARM permission at all -- there's
    nothing for `pm grant` to grant (confirmed: a direct `am start` attempt
    gets a SecurityException naming that exact missing permission). The
    Flutter app declares it for itself instead (see GitHub issue #12).
    """
    try:
        resp = requests.post(
            f"{BRIDGE_BASE}/alarm",
            json={"hour": int(hour), "minute": int(minute), "label": label},
            timeout=10,
        )
        resp.raise_for_status()
        suffix = f" ({label})" if label else ""
        return f"Alarm set for {hour:02d}:{minute:02d}{suffix}"
    except Exception as e:
        return f"set_alarm failed: could not reach the app's alarm bridge ({e})"


_CRON_FIELD_RE = re.compile(r"^[0-9*/,-]+$")


def schedule_reminder(cron_expr: str, message: str) -> str:
    """Schedule a recurring reminder notification via cron. 5-field cron syntax,
    e.g. "0 9 * * *" for daily at 9am.

    Requires `pkg install cronie` and `crond` running, plus `termux-wake-lock`
    active so Android doesn't kill Termux in the background -- unlike
    set_alarm, this does NOT survive Termux being force-stopped.
    """
    if (err := _require_termux("schedule_reminder")) is not None:
        return err
    fields = cron_expr.split()
    if len(fields) != 5 or not all(_CRON_FIELD_RE.match(f) for f in fields):
        return (
            "Invalid cron_expr -- expected 5 space-separated fields using only "
            "digits, *, /, -, , (e.g. '0 9 * * *' for daily at 9am)."
        )
    try:
        existing = subprocess.run(
            ["crontab", "-l"], capture_output=True, text=True, timeout=10
        ).stdout
    except Exception:
        existing = ""
    notify_cmd = ["termux-notification", "--title", "WALL-E", "--content", message]
    new_line = f"{cron_expr} {shlex.join(notify_cmd)}"
    new_crontab = existing.rstrip("\n") + "\n" + new_line + "\n"
    try:
        subprocess.run(
            ["crontab", "-"], input=new_crontab, text=True, check=True, timeout=10
        )
        return (
            f"Scheduled '{message}' for cron time '{cron_expr}'. "
            "Make sure cronie is installed and crond is running."
        )
    except Exception as e:
        return f"Failed to schedule reminder: {e}"


def open_app(uri: str) -> str:
    """Open an app or URL via an Android intent -- e.g. a Spotify URI
    (spotify:track:...), a plain https:// link, or any other app's deep link.
    """
    if (err := _require_termux("open_app")) is not None:
        return err
    try:
        subprocess.run(
            ["am", "start", "-a", "android.intent.action.VIEW", "-d", uri],
            check=True, capture_output=True, text=True, timeout=10,
        )
        return f"Opened: {uri}"
    except Exception as e:
        return f"Failed to open '{uri}': {e}"


_MEDIA_ACTIONS = {"play_pause", "next", "previous"}

BRIDGE_BASE = "http://127.0.0.1:8099"


def media_control(action: str) -> str:
    """Send a media key (play_pause, next, previous) to whatever app is
    currently playing audio (Spotify, YouTube Music, etc) -- generic control
    with no per-app API or login needed.

    Routed through the Flutter app's own AudioManager.dispatchMediaKeyEvent
    (see bridge_server.dart's /media + MainActivity.kt) rather than Termux's
    `input keyevent`, because that needs the signature-level INJECT_EVENTS
    permission, which isn't grantable to a third-party app like Termux on
    this Android version at all (confirmed: `pm grant` itself refuses it --
    see GitHub issue #10). The Flutter app doesn't need any special
    permission for this API, since it's the same mechanism a Bluetooth
    headset's media button uses.
    """
    if action not in _MEDIA_ACTIONS:
        return f"Unknown media action '{action}'. Use one of: {', '.join(_MEDIA_ACTIONS)}."
    try:
        resp = requests.post(f"{BRIDGE_BASE}/media", json={"action": action}, timeout=10)
        resp.raise_for_status()
        return f"Sent media action: {action}"
    except Exception as e:
        return f"media_control failed: could not reach the app's media bridge ({e})"


def open_app_by_name(name: str) -> str:
    """Launch an installed app by its name (e.g. 'Spotify', 'Instagram',
    'Chrome') -- unlike open_app, which needs a specific URI scheme, this
    just matches against the names of apps actually installed on the phone.
    """
    try:
        resp = requests.post(f"{BRIDGE_BASE}/app/open", json={"name": name}, timeout=10)
        resp.raise_for_status()
        if resp.json().get("ok"):
            return f"Opened {name}."
        return f"Couldn't find an installed app matching '{name}'."
    except Exception as e:
        return f"open_app_by_name failed: could not reach the app bridge ({e})"


_SCREEN_ACTIONS = {"back", "home", "recents", "notifications"}


def _accessibility_enabled() -> bool:
    try:
        resp = requests.get(f"{BRIDGE_BASE}/accessibility/status", timeout=5)
        resp.raise_for_status()
        return bool(resp.json().get("enabled"))
    except Exception:
        return False


_ACCESSIBILITY_HINT = (
    "Accessibility access isn't enabled yet. Ask the person to open WALL-E's "
    "accessibility settings (call request_accessibility_access) and turn on "
    "the WALL-E service -- this can't be granted automatically, Android "
    "requires a manual tap for a permission this powerful."
)


def request_accessibility_access() -> str:
    """Opens Android's Accessibility settings screen so the person can
    enable WALL-E's accessibility service -- required once before
    control_screen/read_screen/tap_screen_text will work. Can't be granted
    automatically; this is a deliberately manual step for a permission this
    powerful (system-wide screen reading + gesture injection).
    """
    try:
        resp = requests.post(f"{BRIDGE_BASE}/accessibility/request", timeout=10)
        resp.raise_for_status()
        return (
            "Opened Accessibility settings. Find 'WALL-E' in the list and turn "
            "it on, then let me know."
        )
    except Exception as e:
        return f"request_accessibility_access failed: could not reach the app bridge ({e})"


def read_screen() -> str:
    """Read the text currently visible on screen (whatever app is in the
    foreground, not just WALL-E's own eyes) -- use this to see what's there
    before tapping or scrolling, rather than guessing blind.
    """
    if not _accessibility_enabled():
        return _ACCESSIBILITY_HINT
    try:
        resp = requests.get(f"{BRIDGE_BASE}/screen/text", timeout=10)
        resp.raise_for_status()
        return resp.text.strip() or "(nothing readable on screen right now)"
    except Exception as e:
        return f"read_screen failed: could not reach the app bridge ({e})"


def tap_screen_text(text: str) -> str:
    """Find the first visible element containing `text` (case-insensitive)
    and tap it -- the reliable way to interact with an app: read_screen
    first to see what's actually there, then tap by the text you saw.
    """
    if not _accessibility_enabled():
        return _ACCESSIBILITY_HINT
    try:
        resp = requests.post(f"{BRIDGE_BASE}/screen/tap_text", json={"text": text}, timeout=10)
        resp.raise_for_status()
        if resp.json().get("ok"):
            return f"Tapped '{text}'."
        return f"Couldn't find anything matching '{text}' on screen."
    except Exception as e:
        return f"tap_screen_text failed: could not reach the app bridge ({e})"


def control_screen(action: str) -> str:
    """Send a system-level screen action: 'back', 'home', 'recents', or
    'notifications' (opens the notification shade). For scrolling, use
    scroll_screen instead.
    """
    if not _accessibility_enabled():
        return _ACCESSIBILITY_HINT
    if action not in _SCREEN_ACTIONS:
        return f"Unknown screen action '{action}'. Use one of: {', '.join(_SCREEN_ACTIONS)}."
    try:
        resp = requests.post(f"{BRIDGE_BASE}/screen/action", json={"action": action}, timeout=10)
        resp.raise_for_status()
        if resp.json().get("ok"):
            return f"Sent screen action: {action}"
        return f"Screen action '{action}' didn't go through."
    except Exception as e:
        return f"control_screen failed: could not reach the app bridge ({e})"


_SCROLL_SWIPES = {
    # (x1, y1, x2, y2) as fractions of the screen -- a scroll "down" means
    # the content moves up, so the swipe itself goes from low to high y.
    "up": (0.5, 0.3, 0.5, 0.75),
    "down": (0.5, 0.75, 0.5, 0.3),
    "left": (0.75, 0.5, 0.25, 0.5),
    "right": (0.25, 0.5, 0.75, 0.5),
}


def scroll_screen(direction: str) -> str:
    """Scroll the current screen 'up', 'down', 'left', or 'right'."""
    if not _accessibility_enabled():
        return _ACCESSIBILITY_HINT
    swipe = _SCROLL_SWIPES.get(direction)
    if swipe is None:
        return f"Unknown scroll direction '{direction}'. Use one of: {', '.join(_SCROLL_SWIPES)}."
    x1, y1, x2, y2 = swipe
    try:
        resp = requests.post(
            f"{BRIDGE_BASE}/screen/gesture",
            json={"x1": x1, "y1": y1, "x2": x2, "y2": y2, "duration_ms": 300},
            timeout=10,
        )
        resp.raise_for_status()
        return f"Scrolled {direction}." if resp.json().get("ok") else f"Scroll {direction} didn't go through."
    except Exception as e:
        return f"scroll_screen failed: could not reach the app bridge ({e})"


def tap_screen_at(x: float, y: float) -> str:
    """Tap the screen at a specific point, as fractions of the screen size
    (0.0-1.0 for both x and y, e.g. x=0.5, y=0.5 is dead center). Prefer
    tap_screen_text when you can read what you want to tap instead."""
    if not _accessibility_enabled():
        return _ACCESSIBILITY_HINT
    try:
        resp = requests.post(
            f"{BRIDGE_BASE}/screen/gesture", json={"x1": x, "y1": y}, timeout=10
        )
        resp.raise_for_status()
        return f"Tapped ({x}, {y})." if resp.json().get("ok") else "Tap didn't go through."
    except Exception as e:
        return f"tap_screen_at failed: could not reach the app bridge ({e})"


def analyze_photo(prompt: str) -> str:
    """Take a photo with the phone's camera and ask a question about it,
    e.g. "what am I wearing" or "what does this room look like".

    Routed through the Flutter app's own camera via a local HTTP bridge
    (see bridge_server.dart) rather than termux-camera-photo, because
    Termux:API's Camera command is broken on a sideloaded (non-Play-Store)
    install. Being loopback-only, this also works regardless of any
    network-level isolation (e.g. mobile hotspot client isolation).
    """
    mood_bridge.set_mood("taking_photo")
    try:
        try:
            resp = requests.get(f"{BRIDGE_BASE}/photo", timeout=15)
            resp.raise_for_status()
        except Exception as e:
            return f"analyze_photo failed: could not reach the app's camera bridge ({e})"

        photo_path = str(Path(tempfile.gettempdir()) / f"walle_photo_{int(time.time())}.jpg")
        Path(photo_path).write_bytes(resp.content)
        return vision.analyze(photo_path, prompt)
    finally:
        mood_bridge.set_mood("idle")


def get_location() -> str:
    """Get the phone's current GPS location (lat/lon/accuracy etc. as JSON).

    Routed through the Flutter app's geolocator via the same local bridge,
    for the same reason as analyze_photo -- termux-location is broken on
    this install.
    """
    try:
        resp = requests.get(f"{BRIDGE_BASE}/location", timeout=20)
        resp.raise_for_status()
    except Exception as e:
        return f"get_location failed: could not reach the app's location bridge ({e})"
    return resp.text


def get_weather(latitude: float, longitude: float) -> str:
    """Get current weather for a lat/lon (use get_location first if needed).
    Free, keyless API (open-meteo.com) -- no account required.
    """
    try:
        resp = requests.get(
            "https://api.open-meteo.com/v1/forecast",
            params={"latitude": latitude, "longitude": longitude, "current_weather": "true"},
            timeout=10,
        )
        resp.raise_for_status()
        data = resp.json()
        weather = data.get("current_weather", {})
        return json.dumps(weather)
    except Exception as e:
        return f"get_weather failed: {e}"


def read_skill(name: str) -> str:
    """Load the full instructions for a specific skill by name."""
    return skills.read_skill(name)


def save_skill(name: str, description: str, content: str) -> str:
    """Author a new skill for yourself -- use this when you notice a repeated
    multi-step task so future turns can jump straight to the right approach.
    """
    return skills.save_skill(name, description, content)


# Registry the agent loop uses to dispatch tool calls by name.
REGISTRY = {
    "bash": bash,
    "web_search": web_search,
    "remember": remember,
    "recall": recall,
    "speak": speak,
    "mic_listen": mic_listen,
    "set_alarm": set_alarm,
    "schedule_reminder": schedule_reminder,
    "open_app": open_app,
    "media_control": media_control,
    "read_skill": read_skill,
    "save_skill": save_skill,
    "analyze_photo": analyze_photo,
    "get_location": get_location,
    "get_weather": get_weather,
    "open_app_by_name": open_app_by_name,
    "request_accessibility_access": request_accessibility_access,
    "read_screen": read_screen,
    "tap_screen_text": tap_screen_text,
    "tap_screen_at": tap_screen_at,
    "scroll_screen": scroll_screen,
    "control_screen": control_screen,
}

# Descriptions injected into the system prompt so the model knows what it can do.
TOOL_DESCRIPTIONS = """\
- bash(command: str): Run a shell command on the phone and get its output. \
Use this for anything involving files, system info, or automating tasks.
- web_search(query: str): Search the web for current information.
- remember(key: str, value: str): Save a fact for later, e.g. a user preference.
- recall(query: str): Look up previously remembered facts matching a query.
- speak(text: str): Say something out loud through the phone's speaker.
- mic_listen(): Record from the microphone and transcribe what was said -- \
automatically stops once you stop hearing speech, no need to guess a duration.
- set_alarm(hour: int, minute: int, label: str): Set a real system alarm.
- schedule_reminder(cron_expr: str, message: str): Schedule a recurring notification (cron syntax).
- open_app(uri: str): Open an app or URL via an Android intent (e.g. a Spotify link).
- media_control(action: str): Send play_pause/next/previous to whatever app is playing audio.
- read_skill(name: str): Load detailed instructions for a specific skill (see "Skills available" below).
- save_skill(name: str, description: str, content: str): Author a new skill for yourself.
- analyze_photo(prompt: str): Take a photo with the camera and ask a question about what it shows.
- get_location(): Get the phone's current GPS location as JSON (lat/lon/accuracy).
- get_weather(latitude: float, longitude: float): Get current weather for a location.
- open_app_by_name(name: str): Launch an installed app by its name (e.g. "Spotify").
- request_accessibility_access(): Open settings so the person can enable screen control \
(needed once before read_screen/tap_screen_text/tap_screen_at/scroll_screen/control_screen work).
- read_screen(): Read the text currently visible on screen, in whatever app is in the foreground.
- tap_screen_text(text: str): Find and tap the first on-screen element matching this text.
- tap_screen_at(x: float, y: float): Tap a specific point (fractions 0.0-1.0 of the screen).
- scroll_screen(direction: str): Scroll the screen "up", "down", "left", or "right".
- control_screen(action: str): Send "back", "home", "recents", or "notifications".
"""
