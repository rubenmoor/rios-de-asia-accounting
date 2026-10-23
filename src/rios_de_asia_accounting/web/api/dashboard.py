from datetime import date

from flask import current_app, request

from rios_de_asia_accounting import metrics
from rios_de_asia_accounting.web.api.common import bp, error
from rios_de_asia_accounting.web.app_db import get_db
from rios_de_asia_accounting.web.dashboard import ROWS, build_dashboard


def _number(value: float | None, kind: str):
    if value is None:
        return None
    return int(value) if kind in ("money", "minutes") else value


def _range(rng: metrics.DateRange) -> dict:
    return {"start": rng.start.isoformat(), "end": rng.end.isoformat()}


@bp.get("/dashboard")
def dashboard():
    today = current_app.config.get("TODAY") or date.today()
    data = build_dashboard(get_db(), today, request.args)
    body: dict = {
        "form": data.form,
        "needing_rate": data.needing,
        "empty": data.empty,
        "columns": [],
        "rows": [],
        "rolling_90": [],
        "breakdown": None,
        "notices": [error(text) for text in data.messages],
    }
    if not data.empty:
        body["columns"] = [{"label": label, **_range(rng)} for label, rng in data.columns]
        for label, attr, kind in ROWS:
            kind = "minutes" if kind == "hours" else kind
            body["rows"].append(
                {
                    "key": attr,
                    "label": label,
                    "kind": kind,
                    "values": [_number(getattr(m, attr), kind) for m in data.summaries],
                }
            )
        body["rows"].append(
            {
                "key": "capex_book_value",
                "label": "Remaining capex book value",
                "kind": "money",
                "values": [_number(v, "money") for v in data.capex],
            }
        )
        body["rolling_90"] = [
            {"date": p.date.isoformat(), "adr": p.adr, "revpar": p.revpar, "occupancy": p.occupancy}
            for p in metrics.rolling_90(data.days)
        ]
        body["breakdown"] = {
            **_range(data.breakdown_range),
            "items": [
                {"key": key, "label": label, "amount": amount, "share": share}
                for key, label, amount, share in data.breakdown
            ],
        }
    return body
