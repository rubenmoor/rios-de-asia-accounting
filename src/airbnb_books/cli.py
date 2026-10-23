import argparse
import socket
import webbrowser

from waitress import create_server

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


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="airbnb-books")
    sub = parser.add_subparsers(dest="command")
    serve_parser = sub.add_parser("serve", help="start the web app (default)")
    for p in (parser, serve_parser):
        p.add_argument("--port", type=int, help="port to listen on (default: a free port)")
        p.add_argument("--no-browser", action="store_true", help="do not open the browser")
    args = parser.parse_args(argv)
    serve(args.port, not args.no_browser)


if __name__ == "__main__":
    main()
