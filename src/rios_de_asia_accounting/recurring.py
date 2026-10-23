"""Monthly expenses generated from recurring templates, and the one call that builds the days."""

import sqlite3
from datetime import date

from rios_de_asia_accounting.allocation import allocate
from rios_de_asia_accounting.model import Day, Expense, RecurringExpense
from rios_de_asia_accounting.storage import repo


def _month_index(month: str) -> int:
    return int(month[:4]) * 12 + int(month[5:7]) - 1


def due_expenses(templates: list[RecurringExpense], today: date) -> list[Expense]:
    """One expense per template and month, start_month to min(end_month, today's month)."""
    last = today.year * 12 + today.month - 1
    out = []
    for t in templates:
        end = last if t.end_month is None else min(last, _month_index(t.end_month))
        for m in range(_month_index(t.start_month), end + 1):
            out.append(
                Expense(
                    date(m // 12, m % 12 + 1, 1),
                    t.amount,
                    t.category,
                    description=t.description,
                    recurring_expense_id=t.id,
                )
            )
    return out


def generate_recurring(conn: sqlite3.Connection, today: date) -> int:
    """Create the missing generated expenses; returns how many rows were created."""
    due = due_expenses(repo.list_recurring_expenses(conn), today)
    return sum(repo.insert_generated_expense(conn, e) for e in due)


def load_days(conn: sqlite3.Connection, today: date, start: date | None = None) -> list[Day]:
    generate_recurring(conn, today)
    return allocate(repo.load_inputs(conn), today, start)
