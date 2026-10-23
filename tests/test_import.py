import csv
import io
from datetime import date
from pathlib import Path

import pytest

from airbnb_books.importer.airbnb_csv import REQUIRED_COLUMNS, FileError, parse
from airbnb_books.money import parse_minor

FIXTURE = Path(__file__).parent / "fixtures" / "airbnb_sample.csv"
HEADER = (
    "Date,Arriving by date,Type,Confirmation code,Booking date,Start date,End date,Nights,"
    "Guest,Listing,Details,Reference code,Currency,Amount,Paid out,Service fee,Fast pay fee,"
    "Cleaning fee,Gross earnings,Airbnb remitted tax,Earnings year\n"
)


def one(**kw):
    rec = {
        "Date": "01/10/2025",
        "Type": "Reservation",
        "Code": "HMX",
        "Start": "01/01/2025",
        "End": "01/04/2025",
        "Nights": "3",
        "Amount": "100.00",
        "Service": "3.00",
        "Cleaning": "10.00",
        "Gross": "113.00",
    }
    rec.update(kw)
    cols = [rec["Date"], "", rec["Type"], rec["Code"], "", rec["Start"], rec["End"], rec["Nights"]]
    cols += ["G", "Flat A", "", "", "USD", rec["Amount"], "", rec["Service"], "", rec["Cleaning"]]
    cols += [rec["Gross"], "", ""]
    out = io.StringIO()
    csv.writer(out, lineterminator="\n").writerow(cols)
    return out.getvalue()


def parse_text(text):
    return parse(io.StringIO(text))


def test_fixture_counts():
    p = parse(FIXTURE)
    assert p.problems == []
    assert p.payouts == 3
    assert len(p.rows) == 28
    types = {t: sum(r.type == t for r in p.rows) for t in {r.type for r in p.rows}}
    assert types == {
        "Reservation": 22,
        "Adjustment": 2,
        "Resolution Adjustment": 1,
        "Resolution Payout": 2,
        "Co-Host payout": 1,
    }
    assert sum(p.listings.values()) == 28
    assert len(p.listings) == 5


def test_fixture_has_bom_and_is_read_by_path():
    assert FIXTURE.read_bytes().startswith(b"\xef\xbb\xbf")
    assert parse(str(FIXTURE)).rows[0].date.year >= 2021


def test_fixture_values():
    p = parse(FIXTURE)
    adj = [r for r in p.rows if r.type == "Adjustment" and r.amount == -1]
    assert len(adj) == 1 and adj[0].service_fee == 0 and adj[0].gross is None
    cop = next(r for r in p.rows if r.code == "HMBYBENB5A")
    assert cop.service_fee == 178500 and cop.currency == "COP"
    long_stay = [r for r in p.rows if r.code == "HM9DCZPD4E"]
    assert len(long_stay) == 7
    assert {(r.start, r.end, r.nights) for r in long_stay} == {
        (date(2024, 9, 9), date(2025, 3, 16), 188)
    }


def test_bom_in_stream_and_path(tmp_path):
    f = tmp_path / "a.csv"
    f.write_bytes(b"\xef\xbb\xbf" + (HEADER + one()).encode())
    assert len(parse(f).rows) == 1


def test_comma_amounts():
    p = parse_text(HEADER + one(Amount="1,234.50", Service="1,000.05"))
    assert p.rows[0].amount == 123450
    assert p.rows[0].service_fee == 100005


def test_negative_and_empty_fields():
    p = parse_text(HEADER + one(Amount="-0.01", Service="", Cleaning="", Gross=""))
    r = p.rows[0]
    assert (r.amount, r.service_fee, r.cleaning_fee, r.gross) == (-1, 0, 0, None)
    p = parse_text(HEADER + one(Service="-0.00", Gross="-5.50"))
    assert p.rows[0].service_fee == 0 and p.rows[0].gross == -550


def test_dates_and_nights():
    r = parse_text(HEADER + one()).rows[0]
    assert (r.date, r.start, r.end, r.nights) == (
        date(2025, 1, 10),
        date(2025, 1, 1),
        date(2025, 1, 4),
        3,
    )


def test_missing_column():
    text = HEADER.replace("Cleaning fee,", "") + "\n"
    with pytest.raises(FileError, match="Cleaning fee"):
        parse_text(text)
    assert "Cleaning fee" in REQUIRED_COLUMNS


def test_unknown_type_and_payout():
    p = parse_text(HEADER + one(Type="Mystery") + one(Type="Payout") + one())
    assert [x.line for x in p.problems] == [2]
    assert "Mystery" in p.problems[0].message
    assert p.payouts == 1 and len(p.rows) == 1


@pytest.mark.parametrize(
    "kw, word",
    [
        ({"Start": "2025-01-01"}, "Start date"),
        ({"End": "13/01/2025"}, "End date"),
        ({"Date": ""}, "Date"),
        ({"Amount": "abc"}, "Amount"),
        ({"Amount": "1.234"}, "Amount"),
        ({"Service": "x"}, "Service fee"),
        ({"Nights": "4"}, "Nights"),
        ({"Nights": "n"}, "Nights"),
        ({"Code": ""}, "confirmation code"),
    ],
)
def test_problem_rows(kw, word):
    p = parse_text(HEADER + one() + one(**kw))
    assert len(p.rows) == 1
    assert [x.line for x in p.problems] == [3]
    assert word in p.problems[0].message


@pytest.mark.parametrize(
    "text, minor",
    [
        ("0", 0),
        ("12", 1200),
        ("12.5", 1250),
        ("1,234.50", 123450),
        ("-0.01", -1),
        ("-0.00", 0),
        ("1476880.34", 147688034),
        (" 7.10 ", 710),
        ("5.000", 500),
    ],
)
def test_parse_minor(text, minor):
    assert parse_minor(text) == minor


@pytest.mark.parametrize("text", ["", "abc", "1.234", "NaN", "Infinity", "1.2.3"])
def test_parse_minor_rejects(text):
    with pytest.raises(ValueError):
        parse_minor(text)
