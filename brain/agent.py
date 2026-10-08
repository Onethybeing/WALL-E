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

import memory
import skills
import tools
from llm import get_llm_client

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

    for _ in range(MAX_TOOL_HOPS):
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
    main()
