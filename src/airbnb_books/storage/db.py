import re
import sqlite3
from collections.abc import Callable
from importlib import resources
from pathlib import Path

_MIGRATION_NAME = re.compile(r"^(\d{4})_.*\.sql$")


def connect(path: str | Path) -> sqlite3.Connection:
    # isolation_level=None: no implicit transactions; migrate() manages its own.
    conn = sqlite3.connect(path, isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def _migration_files(directory=None) -> list[tuple[int, str]]:
    directory = directory or resources.files("airbnb_books.storage") / "migrations"
    found = []
    for entry in directory.iterdir():
        m = _MIGRATION_NAME.match(entry.name)
        if m:
            found.append((int(m.group(1)), entry.read_text(encoding="utf-8")))
    return sorted(found)


def _db_path(conn: sqlite3.Connection) -> str:
    return conn.execute("PRAGMA database_list").fetchone()["file"]


def migrate(
    conn: sqlite3.Connection,
    before_migrate: Callable[[str], None] | None = None,
    migrations_dir=None,
) -> int:
    """Apply pending migrations, each in one transaction. Returns how many were applied."""
    current = conn.execute("PRAGMA user_version").fetchone()[0]
    pending = [(n, sql) for n, sql in _migration_files(migrations_dir) if n > current]
    if not pending:
        return 0
    if current > 0 and before_migrate is not None:
        before_migrate(_db_path(conn))
    for number, sql in pending:
        try:
            conn.executescript(f"BEGIN;\n{sql}\nPRAGMA user_version = {number};\nCOMMIT;")
        except Exception:
            if conn.in_transaction:
                conn.execute("ROLLBACK")
            raise
    return len(pending)
