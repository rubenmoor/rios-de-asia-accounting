"""The JSON API under /api: one blueprint, one module per resource."""

from flask import Flask

from rios_de_asia_accounting.web.api import (  # noqa: F401  (register their routes)
    bookings,
    dashboard,
    expenses,
    importing,
    rates,
    settings,
    system,
)
from rios_de_asia_accounting.web.api.common import bp


def register(app: Flask) -> None:
    app.register_blueprint(bp)
