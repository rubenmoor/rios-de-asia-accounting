from flask import Response, current_app

from rios_de_asia_accounting.web.api.common import bp, ok


@bp.post("/quit")
def quit_app() -> Response:
    response = ok(None, [])
    shutdown = current_app.config.get("SHUTDOWN")
    if shutdown is not None:
        response.call_on_close(shutdown)  # after the response has been sent
    return response
