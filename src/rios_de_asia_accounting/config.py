import os
from pathlib import Path

DB_ENV = "RIOS_DE_ASIA_ACCOUNTING_DB"
BACKUP_DIR_ENV = "RIOS_DE_ASIA_ACCOUNTING_BACKUP_DIR"


class ConfigError(Exception):
    pass


def _expand(path: str | Path) -> Path:
    return Path(path).expanduser().absolute()


def resolve_db_path(flag: str | Path | None = None) -> Path:
    """Database path: flag, else env, else XDG data dir. Creates the parent directory."""
    if flag:
        path = _expand(flag)
    elif os.environ.get(DB_ENV):
        path = _expand(os.environ[DB_ENV])
    else:
        data_home = os.environ.get("XDG_DATA_HOME")
        base = _expand(data_home) if data_home else Path.home() / ".local" / "share"
        path = base / "rios-de-asia-accounting" / "books.db"
    if "Dropbox" in path.resolve().parts:
        raise ConfigError(
            f"refusing database path {path}: the live database must not be inside a "
            "Dropbox folder (only backups go there)"
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def resolve_backup_dir(flag: str | Path | None = None) -> Path:
    """Backup directory: flag, else env, else ~/Dropbox/rios-de-asia-accounting (not created)."""
    if flag:
        return _expand(flag)
    if os.environ.get(BACKUP_DIR_ENV):
        return _expand(os.environ[BACKUP_DIR_ENV])
    return Path.home() / "Dropbox" / "rios-de-asia-accounting"
