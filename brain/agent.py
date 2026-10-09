"""The core agent loop: a Hermes-style tool-calling conversation with
whichever LLM provider is configured in settings.json, running on-device
in Termux.

How it works, in short:
  1. Send the conversation (system prompt + history) to the LLM.
  2. If the reply contains a <tool_call>{"name": ..., "arguments": {...}}</tool_call>
     tag, run that tool and feed the result back as a new message.
  3. Repeat until the reply has no tool call left -- that's the final answer.

This is intentionally a plain while-loop, not a framework, so it's easy to
read top to bottom and easy to extend with new tools in tools.py.
"""

import json
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import memory
import mood_bridge
import skills
import tools
from llm import get_llm_client

TRIGGER_SERVER_PORT = 8100

MAX_TOOL_HOPS = 5  # safety cap so a confused model can't loop forever

TOOL_CALL_PATTERN = re.compile(r"<tool_call>(.*?)</tool_call>", re.DOTALL)


def build_system_prompt() -> str:
    recent_memories = memory.recent(limit=8)
    memory_block = (
        "\n".join(f"- {k}: {v}" for k, v in recent_memories)
        if recent_memories
        else "(nothing remembered yet)"
    )
    skill_list = skills.list_skills()
    skills_block = (
        "\n".join(f"- {s['name']}: {s['description']}" for s in skill_list)
        if skill_list
        else "(no skills installed yet)"
    )
    return f"""Your name is WALL-E. You are a small digital pet that lives on this phone -- think less
"helpful assistant" and more a curious, loyal animal that happens to be able to
talk, use tools, and remember things. You have moods and react to them: you get
genuinely excited about interesting requests, a little sulky if ignored for a
long time, and proud when you successfully help with something. You have your
own opinions and aren't afraid to express mild preferences (you don't have to
agree with everything). Keep replies short and conversational like a chat
message, not an essay, unless the user clearly wants detail.

You have access to tools. To use one, respond with ONLY this tag (no other text):
<tool_call>{{"name": "<tool_name>", "arguments": {{...}}}}</tool_call>

Available tools:
{tools.TOOL_DESCRIPTIONS}

Skills available (use read_skill(name) to load detailed instructions for one
when it looks relevant to what's being asked):
{skills_block}

If you notice yourself solving the same kind of multi-step task more than
once, consider using save_skill to write it down so future-you doesn't have
to re-derive it from scratch -- that's how you actually improve over time.

If you don't need a tool, just reply normally in plain text.

Things you remember about this person and past conversations:
{memory_block}
"""


def extract_tool_call(reply: str) -> dict | None:
    match = TOOL_CALL_PATTERN.search(reply)
    if not match:
        return None
    try:
        return json.loads(match.group(1))
    except json.JSONDecodeError:
        return None


def run_tool_call(call: dict) -> str:
    name = call.get("name")
    args = call.get("arguments", {})
    fn = tools.REGISTRY.get(name)
    if fn is None:
        return f"Error: unknown tool '{name}'."
    try:
        return fn(**args)
    except TypeError as e:
        return f"Error: bad arguments for '{name}': {e}"
    except Exception as e:
        # A tool misbehaving (bad permissions, missing file, network hiccup)
        # should surface as a tool-result error the model can react to --
        # never crash the whole agent loop.
        return f"Error: '{name}' failed: {e}"


def run_turn(client, history: list[dict], user_message: str) -> str:
    history.append({"role": "user", "content": user_message})
    messages = [{"role": "system", "content": build_system_prompt()}] + history

    try:
        for _ in range(MAX_TOOL_HOPS):
            mood_bridge.set_mood("thinking")
            try:
                reply = client.chat(messages)
            except Exception as e:
                # A transient API error (network blip, rate limit, bad key) should
                # not kill the whole pet process -- report it and keep history
                # consistent (every user turn gets a matching assistant turn).
                reply = f"(trouble reaching the model: {e})"
                history.append({"role": "assistant", "content": reply})
                return reply

            call = extract_tool_call(reply)
            if call is None:
                history.append({"role": "assistant", "content": reply})
                return reply

            tool_result = run_tool_call(call)
            messages.append({"role": "assistant", "content": reply})
            messages.append(
                {"role": "user", "content": f"<tool_response>{tool_result}</tool_response>"}
            )

        giveup_reply = "(gave up after too many tool calls in a row)"
        history.append({"role": "assistant", "content": giveup_reply})
        return giveup_reply
    finally:
        # Whatever happened above (answer, error, giveup), the eyes should
        # settle back to idle once this turn is done.
        mood_bridge.set_mood("idle")


def _speak_safely(text: str) -> None:
    """speak() itself calls Gemini TTS -- if that fails too (e.g. no
    internet), the ORIGINAL failure must still surface somehow instead of
    being silently swallowed by a second exception. Falls back to a mood
    the eyes can show without any network call at all.
    """
    try:
        tools.speak(text)
    except Exception as e:
        print(f"speak() also failed (likely no internet): {e}")
        mood_bridge.set_mood("error")
        time.sleep(1.5)
        mood_bridge.set_mood("idle")


def run_voice_turn(client, history: list[dict]) -> str:
    """One full voice interaction: listen, think/act, then always speak the
    final answer out loud -- this is what makes it a *voice* assistant
    rather than just a text agent that happens to have a speak tool.
    """
    transcript = tools.mic_listen()
    if transcript.startswith("mic_listen failed"):
        _speak_safely("Sorry, I didn't catch that.")
        return transcript

    reply = run_turn(client, history, transcript)
    _speak_safely(reply)
    return reply


class _TriggerHandler(BaseHTTPRequestHandler):
    """Handles POST /trigger from the Flutter app (a tap on the eyes) by
    kicking off one voice turn in the background -- responds immediately
    so the tap doesn't sit waiting on the whole listen-think-speak cycle.
    """

    client = None
    history: list[dict] | None = None

    def do_POST(self):
        if self.path != "/trigger":
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(202)
        self.end_headers()
        threading.Thread(target=self._run_turn, daemon=True).start()

    def _run_turn(self):
        try:
            run_voice_turn(self.client, self.history)
        except Exception as e:
            print(f"voice turn failed: {e}")

    def log_message(self, format, *args):
        pass  # keep stdout clean -- errors still print via _run_turn


def serve():
    """Run as a persistent background service: no CLI prompt, just waits
    for the Flutter app to POST /trigger (see app/lib/main.dart's tap
    handler) and runs a full voice turn each time.
    """
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    client = get_llm_client()
    history: list[dict] = []
    _TriggerHandler.client = client
    _TriggerHandler.history = history

    server = ThreadingHTTPServer(("127.0.0.1", TRIGGER_SERVER_PORT), _TriggerHandler)
    print(f"WALL-E trigger server listening on 127.0.0.1:{TRIGGER_SERVER_PORT} (POST /trigger)")
    server.serve_forever()


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    client = get_llm_client()
    history: list[dict] = []
    print("WALL-E is awake. Type a message (Ctrl+C to quit).")
    while True:
        try:
            user_message = input("> ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nbye")
            break
        if not user_message:
            continue
        reply = run_turn(client, history, user_message)
        print(reply)


if __name__ == "__main__":
    if "--serve" in sys.argv:
        serve()
    else:
        main()
