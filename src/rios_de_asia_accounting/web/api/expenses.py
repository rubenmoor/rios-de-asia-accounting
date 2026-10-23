from datetime import date, timedelta

from flask import request

from rios_de_asia_accounting.model import Expense, RecurringExpense
from rios_de_asia_accounting.recurring import generate_recurring
from rios_de_asia_accounting.storage import repo
from rios_de_asia_accounting.web.api.common import bp, info, invalid, ok, read_form
from rios_de_asia_accounting.web.app_db import get_db
from rios_de_asia_accounting.web.expenses import (
    EXPENSE_CATEGORIES,
    RECURRING_CATEGORIES,
    RECURRING_DELETED,
    _fill_expense,
    _fill_recurring,
    _read_expense,
    _read_recurring,
    _recurring_saved,
)
from rios_de_asia_accounting.web.forms import Form, booking_options


def _expense(e: Expense) -> dict:
    return {
        "id": e.id,
        "date": e.date.isoformat(),
        "amount": e.amount,
        "category": e.category,
        "booking_id": e.booking_id,
        "useful_life_days": e.useful_life_days,
        "description": e.description,
        "recurring_expense_id": e.recurring_expense_id,
    }


def _recurring(r: RecurringExpense) -> dict:
    return {
        "id": r.id,
        "description": r.description,
        "amount": r.amount,
        "category": r.category,
        "start_month": r.start_month,
        "end_month": r.end_month,
    }


def _recurring_detail(conn, r: RecurringExpense) -> dict:
    generated = repo.list_expenses_of_recurring(conn, r.id)
    generated.sort(key=lambda e: e.date, reverse=True)
    return {**_recurring(r), "generated": [_expense(e) for e in generated]}


def _not_found(what: str):
    return {"error": f"{what} not found"}, 404


@bp.get("/expenses")
def list_expenses():
    form = Form(request.args)
    first = form.day("from")
    last = form.day("to")
    category = form.choice("category", EXPENSE_CATEGORIES, required=False)
    if not form.ok:
        return invalid(form)
    found = repo.list_expenses(get_db(), first, last + timedelta(days=1) if last else None)
    if category:
        found = [e for e in found if e.category == category]
    found.sort(key=lambda e: (e.date, e.id or 0), reverse=True)
    return [_expense(e) for e in found]


@bp.get("/expenses/options")
def expense_options():
    bookings = booking_options(repo.list_bookings(get_db()))
    return {
        "categories": EXPENSE_CATEGORIES,
        "bookings": [{"id": i, "label": label} for i, label in bookings],
    }


@bp.get("/expenses/<int:expense_id>")
def expense_detail(expense_id: int):
    expense = repo.get_expense(get_db(), expense_id)
    return _expense(expense) if expense else _not_found("expense")


def _save_expense(expense: Expense, saving):
    conn = get_db()
    form = read_form()
    _read_expense(form)
    if form.ok:
        _fill_expense(form, expense)
        form.apply(lambda: saving(conn, expense))
    if not form.ok:
        return invalid(form)
    return ok(_expense(expense), [info("Expense saved.")])


@bp.post("/expenses")
def create_expense():
    return _save_expense(Expense(date.today(), 0, ""), repo.create_expense)


@bp.put("/expenses/<int:expense_id>")
def update_expense(expense_id: int):
    expense = repo.get_expense(get_db(), expense_id)
    if expense is None:
        return _not_found("expense")
    return _save_expense(expense, repo.update_expense)


@bp.delete("/expenses/<int:expense_id>")
def delete_expense(expense_id: int):
    conn = get_db()
    if repo.get_expense(conn, expense_id) is None:
        return _not_found("expense")
    repo.delete_expense(conn, expense_id)
    return ok(None, [info("Expense deleted.")])


@bp.get("/recurring")
def list_recurring():
    return [_recurring(r) for r in repo.list_recurring_expenses(get_db())]


@bp.get("/recurring/options")
def recurring_options():
    return {"categories": RECURRING_CATEGORIES}


@bp.get("/recurring/<int:item_id>")
def recurring_detail(item_id: int):
    conn = get_db()
    item = repo.get_recurring_expense(conn, item_id)
    return _recurring_detail(conn, item) if item else _not_found("recurring expense")


def _save_recurring(item: RecurringExpense, saving):
    conn = get_db()
    form = read_form()
    _read_recurring(form)
    if form.ok:
        _fill_recurring(form, item)
        form.apply(lambda: saving(conn, item))
    if not form.ok:
        return invalid(form)
    created = generate_recurring(conn, date.today())
    return ok(_recurring_detail(conn, item), [info(_recurring_saved(created))])


@bp.post("/recurring")
def create_recurring():
    return _save_recurring(RecurringExpense("", 0, "", ""), repo.create_recurring_expense)


@bp.put("/recurring/<int:item_id>")
def update_recurring(item_id: int):
    item = repo.get_recurring_expense(get_db(), item_id)
    if item is None:
        return _not_found("recurring expense")
    return _save_recurring(item, repo.update_recurring_expense)


@bp.delete("/recurring/<int:item_id>")
def delete_recurring(item_id: int):
    conn = get_db()
    if repo.get_recurring_expense(conn, item_id) is None:
        return _not_found("recurring expense")
    repo.delete_recurring_expense(conn, item_id)
    return ok(None, [info(RECURRING_DELETED)])
