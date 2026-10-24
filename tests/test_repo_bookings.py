from datetime import date

import pytest

from rios_de_asia_accounting import conversion
from rios_de_asia_accounting.model import Booking, BookingLine
from rios_de_asia_accounting.money import to_usd
from rios_de_asia_accounting.rates import RateUnavailable
from rios_de_asia_accounting.storage import repo
from rios_de_asia_accounting.storage.db import connect, migrate

TODAY = date(2026, 10, 23)
COP = 4_000_000_000  # the fixed test rate, see conftest


@pytest.fixture
def conn(tmp_path):
    c = connect(tmp_path / "t.db")
    migrate(c)
    return c


def d(s):
    return date.fromisoformat(s)


def stay(code=None, cin="2026-01-01", cout="2026-01-04", **kw):
    return Booking(check_in=d(cin), check_out=d(cout), airbnb_code=code, **kw)


@pytest.mark.parametrize(
    ("minor", "rate", "expected"),
    [
        (400_000, COP, 100),  # 4000 COP = 1.00 USD
        (200_000, COP, 50),
        (2, 4_000_000, 1),  # 0.5 -> 1
        (-2, 4_000_000, -1),  # -0.5 -> -1
        (1, 4_000_000, 0),
        (8_829, 882_920, 10_000),  # EUR 88.29 at 0.88292 per USD
        (10_000, 1_000_000, 10_000),  # USD
    ],
)
def test_to_usd(minor, rate, expected):
    assert to_usd(minor, rate) == expected


def test_manual_booking_round_trip(conn):
    b = stay(listing="L", guest_name="Ana", guests=2, notes="hi")
    bid = repo.create_booking(conn, b, manual_amount=(120_000_000, "COP"))
    assert repo.get_booking(conn, bid).waiting
    conversion.convert_waiting(conn, TODAY)
    got = repo.get_booking(conn, bid)
    assert got == Booking(
        id=bid,
        check_in=d("2026-01-01"),
        check_out=d("2026-01-04"),
        listing="L",
        guest_name="Ana",
        guests=2,
        notes="hi",
        nights=3,
        net_payout=30_000,
    )
    lines = repo.list_lines(conn, bid)
    assert [(ln.type, ln.currency, ln.rate, ln.rate_date, ln.amount_usd) for ln in lines] == [
        ("Manual", "COP", COP, d("2026-01-01"), 30_000)
    ]

    got.guest_name = "Bea"
    repo.update_booking(conn, got, manual_amount=(350_00, "USD"))
    conversion.convert_waiting(conn, TODAY)
    again = repo.get_booking(conn, bid)
    assert again.guest_name == "Bea"
    assert again.net_payout == 350_00
    assert len(repo.list_lines(conn, bid)) == 1

    repo.delete_booking(conn, bid)
    assert repo.get_booking(conn, bid) is None
    assert repo.list_lines(conn, bid) == []


def test_find_by_code_and_lists(conn):
    a = repo.create_booking(conn, stay("A", "2026-01-01", "2026-01-05", listing="L1"))
    b = repo.create_booking(conn, stay("B", "2026-01-10", "2026-01-12", listing="L2"))
    assert repo.find_booking_by_code(conn, "B").id == b
    assert repo.find_booking_by_code(conn, "Z") is None
    assert [x.id for x in repo.list_bookings(conn)] == [a, b]
    assert [x.id for x in repo.list_bookings(conn, listing="L2")] == [b]
    # overlap with [start, end), check-out exclusive
    assert [x.id for x in repo.list_bookings(conn, d("2026-01-05"), d("2026-01-10"))] == []
    assert [x.id for x in repo.list_bookings(conn, d("2026-01-04"), d("2026-01-11"))] == [a, b]
    assert [x.id for x in repo.list_bookings(conn, start=d("2026-01-06"))] == [b]
    assert [x.id for x in repo.list_bookings(conn, end=d("2026-01-02"))] == [a]


def test_add_line_dedup_and_totals(conn):
    bid = repo.create_booking(conn, stay("A"))
    line = BookingLine(
        bid, "Reservation", d("2026-01-04"), "COP", 200_000_000, gross_minor=240_000_000
    )
    assert repo.add_line(conn, line) is True
    dup = BookingLine(bid, "Reservation", d("2026-01-04"), "COP", 200_000_000)
    assert repo.add_line(conn, dup) is False
    cohost = BookingLine(bid, "Co-Host payout", d("2026-01-04"), "COP", -20_000_000)
    assert repo.add_line(conn, cohost) is True
    assert conversion.convert_waiting(conn, TODAY) == 0
    got = repo.get_booking(conn, bid)
    assert (got.net_payout, got.cohost_cost, got.gross) == (50_000, 5_000, 60_000)
    assert got.waiting is False


def _rates(conn, *rows):
    conn.executemany("INSERT INTO exchange_rates VALUES (?, 'COP', ?)", rows)
    conn.execute("INSERT INTO rate_coverage VALUES ('COP', '2026-01-20')")


def test_rate_on_or_before_from_the_cache(conn, monkeypatch):
    monkeypatch.setitem(conversion.FETCHERS, "COP", None)  # any fetch would fail
    _rates(conn, ("2026-01-10", 4_000_000_000), ("2026-01-17", 4_100_000_000))
    assert conversion.rate_on(conn, "COP", d("2026-01-12"), TODAY) == (
        4_000_000_000,
        d("2026-01-10"),
    )
    assert conversion.rate_on(conn, "COP", d("2026-01-20"), TODAY) == (
        4_100_000_000,
        d("2026-01-17"),
    )
    assert conversion.rate_on(conn, "USD", d("2020-01-01"), TODAY) == (1_000_000, d("2020-01-01"))


def test_waiting_then_converted_and_provisional(conn, monkeypatch, capsys):
    def offline(start, end):
        raise RateUnavailable("no connection")

    fetch = conversion.FETCHERS["COP"]
    monkeypatch.setitem(conversion.FETCHERS, "COP", offline)
    bid = repo.create_booking(conn, stay("A", "2026-12-20", "2026-12-23"))  # after today
    repo.add_line(conn, BookingLine(bid, "Reservation", d("2026-12-24"), "COP", 400_000))
    assert conversion.convert_waiting(conn, TODAY) == 1
    assert "no COP rates" in capsys.readouterr().err

    monkeypatch.setitem(conversion.FETCHERS, "COP", fetch)
    assert conversion.convert_waiting(conn, TODAY, force=True) == 0
    (line,) = repo.list_lines(conn, bid)
    assert (line.amount_usd, line.rate_date) == (100, TODAY)  # provisional: latest known

    # the check-in moves into the coverage: converted again at the new check-in
    booking = repo.get_booking(conn, bid)
    booking.check_in, booking.check_out = d("2026-10-01"), d("2026-10-03")
    repo.update_booking(conn, booking)
    assert repo.get_booking(conn, bid).waiting
    conversion.convert_waiting(conn, TODAY)
    (line,) = repo.list_lines(conn, bid)
    assert line.rate_date == d("2026-10-01")
