"""Autonomous "free time" learning loop (GitHub issue #7).

Pattern borrowed from how OpenClaw-style agents are described to
self-extend: discover what's already known (list_skills), research a gap
(web_search), then learn (save_skill) -- so the same topic is already
covered next time it comes up. Meant to run unattended on a schedule (see
setup_cron() below), not during a live conversation.
"""

import json
import re
from pathlib import Path

import skills
import tools

LEARN_LOG_PATH = Path(__file__).parent / "learn.log"

_JSON_BLOCK = re.compile(r"\{.*\}", re.DOTALL)


def _log(line: str) -> None:
    with open(LEARN_LOG_PATH, "a", encoding="utf-8") as f:
        f.write(line.rstrip("\n") + "\n")


def _pick_topic(client) -> str:
    skill_list = skills.list_skills()
    existing = ", ".join(s["name"] for s in skill_list) or "none yet"
    prompt = (
        "You are deciding what to learn next in your free time, to become more "
        "useful as a voice assistant living on someone's phone. "
        f"Skills you already have saved: {existing}. "
        "Suggest ONE new practical topic or skill you don't have yet -- a tool "
        "technique, a domain fact pattern, something genuinely useful to know. "
        "Reply with ONLY the topic itself, 3-8 words, nothing else."
    )
    topic = client.chat([{"role": "user", "content": prompt}], temperature=0.9)
    return topic.strip().strip('"').strip("'")


def _write_up_as_skill(client, topic: str, research: str) -> dict | None:
    prompt = (
        f"You researched this topic: \"{topic}\"\n\nWhat you found:\n{research}\n\n"
        "Turn this into a reusable skill for your own future reference: a short "
        "snake_case name, a one-sentence description, and concrete step-by-step "
        "instructions you could follow next time this topic comes up. Reply with "
        "ONLY this JSON object, no other text:\n"
        '{"name": "...", "description": "...", "content": "..."}'
    )
    reply = client.chat([{"role": "user", "content": prompt}], temperature=0.5)
    match = _JSON_BLOCK.search(reply)
    if not match:
        return None
    try:
        data = json.loads(match.group(0))
    except json.JSONDecodeError:
        return None
    if not all(k in data for k in ("name", "description", "content")):
        return None
    return data


def learn_once(client) -> str:
    """Run one discover -> research -> save cycle. Returns a short summary
    of what happened, for logging."""
    try:
        topic = _pick_topic(client)
        if not topic:
            result = "picked no topic, skipping this cycle"
            _log(result)
            return result

        research = tools.web_search(topic)
        if research.startswith("Search failed") or research == "No quick answer found for that query.":
            result = f"topic='{topic}' -- research came up empty ({research}), skipping save"
            _log(result)
            return result

        skill_data = _write_up_as_skill(client, topic, research)
        if skill_data is None:
            result = f"topic='{topic}' -- couldn't parse a skill out of the writeup, skipping save"
            _log(result)
            return result

        save_result = tools.save_skill(**skill_data)
        result = f"topic='{topic}' -- {save_result}"
        _log(result)
        return result
    except Exception as e:
        result = f"learn_once failed: {e}"
        _log(result)
        return result


def setup_cron(interval_hours: int = 4) -> str:
    """Install (or replace) a crontab entry that runs `agent.py --learn`
    every `interval_hours`, unattended -- requires `pkg install cronie` and
    `crond` running (same prerequisite as tools.schedule_reminder).
    """
    import shlex
    import subprocess

    brain_dir = Path(__file__).parent
    cmd = f"cd {shlex.quote(str(brain_dir))} && python agent.py --learn >> learn_cron.log 2>&1"
    cron_line = f"0 */{interval_hours} * * * {cmd}"

    try:
        existing = subprocess.run(
            ["crontab", "-l"], capture_output=True, text=True, timeout=10
        ).stdout
    except Exception:
        existing = ""

    # Replace any previous learn-loop entry rather than stacking duplicates.
    kept_lines = [
        line for line in existing.splitlines() if "agent.py --learn" not in line
    ]
    new_crontab = "\n".join(kept_lines).rstrip("\n") + "\n" + cron_line + "\n"
    subprocess.run(["crontab", "-"], input=new_crontab, text=True, check=True, timeout=10)
    return f"Autonomous learning scheduled every {interval_hours}h via cron."
