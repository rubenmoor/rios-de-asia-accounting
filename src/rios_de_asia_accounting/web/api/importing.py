from dataclasses import asdict

from flask import jsonify, request

from rios_de_asia_accounting.importer.airbnb_csv import FileError, ImportPlan, ImportSummary
from rios_de_asia_accounting.importer.trm_csv import ParsedRates, RatesSummary
from rios_de_asia_accounting.web.api.common import bp, info, invalid, ok, read_form
from rios_de_asia_accounting.web.app_db import get_db
from rios_de_asia_accounting.web.forms import Form
from rios_de_asia_accounting.web.importing import (
    NO_AIRBNB_FILE,
    NO_RATES_FILE,
    apply_upload,
    cancel_upload,
    has_file,
    import_rates_file,
    preview_upload,
)


def _problems(problems) -> list[dict]:
    return [{"line": p.line, "message": p.message} for p in problems]


def _skipped_listings(counter) -> list[dict]:
    return [{"listing": name, "rows": n} for name, n in counter.most_common()]


def _booking(p) -> dict:
    return {
        "code": p.code,
        "listing": p.listing,
        "guest": p.guest,
        "check_in": p.check_in.isoformat(),
        "check_out": p.check_out.isoformat(),
        "lines": len(p.lines),
        "changes": [asdict(c) for c in p.changes],
    }


def _plan(plan: ImportPlan, token: str) -> dict:
    return {
        "token": token,
        "needs_listing_choice": plan.needs_listing_choice,
        "listings_found": [{"listing": n, "rows": c} for n, c in plan.listings_found.most_common()],
        "listings": plan.listings,
        "new": [_booking(p) for p in plan.new],
        "updated": [_booking(p) for p in plan.updated],
        "skipped": {
            "payouts": plan.skipped_payouts,
            "known_lines": plan.skipped_known_lines,
            "listings": _skipped_listings(plan.skipped_listings),
        },
        "problems": _problems(plan.problems),
        "warnings": plan.warnings,
    }


def _summary(s: ImportSummary) -> dict:
    return {
        "new": s.new,
        "updated": s.updated,
        "lines_added": s.lines_added,
        "needing_rate": s.needing_rate,
        "skipped": {
            "payouts": s.skipped_payouts,
            "known_lines": s.skipped_known_lines,
            "listings": _skipped_listings(s.skipped_listings),
        },
        "problems": _problems(s.problems),
        "warnings": s.warnings,
    }


def _rates_summary(s: RatesSummary, parsed: ParsedRates) -> dict:
    return {
        "added": s.added,
        "changed": s.changed,
        "lines_recomputed": s.lines_recomputed,
        "needing_rate": s.needing_rate,
        "problems": _problems(parsed.problems),
    }


@bp.post("/import/airbnb")
def import_airbnb():
    upload = request.files.get("file")
    form = Form({})
    if upload is None or not has_file(upload):
        form.error("file", NO_AIRBNB_FILE)
        return invalid(form)
    try:
        plan, token = preview_upload(get_db(), upload)
    except FileError as e:
        form.error("file", str(e))
        return invalid(form)
    return ok(_plan(plan, token))


@bp.post("/import/airbnb/apply")
def apply_airbnb():
    form = read_form()
    token = form.text("token") or ""
    plan, summary, error = apply_upload(
        get_db(), token, form.raw_list("listings"), form.text("other_listing") or ""
    )
    if summary is None:
        if plan is not None:  # the listing choice is missing: the preview again
            form.error("listings", error)
            return jsonify({"errors": form.errors, "preview": _plan(plan, token)}), 422
        form.error("token", error)
        return invalid(form)
    return ok(_summary(summary))


@bp.delete("/import/airbnb/<token>")
def cancel_airbnb(token: str):
    cancel_upload(token)
    return ok(None, [info("Import cancelled; nothing was changed.")])


@bp.post("/import/rates")
def import_rates():
    form = Form(request.form)
    currency = form.currency("currency", required=True)
    upload = request.files.get("file")
    if upload is None or not has_file(upload):
        form.error("file", NO_RATES_FILE)
    if form.ok:
        try:
            summary, parsed = import_rates_file(get_db(), upload, currency)
        except FileError as e:
            form.error("file", str(e))
    if not form.ok:
        return invalid(form)
    return ok(_rates_summary(summary, parsed))
