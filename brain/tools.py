"""Tools the agent is allowed to call. Each tool is a plain Python function
plus a JSON-schema-ish description the model sees in the system prompt.

Keep this list short and sharp — every tool here is something the model
might misuse, so bash especially should only ever run on a device you own.
"""

import platform
import re
import shlex
import subprocess
import tempfile
import time
from pathlib import Path

import requests

import json

import memory
import skills
import vision
import voice

BASH_TIMEOUT_SECONDS = 30
MAX_OUTPUT_CHARS = 4000
MIC_RECORD_SECONDS_DEFAULT = 5


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


def web_search(query: str) -> str:
    """Basic, keyless web search using DuckDuckGo's instant-answer API.

    Deliberately lightweight for v1 — no API key, no heavy scraping deps.
    Upgrade path: swap this for a real search API once we need better recall.
    """
    try:
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
    except Exception as e:
        return f"Search failed: {e}"


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
    out_path = str(Path(tempfile.gettempdir()) / f"walle_speak_{int(time.time())}.wav")
    voice.speak(text, out_path)
    _play_audio(out_path)
    return f"(spoke): {text}"


def mic_listen(seconds: int = MIC_RECORD_SECONDS_DEFAULT) -> str:
    """Record from the microphone for a few seconds and transcribe it.

    Phone-only (Termux): uses `termux-microphone-record`, which requires the
    Termux:API app and microphone permission.
    """
    if platform.system() == "Windows":
        return "mic_listen is only implemented for Termux/Android right now."

    rec_path = str(Path(tempfile.gettempdir()) / f"walle_listen_{int(time.time())}.wav")
    start = subprocess.run(
        ["termux-microphone-record", "-f", rec_path, "-l", str(seconds)],
        capture_output=True, text=True, check=False,
    )
    time.sleep(seconds + 1)
    subprocess.run(["termux-microphone-record", "-q"], check=False)

    if not Path(rec_path).exists():
        # termux-microphone-record reports errors (e.g. missing RECORD_AUDIO
        # permission) as JSON on stdout rather than a nonzero exit code, so
        # surface that instead of a confusing downstream FileNotFoundError.
        detail = start.stdout.strip() or start.stderr.strip() or "no recording was produced"
        return f"mic_listen failed: {detail}"

    return voice.transcribe(rec_path)


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
    """
    if (err := _require_termux("set_alarm")) is not None:
        return err
    try:
        subprocess.run(
            [
                "am", "start", "-a", "android.intent.action.SET_ALARM",
                "--ei", "android.intent.extra.alarm.HOUR", str(int(hour)),
                "--ei", "android.intent.extra.alarm.MINUTES", str(int(minute)),
                "--es", "android.intent.extra.alarm.MESSAGE", label,
                "--ez", "android.intent.extra.alarm.SKIP_UI", "true",
            ],
            check=True, capture_output=True, text=True, timeout=10,
        )
        suffix = f" ({label})" if label else ""
        return f"Alarm set for {hour:02d}:{minute:02d}{suffix}"
    except Exception as e:
        return f"Failed to set alarm: {e}"


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


_MEDIA_KEYCODES = {"play_pause": "85", "next": "87", "previous": "88"}


def media_control(action: str) -> str:
    """Send a media key (play_pause, next, previous) to whatever app is
    currently playing audio (Spotify, YouTube Music, etc) -- generic control
    with no per-app API or login needed.

    Note: on a non-rooted phone, `input keyevent` may fail with a permission
    error unless the device has granted Termux the INJECT_EVENTS permission
    (one-time `adb shell pm grant com.termux android.permission.INJECT_EVENTS`
    from a PC). If that's not set up, this tool will return a clear error
    rather than silently doing nothing.
    """
    if (err := _require_termux("media_control")) is not None:
        return err
    code = _MEDIA_KEYCODES.get(action)
    if code is None:
        return f"Unknown media action '{action}'. Use one of: {', '.join(_MEDIA_KEYCODES)}."
    try:
        subprocess.run(
            ["input", "keyevent", code], check=True, capture_output=True, text=True, timeout=10
        )
        return f"Sent media action: {action}"
    except Exception as e:
        return f"Failed to send media action (device may need INJECT_EVENTS permission): {e}"


BRIDGE_BASE = "http://127.0.0.1:8099"


def analyze_photo(prompt: str) -> str:
    """Take a photo with the phone's camera and ask a question about it,
    e.g. "what am I wearing" or "what does this room look like".

    Routed through the Flutter app's own camera via a local HTTP bridge
    (see bridge_server.dart) rather than termux-camera-photo, because
    Termux:API's Camera command is broken on a sideloaded (non-Play-Store)
    install. Being loopback-only, this also works regardless of any
    network-level isolation (e.g. mobile hotspot client isolation).
    """
    try:
        resp = requests.get(f"{BRIDGE_BASE}/photo", timeout=15)
        resp.raise_for_status()
    except Exception as e:
        return f"analyze_photo failed: could not reach the app's camera bridge ({e})"

    photo_path = str(Path(tempfile.gettempdir()) / f"walle_photo_{int(time.time())}.jpg")
    Path(photo_path).write_bytes(resp.content)
    return vision.analyze(photo_path, prompt)


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
}

# Descriptions injected into the system prompt so the model knows what it can do.
TOOL_DESCRIPTIONS = """\
- bash(command: str): Run a shell command on the phone and get its output. \
Use this for anything involving files, system info, or automating tasks.
- web_search(query: str): Search the web for current information.
- remember(key: str, value: str): Save a fact for later, e.g. a user preference.
- recall(query: str): Look up previously remembered facts matching a query.
- speak(text: str): Say something out loud through the phone's speaker.
- mic_listen(seconds: int): Record from the microphone and transcribe what was said.
- set_alarm(hour: int, minute: int, label: str): Set a real system alarm.
- schedule_reminder(cron_expr: str, message: str): Schedule a recurring notification (cron syntax).
- open_app(uri: str): Open an app or URL via an Android intent (e.g. a Spotify link).
- media_control(action: str): Send play_pause/next/previous to whatever app is playing audio.
- read_skill(name: str): Load detailed instructions for a specific skill (see "Skills available" below).
- save_skill(name: str, description: str, content: str): Author a new skill for yourself.
- analyze_photo(prompt: str): Take a photo with the camera and ask a question about what it shows.
- get_location(): Get the phone's current GPS location as JSON (lat/lon/accuracy).
- get_weather(latitude: float, longitude: float): Get current weather for a location.
"""
