"""Helpers shared by all API modules: request reading, responses, notices, errors."""

from typing import Any

from flask import Blueprint, Flask, Response, jsonify, request
from werkzeug.exceptions import BadRequest, HTTPException

from rios_de_asia_accounting.storage.repo import ValidationError
from rios_de_asia_accounting.web.forms import Form

bp = Blueprint("api", __name__, url_prefix="/api")


def notice(level: str, text: str) -> dict[str, str]:
    return {"level": level, "text": text}


def info(text: str) -> dict[str, str]:
    return notice("info", text)


def warning(text: str) -> dict[str, str]:
    return notice("warning", text)


def error(text: str) -> dict[str, str]:
    return notice("error", text)


def read_form() -> Form:
    """The JSON body (object of strings, arrays of strings for multi-value fields) as a Form."""
    body = request.get_json(silent=True)
    if not isinstance(body, dict):
        raise BadRequest("the request body must be a JSON object")
    data: dict[str, str] = {}
    lists: dict[str, list[str]] = {}
    for key, value in body.items():
        if isinstance(value, str):
            data[key] = value
        elif isinstance(value, list) and all(isinstance(v, str) for v in value):
            lists[key] = value
        else:
            raise BadRequest(f"{key!r} must be a string or an array of strings")
    return Form(data, lists)


def ok(data: Any = None, notices: list[dict[str, str]] | None = None) -> Response:
    return jsonify({"data": data, "notices": notices or []})


def invalid(form: Form | None = None, exc: ValidationError | None = None) -> tuple[Response, int]:
    """422 with one message per field; a repo ValidationError is form-level (key "")."""
    errors = dict(form.errors) if form is not None else {}
    if exc is not None:
        errors[""] = str(exc)
    return jsonify({"errors": errors}), 422


def _json_error(exc: HTTPException):
    if not request.path.startswith("/api/") and request.path != "/api":
        return exc  # HTML routes keep their pages
    response = jsonify({"error": exc.description or exc.name})
    response.status_code = exc.code or 500
    return response


def register_errors(app: Flask) -> None:
    app.register_error_handler(HTTPException, _json_error)
