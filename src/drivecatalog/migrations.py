"""Schema migration system for DriveCatalog.

Provides numbered, ordered migrations with a guardrail that prevents schema
changes from silently invalidating 800K+ rows of scan data.

HOW TO ADD A NEW MIGRATION
--------------------------
1. Add a Migration(...) to the MIGRATIONS list at the bottom of this file.
2. Increment the version number by 1.
3. Set `requires_rescan`:
   - False  if existing rows remain valid after the DDL runs.
   - True   if the change means old data is wrong/incomplete and a full
            drive rescan would normally be needed to fix it.
4. If `requires_rescan=True`, you MUST provide a `data_migration` callable
   (signature: `(conn: sqlite3.Connection) -> None`) that transforms the
   existing data in-place so no rescan is needed.  If you cannot write such
   a function, the migration will refuse to apply — this is intentional.

WHAT COUNTS AS requires_rescan?
-------------------------------
Does NOT require rescan (set False):
  - Adding a nullable column with a sensible default (e.g. used_bytes)
  - Adding a brand-new table unrelated to existing scan data
  - Adding an index
  - Changing a default value for future rows only

DOES require rescan (set True, must supply data_migration):
  - Renaming or removing a column that scanners populate
  - Changing the hash algorithm (old hashes become meaningless)
  - Splitting a table that existing scan data lives in
  - Altering path normalisation (existing paths no longer match disk)

If in doubt, set requires_rescan=True and write the data_migration.  Better
safe than sorry when 9 drives worth of files are at stake.
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass, field
from typing import Callable


@dataclass
class Migration:
    """A single schema migration step."""

    version: int
    description: str
    sql: str
    requires_rescan: bool = False
    data_migration: Callable[[sqlite3.Connection], None] | None = None


# ---------------------------------------------------------------------------
# Migration registry — append-only, never reorder or delete entries.
# ---------------------------------------------------------------------------

MIGRATIONS: list[Migration] = [
    # ------------------------------------------------------------------
    # Version 1 — baseline schema
    # Uses CREATE TABLE/INDEX IF NOT EXISTS so it is idempotent for
    # databases that already had the schema applied via the old
    # schema.sql path.
    # ------------------------------------------------------------------
    Migration(
        version=1,
        description="Baseline schema: drives, files, copy_operations, media_metadata, folder_stats",
        requires_rescan=False,
        sql="""\
-- Drives table
CREATE TABLE IF NOT EXISTS drives (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    uuid TEXT UNIQUE,
    mount_path TEXT,
    total_bytes INTEGER,
    first_seen TEXT NOT NULL DEFAULT (datetime('now')),
    last_scan TEXT,
    notes TEXT
);

-- Files table
CREATE TABLE IF NOT EXISTS files (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    drive_id INTEGER NOT NULL REFERENCES drives(id) ON DELETE CASCADE,
    path TEXT NOT NULL,
    filename TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    mtime TEXT NOT NULL,
    partial_hash TEXT,
    full_hash TEXT,
    is_media INTEGER DEFAULT 0,
    first_seen TEXT NOT NULL DEFAULT (datetime('now')),
    last_verified TEXT,
    UNIQUE(drive_id, path)
);

CREATE INDEX IF NOT EXISTS idx_files_partial_hash ON files(partial_hash);
CREATE INDEX IF NOT EXISTS idx_files_drive_id ON files(drive_id);
CREATE INDEX IF NOT EXISTS idx_files_filename ON files(filename);

-- Copy operations table
CREATE TABLE IF NOT EXISTS copy_operations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    dest_drive_id INTEGER NOT NULL REFERENCES drives(id) ON DELETE CASCADE,
    dest_path TEXT NOT NULL,
    source_hash TEXT NOT NULL,
    dest_hash TEXT NOT NULL,
    verified INTEGER NOT NULL,
    bytes_copied INTEGER NOT NULL,
    started_at TEXT NOT NULL,
    completed_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_copy_operations_source_file_id ON copy_operations(source_file_id);

-- Media metadata table (extracted via ffprobe)
CREATE TABLE IF NOT EXISTS media_metadata (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_id INTEGER NOT NULL UNIQUE REFERENCES files(id) ON DELETE CASCADE,
    duration_seconds REAL,
    codec_name TEXT,
    width INTEGER,
    height INTEGER,
    frame_rate TEXT,
    bit_rate INTEGER,
    extracted_at TEXT NOT NULL DEFAULT (datetime('now')),
    integrity_verified_at TEXT,
    integrity_errors TEXT
);

