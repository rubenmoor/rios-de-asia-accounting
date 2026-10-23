import os
import sqlite3
from pathlib import Path
from urllib.parse import urlparse

from flask import Flask, abort, g, render_template, request

from airbnb_books import __version__
from airbnb_books.storage.db import connect

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


def get_db() -> sqlite3.Connection:
    """The request's connection, opened on first use and closed on teardown."""
    if "db" not in g:
        g.db = connect(g.app_db_path)
    return g.db


def _same_origin() -> bool:
    for header in ("Origin", "Referer"):
        value = request.headers.get(header)
        if value:
            return urlparse(value).netloc == request.host
    return True


def create_app(db_path: str | Path) -> Flask:
    app = Flask(__name__)
    app.secret_key = os.urandom(24)  # only signs flash messages of this run
    app.config["DB_PATH"] = str(db_path)

    @app.before_request
    def guard() -> None:
        g.app_db_path = app.config["DB_PATH"]
        if request.method == "POST" and not _same_origin():
            abort(403)

    @app.teardown_appcontext
    def close_db(_exc: BaseException | None) -> None:
        conn = g.pop("db", None)
        if conn is not None:
            conn.close()

    @app.context_processor
    def nav() -> dict:
        return {"nav": NAV, "active": request.endpoint}

    @app.route("/")
    def index() -> str:
        return render_template("index.html", version=__version__)

    def register_stub(endpoint: str, url: str, title: str) -> None:
        def view() -> str:
            return render_template("stub.html", title=title)

        app.add_url_rule(url, endpoint, view)

    for endpoint, url, title in NAV:
        register_stub(endpoint, url, title)

    return app
