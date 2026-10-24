import argparse
import signal
import socket
import sqlite3
import sys
import threading
import webbrowser
from datetime import date, datetime
from pathlib import Path

from waitress import create_server

from rios_de_asia_accounting.backup import BackupError, backup, before_migrate_hook, resolve_keep
from rios_de_asia_accounting.config import ConfigError, resolve_backup_dir, resolve_db_path
from rios_de_asia_accounting.conversion import convert_waiting
from rios_de_asia_accounting.importer.airbnb_csv import (
    FileError,
    ImportPlan,
    apply_import,
    parse,
    plan_import,
)
from rios_de_asia_accounting.recurring import generate_recurring
from rios_de_asia_accounting.storage.db import connect, migrate
from rios_de_asia_accounting.web.app import create_app

HOST = "127.0.0.1"
BACKUP_INTERVAL = 3600  # seconds between backups while the app runs


def _free_port() -> int:
    with socket.socket() as s:
        s.bind((HOST, 0))
        return s.getsockname()[1]


def serve(
    db_path: Path,
    port: int | None,
    open_browser: bool,
    backup_dir: str | None = None,
    backup_interval: float | None = BACKUP_INTERVAL,
) -> None:
    """Run the web app until Ctrl-C or SIGTERM, backing up at start, hourly when the books
    changed, and once more at stop. `backup_interval` None turns the timer thread off."""
    app = create_app(db_path)
    server = create_server(app, host=HOST, port=port or _free_port())
    stop_loop = threading.Event()
    loop = None
    if backup_interval is not None:
        loop = threading.Thread(
            target=backup_loop,
            args=(db_path, backup_dir, app.config, stop_loop, backup_interval),
            daemon=True,
        )
        loop.start()
    # explicit: a background shell can leave SIGINT ignored
    signal.signal(signal.SIGINT, signal.default_int_handler)
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    url = f"http://{HOST}:{server.effective_port}/"
    print(f"rios-de-asia-accounting running at {url} (Ctrl-C to stop)", flush=True)
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
        stop_loop.set()
        if loop is not None:
            loop.join(timeout=30)
        backup_on_exit(db_path, backup_dir, app.config)


def backup_now(
    db_path: Path, backup_dir: str | None, config: dict | None = None, when: str = ""
) -> bool:
    """Back up; a failure goes to stderr and never stops the app. The result is kept in
    `config["LAST_BACKUP"]` (time and file, or the error) for the Settings screen."""
    result: dict = {
        "time": datetime.now().isoformat(timespec="seconds"),
        "file": None,
        "error": None,
    }
    try:
        target = backup(
            db_path, resolve_backup_dir(backup_dir), resolve_keep(db_path), date.today()
        )
        result["file"] = str(target)
        print(f"backup written: {target}", flush=True)
    except (BackupError, OSError) as e:
        result["error"] = str(e)
        print(f"rios-de-asia-accounting: backup{when} failed: {e}", file=sys.stderr, flush=True)
    if config is not None:
        config["LAST_BACKUP"] = result
    return result["error"] is None


def backup_on_exit(db_path: Path, backup_dir: str | None, config: dict | None = None) -> None:
    backup_now(db_path, backup_dir, config, " at exit")


def backup_loop(
    db_path: Path,
    backup_dir: str | None,
    config: dict,
    stop: threading.Event,
    interval: float,
) -> None:
    """Back up right away, then every `interval` seconds when another connection has
    written since the last successful backup, until `stop` is set."""
    conn = None
    done = None
    try:
        while not stop.is_set():
            try:
                if conn is None:
                    conn = sqlite3.connect(db_path)
                version = conn.execute("PRAGMA data_version").fetchone()[0]
            except sqlite3.Error as e:
                print(f"rios-de-asia-accounting: backup check failed: {e}", file=sys.stderr)
                version = None
            if version is None or version != done:
                if backup_now(db_path, backup_dir, config) and version is not None:
                    done = version
            stop.wait(interval)
    finally:
        if conn is not None:
            conn.close()


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
            f"{summary.waiting} line(s) wait for an exchange rate"
        )
        return 0
    finally:
        conn.close()


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="rios-de-asia-accounting")
    parser.add_argument(
        "--db", help="database file (default: $RIOS_DE_ASIA_ACCOUNTING_DB or the XDG data dir)"
    )
    sub = parser.add_subparsers(dest="command")
    serve_parser = sub.add_parser("serve", help="start the web app (default)")
    sub.add_parser("migrate", help="create or upgrade the database")
    backup_parser = sub.add_parser("backup", help="copy the database into the backup folder")
    backup_parser.add_argument(
        "--backup-dir",
        help=(
            "backup folder (default: $RIOS_DE_ASIA_ACCOUNTING_BACKUP_DIR"
            " or ~/Dropbox/rios-de-asia-accounting)"
        ),
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
        else:
            run_migrate(args.db, args.backup_dir)
            db_path = resolve_db_path(args.db)
            conn = connect(db_path)
            try:
                generate_recurring(conn, date.today())
                convert_waiting(conn, date.today())
            finally:
                conn.close()
            serve(db_path, args.port, not args.no_browser, args.backup_dir)
    except (ConfigError, BackupError, FileError, OSError) as e:
        parser.exit(2, f"rios-de-asia-accounting: {e}\n")


if __name__ == "__main__":
    main()
