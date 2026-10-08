"""Skills: the plugin/extension system, modeled on OpenClaw's pattern.

A skill is just a folder under skills/ containing a SKILL.md file with YAML
frontmatter (name, description) followed by markdown instructions. This is
deliberately NOT Python code -- a skill can't do anything a tool doesn't
already expose, it just teaches the model *when and how* to combine existing
tools for a specific task. That keeps the "plugin" surface low-risk: adding a
skill can't add new capabilities, only new judgment about using old ones.

Only name + description are loaded into every system prompt (cheap, scales
to many skills). The full body is fetched on demand via the `read_skill`
tool when the model decides a particular skill is relevant -- same idea as
OpenClaw injecting full skill content only when a request matches it.
"""

from pathlib import Path

SKILLS_DIR = Path(__file__).parent / "skills"


def _parse_frontmatter(text: str) -> tuple[dict, str]:
    """Split '---\\nkey: value\\n---\\nbody' into (frontmatter dict, body)."""
    if not text.startswith("---"):
        return {}, text
    parts = text.split("---", 2)
    if len(parts) < 3:
        return {}, text
    meta = {}
    for line in parts[1].strip().splitlines():
        if ":" in line:
            key, _, value = line.partition(":")
            meta[key.strip()] = value.strip()
    return meta, parts[2].strip()


def list_skills() -> list[dict]:
    """Return [{name, description}, ...] for every installed skill."""
    if not SKILLS_DIR.exists():
        return []
    skills = []
    for skill_dir in sorted(SKILLS_DIR.iterdir()):
        skill_file = skill_dir / "SKILL.md"
        if not skill_file.exists():
            continue
        meta, _ = _parse_frontmatter(skill_file.read_text(encoding="utf-8"))
        skills.append(
            {
                "name": meta.get("name", skill_dir.name),
                "description": meta.get("description", "(no description)"),
            }
        )
    return skills


def read_skill(name: str) -> str:
    """Fetch the full instructions body for one skill, by name."""
    skill_file = SKILLS_DIR / name / "SKILL.md"
    if not skill_file.exists():
        return f"No skill named '{name}' found."
    _, body = _parse_frontmatter(skill_file.read_text(encoding="utf-8"))
    return body


def save_skill(name: str, description: str, content: str) -> str:
    """Author a brand-new skill. This is the self-learning hook: when the
    agent notices a repeated multi-step task, it can turn it into a skill
    so future turns jump straight to it instead of re-deriving the steps.
    """
    safe_name = "".join(c for c in name if c.isalnum() or c in "-_").lower()
    if not safe_name:
        return "Error: skill name must contain at least one letter/number."
    skill_dir = SKILLS_DIR / safe_name
    skill_dir.mkdir(parents=True, exist_ok=True)
    (skill_dir / "SKILL.md").write_text(
        f"---\nname: {name}\ndescription: {description}\n---\n\n{content}\n",
        encoding="utf-8",
    )
    return f"Saved new skill '{name}'."
