"""Long-term memory: a flat table of facts the agent has chosen to remember.

This is deliberately simple (sqlite + substring search, no embeddings) so it
runs cheaply on a phone. Good enough to let the pet recall preferences and
facts across sessions; can be swapped for real vector search later without
changing the tool interface the agent sees.
"""

import sqlite3
import time
from pathlib import Path

DB_PATH = Path(__file__).parent / "memory.db"


def _connect():
    conn = sqlite3.connect(DB_PATH)
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS memories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            created_at REAL NOT NULL
        )
        """
    )
    return conn


def remember(key: str, value: str) -> str:
    conn = _connect()
    with conn:
        conn.execute(
            "INSERT INTO memories (key, value, created_at) VALUES (?, ?, ?)",
            (key, value, time.time()),
        )
    conn.close()
    return f"Remembered: {key} = {value}"


def recall(query: str, limit: int = 5) -> str:
    conn = _connect()
    rows = conn.execute(
        "SELECT key, value FROM memories WHERE key LIKE ? OR value LIKE ? "
        "ORDER BY created_at DESC LIMIT ?",
        (f"%{query}%", f"%{query}%", limit),
    ).fetchall()
    conn.close()
    if not rows:
        return "No matching memories found."
    return "\n".join(f"- {k}: {v}" for k, v in rows)


def recent(limit: int = 10) -> list[tuple[str, str]]:
    """Used to seed the system prompt with a bit of standing context."""
    conn = _connect()
    rows = conn.execute(
        "SELECT key, value FROM memories ORDER BY created_at DESC LIMIT ?",
        (limit,),
    ).fetchall()
    conn.close()
    return rows
