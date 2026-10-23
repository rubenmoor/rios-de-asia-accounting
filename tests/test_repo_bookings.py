from datetime import date

import pytest

from airbnb_books.model import Booking, BookingLine, ExchangeRate
from airbnb_books.money import to_cop
from airbnb_books.storage import repo
from airbnb_books.storage.db import connect, migrate


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
        (10_000, 412345, 412_345),
        (1, 5000, 1),  # 0.5 -> 1
        (-1, 5000, -1),  # -0.5 -> -1
        (1, 4999, 0),
        (-1, 4999, 0),
        (3, 5000, 2),  # 1.5 -> 2
        (-3, 5000, -2),
        (2, 5000, 1),  # exact
        (0, 412345, 0),
        (-10_000, 412345, -412_345),
    ],
)
def test_to_cop(minor, rate, expected):
    assert to_cop(minor, rate) == expected


def test_manual_booking_round_trip(conn):
    b = stay(listing="L", guest_name="Ana", guests=2, notes="hi")
    bid = repo.create_booking(conn, b, manual_amount_cop=300_000)
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
        net_payout=300_000,
    )
    lines = repo.list_lines(conn, bid)
    assert [(ln.type, ln.currency, ln.rate, ln.amount_cop) for ln in lines] == [
        ("Manual", "COP", 100, 300_000)
    ]

    got.guest_name = "Bea"
    repo.update_booking(conn, got, manual_amount_cop=350_000)
    again = repo.get_booking(conn, bid)
    assert again.guest_name == "Bea"
    assert again.net_payout == 350_000
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
        bid, "Reservation", d("2026-01-04"), "COP", 50_000_000, gross_minor=60_000_000
    )
    assert repo.add_line(conn, line) is True
    assert line.id is not None and line.amount_cop == 500_000
    dup = BookingLine(bid, "Reservation", d("2026-01-04"), "COP", 50_000_000)
    assert repo.add_line(conn, dup) is False
    cohost = BookingLine(bid, "Co-Host payout", d("2026-01-04"), "COP", -5_000_000)
    assert repo.add_line(conn, cohost) is True
    got = repo.get_booking(conn, bid)
    assert (got.net_payout, got.cohost_cost, got.gross) == (500_000, 50_000, 600_000)
    assert got.needs_rate is False


def test_rate_for_on_or_before(conn):
    repo.set_exchange_rate(conn, ExchangeRate(d("2026-01-10"), "USD", 400_000))
    repo.set_exchange_rate(conn, ExchangeRate(d("2026-01-20"), "USD", 410_000))
    assert repo.rate_for(conn, "USD", d("2026-01-09")) is None
    assert repo.rate_for(conn, "USD", d("2026-01-10")) == 400_000
    assert repo.rate_for(conn, "USD", d("2026-01-19")) == 400_000
    assert repo.rate_for(conn, "USD", d("2026-01-20")) == 410_000
    assert repo.rate_for(conn, "COP", d("2020-01-01")) == 100
    assert [r.date for r in repo.list_exchange_rates(conn, "USD")] == [
        d("2026-01-20"),
        d("2026-01-10"),
    ]


def test_recompute_after_adding_changing_and_deleting_rates(conn):
    bid = repo.create_booking(conn, stay("A"))
    usd = BookingLine(bid, "Reservation", d("2026-01-15"), "USD", 10_000)
    assert repo.add_line(conn, usd)
    assert usd.amount_cop is None
    assert repo.get_booking(conn, bid).needs_rate is True

    repo.set_exchange_rate(conn, ExchangeRate(d("2026-01-10"), "USD", 400_000))
    (line,) = repo.list_lines(conn, bid)
    assert (line.rate, line.amount_cop) == (400_000, 400_000)
    got = repo.get_booking(conn, bid)
    assert (got.net_payout, got.needs_rate) == (400_000, False)

    repo.set_exchange_rate(conn, ExchangeRate(d("2026-01-10"), "USD", 420_000))
    assert repo.get_booking(conn, bid).net_payout == 420_000

    repo.set_exchange_rate(conn, ExchangeRate(d("2026-01-14"), "USD", 430_000))
    assert repo.get_booking(conn, bid).net_payout == 430_000

    repo.delete_exchange_rate(conn, d("2026-01-14"), "USD")
    assert repo.get_booking(conn, bid).net_payout == 420_000
    repo.delete_exchange_rate(conn, d("2026-01-10"), "USD")
    got = repo.get_booking(conn, bid)
    assert (got.net_payout, got.needs_rate) == (0, True)


def test_add_line_uses_existing_rate(conn):
    repo.set_exchange_rate(conn, ExchangeRate(d("2026-01-01"), "USD", 412_345))
    bid = repo.create_booking(conn, stay("A"))
    line = BookingLine(bid, "Reservation", d("2026-01-04"), "USD", 10_000)
    repo.add_line(conn, line)
    assert (line.rate, line.amount_cop) == (412_345, 412_345)
