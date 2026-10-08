# Contributing

Two independent pieces, two different languages -- see each folder's own
README for setup:

- `app/` -- Flutter/Dart. Run `flutter build web` and serve `build/web` for
  fast iteration on the eyes/animations without needing a device.
- `brain/` -- Python. Runs fine on a regular machine for development; only
  the Termux-specific tools (`bash` on-device semantics, `mic_listen`,
  `speak`, alarms, the camera/location bridge) need an actual phone.

## Adding a new tool

Tools live in `brain/tools.py`: add a plain Python function, register it in
`REGISTRY`, and add one line to `TOOL_DESCRIPTIONS` so the model knows it
exists. Keep tools narrow and single-purpose -- compose behavior via skills
(see `brain/skills/`), not by making one tool do many things.

## Adding a skill (no code required)

Skills are just a folder under `brain/skills/<name>/SKILL.md` with a YAML
frontmatter (`name`, `description`) and a markdown body of instructions. No
Python needed -- see `brain/skills/example_greeting/` for the shape.

## Pull requests

Keep PRs scoped to one change. If you're touching `brain/`, include what you
tested it against (even just "ran locally, not on-device" is useful context).
