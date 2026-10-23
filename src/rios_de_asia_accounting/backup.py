import os
import re
import sqlite3
import tempfile
from datetime import date
from pathlib import Path

from rios_de_asia_accounting.config import resolve_backup_dir

DEFAULT_KEEP = 30
_BACKUP_NAME = re.compile(r"^books-\d{4}-\d{2}-\d{2}\.db$")


class BackupError(Exception):
    pass


def stored_keep(db_path: str | Path) -> int | None:
    """The `backup_keep` setting of a database, or None when it is not set or unreadable."""
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        try:
            row = conn.execute("SELECT value FROM settings WHERE key = 'backup_keep'").fetchone()
        finally:
            conn.close()
        return int(row[0]) if row else None
    except (sqlite3.Error, ValueError):
        return None


def resolve_keep(db_path: str | Path, flag: int | None = None) -> int:
    """Number of backups to keep: flag, else the setting, else 30."""
    keep = flag if flag is not None else stored_keep(db_path)
    return keep if keep is not None else DEFAULT_KEEP


def backup(db_path: str | Path, backup_dir: str | Path, keep: int, today: date) -> Path:
    """Copy the live database to backup_dir/books-YYYY-MM-DD.db, then prune old copies."""
    if keep < 1:
        raise BackupError("the number of backups to keep must be at least 1")
    db_path, backup_dir = Path(db_path), Path(backup_dir)
    if not db_path.is_file():
        raise BackupError(f"database {db_path} does not exist")
    try:
        backup_dir.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(prefix=".books-", suffix=".tmp", dir=backup_dir)
        os.close(fd)
        tmp = Path(tmp_name)
        try:
            src = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
            try:
                dst = sqlite3.connect(tmp)
                try:
                    src.backup(dst)
                finally:
                    dst.close()
            finally:
                src.close()
            target = backup_dir / f"books-{today.isoformat()}.db"
            os.replace(tmp, target)
        except BaseException:
            tmp.unlink(missing_ok=True)
            raise
        _prune(backup_dir, keep)
    except (OSError, sqlite3.Error) as e:
        raise BackupError(f"backup of {db_path} to {backup_dir} failed: {e}") from e
    return target


def _prune(backup_dir: Path, keep: int) -> None:
    files = sorted(
        (p for p in backup_dir.iterdir() if _BACKUP_NAME.match(p.name) and p.is_file()),
        key=lambda p: p.name,
    )
    for old in files[:-keep]:
        old.unlink()


def before_migrate_hook(backup_dir_flag: str | Path | None = None, keep_flag: int | None = None):
    """A `before_migrate` callback for storage.db.migrate: a failure aborts the migration."""

    def hook(db_path: str) -> None:
        target = backup(
            db_path,
            resolve_backup_dir(backup_dir_flag),
            resolve_keep(db_path, keep_flag),
            date.today(),
        )
        print(f"backup before migration: {target}", flush=True)

    return hook
