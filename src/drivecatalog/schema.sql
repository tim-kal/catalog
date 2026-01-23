-- DriveCatalog database schema
-- Tables: drives, files (media_metadata, copy_operations added in later phases)

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

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_files_partial_hash ON files(partial_hash);
CREATE INDEX IF NOT EXISTS idx_files_drive_id ON files(drive_id);
CREATE INDEX IF NOT EXISTS idx_files_filename ON files(filename);
