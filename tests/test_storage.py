from pathlib import Path

import pytest

from airbnb_books.config import ConfigError, resolve_backup_dir, resolve_db_path
from airbnb_books.storage.db import connect, migrate


def version(conn):
    return conn.execute("PRAGMA user_version").fetchone()[0]


def make_dir(tmp_path: Path, files: dict[str, str]) -> Path:
    d = tmp_path / "migrations"
    d.mkdir()
    for name, sql in files.items():
        (d / name).write_text(sql)
    return d


def test_new_db_gets_all_migrations_and_second_run_none(tmp_path):
    conn = connect(tmp_path / "a.db")
    assert migrate(conn) >= 1
    assert version(conn) >= 1
    assert conn.execute("PRAGMA foreign_keys").fetchone()[0] == 1
    assert migrate(conn) == 0


def test_failing_migration_rolls_back(tmp_path):
    d = make_dir(
        tmp_path,
        {
            "0001_a.sql": "CREATE TABLE a (x INTEGER) STRICT;",
            "0002_b.sql": "CREATE TABLE b (x INTEGER) STRICT; INSERT INTO nope VALUES (1);",
        },
    )
    conn = connect(tmp_path / "a.db")
    with pytest.raises(Exception, match="nope"):
        migrate(conn, migrations_dir=d)
    assert version(conn) == 1
    tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    assert tables == {"a"}


def test_hook_only_for_existing_db_with_pending(tmp_path):
    d = make_dir(tmp_path, {"0001_a.sql": "CREATE TABLE a (x INTEGER) STRICT;"})
    calls = []
    path = tmp_path / "a.db"
    conn = connect(path)
    migrate(conn, calls.append, d)
    assert calls == []  # new database
    migrate(conn, calls.append, d)
    assert calls == []  # nothing pending
    (d / "0002_b.sql").write_text("CREATE TABLE b (x INTEGER) STRICT;")
    migrate(conn, calls.append, d)
    assert calls == [str(path)]


def test_db_path_resolution_order(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.delenv("AIRBNB_BOOKS_DB", raising=False)
    monkeypatch.delenv("XDG_DATA_HOME", raising=False)
    assert resolve_db_path() == tmp_path / "home/.local/share/airbnb-books/books.db"
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "xdg"))
    assert resolve_db_path() == tmp_path / "xdg/airbnb-books/books.db"
    monkeypatch.setenv("AIRBNB_BOOKS_DB", str(tmp_path / "env/b.db"))
    assert resolve_db_path() == tmp_path / "env/b.db"
    assert resolve_db_path(tmp_path / "flag/c.db") == tmp_path / "flag/c.db"
    assert (tmp_path / "flag").is_dir()


def test_dropbox_refused(tmp_path):
    with pytest.raises(ConfigError, match="Dropbox"):
        resolve_db_path(tmp_path / "Dropbox" / "sub" / "x.db")
    assert not (tmp_path / "Dropbox").exists()


def test_backup_dir_resolution(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("AIRBNB_BOOKS_BACKUP_DIR", raising=False)
    assert resolve_backup_dir() == tmp_path / "Dropbox/airbnb-books"
    monkeypatch.setenv("AIRBNB_BOOKS_BACKUP_DIR", str(tmp_path / "env"))
    assert resolve_backup_dir() == tmp_path / "env"
    assert resolve_backup_dir(tmp_path / "flag") == tmp_path / "flag"
