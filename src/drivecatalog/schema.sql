-- DriveCatalog database schema
-- Tables: drives, files (media_metadata, copy_operations added in later phases)

-- Drives table
CREATE TABLE IF NOT EXISTS drives (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    uuid TEXT UNIQUE,
    mount_path TEXT,
    total_bytes INTEGER,
    used_bytes INTEGER,
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
    catalog_bundle TEXT,
    first_seen TEXT NOT NULL DEFAULT (datetime('now')),
    last_verified TEXT,
    UNIQUE(drive_id, path)
);

-- Indexes for common queries
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

-- Index for querying copy history of a file
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
-- Stores per-directory metadata so auto-scan can skip unchanged subtrees.
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

-- Migration plans: track full migration lifecycle for consolidating a source drive.
CREATE TABLE IF NOT EXISTS migration_plans (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_drive_id INTEGER NOT NULL REFERENCES drives(id),
    source_drive_name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'draft',  -- draft, validated, executing, completed, failed, cancelled
    total_files INTEGER NOT NULL DEFAULT 0,
    files_to_copy INTEGER NOT NULL DEFAULT 0,
    files_to_delete INTEGER NOT NULL DEFAULT 0,  -- already backed up, just need source deleted
    total_bytes_to_transfer INTEGER NOT NULL DEFAULT 0,
    files_completed INTEGER NOT NULL DEFAULT 0,
    bytes_transferred INTEGER NOT NULL DEFAULT 0,
    files_failed INTEGER NOT NULL DEFAULT 0,
    errors TEXT,  -- JSON array of error strings
    operation_id TEXT,  -- links to in-memory operation tracker
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    started_at TEXT,
    completed_at TEXT
);

-- Migration files: per-file entries within a migration plan.
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
    action TEXT NOT NULL,  -- 'copy_and_delete' or 'delete_only'
    status TEXT NOT NULL DEFAULT 'pending',  -- pending, copying, verifying, verified, deleted, failed, skipped
    error TEXT,
    started_at TEXT,
    completed_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_migration_files_plan_id ON migration_files(plan_id);
CREATE INDEX IF NOT EXISTS idx_migration_files_status ON migration_files(plan_id, status);
