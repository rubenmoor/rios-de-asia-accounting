from pathlib import Path

import pytest

from airbnb_books.cli import main
from airbnb_books.importer.airbnb_csv import parse
from airbnb_books.storage import repo
from airbnb_books.storage.db import connect

FIXTURE = Path(__file__).parent / "fixtures" / "airbnb_sample.csv"
REAL = Path(__file__).parent.parent / "airbnb_.csv"


def listing_args(path):
    args = []
    for name in parse(path).listings:
        args += ["--listing", name]
    return args


def booking_count(db):
    conn = connect(db)
    try:
        return len(repo.list_bookings(conn))
    finally:
        conn.close()


def test_exit_2_without_listings(tmp_path, capsys):
    db = str(tmp_path / "t.db")
    with pytest.raises(SystemExit) as e:
        main(["--db", db, "import", str(FIXTURE)])
    assert e.value.code == 2
    assert "--listing" in capsys.readouterr().out
    assert booking_count(db) == 0


def test_dry_run_then_real_run(tmp_path, capsys):
    db = str(tmp_path / "t.db")
    args = ["--db", db, "import", str(FIXTURE), *listing_args(FIXTURE)]
    main([*args, "--dry-run"])
    assert booking_count(db) == 0
    assert "nothing changed" in capsys.readouterr().out
    main(args)
    assert booking_count(db) > 0
    assert "imported:" in capsys.readouterr().out


@pytest.mark.skipif(not REAL.exists(), reason="airbnb_.csv not present")
def test_real_file_has_no_problems(tmp_path, capsys):
    db = str(tmp_path / "t.db")
    main(["--db", db, "import", str(REAL), *listing_args(REAL)])
    assert "0 problem(s)" in capsys.readouterr().out
