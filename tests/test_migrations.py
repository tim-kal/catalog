"""Tests for migration backup, rollback, status file lifecycle."""

import json
import sqlite3
from pathlib import Path
from unittest.mock import patch

import pytest

import drivecatalog.migrations as migrations_mod
from drivecatalog.migrations import (
    MIGRATIONS,
    Migration,
    apply_migrations,
)


@pytest.fixture()
def migration_db(tmp_path, monkeypatch):
    """Create a DB at a known path with schema_version table only (no migrations applied).

    Returns (connection, db_path).
    """
    db_file = tmp_path / "catalog.db"
    monkeypatch.setenv("DRIVECATALOG_DB", str(db_file))
    # Point migration status at tmp dir
    monkeypatch.setattr(
        "drivecatalog.migrations._migration_status_path",
        lambda: tmp_path / "migration_status.json",
    )

    conn = sqlite3.connect(str(db_file))
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA foreign_keys = ON")
    return conn, db_file


def _get_version(conn: sqlite3.Connection) -> int:
    try:
        row = conn.execute("SELECT COALESCE(MAX(version), 0) FROM schema_version").fetchone()
        return row[0]
    except sqlite3.OperationalError:
        return 0


class TestBackupCreation:
    """Test: backup is created before migration runs, with correct filename."""

    def test_backup_created_with_correct_name(self, migration_db):
        conn, db_file = migration_db
        apply_migrations(conn, db_path=db_file)
        # Backup should be named catalog.db.backup-v0 (started from version 0)
        backup = db_file.parent / "catalog.db.backup-v0"
        assert backup.exists(), f"Expected backup at {backup}"

    def test_backup_preserves_data(self, migration_db):
        conn, db_file = migration_db
        # Apply migrations to create tables, then add some data
        apply_migrations(conn, db_path=db_file)
        conn.close()

        # Now open a fresh connection at current version and add data
        conn2 = sqlite3.connect(str(db_file))
        conn2.execute(
            "INSERT INTO drives (name, uuid, mount_path, total_bytes) "
            "VALUES ('TestDrive', 'AAAA', '/tmp', 1000)"
        )
        conn2.commit()
        current_ver = _get_version(conn2)
        conn2.close()

        # Force a new migration by adding a dummy one
        test_migration = Migration(
            version=current_ver + 1,
            description="Test migration",
            sql="SELECT 1;",
        )
        original_migrations = MIGRATIONS.copy()
        MIGRATIONS.append(test_migration)
        try:
            conn3 = sqlite3.connect(str(db_file))
            apply_migrations(conn3, db_path=db_file)
            conn3.close()
            backup = db_file.parent / f"catalog.db.backup-v{current_ver}"
            assert backup.exists()
        finally:
            MIGRATIONS.clear()
            MIGRATIONS.extend(original_migrations)


class TestRollbackOnFailure:
    """Test: if migration fails, backup is restored and DB is at old version."""

    def test_rollback_restores_backup(self, migration_db):
        conn, db_file = migration_db
        # First apply all real migrations
        apply_migrations(conn, db_path=db_file)
        conn.close()

        conn2 = sqlite3.connect(str(db_file))
        version_before = _get_version(conn2)
        conn2.close()

        # Now add a migration that will fail
        def failing_data_migration(c):
            raise ValueError("Intentional test failure")

        bad_migration = Migration(
            version=version_before + 1,
            description="Failing migration",
            requires_rescan=True,
            sql="SELECT 1;",
            data_migration=failing_data_migration,
        )
        original_migrations = MIGRATIONS.copy()
        MIGRATIONS.append(bad_migration)
        try:
            conn3 = sqlite3.connect(str(db_file))
            with pytest.raises(RuntimeError, match="Migration to v.* failed"):
                apply_migrations(conn3, db_path=db_file)

            # DB should be restored to version_before
            conn4 = sqlite3.connect(str(db_file))
            assert _get_version(conn4) == version_before
            conn4.close()
        finally:
            MIGRATIONS.clear()
            MIGRATIONS.extend(original_migrations)

    def test_failure_writes_status_file(self, migration_db, tmp_path, monkeypatch):
        conn, db_file = migration_db
        apply_migrations(conn, db_path=db_file)
        conn.close()

        conn2 = sqlite3.connect(str(db_file))
        version_before = _get_version(conn2)
        conn2.close()

        def failing_migration(c):
            raise ValueError("boom")

        bad = Migration(
            version=version_before + 1,
            description="Bad",
            requires_rescan=True,
            sql="SELECT 1;",
            data_migration=failing_migration,
        )
        original = MIGRATIONS.copy()
        MIGRATIONS.append(bad)
        try:
            conn3 = sqlite3.connect(str(db_file))
            with pytest.raises(RuntimeError):
                apply_migrations(conn3, db_path=db_file)

            status = migrations_mod.read_migration_status()
            assert status.get("failed") is True
            assert "boom" in status.get("error", "")
        finally:
            MIGRATIONS.clear()
            MIGRATIONS.extend(original)


class TestStatusFileLifecycle:
    """Test: migration_status.json is written during migration and cleaned up after."""

    def test_status_file_cleaned_up_after_success(self, migration_db):
        conn, db_file = migration_db
        apply_migrations(conn, db_path=db_file)
        # After successful migration, status file should not exist
        assert not migrations_mod._migration_status_path().exists()

    def test_status_reports_not_migrating_when_clean(self, migration_db):
        conn, db_file = migration_db
        apply_migrations(conn, db_path=db_file)
        status = migrations_mod.read_migration_status()
        assert status["migrating"] is False


