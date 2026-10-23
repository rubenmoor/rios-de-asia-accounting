import os
from collections.abc import Callable
from pathlib import Path
from urllib.parse import urlparse

from flask import Flask, abort, g, render_template, request

from rios_de_asia_accounting.web import (
    api,
    blocked,
    bookings,
    dashboard,
    expenses,
    importing,
    settings,
    timelog,
)
from rios_de_asia_accounting.web.app_db import get_db  # noqa: F401  (re-exported)
from rios_de_asia_accounting.web.forms import format_money, format_rate

NAV = [
    ("bookings", "/bookings", "Bookings"),
    ("expenses", "/expenses", "Expenses"),
    ("recurring", "/recurring", "Recurring"),
    ("blocked", "/blocked-days", "Blocked days"),
    ("time", "/time", "Time"),
    ("rates", "/rates", "Rates"),
    ("import", "/import", "Import"),
    ("settings", "/settings", "Settings"),
]


def _same_origin() -> bool:
    for header in ("Origin", "Referer"):
        value = request.headers.get(header)
        if value:
            return urlparse(value).netloc == request.host
    return True


def create_app(db_path: str | Path, shutdown: Callable[[], None] | None = None) -> Flask:
    app = Flask(__name__)
    app.secret_key = os.urandom(24)  # only signs flash messages of this run
    app.config["DB_PATH"] = str(db_path)
    app.config["SHUTDOWN"] = shutdown

    @app.before_request
    def guard() -> None:
        g.app_db_path = app.config["DB_PATH"]
        if request.method != "GET" and not _same_origin():
            abort(403)

    @app.teardown_appcontext
    def close_db(_exc: BaseException | None) -> None:
        conn = g.pop("db", None)
        if conn is not None:
            conn.close()

    app.jinja_env.filters["money"] = format_money
    app.jinja_env.filters["rate"] = format_rate

    @app.context_processor
    def nav() -> dict:
        active = next((e for e, url, _ in NAV if request.path.startswith(url)), None)
        return {"nav": NAV, "active": active}

    @app.post("/quit")
    def quit_app():
        response = app.make_response(render_template("stopped.html"))
        if shutdown is not None:
            response.call_on_close(shutdown)  # after the page has been sent
        return response

    dashboard.register(app)
    bookings.register(app)
    expenses.register(app)
    blocked.register(app)
    timelog.register(app)
    settings.register(app)
    importing.register(app)
    api.register(app)
    api.common.register_errors(app)

    return app
