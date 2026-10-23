import argparse
import signal
import socket
import sys
import threading
import webbrowser
from datetime import date
from pathlib import Path

from waitress import create_server

from airbnb_books.backup import BackupError, backup, before_migrate_hook, resolve_keep
from airbnb_books.config import ConfigError, resolve_backup_dir, resolve_db_path
from airbnb_books.importer.airbnb_csv import (
    FileError,
    ImportPlan,
    apply_import,
    parse,
    plan_import,
)
from airbnb_books.importer.trm_csv import apply_rates
from airbnb_books.importer.trm_csv import parse as parse_rates
from airbnb_books.recurring import generate_recurring
from airbnb_books.storage.db import connect, migrate
from airbnb_books.web.app import create_app

HOST = "127.0.0.1"


def _free_port() -> int:
    with socket.socket() as s:
        s.bind((HOST, 0))
        return s.getsockname()[1]


def serve(
    db_path: Path, port: int | None, open_browser: bool, backup_dir: str | None = None
) -> None:
    """Run the web app until Ctrl-C, SIGTERM or the Quit button; then back up once."""
    # Quit (a request thread) and SIGTERM both end up as KeyboardInterrupt in the main thread.
    main_thread = threading.get_ident()
    server = create_server(
        create_app(db_path, shutdown=lambda: signal.pthread_kill(main_thread, signal.SIGINT)),
        host=HOST,
        port=port or _free_port(),
    )
    # explicit: a background shell can leave SIGINT ignored
    signal.signal(signal.SIGINT, signal.default_int_handler)
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    url = f"http://{HOST}:{server.effective_port}/"
    print(f"airbnb-books running at {url} (Ctrl-C to stop)", flush=True)
    if open_browser:
        webbrowser.open(url)
    try:
        server.run()
    except KeyboardInterrupt:
        pass
    finally:
        # further stop signals must not interrupt the shutdown
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        server.close()
        backup_on_exit(db_path, backup_dir)


def backup_on_exit(db_path: Path, backup_dir: str | None) -> None:
    """Back up at exit; a failure is reported but never stops the app from closing."""
    try:
        target = backup(
            db_path, resolve_backup_dir(backup_dir), resolve_keep(db_path), date.today()
        )
        print(f"backup written: {target}", flush=True)
    except (BackupError, OSError) as e:
        print(f"airbnb-books: backup at exit failed: {e}", file=sys.stderr, flush=True)


def run_migrate(db: str | None, backup_dir: str | None = None) -> None:
    path = resolve_db_path(db)
    conn = connect(path)
    try:
        applied = migrate(conn, before_migrate=before_migrate_hook(backup_dir))
    finally:
        conn.close()
    print(f"{path}: {applied} migration(s) applied")


def run_backup(db: str | None, backup_dir: str | None, keep: int | None) -> None:
    path = resolve_db_path(db)
    target = backup(path, resolve_backup_dir(backup_dir), resolve_keep(path, keep), date.today())
    print(f"backup written: {target}")


def _print_plan(plan: ImportPlan, applied: bool) -> None:
    verb = "" if applied else "would be "
    print(f"{len(plan.new)} new booking(s) {verb}created")
    print(f"{len(plan.updated)} booking(s) {verb}updated")
    for p in plan.updated:
        for c in p.changes:
            print(f"  {p.code}: {c.field} {c.old or '-'} -> {c.new}")
    print(
        f"skipped: {plan.skipped_payouts} payout row(s), "
        f"{plan.skipped_known_lines} known line(s), "
        f"{sum(plan.skipped_listings.values())} row(s) of other listings"
    )
    for name, n in plan.skipped_listings.most_common():
        print(f"  {n} row(s): {name}")
    print(f"{len(plan.problems)} problem(s)")
    for pr in plan.problems:
        print(f"  line {pr.line}: {pr.message}")
    print(f"{len(plan.warnings)} warning(s)")
    for w in plan.warnings:
        print(f"  {w}")