CREATE INDEX IF NOT EXISTS idx_media_metadata_file_id ON media_metadata(file_id);

-- Folder-level stats for incremental (smart) scanning.
CREATE TABLE IF NOT EXISTS folder_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    drive_id INTEGER NOT NULL REFERENCES drives(id) ON DELETE CASCADE,
    path TEXT NOT NULL,
    file_count INTEGER NOT NULL DEFAULT 0,
    total_size_bytes INTEGER NOT NULL DEFAULT 0,
    child_dir_count INTEGER NOT NULL DEFAULT 0,
    dir_mtime TEXT NOT NULL,
    last_updated TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(drive_id, path)
);

CREATE INDEX IF NOT EXISTS idx_folder_stats_drive_id ON folder_stats(drive_id);
""",
    ),
    # ------------------------------------------------------------------
    # Version 2 — add used_bytes to drives
    # Nullable column, no existing data is invalidated.
    # ------------------------------------------------------------------
    Migration(
        version=2,
        description="Add used_bytes column to drives table",
        requires_rescan=False,
        sql="""\
-- SQLite ALTER TABLE ADD COLUMN is a no-op if the column already exists
-- when wrapped in a check, so we guard it manually.
-- (handled in apply_migrations via _column_exists check)
ALTER TABLE drives ADD COLUMN used_bytes INTEGER;
""",
    ),
    # ------------------------------------------------------------------
    # Version 3 — migration_plans and migration_files tables
    # Brand-new tables, no impact on existing scan data.
    # ------------------------------------------------------------------
    Migration(
        version=3,
        description="Add migration_plans and migration_files tables",
        requires_rescan=False,
        sql="""\
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
""",
    ),
]


# ---------------------------------------------------------------------------
# Migration engine
# ---------------------------------------------------------------------------

def _ensure_schema_version_table(conn: sqlite3.Connection) -> None:
    """Create the schema_version table if it does not exist."""
    conn.execute("""\
        CREATE TABLE IF NOT EXISTS schema_version (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
    """)
    conn.commit()


def _get_current_version(conn: sqlite3.Connection) -> int:
    """Return the highest applied migration version, or 0 if none."""
    row = conn.execute(
        "SELECT COALESCE(MAX(version), 0) FROM schema_version"
    ).fetchone()
    return row[0]


def _column_exists(conn: sqlite3.Connection, table: str, column: str) -> bool:
    """Check whether a column exists on a table."""
    cols = {r[1] for r in conn.execute(f"PRAGMA table_info({table})").fetchall()}
    return column in cols


def apply_migrations(conn: sqlite3.Connection) -> None:
    """Apply all pending migrations in order.

    For brand-new databases every migration runs sequentially.
    For existing databases (created before the migration system) the
    IF NOT EXISTS / column-existence guards make earlier migrations safe.

    Raises RuntimeError if a migration has requires_rescan=True but no
    data_migration callable — this is the core guardrail.
    """
    _ensure_schema_version_table(conn)
    current = _get_current_version(conn)

    for m in MIGRATIONS:
        if m.version <= current:
            continue

        # --- Guardrail: block dangerous migrations without a data fix ---
        if m.requires_rescan and m.data_migration is None:
            raise RuntimeError(
                f"Migration v{m.version} ({m.description}) requires a rescan "
                f"but no data_migration function was provided. Refusing to "
                f"apply. Either supply a data_migration that transforms "
                f"existing data in-place, or reconsider the schema change."
            )

        # --- Apply DDL ---
        # Special handling for ALTER TABLE ADD COLUMN — skip if column exists.
        # Strip SQL comment lines before detection (comments break startswith).
        sql = m.sql.strip()
        sql_no_comments = "\n".join(
            line for line in sql.splitlines()
            if not line.strip().startswith("--")
        ).strip()

        if sql_no_comments.upper().startswith("ALTER TABLE") and "ADD COLUMN" in sql_no_comments.upper():
            parts = sql_no_comments.split()
            table_name = parts[2]
            col_idx = next(
                i for i, p in enumerate(parts) if p.upper() == "COLUMN"
            ) + 1
            col_name = parts[col_idx]
            if not _column_exists(conn, table_name, col_name):
                conn.executescript(sql)
        else:
            conn.executescript(sql)

        # --- Run data migration if provided ---
        if m.data_migration is not None:
            m.data_migration(conn)

        # --- Record version ---
        conn.execute(
            "INSERT INTO schema_version (version) VALUES (?)", (m.version,)
        )
        conn.commit()
