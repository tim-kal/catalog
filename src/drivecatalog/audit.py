"""Immutable audit log for DriveCatalog.

Append-only ledger that records every data-changing operation so you can
trace exactly what happened to your data and when.  Entries are never
modified or deleted by application code.

Usage:
    from drivecatalog.audit import log_event
    log_event(conn, "scan_completed", drive_name="MyDrive",
              detail="new=142 modified=3 removed=0", files_affected=145)
"""

from __future__ import annotations

import sqlite3


def log_event(
    conn: sqlite3.Connection,
    event_type: str,
    *,
    drive_name: str | None = None,
    operation_id: str | None = None,
    detail: str | None = None,
    files_affected: int = 0,
    bytes_affected: int = 0,
) -> None:
    """Append a single entry to the audit log.

    This is intentionally fire-and-forget — a logging failure should
    never crash an operation.  Commits immediately so the entry is
    durable even if the caller's transaction rolls back.
    """
    try:
        conn.execute(
            """INSERT INTO audit_log
               (event_type, drive_name, operation_id, detail, files_affected, bytes_affected)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (event_type, drive_name, operation_id, detail, files_affected, bytes_affected),
        )
        conn.commit()
    except Exception:
        pass  # Never let audit logging break an operation
