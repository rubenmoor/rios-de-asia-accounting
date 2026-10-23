from datetime import date

import pytest

from airbnb_books.backup import BackupError, backup, before_migrate_hook, resolve_keep
from airbnb_books.cli import main
from airbnb_books.model import Settings
from airbnb_books.storage import repo
from airbnb_books.storage.db import connect, migrate


@pytest.fixture
def db(tmp_path):
    path = tmp_path / "live" / "books.db"
    path.parent.mkdir()
    conn = connect(path)
    migrate(conn)
    conn.execute("INSERT INTO settings (key, value) VALUES ('currency', 'COP')")
    conn.close()
    return path


def pending_dir(tmp_path):
    d = tmp_path / "migrations"
    d.mkdir(exist_ok=True)
    (d / "0002_more.sql").write_text("CREATE TABLE u (b);")
    return d


def names(d):
    return sorted(p.name for p in d.iterdir())


def test_backup_is_readable_copy_and_overwrites_same_day(db, tmp_path):
    out = tmp_path / "bk" / "nested"
    target = backup(db, out, 5, date(2026, 1, 2))
    assert target.name == "books-2026-01-02.db"
    conn = connect(db)
    conn.execute("INSERT INTO settings (key, value) VALUES ('x', '1')")
    conn.close()
    backup(db, out, 5, date(2026, 1, 2))
    copy = connect(target)
    rows = {r["key"] for r in copy.execute("SELECT key FROM settings")}
    copy.close()
    assert rows == {"currency", "x"}
    assert names(out) == ["books-2026-01-02.db"]


def test_prune_keeps_newest_and_leaves_foreign_files(db, tmp_path):
    out = tmp_path / "bk"
    out.mkdir()
    (out / "notes.txt").write_text("mine")
    (out / "books-2026-01-01.db.bak").write_text("mine")
    for day in (1, 2, 3, 4):
        backup(db, out, 2, date(2026, 1, day))
    assert names(out) == [
        "books-2026-01-01.db.bak",
        "books-2026-01-03.db",
        "books-2026-01-04.db",
        "notes.txt",
    ]


def test_failed_backup_deletes_nothing(db, tmp_path):
    out = tmp_path / "bk"
    backup(db, out, 5, date(2026, 1, 1))
    with pytest.raises(BackupError):
        backup(tmp_path / "missing.db", out, 1, date(2026, 1, 2))
    assert names(out) == ["books-2026-01-01.db"]


def test_keep_precedence(db):
    assert resolve_keep(db, None) == 30
    conn = connect(db)
    repo.save_settings(conn, Settings(backup_keep=7))
    conn.close()
    assert resolve_keep(db, None) == 7
    assert resolve_keep(db, 3) == 3


def test_migration_hook_only_for_existing_db(tmp_path):
    calls = []
    new = connect(tmp_path / "new.db")
    migrate(new, before_migrate=calls.append)
    assert calls == []
    new.close()


def test_migration_hook_called_for_existing_db(tmp_path, monkeypatch):
    calls = []
    conn = connect(tmp_path / "old.db")
    conn.execute("CREATE TABLE t (a)")
    conn.execute("PRAGMA user_version = 1")
    migrate(conn, before_migrate=calls.append, migrations_dir=pending_dir(tmp_path))
    assert len(calls) == 1 and calls[0].endswith("old.db")
    conn.close()


def test_hook_failure_aborts_migration(tmp_path):
    conn = connect(tmp_path / "old.db")
    conn.execute("CREATE TABLE t (a)")
    conn.execute("PRAGMA user_version = 1")
    bad = before_migrate_hook(tmp_path / "file")
    (tmp_path / "file").write_text("not a dir")
    with pytest.raises(BackupError):
        migrate(conn, before_migrate=bad, migrations_dir=pending_dir(tmp_path))
    assert conn.execute("PRAGMA user_version").fetchone()[0] == 1
    conn.close()


def test_cli_backup(db, tmp_path, capsys):
    out = tmp_path / "bk"
    main(["--db", str(db), "backup", "--backup-dir", str(out), "--keep", "2"])
    assert len(names(out)) == 1
    blocker = tmp_path / "file"
    blocker.write_text("x")
    with pytest.raises(SystemExit) as e:
        main(["--db", str(db), "backup", "--backup-dir", str(blocker)])
    assert e.value.code != 0
    assert "backup" in capsys.readouterr().err
