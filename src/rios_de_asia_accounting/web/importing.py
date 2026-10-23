"""Import screen: Airbnb earnings CSV (preview, then apply) and TRM exchange-rate CSV."""

import re
import secrets
import tempfile
from pathlib import Path

from flask import Flask, abort, flash, redirect, render_template, request, url_for
from werkzeug.datastructures import FileStorage
from werkzeug.wrappers import Response

from rios_de_asia_accounting.importer.airbnb_csv import FileError, apply_import, parse, plan_import
from rios_de_asia_accounting.importer.trm_csv import apply_rates
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


def _index(**context) -> str:
    return render_template("import.html", **context)


def register(app: Flask) -> None:
    def import_page() -> str:
        return _index()

    def airbnb_preview() -> str:
        upload = request.files.get("file")
        if upload is None or not upload.filename:
            return _index(airbnb_error="choose the Airbnb CSV file")
        path = _save_upload(upload)
        try:
            plan = plan_import(get_db(), parse(path))
        except FileError as e:
            path.unlink(missing_ok=True)
            return _index(airbnb_error=str(e))
        return render_template("import_preview.html", plan=plan, token=path.stem, error=None)

    def airbnb_apply() -> str:
        conn = get_db()
        token = request.form.get("token", "")
        path = _token_path(token)
        if not path.is_file():
            return _index(airbnb_error="the uploaded file is gone; upload it again")
        chosen = [v.strip() for v in request.form.getlist("listings") if v.strip()]
        extra = request.form.get("other_listing", "").strip()
        if extra and extra not in chosen:
            chosen.append(extra)
        try:
            plan = plan_import(conn, parse(path), chosen or None)
            if plan.needs_listing_choice:
                return render_template(
                    "import_preview.html",
                    plan=plan,
                    token=token,
                    error="choose at least one listing",
                )
            summary = apply_import(conn, plan)
        except FileError as e:
            path.unlink(missing_ok=True)
            return _index(airbnb_error=str(e))
        path.unlink(missing_ok=True)
        return render_template("import_summary.html", summary=summary)

    def airbnb_cancel() -> Response:
        _token_path(request.form.get("token", "")).unlink(missing_ok=True)
        flash("Import cancelled; nothing was changed.")
        return redirect(url_for("import"))

    def rates_import() -> str:
        form = Form(request.form)
        currency = form.currency("currency", required=True)
        upload = request.files.get("file")
        if upload is None or not upload.filename:
            form.error("file", "choose the exchange-rate CSV file")
        if not form.ok:
            return _index(rates_error=" ".join(form.errors.values()), rates_form=form)
        path = _save_upload(upload)
        try:
            parsed = parse_rates(path)
            summary = apply_rates(get_db(), parsed, currency)
        except FileError as e:
            return _index(rates_error=str(e), rates_form=form)
        finally:
            path.unlink(missing_ok=True)
        return _index(
            rates_summary=summary, rates_problems=parsed.problems, rates_currency=currency
        )

    app.add_url_rule("/import", "import", import_page)
    app.add_url_rule("/import/airbnb", "import_airbnb", airbnb_preview, methods=["POST"])
    app.add_url_rule("/import/airbnb/apply", "import_apply", airbnb_apply, methods=["POST"])
    app.add_url_rule("/import/airbnb/cancel", "import_cancel", airbnb_cancel, methods=["POST"])
    app.add_url_rule("/import/rates", "import_rates", rates_import, methods=["POST"])