def run_import(db: str | None, csv_path: str, listings: list[str] | None, dry_run: bool) -> int:
    path = resolve_db_path(db)
    conn = connect(path)
    try:
        migrate(conn)
        plan = plan_import(conn, parse(csv_path), listings or None)
        if plan.needs_listing_choice:
            print("No property listings chosen yet. Listings found in the file:")
            for name, n in plan.listings_found.most_common():
                print(f"  {n} row(s): {name}")
            print('Nothing imported. Pass each listing to import with --listing "NAME".')
            return 2
        _print_plan(plan, applied=not dry_run)
        if dry_run:
            print("dry run: nothing changed")
            return 0
        summary = apply_import(conn, plan)
        print(
            f"imported: {summary.new} new, {summary.updated} updated, "
            f"{summary.lines_added} line(s) added; "
            f"{summary.needing_rate} booking(s) need an exchange rate"
        )
        return 0
    finally:
        conn.close()


def run_import_rates(db: str | None, csv_path: str, currency: str) -> None:
    parsed = parse_rates(csv_path)
    conn = connect(resolve_db_path(db))
    try:
        migrate(conn)
        summary = apply_rates(conn, parsed, currency)
    finally:
        conn.close()
    print(f"{len(parsed.problems)} problem(s)")
    for pr in parsed.problems:
        print(f"  line {pr.line}: {pr.message}")
    print(
        f"{currency} rates: {summary.added} added, {summary.changed} changed; "
        f"{summary.lines_recomputed} line(s) recomputed; "
        f"{summary.needing_rate} booking(s) still need an exchange rate"
    )


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="airbnb-books")
    parser.add_argument(
        "--db", help="database file (default: $AIRBNB_BOOKS_DB or the XDG data dir)"
    )
    sub = parser.add_subparsers(dest="command")
    serve_parser = sub.add_parser("serve", help="start the web app (default)")
    sub.add_parser("migrate", help="create or upgrade the database")
    backup_parser = sub.add_parser("backup", help="copy the database into the backup folder")
    backup_parser.add_argument(
        "--backup-dir",
        help="backup folder (default: $AIRBNB_BOOKS_BACKUP_DIR or ~/Dropbox/airbnb-books)",
    )
    backup_parser.add_argument(
        "--keep", type=int, help="backups to keep (default: the backup_keep setting, else 30)"
    )
    import_parser = sub.add_parser("import", help="import an Airbnb transaction CSV")
    import_parser.add_argument("csv", help="Airbnb transaction history CSV")
    import_parser.add_argument(
        "--listing",
        action="append",
        help="listing to import (repeatable; saved as the property listings)",
    )
    import_parser.add_argument(
        "--dry-run", action="store_true", help="show what would happen, change nothing"
    )
    rates_parser = sub.add_parser("import-rates", help="import the official TRM rate history")
    rates_parser.add_argument("csv", help="TRM history CSV from datos.gov.co")
    rates_parser.add_argument("--currency", default="USD", help="currency of the rates")
    for p in (parser, serve_parser):
        p.add_argument("--backup-dir", help="backup folder (default: see backup)")
        p.add_argument("--port", type=int, help="port to listen on (default: a free port)")
        p.add_argument("--no-browser", action="store_true", help="do not open the browser")
    args = parser.parse_args(argv)
    try:
        if args.command == "migrate":
            run_migrate(args.db)
        elif args.command == "backup":
            run_backup(args.db, args.backup_dir, args.keep)
        elif args.command == "import":
            code = run_import(args.db, args.csv, args.listing, args.dry_run)
            if code:
                sys.exit(code)
        elif args.command == "import-rates":
            run_import_rates(args.db, args.csv, args.currency)
        else:
            run_migrate(args.db, args.backup_dir)
            db_path = resolve_db_path(args.db)
            conn = connect(db_path)
            try:
                generate_recurring(conn, date.today())
            finally:
                conn.close()
            serve(db_path, args.port, not args.no_browser, args.backup_dir)
    except (ConfigError, BackupError, FileError, OSError) as e:
        parser.exit(2, f"airbnb-books: {e}\n")


if __name__ == "__main__":
    main()
