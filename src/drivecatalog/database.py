"""Database connection and initialization for DriveCatalog."""

import os
import sqlite3
from pathlib import Path

# Environment variable for custom database path (useful for testing)
DB_PATH_ENV = "DRIVECATALOG_DB"


def get_db_path() -> Path:
    """Return path to database file, creating parent directory if needed.

    Default location: ~/.drivecatalog/catalog.db
    Override with DRIVECATALOG_DB environment variable.
    """
    if env_path := os.environ.get(DB_PATH_ENV):
        db_path = Path(env_path)
    else:
        db_path = Path.home() / ".drivecatalog" / "catalog.db"

    # Create parent directory with secure permissions if it doesn't exist
    db_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)

    return db_path


def get_connection() -> sqlite3.Connection:
    """Return a connection to the catalog database.

    Caller is responsible for closing the connection.

    Connection settings:
    - Foreign keys enabled
    - Row factory set to sqlite3.Row for dict-like access
    """
    db_path = get_db_path()
    conn = sqlite3.connect(str(db_path), timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    # busy_timeout ensures concurrent writers wait rather than failing immediately.
    # 30s matches the connect timeout and is safe for parallel scan operations.
    conn.execute("PRAGMA busy_timeout = 30000")
    return conn


def init_db() -> None:
    """Initialize database schema via the migration system.

    Applies all pending migrations in order.  For brand-new databases this
    creates every table from scratch.  For existing databases it picks up
    where it left off.  Safe to call multiple times.

    See migrations.py for the migration registry and the requires_rescan
    guardrail that protects against silent data invalidation.

    Note: schema.sql is kept as reference documentation but is no longer
    executed directly — all DDL lives in the MIGRATIONS list.
    """
    from drivecatalog.migrations import apply_migrations

    conn = get_connection()
    try:
        apply_migrations(conn)
    finally:
        conn.close()
