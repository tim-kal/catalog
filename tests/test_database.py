"""Tests for database module."""

import sqlite3

from drivecatalog.database import get_connection, get_db_path, init_db


def test_get_db_path_default(monkeypatch, tmp_path):
    """Default path is under ~/.drivecatalog/."""
    monkeypatch.delenv("DRIVECATALOG_DB", raising=False)
    monkeypatch.setattr("pathlib.Path.home", lambda: tmp_path)
    db_path = get_db_path()
    assert db_path == tmp_path / ".drivecatalog" / "catalog.db"
    assert db_path.parent.exists()


def test_get_db_path_env_override(monkeypatch, tmp_path):
    """DRIVECATALOG_DB env var overrides default."""
    custom = tmp_path / "custom" / "my.db"
    monkeypatch.setenv("DRIVECATALOG_DB", str(custom))
    db_path = get_db_path()
    assert db_path == custom
    assert db_path.parent.exists()


def test_init_db_creates_tables(tmp_db):
    """init_db creates all four tables."""
    tables = [
        row[0]
        for row in tmp_db.execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        ).fetchall()
    ]
    assert "drives" in tables
    assert "files" in tables
    assert "copy_operations" in tables
    assert "media_metadata" in tables


def test_init_db_idempotent(tmp_db, monkeypatch):
    """Calling init_db twice does not error."""
    init_db()  # second call
    count = tmp_db.execute("SELECT COUNT(*) FROM drives").fetchone()[0]
    assert count == 0


def test_get_connection_row_factory(monkeypatch, tmp_path):
    """Connection has Row factory and foreign keys enabled."""
    db_file = tmp_path / "test.db"
    monkeypatch.setenv("DRIVECATALOG_DB", str(db_file))
    init_db()

    conn = get_connection()
    try:
        assert conn.row_factory == sqlite3.Row
        fk = conn.execute("PRAGMA foreign_keys").fetchone()[0]
        assert fk == 1
    finally:
        conn.close()
