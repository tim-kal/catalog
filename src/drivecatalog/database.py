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
    return conn


def init_db() -> None:
    """Initialize database with schema if not already created.

    Reads schema.sql from package and executes it.
    Safe to call multiple times (uses CREATE IF NOT EXISTS).
    """
    conn = get_connection()
    try:
        # Read schema from package
        schema_path = Path(__file__).parent / "schema.sql"
        schema_sql = schema_path.read_text()
        conn.executescript(schema_sql)
        conn.commit()

        # Auto-migrate: add used_bytes column if missing
        cols = {r[1] for r in conn.execute("PRAGMA table_info(drives)").fetchall()}
        if "used_bytes" not in cols:
            conn.execute("ALTER TABLE drives ADD COLUMN used_bytes INTEGER")
            conn.commit()

        # Auto-migrate: add migration_plans and migration_files tables if missing
        existing_tables = {
            r[0]
            for r in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        }
        if "migration_plans" not in existing_tables:
            conn.executescript("""
                CREATE TABLE IF NOT EXISTS migration_plans (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_drive_id INTEGER NOT NULL REFERENCES drives(id),
                    source_drive_name TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'draft',
                    total_files INTEGER NOT NULL DEFAULT 0,
                    files_to_copy INTEGER NOT NULL DEFAULT 0,
                    files_to_delete INTEGER NOT NULL DEFAULT 0,
                    total_bytes_to_transfer INTEGER NOT NULL DEFAULT 0,
                    files_completed INTEGER NOT NULL DEFAULT 0,
                    bytes_transferred INTEGER NOT NULL DEFAULT 0,
                    files_failed INTEGER NOT NULL DEFAULT 0,
                    errors TEXT,
                    operation_id TEXT,
                    created_at TEXT NOT NULL DEFAULT (datetime('now')),
                    started_at TEXT,
                    completed_at TEXT
                );
                CREATE TABLE IF NOT EXISTS migration_files (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    plan_id INTEGER NOT NULL REFERENCES migration_plans(id) ON DELETE CASCADE,
                    source_file_id INTEGER NOT NULL REFERENCES files(id),
                    source_path TEXT NOT NULL,
                    source_size_bytes INTEGER NOT NULL,
                    source_partial_hash TEXT,
                    target_drive_id INTEGER REFERENCES drives(id),
                    target_drive_name TEXT,
                    target_path TEXT,
                    action TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending',
                    error TEXT,
                    started_at TEXT,
                    completed_at TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_migration_files_plan_id ON migration_files(plan_id);
                CREATE INDEX IF NOT EXISTS idx_migration_files_status ON migration_files(plan_id, status);
            """)
            conn.commit()
    finally:
        conn.close()
