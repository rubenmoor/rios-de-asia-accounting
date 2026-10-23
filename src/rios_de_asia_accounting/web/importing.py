"""Import screen: Airbnb earnings CSV (preview, then apply) and TRM exchange-rate CSV."""

import re
import secrets
import tempfile
from pathlib import Path

from flask import Flask, abort, flash, redirect, render_template, request, url_for
from werkzeug.datastructures import FileStorage
from werkzeug.wrappers import Response

from rios_de_asia_accounting.importer.airbnb_csv import (
    FileError,
    ImportPlan,
    ImportSummary,
    apply_import,
    parse,
    plan_import,
)
from rios_de_asia_accounting.importer.trm_csv import ParsedRates, RatesSummary, apply_rates
from rios_de_asia_accounting.importer.trm_csv import parse as parse_rates
from rios_de_asia_accounting.web.app_db import get_db
from rios_de_asia_accounting.web.forms import Form

_TOKEN = re.compile(r"[0-9a-f]{32}")


def _upload_dir() -> Path:
    path = Path(tempfile.gettempdir()) / "rios-de-asia-accounting-uploads"
    path.mkdir(mode=0o700, exist_ok=True)
    return path


def _token_path(token: str) -> Path:
    """The kept file of a token; the token is checked, never used as a path."""
    if not _TOKEN.fullmatch(token):
        abort(404)
    return _upload_dir() / f"{token}.csv"


def _save_upload(upload: FileStorage) -> Path:
    path = _upload_dir() / f"{secrets.token_hex(16)}.csv"
    upload.save(path)
    return path


GONE = "the uploaded file is gone; upload it again"
NO_AIRBNB_FILE = "choose the Airbnb CSV file"
NO_RATES_FILE = "choose the exchange-rate CSV file"
NO_LISTING = "choose at least one listing"


def has_file(upload: FileStorage | None) -> bool:
    return upload is not None and bool(upload.filename)


def preview_upload(conn, upload: FileStorage) -> tuple[ImportPlan, str]:
    """Keep the upload under a new token and plan its import; FileError drops the file."""
    path = _save_upload(upload)
    try:
        return plan_import(conn, parse(path)), path.stem
    except FileError:
        path.unlink(missing_ok=True)
        raise


def apply_upload(
    conn, token: str, listings: list[str], extra: str
) -> tuple[ImportPlan | None, ImportSummary | None, str | None]:
    """Apply the kept file of `token`: (plan, summary, error).

    Error with a plan: the listing choice is missing (ask again); error alone: the file is
    gone or unreadable; otherwise the summary.
    """
    path = _token_path(token)
    if not path.is_file():
        return None, None, GONE
    chosen = [v.strip() for v in listings if v.strip()]
    extra = extra.strip()
    if extra and extra not in chosen:
        chosen.append(extra)
    try:
        plan = plan_import(conn, parse(path), chosen or None)
        if plan.needs_listing_choice:
            return plan, None, NO_LISTING
        summary = apply_import(conn, plan)
    except FileError as e:
        path.unlink(missing_ok=True)
        return None, None, str(e)
    path.unlink(missing_ok=True)
    return plan, summary, None


def cancel_upload(token: str) -> None:
    _token_path(token).unlink(missing_ok=True)


def import_rates_file(conn, upload: FileStorage, currency: str) -> tuple[RatesSummary, ParsedRates]:
    """Apply an uploaded exchange-rate CSV; raises FileError."""
    path = _save_upload(upload)
    try:
        parsed = parse_rates(path)
        return apply_rates(conn, parsed, currency), parsed
    finally:
        path.unlink(missing_ok=True)


def _index(**context) -> str:
    return render_template("import.html", **context)


def register(app: Flask) -> None:
    def import_page() -> str:
        return _index()

    def airbnb_preview() -> str:
        upload = request.files.get("file")
        if upload is None or not has_file(upload):
            return _index(airbnb_error=NO_AIRBNB_FILE)
        try:
            plan, token = preview_upload(get_db(), upload)
        except FileError as e:
            return _index(airbnb_error=str(e))
        return render_template("import_preview.html", plan=plan, token=token, error=None)

    def airbnb_apply() -> str:
        token = request.form.get("token", "")
        plan, summary, error = apply_upload(
            get_db(),
            token,
            request.form.getlist("listings"),
            request.form.get("other_listing", ""),
        )
        if plan is not None and summary is None:
            return render_template("import_preview.html", plan=plan, token=token, error=error)
        if summary is None:
            return _index(airbnb_error=error)
        return render_template("import_summary.html", summary=summary)

    def airbnb_cancel() -> Response:
        cancel_upload(request.form.get("token", ""))
        flash("Import cancelled; nothing was changed.")
        return redirect(url_for("import"))

    def rates_import() -> str:
        form = Form(request.form)
        currency = form.currency("currency", required=True)
        upload = request.files.get("file")
        if upload is None or not has_file(upload):
            form.error("file", NO_RATES_FILE)
        if not form.ok:
            return _index(rates_error=" ".join(form.errors.values()), rates_form=form)
        try:
            summary, parsed = import_rates_file(get_db(), upload, currency)
        except FileError as e:
            return _index(rates_error=str(e), rates_form=form)
        return _index(
            rates_summary=summary, rates_problems=parsed.problems, rates_currency=currency
        )

    app.add_url_rule("/import", "import", import_page)
    app.add_url_rule("/import/airbnb", "import_airbnb", airbnb_preview, methods=["POST"])
    app.add_url_rule("/import/airbnb/apply", "import_apply", airbnb_apply, methods=["POST"])
    app.add_url_rule("/import/airbnb/cancel", "import_cancel", airbnb_cancel, methods=["POST"])
    app.add_url_rule("/import/rates", "import_rates", rates_import, methods=["POST"])