class TestStaleCleanup:
    """Test: stale migration_status.json from crash is cleaned up on next start."""

    def test_stale_file_removed_on_startup(self, migration_db):
        conn, db_file = migration_db
        # Simulate a crash: write a stale status file
        migrations_mod._write_migration_status({"migrating": True, "current": 2, "total": 5})
        assert migrations_mod._migration_status_path().exists()

        # apply_migrations should clean it up at the start
        apply_migrations(conn, db_path=db_file)
        assert not migrations_mod._migration_status_path().exists()


class TestNoBackupWhenUpToDate:
    """Test: no backup created when DB is already up to date."""

    def test_no_backup_when_current(self, migration_db):
        conn, db_file = migration_db
        # Apply all migrations
        apply_migrations(conn, db_path=db_file)

        # Remove any backups
        for bak in db_file.parent.glob("*.backup-*"):
            bak.unlink()

        # Apply again — should be a no-op
        apply_migrations(conn, db_path=db_file)

        backups = list(db_file.parent.glob("*.backup-*"))
        assert len(backups) == 0, f"Unexpected backups: {backups}"


def test_migrate_clear_stale_device_serials(migration_db):
    """v9 data migration clears non-unique product-name serial placeholders."""
    conn, _ = migration_db
    apply_migrations(conn)
    conn.execute(
        "INSERT INTO drives (name, uuid, mount_path, total_bytes, device_serial) VALUES (?, ?, ?, ?, ?)",
        ("StaleSerial", "uuid-stale", "/Volumes/Stale", 123, "Samsung PSSD T7 Media"),
    )
    conn.execute(
        "INSERT INTO drives (name, uuid, mount_path, total_bytes, device_serial) VALUES (?, ?, ?, ?, ?)",
        ("RealSerial", "uuid-real", "/Volumes/Real", 123, "SN-ABC-12345"),
    )
    conn.commit()

    migrations_mod._migrate_clear_stale_device_serials(conn)

    stale = conn.execute("SELECT device_serial FROM drives WHERE name = 'StaleSerial'").fetchone()[0]
    real = conn.execute("SELECT device_serial FROM drives WHERE name = 'RealSerial'").fetchone()[0]
    assert stale is None
    assert real == "SN-ABC-12345"


class TestMigrationV10PlannedActions:
    """Test: migration v10 creates planned_actions table with correct schema."""

    def test_table_created(self, migration_db):
        conn, db_file = migration_db
        apply_migrations(conn, db_path=db_file)
        tables = {
            r[0]
            for r in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        }
        assert "planned_actions" in tables

    def test_indexes_created(self, migration_db):
        conn, db_file = migration_db
        apply_migrations(conn, db_path=db_file)
        indexes = {
            r[0]
            for r in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='index'"
            ).fetchall()
        }
        assert "idx_planned_actions_status" in indexes
        assert "idx_planned_actions_transfer_id" in indexes

    def test_insert_and_query(self, migration_db):
        conn, db_file = migration_db
        conn.row_factory = sqlite3.Row
        apply_migrations(conn, db_path=db_file)

        conn.execute(
            """
            INSERT INTO planned_actions
                (action_type, source_drive, source_path, target_drive,
                 target_path, priority, estimated_bytes, transfer_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            ("copy", "DriveA", "/photos/img.jpg", "DriveB",
             "/photos/img.jpg", 1, 4096, "batch-001"),
        )
        conn.commit()

        row = conn.execute("SELECT * FROM planned_actions WHERE id = 1").fetchone()
        assert row["action_type"] == "copy"
        assert row["status"] == "pending"  # default
        assert row["source_drive"] == "DriveA"
        assert row["target_drive"] == "DriveB"
        assert row["transfer_id"] == "batch-001"
        assert row["priority"] == 1
        assert row["estimated_bytes"] == 4096
        assert row["created_at"] is not None
        assert row["error"] is None
        assert row["depends_on"] is None

    def test_action_type_check_constraint(self, migration_db):
        conn, db_file = migration_db
        apply_migrations(conn, db_path=db_file)
        with pytest.raises(sqlite3.IntegrityError):
            conn.execute(
                "INSERT INTO planned_actions (action_type, source_drive, source_path) "
                "VALUES ('invalid', 'DriveA', '/path')"
            )

    def test_depends_on_chain(self, migration_db):
        conn, db_file = migration_db
        conn.row_factory = sqlite3.Row
        apply_migrations(conn, db_path=db_file)

        # Insert a copy action, then a delete that depends on it
        conn.execute(
            "INSERT INTO planned_actions (action_type, source_drive, source_path, "
            "target_drive, target_path) VALUES ('copy', 'A', '/f.txt', 'B', '/f.txt')"
        )
        conn.execute(
            "INSERT INTO planned_actions (action_type, source_drive, source_path, "
            "depends_on) VALUES ('delete', 'A', '/f.txt', 1)"
        )
        conn.commit()

        dep = conn.execute(
            "SELECT depends_on FROM planned_actions WHERE id = 2"
        ).fetchone()
        assert dep["depends_on"] == 1

    def test_schema_version_matches(self, migration_db):
        conn, db_file = migration_db
        apply_migrations(conn, db_path=db_file)
        from drivecatalog.migrations import SCHEMA_VERSION
        version = _get_version(conn)
        assert version == SCHEMA_VERSION
