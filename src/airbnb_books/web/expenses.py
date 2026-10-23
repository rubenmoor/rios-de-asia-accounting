"""Expense and recurring expense screens."""

from datetime import date, timedelta

from flask import Flask, abort, flash, redirect, render_template, request, url_for
from werkzeug.wrappers import Response

from airbnb_books.model import Expense, RecurringExpense
from airbnb_books.recurring import generate_recurring
from airbnb_books.storage import repo
from airbnb_books.web.app_db import get_db
from airbnb_books.web.forms import Form, booking_options, format_money

EXPENSE_CATEGORIES = ["fixed", "per_night", "per_booking", "maintenance", "capex", "tax"]
RECURRING_CATEGORIES = ["fixed", "per_night", "maintenance", "tax"]


def _expense_page(conn, expense: Expense | None, form: Form) -> str:
    return render_template(
        "expense_form.html",
        expense=expense,
        form=form,
        categories=EXPENSE_CATEGORIES,
        bookings=booking_options(repo.list_bookings(conn)),
        title="Edit expense" if expense else "New expense",
    )


def _read_expense(form: Form) -> None:
    form.day("date", required=True)
    form.money("amount", positive=True, required=True)
    category = form.choice("category", EXPENSE_CATEGORIES)
    form.text("description")
    # booking and useful life only count for their own category
    booking = form.whole("booking_id", required=category == "per_booking")
    form.whole("useful_life_days", required=category == "capex", positive=True)
    if category != "per_booking":
        form.errors.pop("booking_id", None)
        form.values["booking_id"] = None
    elif booking is not None and repo.get_booking(get_db(), booking) is None:
        form.error("booking_id", "choose one of the bookings")
    if category != "capex":
        form.errors.pop("useful_life_days", None)
        form.values["useful_life_days"] = None


def _fill_expense(form: Form, expense: Expense) -> None:
    expense.date = form.values["date"]
    expense.amount = form.values["amount"]
    expense.category = form.values["category"]
    expense.booking_id = form.values["booking_id"]
    expense.useful_life_days = form.values["useful_life_days"]
    expense.description = form.values["description"]


def _recurring_page(conn, item: RecurringExpense | None, form: Form) -> str:
    generated = repo.list_expenses_of_recurring(conn, item.id) if item else []
    generated.sort(key=lambda e: e.date, reverse=True)
    return render_template(
        "recurring_form.html",
        item=item,
        form=form,
        categories=RECURRING_CATEGORIES,
        generated=generated,
        title="Edit recurring expense" if item else "New recurring expense",
    )


def _read_recurring(form: Form) -> None:
    form.text("description", required=True)
    form.money("amount", positive=True, required=True)
    form.choice("category", RECURRING_CATEGORIES)
    start = form.month("start_month", required=True)
    end = form.month("end_month")
    if start and end and end < start:
        form.error("end_month", "the end month must not be before the start month")


def _fill_recurring(form: Form, item: RecurringExpense) -> None:
    item.description = form.values["description"]
    item.amount = form.values["amount"]
    item.category = form.values["category"]
    item.start_month = form.values["start_month"].isoformat()[:7]
    end = form.values["end_month"]
    item.end_month = end.isoformat()[:7] if end else None


