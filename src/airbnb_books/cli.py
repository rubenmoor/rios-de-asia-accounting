import argparse
import socket
import webbrowser

from waitress import create_server

from airbnb_books.config import ConfigError, resolve_db_path
from airbnb_books.storage.db import connect, migrate
from airbnb_books.web.app import create_app

HOST = "127.0.0.1"


def _free_port() -> int:
    with socket.socket() as s:
        s.bind((HOST, 0))
        return s.getsockname()[1]


def serve(port: int | None, open_browser: bool) -> None:
    server = create_server(create_app(), host=HOST, port=port or _free_port())
    url = f"http://{HOST}:{server.effective_port}/"
    print(f"airbnb-books running at {url} (Ctrl-C to stop)", flush=True)
    if open_browser:
        webbrowser.open(url)
    try:
        server.run()
    except KeyboardInterrupt:
        pass
    finally:
        server.close()


def run_migrate(db: str | None) -> None:
    path = resolve_db_path(db)
    conn = connect(path)
    try:
        applied = migrate(conn)
    finally:
        conn.close()
    print(f"{path}: {applied} migration(s) applied")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="airbnb-books")
    parser.add_argument(
        "--db", help="database file (default: $AIRBNB_BOOKS_DB or the XDG data dir)"
    )
    sub = parser.add_subparsers(dest="command")
    serve_parser = sub.add_parser("serve", help="start the web app (default)")
    sub.add_parser("migrate", help="create or upgrade the database")
    for p in (parser, serve_parser):
        p.add_argument("--port", type=int, help="port to listen on (default: a free port)")
        p.add_argument("--no-browser", action="store_true", help="do not open the browser")
    args = parser.parse_args(argv)
    try:
        if args.command == "migrate":
            run_migrate(args.db)
        else:
            run_migrate(args.db)
            serve(args.port, not args.no_browser)
    except ConfigError as e:
        parser.exit(2, f"airbnb-books: {e}\n")


if __name__ == "__main__":
    main()
