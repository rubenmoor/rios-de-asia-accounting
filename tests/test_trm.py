from datetime import date
from pathlib import Path

import pytest

from airbnb_books.cli import main
from airbnb_books.importer.airbnb_csv import FileError, apply_import, parse, plan_import
from airbnb_books.importer.trm_csv import apply_rates
from airbnb_books.importer.trm_csv import parse as parse_rates
from airbnb_books.money import to_cop
from airbnb_books.storage import repo
from airbnb_books.storage.db import connect, migrate

HERE = Path(__file__).parent / "fixtures"
TRM = HERE / "trm_sample.csv"
AIRBNB = HERE / "airbnb_sample.csv"


@pytest.fixture
def conn(tmp_path):
    c = connect(tmp_path / "t.db")
    migrate(c)
    yield c
    c.close()


def usd_line_cop(conn):
    b = repo.find_booking_by_code(conn, "HMECDBYSMK")
    line = next(x for x in repo.list_lines(conn, b.id) if x.type == "Reservation")
    return line, line.amount_cop


def test_parse():
    p = parse_rates(TRM)
    assert not p.problems and len(p.rates) == 25
    assert (date(2026, 10, 3), 327_349) in p.rates  # weekend span stored at its first day


def test_reimport_changes_nothing_and_fills_booking(conn):
    apply_import(conn, plan_import(conn, parse(AIRBNB), list(parse(AIRBNB).listings)))
    first = apply_rates(conn, parse_rates(TRM))
    assert first.added == 25 and first.lines_recomputed > 0
    line, cop = usd_line_cop(conn)
    assert (line.date, line.rate) == (date(2026, 10, 8), 320_978)
    assert cop == to_cop(line.amount_minor, 320_978)
    again = apply_rates(conn, parse_rates(TRM))
    assert (again.added, again.changed, again.lines_recomputed) == (0, 0, 0)


def test_changed_rate_recomputes_cop(conn, tmp_path):
    apply_import(conn, plan_import(conn, parse(AIRBNB), list(parse(AIRBNB).listings)))
    apply_rates(conn, parse_rates(TRM))
    edited = tmp_path / "edited.csv"
    edited.write_text(TRM.read_text().replace("3209.78", "3300.00"))
    s = apply_rates(conn, parse_rates(edited))
    assert (s.added, s.changed) == (0, 1) and s.lines_recomputed > 0
    line, cop = usd_line_cop(conn)
    assert cop == to_cop(line.amount_minor, 330_000)


def test_bad_rows_are_problems_with_line_numbers(tmp_path):
    f = tmp_path / "bad.csv"
    f.write_text(
        "VALOR,UNIDAD,VIGENCIADESDE,VIGENCIAHASTA\n"
        "3209.78,COP,06/10/2026,06/10/2026\n"
        "abc,COP,05/10/2026,05/10/2026\n"
        "3200.00,COP,31/31/2026,31/31/2026\n"
    )
    p = parse_rates(f)
    assert len(p.rates) == 1
    assert [x.line for x in p.problems] == [3, 4]


def test_missing_column(tmp_path):
    f = tmp_path / "x.csv"
    f.write_text("A,B\n1,2\n")
    with pytest.raises(FileError):
        parse_rates(f)


def test_cli(tmp_path, capsys):
    db = str(tmp_path / "t.db")
    main(["--db", db, "import-rates", str(TRM)])
    assert "25 added" in capsys.readouterr().out