def register(app: Flask) -> None:
    def expenses() -> str:
        conn = get_db()
        form = Form(request.args)
        first = form.day("from")
        last = form.day("to")
        category = form.choice("category", EXPENSE_CATEGORIES, required=False)
        if not form.ok:
            first = last = category = None
        found = repo.list_expenses(conn, first, last + timedelta(days=1) if last else None)
        if category:
            found = [e for e in found if e.category == category]
        found.sort(key=lambda e: (e.date, e.id or 0), reverse=True)
        templates = {t.id: t for t in repo.list_recurring_expenses(conn)}
        return render_template(
            "expenses.html",
            expenses=found,
            form=form,
            categories=EXPENSE_CATEGORIES,
            templates=templates,
            total=sum(e.amount for e in found),
        )

    def expense_new() -> str | Response:
        conn = get_db()
        if request.method == "GET":
            return _expense_page(conn, None, Form({"date": date.today().isoformat()}))
        form = Form(request.form)
        _read_expense(form)
        if form.ok:
            expense = Expense(date.today(), 0, "")
            _fill_expense(form, expense)
            form.apply(lambda: repo.create_expense(conn, expense))
            if form.ok:
                flash("Expense saved.")
                return redirect(url_for("expenses"))
        return _expense_page(conn, None, form)

    def expense_edit(expense_id: int) -> str | Response:
        conn = get_db()
        expense = repo.get_expense(conn, expense_id)
        if expense is None:
            abort(404)
        if request.method == "GET":
            form = Form(
                {
                    "date": str(expense.date),
                    "amount": format_money(expense.amount),
                    "category": expense.category,
                    "booking_id": str(expense.booking_id or ""),
                    "useful_life_days": str(expense.useful_life_days or ""),
                    "description": expense.description or "",
                }
            )
            return _expense_page(conn, expense, form)
        form = Form(request.form)
        _read_expense(form)
        if form.ok:
            _fill_expense(form, expense)
            form.apply(lambda: repo.update_expense(conn, expense))
            if form.ok:
                flash("Expense saved.")
                return redirect(url_for("expenses"))
        return _expense_page(conn, expense, form)

    def expense_delete(expense_id: int) -> Response:
        repo.delete_expense(get_db(), expense_id)
        flash("Expense deleted.")
        return redirect(url_for("expenses"))

    def recurring() -> str:
        return render_template("recurring.html", items=repo.list_recurring_expenses(get_db()))

    def _save_recurring(conn, form: Form, item: RecurringExpense, saving) -> Response | None:
        _fill_recurring(form, item)
        form.apply(lambda: saving(conn, item))
        if not form.ok:
            return None
        created = generate_recurring(conn, date.today())
        flash(f"Recurring expense saved; {created} expense(s) generated.")
        return redirect(url_for("recurring_edit", item_id=item.id))

    def recurring_new() -> str | Response:
        conn = get_db()
        if request.method == "GET":
            return _recurring_page(conn, None, Form({"start_month": date.today().isoformat()[:7]}))
        form = Form(request.form)
        _read_recurring(form)
        if form.ok:
            item = RecurringExpense("", 0, "", "")
            done = _save_recurring(conn, form, item, repo.create_recurring_expense)
            if done:
                return done
        return _recurring_page(conn, None, form)

    def recurring_edit(item_id: int) -> str | Response:
        conn = get_db()
        item = repo.get_recurring_expense(conn, item_id)
        if item is None:
            abort(404)
        if request.method == "GET":
            form = Form(
                {
                    "description": item.description,
                    "amount": format_money(item.amount),
                    "category": item.category,
                    "start_month": item.start_month,
                    "end_month": item.end_month or "",
                }
            )
            return _recurring_page(conn, item, form)
        form = Form(request.form)
        _read_recurring(form)
        if form.ok:
            done = _save_recurring(
                conn, form, item, lambda c, i: repo.update_recurring_expense(c, i)
            )
            if done:
                return done
        return _recurring_page(conn, item, form)

    def recurring_delete(item_id: int) -> Response:
        repo.delete_recurring_expense(get_db(), item_id)
        flash("Recurring expense deleted; the expenses it generated are kept.")
        return redirect(url_for("recurring"))

    app.add_url_rule("/expenses", "expenses", expenses)
    app.add_url_rule("/expenses/new", "expense_new", expense_new, methods=["GET", "POST"])
    app.add_url_rule(
        "/expenses/<int:expense_id>/edit", "expense_edit", expense_edit, methods=["GET", "POST"]
    )
    app.add_url_rule(
        "/expenses/<int:expense_id>/delete", "expense_delete", expense_delete, methods=["POST"]
    )
    app.add_url_rule("/recurring", "recurring", recurring)
    app.add_url_rule("/recurring/new", "recurring_new", recurring_new, methods=["GET", "POST"])
    app.add_url_rule(
        "/recurring/<int:item_id>", "recurring_edit", recurring_edit, methods=["GET", "POST"]
    )
    app.add_url_rule(
        "/recurring/<int:item_id>/delete", "recurring_delete", recurring_delete, methods=["POST"]
    )
