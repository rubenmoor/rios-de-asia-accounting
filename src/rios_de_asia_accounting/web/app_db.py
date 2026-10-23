import sqlite3

from flask import g

from rios_de_asia_accounting.storage.db import connect


def get_db() -> sqlite3.Connection:
    """The request's connection, opened on first use and closed on teardown."""
    if "db" not in g:
        g.db = connect(g.app_db_path)
    return g.db
