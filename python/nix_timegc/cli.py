#!/usr/bin/env python3

import argparse
import sqlite3
import subprocess
import os
import sys
from sqlite3 import Connection
from datetime import datetime, timedelta
from pathlib import Path


def get_db_uri(db_path: Path) -> str:
    """Determines the correct SQLite connection URI based on user privileges."""
    if os.geteuid() == 0:
        return f"file:{db_path}?mode=rwc&immutable=0"
    else:
        db_uri = f"file:{db_path}?mode=ro"
        try:
            with sqlite3.connect(db_uri, uri=True) as testConn:
                testConn.execute("SELECT 1 FROM ValidPaths LIMIT 1;")
        except sqlite3.OperationalError:
            db_uri = f"file:{db_path}?mode=ro&immutable=1"
        return db_uri


def get_old_paths(conn: Connection, seconds: int) -> list[str]:
    """Get store paths older than specified seconds from the Nix database."""
    cutoff_time = int((datetime.now() - timedelta(seconds=seconds)).timestamp())
    cursor = conn.cursor()
    cursor.execute(
        """
        SELECT path
        FROM ValidPaths
        WHERE registrationTime < ?
        """,
        (cutoff_time,),
    )
    return [row[0] for row in cursor.fetchall()]


def delete_paths(paths: list[str], dry_run: bool = False) -> None:
    """Attempt to delete specified store paths."""
    if not paths:
        print("No old paths to delete.")
        return

    action = "Would delete" if dry_run else "Attempting to delete"
    print(f"{action} {len(paths)} paths...")

    if dry_run:
        for path in paths:
            print(path)
        return

    # Let nix-store handle checks for live GC roots.
    # check=False allows the command to continue even if some paths are live.
    result = subprocess.run(
        ["nix-store", "--delete", *paths],
        check=False,
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        print(
            "Deletion command finished with errors (some paths may still be live).",
            file=sys.stderr,
        )
        print(f"Stderr:\n{result.stderr}", file=sys.stderr)
    else:
        print(f"Successfully processed {len(paths)} paths for deletion.")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Delete Nix store paths older than a specified time.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "seconds", type=int, help="Attempt to delete paths older than this many seconds"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print paths that would be deleted without deleting them.",
    )
    args = parser.parse_args()

    try:
        db_path = Path(os.environ.get("NIX_STATE_DIR", "/nix/var/nix")) / "db/db.sqlite"
        if not db_path.exists():
            raise Exception(f"Nix database not found: {db_path}")

        is_dry_run = args.dry_run or os.geteuid() != 0

        with sqlite3.connect(get_db_uri(db_path), uri=True) as conn:
            old_paths = get_old_paths(conn, args.seconds)
            print(
                f"Found {len(old_paths)} paths older than {args.seconds} seconds."
            )

            delete_paths(old_paths, is_dry_run)

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
