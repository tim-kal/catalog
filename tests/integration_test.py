#!/usr/bin/env python3
"""
DriveSnapshots Integration Test Suite
=====================================
Staged real-world testing with escalating complexity.

Stage 1: Two small drives, 3 files each. Mount/unmount survival.
Stage 2: Five drives, hundreds of files, various sizes including large.
Stage 3: Deletion and backup integrity verification.
Stage 4: Duplicate detection across drives at scale.
Stage 5: Copy & verify with hash validation.
"""

import hashlib
import json
import os
import random
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

# Configuration
VOLUMES = Path("/Volumes")
DB_PATH = Path.home() / ".drivecatalog" / "catalog.db"
PYTHON = str(Path.home() / "code" / "DriveSnapshots" / ".venv" / "bin" / "python")
PROJECT = Path.home() / "code" / "DriveSnapshots"

# Test state
results = {"passed": 0, "failed": 0, "errors": []}


def run_cli(*args, expect_fail=False):
    """Run a drivecatalog CLI command."""
    cmd = [PYTHON, "-m", "drivecatalog"] + list(args)
    result = subprocess.run(
        cmd, capture_output=True, text=True, cwd=str(PROJECT),
        env={**os.environ, "HOME": str(Path.home())}
    )
    if not expect_fail and result.returncode != 0:
        print(f"  COMMAND FAILED: {' '.join(args)}")
        print(f"  STDERR: {result.stderr[:500]}")
    return result


def check(name, condition, detail=""):
    """Assert a test condition."""
    if condition:
        results["passed"] += 1
        print(f"  ✓ {name}")
    else:
        results["failed"] += 1
        results["errors"].append(f"{name}: {detail}")
        print(f"  ✗ {name} — {detail}")


def query_db(sql, params=()):
    """Query the catalog database."""
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(sql, params).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


def create_file(path, size_bytes, content=None):
    """Create a file with specific size. If content given, use it (for duplicates)."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if content is not None:
        path.write_bytes(content)
    else:
        # Random content
        path.write_bytes(os.urandom(size_bytes))


def file_sha256(path):
    """Get SHA256 of a file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(8192):
            h.update(chunk)
    return h.hexdigest()


def clean_all():
    """Reset everything for a clean test run."""
    # Remove test drives
    for d in VOLUMES.glob("TestDrive*"):
        shutil.rmtree(d, ignore_errors=True)
    # Remove database
    if DB_PATH.exists():
        DB_PATH.unlink()
    # Re-init
    run_cli("--version")


# ============================================================
# STAGE 1: Two small drives, mount/unmount survival
# ============================================================
def stage_1():
    print("\n" + "=" * 60)
    print("STAGE 1: Two drives, 3 files each, mount/unmount")
    print("=" * 60)

    # Create two drives
    driveA = VOLUMES / "TestDriveA"
    driveB = VOLUMES / "TestDriveB"

    for d in [driveA, driveB]:
        d.mkdir(parents=True, exist_ok=True)

    # Populate with files
    shared_content = os.urandom(1024)  # 1KB shared between drives (duplicate)

    create_file(driveA / "readme.txt", 256)
    create_file(driveA / "photo.jpg", 4096)
    create_file(driveA / "shared.dat", 0, content=shared_content)

    create_file(driveB / "notes.md", 512)
    create_file(driveB / "video.mp4", 8192)
    create_file(driveB / "shared.dat", 0, content=shared_content)

    # Register drives
    r = run_cli("drives", "add", str(driveA), "--name", "TestDriveA")
    check("Add drive A", r.returncode == 0, r.stderr)

    r = run_cli("drives", "add", str(driveB), "--name", "TestDriveB")
    check("Add drive B", r.returncode == 0, r.stderr)

    # List drives
    r = run_cli("drives", "list")
    check("List shows 2 drives", "TestDriveA" in r.stdout and "TestDriveB" in r.stdout, r.stdout[:200])

    # Scan both
    r = run_cli("drives", "scan", "TestDriveA")
    check("Scan drive A", r.returncode == 0, r.stderr)

    r = run_cli("drives", "scan", "TestDriveB")
    check("Scan drive B", r.returncode == 0, r.stderr)

    # Verify file counts in DB
    files_a = query_db("SELECT COUNT(*) as cnt FROM files f JOIN drives d ON f.drive_id=d.id WHERE d.name='TestDriveA'")
    check("Drive A has 3 files", files_a[0]["cnt"] == 3, f"got {files_a[0]['cnt']}")

    files_b = query_db("SELECT COUNT(*) as cnt FROM files f JOIN drives d ON f.drive_id=d.id WHERE d.name='TestDriveB'")
    check("Drive B has 3 files", files_b[0]["cnt"] == 3, f"got {files_b[0]['cnt']}")

    # Hash both
    r = run_cli("drives", "hash", "TestDriveA")
    check("Hash drive A", r.returncode == 0, r.stderr)

    r = run_cli("drives", "hash", "TestDriveB")
    check("Hash drive B", r.returncode == 0, r.stderr)

    # Check hashes in DB
    hashed = query_db("SELECT COUNT(*) as cnt FROM files WHERE partial_hash IS NOT NULL")
    check("All 6 files hashed", hashed[0]["cnt"] == 6, f"got {hashed[0]['cnt']}")

    # Check duplicate detection
    r = run_cli("drives", "duplicates")
    check("Duplicates found (shared.dat)", "shared.dat" in r.stdout or "1 duplicate" in r.stdout.lower() or "cluster" in r.stdout.lower(),
          f"output: {r.stdout[:300]}")

    dups = query_db("""
        SELECT partial_hash, COUNT(*) as cnt
        FROM files WHERE partial_hash IS NOT NULL
        GROUP BY partial_hash HAVING cnt > 1
    """)
    check("DB has 1 duplicate cluster", len(dups) == 1, f"got {len(dups)} clusters")

    # Search
    r = run_cli("drives", "search", "*.jpg")
    check("Search finds photo.jpg", "photo.jpg" in r.stdout, r.stdout[:200])

    r = run_cli("drives", "search", "*.mp4")
    check("Search finds video.mp4", "video.mp4" in r.stdout, r.stdout[:200])

    # ---- UNMOUNT SIMULATION ----
    print("\n  --- Simulating drive unmount ---")
    driveA_backup = VOLUMES / "_unmounted_TestDriveA"
    driveA.rename(driveA_backup)

    # Drive A is "unmounted" — path doesn't exist
    check("Drive A path gone", not driveA.exists())

    # But catalog should still have the data
    files_a_after = query_db("SELECT COUNT(*) as cnt FROM files f JOIN drives d ON f.drive_id=d.id WHERE d.name='TestDriveA'")
    check("Snapshot survives unmount: 3 files still in DB", files_a_after[0]["cnt"] == 3)

    # Search should still find files from unmounted drive
    r = run_cli("drives", "search", "photo.jpg")
    check("Search still finds photo.jpg from unmounted drive", "photo.jpg" in r.stdout, r.stdout[:200])

    # Duplicate detection should still work
    dups_after = query_db("""
        SELECT partial_hash, COUNT(*) as cnt
        FROM files WHERE partial_hash IS NOT NULL
        GROUP BY partial_hash HAVING cnt > 1
    """)
    check("Duplicates still detected after unmount", len(dups_after) == 1)

    # ---- REMOUNT ----
    print("\n  --- Simulating drive remount ---")
    driveA_backup.rename(driveA)
    check("Drive A remounted", driveA.exists())

    # Rescan should work
    r = run_cli("drives", "scan", "TestDriveA")
    check("Rescan after remount works", r.returncode == 0, r.stderr)

    print(f"\n  Stage 1 complete: {results['passed']} passed, {results['failed']} failed")


# ============================================================
# STAGE 2: Five drives, hundreds of files, various sizes
# ============================================================
def stage_2():
    print("\n" + "=" * 60)
    print("STAGE 2: Five drives, hundreds of files, big and small")
    print("=" * 60)

    drives_config = {
        "TestDrive_Photos": {
            "dirs": ["2023", "2024", "2025", "2025/January", "2025/February", "2025/March"],
            "files_per_dir": 15,
            "size_range": (50_000, 500_000),  # 50KB-500KB (simulating photos)
            "extensions": [".jpg", ".png", ".heic", ".raw"],
        },
        "TestDrive_Video": {
            "dirs": ["Projects", "Projects/FilmA", "Projects/FilmB", "Exports", "Raw"],
            "files_per_dir": 8,
            "size_range": (100_000, 2_000_000),  # 100KB-2MB (simulated video)
            "extensions": [".mp4", ".mov", ".mxf"],
        },
        "TestDrive_Backup": {
            "dirs": ["Documents", "Documents/Work", "Documents/Personal", "Archive", "Archive/2023", "Archive/2024"],
            "files_per_dir": 20,
            "size_range": (1_000, 100_000),  # 1KB-100KB
            "extensions": [".txt", ".pdf", ".docx", ".md"],
        },
        "TestDrive_Music": {
            "dirs": ["Albums", "Albums/Jazz", "Albums/Electronic", "Playlists", "Podcasts"],
            "files_per_dir": 12,
            "size_range": (200_000, 1_000_000),  # 200KB-1MB
            "extensions": [".mp3", ".flac", ".wav"],
        },
        "TestDrive_Mixed": {
            "dirs": ["Downloads", "Desktop", "Misc"],
            "files_per_dir": 25,
            "size_range": (500, 50_000),
            "extensions": [".txt", ".jpg", ".pdf", ".zip", ".py", ".sh"],
        },
    }

    total_files_created = 0

    for drive_name, config in drives_config.items():
        drive_path = VOLUMES / drive_name
        drive_path.mkdir(parents=True, exist_ok=True)

        files_created = 0
        for subdir in config["dirs"]:
            dir_path = drive_path / subdir
            dir_path.mkdir(parents=True, exist_ok=True)

            for i in range(config["files_per_dir"]):
                ext = random.choice(config["extensions"])
                size = random.randint(*config["size_range"])
                fname = f"file_{subdir.replace('/', '_')}_{i:03d}{ext}"
                create_file(dir_path / fname, size)
                files_created += 1

        total_files_created += files_created

        # Register and scan
        r = run_cli("drives", "add", str(drive_path), "--name", drive_name)
        check(f"Add {drive_name}", r.returncode == 0, r.stderr)

        r = run_cli("drives", "scan", drive_name)
        check(f"Scan {drive_name} ({files_created} files)", r.returncode == 0, r.stderr)

    print(f"\n  Total files created: {total_files_created}")

    # Verify total file count
    total_db = query_db("SELECT COUNT(*) as cnt FROM files")
    # Stage 1 had 6 files + stage 2 files
    expected_min = total_files_created + 6
    check(f"DB has all files ({total_db[0]['cnt']})", total_db[0]["cnt"] >= total_files_created,
          f"expected >= {total_files_created}, got {total_db[0]['cnt']}")

    # Hash all new drives
    for drive_name in drives_config:
        r = run_cli("drives", "hash", drive_name)
        check(f"Hash {drive_name}", r.returncode == 0, r.stderr)

    # Verify hashing
    unhashed = query_db("SELECT COUNT(*) as cnt FROM files WHERE partial_hash IS NULL")
    check("All files hashed", unhashed[0]["cnt"] == 0, f"{unhashed[0]['cnt']} unhashed files remain")

    # Test big file
    print("\n  --- Testing large file ---")
    big_drive = VOLUMES / "TestDrive_Video"
    big_file = big_drive / "Raw" / "massive_clip.mxf"
    # Create a 50MB sparse file (fast to create, tests large file handling)
    with open(big_file, "wb") as f:
        f.write(os.urandom(1024 * 1024))  # 1MB real data at start
        f.seek(50 * 1024 * 1024 - 1)  # seek to 50MB
        f.write(b"\0")

    r = run_cli("drives", "scan", "TestDrive_Video")
    check("Rescan with big file", r.returncode == 0, r.stderr)

    r = run_cli("drives", "hash", "TestDrive_Video")
    check("Hash big file", r.returncode == 0, r.stderr)

    big_in_db = query_db("SELECT * FROM files WHERE filename='massive_clip.mxf'")
    check("Big file in DB", len(big_in_db) == 1)
    check("Big file has hash", big_in_db[0]["partial_hash"] is not None if big_in_db else False)
    check("Big file size correct (50MB)", big_in_db[0]["size_bytes"] == 50 * 1024 * 1024 if big_in_db else False,
          f"got {big_in_db[0]['size_bytes'] if big_in_db else 'N/A'}")

    # Search across all drives
    r = run_cli("drives", "search", "*.mp4", "--limit", "500")
    check("Cross-drive search works", r.returncode == 0, r.stderr)

    # Test directory browsing via API
    print("\n  --- Testing directory structure ---")
    photos_dirs = query_db("""
        SELECT DISTINCT
            CASE WHEN path LIKE '%/%' THEN SUBSTR(path, 1, INSTR(path, '/') - 1) ELSE '' END as top_dir
        FROM files f JOIN drives d ON f.drive_id=d.id
        WHERE d.name='TestDrive_Photos'
    """)
    check("Photos drive has subdirectories", len(photos_dirs) > 1, f"got {len(photos_dirs)} top dirs")

    print(f"\n  Stage 2 complete: {results['passed']} passed, {results['failed']} failed")


# ============================================================
# STAGE 3: Deletion and backup integrity verification
# ============================================================
def stage_3():
    print("\n" + "=" * 60)
    print("STAGE 3: Deletion testing and backup integrity")
    print("=" * 60)

    # Create deliberate duplicates across drives for backup testing
    print("\n  --- Creating known duplicates for backup verification ---")
    backup_content_1 = os.urandom(2048)  # "important document"
    backup_content_2 = os.urandom(4096)  # "critical spreadsheet"
    backup_content_3 = os.urandom(8192)  # "key presentation"

    # Put them on multiple drives
    for name, content in [
        ("important_doc.pdf", backup_content_1),
        ("critical_sheet.xlsx", backup_content_2),
        ("key_presentation.pptx", backup_content_3),
    ]:
        for drive in ["TestDrive_Backup", "TestDrive_Mixed", "TestDriveA"]:
            drive_path = VOLUMES / drive
            if drive_path.exists():
                create_file(drive_path / "backup_test" / name, 0, content=content)

    # Rescan affected drives
    for drive in ["TestDrive_Backup", "TestDrive_Mixed", "TestDriveA"]:
        r = run_cli("drives", "scan", drive)
        r = run_cli("drives", "hash", drive)

    # Verify duplicates detected
    dups = query_db("""
        SELECT partial_hash, COUNT(*) as cnt
        FROM files WHERE partial_hash IS NOT NULL
        GROUP BY partial_hash HAVING cnt > 1
        ORDER BY cnt DESC
    """)
    three_copy_dups = [d for d in dups if d["cnt"] >= 3]
    check("3-copy duplicates detected (backup files)", len(three_copy_dups) >= 3,
          f"got {len(three_copy_dups)} clusters with 3+ copies")

    # --- Test: Delete files from one drive, verify backup claim ---
    print("\n  --- Delete from primary, verify backup exists ---")

    # Record the hash of important_doc.pdf before deletion
    doc_hash = query_db("""
        SELECT f.partial_hash, f.path, d.name as drive, d.mount_path
        FROM files f JOIN drives d ON f.drive_id=d.id
        WHERE f.filename='important_doc.pdf'
    """)
    check("important_doc.pdf tracked on 3 drives", len(doc_hash) == 3, f"got {len(doc_hash)}")

    if doc_hash:
        the_hash = doc_hash[0]["partial_hash"]

        # Delete the file from TestDriveA physically
        physical_path = Path(VOLUMES / "TestDriveA" / "backup_test" / "important_doc.pdf")
        if physical_path.exists():
            physical_path.unlink()
            check("Physical file deleted from DriveA", not physical_path.exists())

        # Rescan DriveA — the file should disappear from its catalog
        r = run_cli("drives", "scan", "TestDriveA")
        check("Rescan after deletion", r.returncode == 0, r.stderr)

        # Check: DB should now show the file only on 2 drives
        doc_after = query_db("""
            SELECT f.path, d.name as drive, d.mount_path
            FROM files f JOIN drives d ON f.drive_id=d.id
            WHERE f.partial_hash=?
        """, (the_hash,))

        check("File removed from DriveA catalog after rescan",
              not any(d["drive"] == "TestDriveA" for d in doc_after),
              f"drives: {[d['drive'] for d in doc_after]}")

        check("Backup still exists on 2 other drives", len(doc_after) >= 2,
              f"got {len(doc_after)} copies")

        # CRITICAL: Verify the backup files ACTUALLY exist on disk
        print("\n  --- INTEGRITY CHECK: Do backup claims match reality? ---")
        for backup in doc_after:
            real_path = Path(backup["mount_path"]) / backup["path"]
            exists = real_path.exists()
            check(f"Backup on {backup['drive']} actually exists at {real_path}", exists)

    # --- Test: What happens when a drive is unmounted but catalog says backup exists ---
    print("\n  --- Unmount a backup drive, check integrity claims ---")

    # Unmount TestDrive_Backup
    backup_path = VOLUMES / "TestDrive_Backup"
    backup_stash = VOLUMES / "_stashed_Backup"
    if backup_path.exists():
        backup_path.rename(backup_stash)

    # The catalog still says files are on TestDrive_Backup
    backup_files = query_db("""
        SELECT f.path, d.name, d.mount_path
        FROM files f JOIN drives d ON f.drive_id=d.id
        WHERE d.name='TestDrive_Backup'
    """)
    check("Catalog still has TestDrive_Backup files", len(backup_files) > 0,
          f"got {len(backup_files)}")

    # But the mount path doesn't exist!
    check("TestDrive_Backup is unmounted (path gone)", not backup_path.exists())

    # Verify: for each file claimed on Backup drive, check if it really exists
    phantom_count = 0
    for bf in backup_files[:10]:  # check first 10
        real_path = Path(bf["mount_path"]) / bf["path"]
        if not real_path.exists():
            phantom_count += 1

    check("Phantom files detected (claimed but unmounted)",
          phantom_count > 0,
          f"{phantom_count} phantom files out of {min(10, len(backup_files))} checked")

    # This is the key insight: the catalog should distinguish between
    # "file exists in catalog" and "file is currently accessible"
    # Let's check if the drives list shows mounted status
    r = run_cli("drives", "list")
    # The output should ideally show TestDrive_Backup as unmounted
    check("Drive list output available", r.returncode == 0, r.stderr)

    # Restore backup drive
    backup_stash.rename(backup_path)
    check("TestDrive_Backup restored", backup_path.exists())

    # --- Test: Delete entire directory ---
    print("\n  --- Delete entire directory, verify catalog updates ---")
    photos_2023 = VOLUMES / "TestDrive_Photos" / "2023"
    files_before = query_db("""
        SELECT COUNT(*) as cnt FROM files f JOIN drives d ON f.drive_id=d.id
        WHERE d.name='TestDrive_Photos' AND f.path LIKE '2023/%'
    """)
    count_2023 = files_before[0]["cnt"]

    if photos_2023.exists():
        shutil.rmtree(photos_2023)
        check("2023 directory deleted", not photos_2023.exists())

        r = run_cli("drives", "scan", "TestDrive_Photos")
        check("Rescan after directory deletion", r.returncode == 0, r.stderr)

        files_after = query_db("""
            SELECT COUNT(*) as cnt FROM files f JOIN drives d ON f.drive_id=d.id
            WHERE d.name='TestDrive_Photos' AND f.path LIKE '2023/%'
        """)
        check(f"2023 files removed from catalog ({count_2023} -> {files_after[0]['cnt']})",
              files_after[0]["cnt"] == 0,
              f"still has {files_after[0]['cnt']} files")

    print(f"\n  Stage 3 complete: {results['passed']} passed, {results['failed']} failed")


# ============================================================
# STAGE 4: Duplicate detection at scale
# ============================================================
def stage_4():
    print("\n" + "=" * 60)
    print("STAGE 4: Duplicate detection at scale")
    print("=" * 60)

    # Create intentional duplicates across multiple drives
    print("  Creating 50 unique files duplicated across 3 drives...")
    dup_contents = [os.urandom(random.randint(1000, 50000)) for _ in range(50)]

    for i, content in enumerate(dup_contents):
        ext = random.choice([".jpg", ".mp4", ".pdf", ".txt"])
        # Put on 2-3 random drives
        target_drives = random.sample(
            ["TestDrive_Photos", "TestDrive_Video", "TestDrive_Backup", "TestDrive_Mixed"],
            k=random.randint(2, 3)
        )
        for drive in target_drives:
            drive_path = VOLUMES / drive
            if drive_path.exists():
                fname = f"duptest_{i:03d}{ext}"
                create_file(drive_path / "dup_test" / fname, 0, content=content)

    # Rescan and rehash all drives
    for drive in ["TestDrive_Photos", "TestDrive_Video", "TestDrive_Backup", "TestDrive_Mixed"]:
        run_cli("drives", "scan", drive)
        run_cli("drives", "hash", drive)

    # Check duplicate stats
    r = run_cli("drives", "duplicates")
    check("Duplicate command runs", r.returncode == 0, r.stderr)

    dup_stats = query_db("""
        SELECT partial_hash, COUNT(*) as cnt,
               SUM(size_bytes) as total_size
        FROM files WHERE partial_hash IS NOT NULL
        GROUP BY partial_hash HAVING cnt > 1
    """)
    check(f"Duplicate clusters detected: {len(dup_stats)}", len(dup_stats) >= 50,
          f"expected >= 50, got {len(dup_stats)}")

    # Calculate reclaimable space
    reclaimable = sum(
        d["total_size"] - (d["total_size"] // d["cnt"])  # total - one copy
        for d in dup_stats
    )
    print(f"  Reclaimable space: {reclaimable / 1024 / 1024:.1f} MB")
    check("Reclaimable space > 0", reclaimable > 0)

    # Verify each duplicate cluster has files on different drives
    cross_drive_dups = 0
    for ds in dup_stats[:20]:  # check 20 clusters
        cluster_drives = query_db("""
            SELECT DISTINCT d.name FROM files f JOIN drives d ON f.drive_id=d.id
            WHERE f.partial_hash=?
        """, (ds["partial_hash"],))
        if len(cluster_drives) > 1:
            cross_drive_dups += 1

    check(f"Cross-drive duplicates found: {cross_drive_dups}/20",
          cross_drive_dups > 10,
          f"only {cross_drive_dups} clusters span multiple drives")

    print(f"\n  Stage 4 complete: {results['passed']} passed, {results['failed']} failed")


# ============================================================
# STAGE 5: Copy and verify
# ============================================================
def stage_5():
    print("\n" + "=" * 60)
    print("STAGE 5: Copy and verify")
    print("=" * 60)

    # Find a file to copy
    source_file = query_db("""
        SELECT f.path, f.filename, d.name as drive, d.mount_path, f.size_bytes
        FROM files f JOIN drives d ON f.drive_id=d.id
        WHERE d.name='TestDriveA' AND f.filename != 'shared.dat'
        LIMIT 1
    """)

    if not source_file:
        check("Source file found for copy", False, "no files on TestDriveA")
        return

    src = source_file[0]
    src_real_path = Path(src["mount_path"]) / src["path"]
    check(f"Source file exists: {src['filename']}", src_real_path.exists())

    # Copy to TestDriveB
    dest_path = f"copies/{src['filename']}"
    r = run_cli("drives", "copy", "TestDriveA", src["path"], "TestDriveB", "--dest-path", dest_path)
    check("Copy command succeeds", r.returncode == 0, r.stderr)

    # Verify the copy exists
    dest_real_path = VOLUMES / "TestDriveB" / dest_path
    check("Copied file exists on disk", dest_real_path.exists())

    if src_real_path.exists() and dest_real_path.exists():
        src_hash = file_sha256(src_real_path)
        dst_hash = file_sha256(dest_real_path)
        check("SHA256 matches (verified copy)", src_hash == dst_hash,
              f"src={src_hash[:16]}... dst={dst_hash[:16]}...")

        check("File sizes match",
              src_real_path.stat().st_size == dest_real_path.stat().st_size)

    print(f"\n  Stage 5 complete: {results['passed']} passed, {results['failed']} failed")


# ============================================================
# MAIN
# ============================================================
def main():
    print("DriveSnapshots Integration Test Suite")
    print("=" * 60)
    print(f"DB: {DB_PATH}")
    print(f"Volumes: {VOLUMES}")
    start = time.time()

    # Create /Volumes if it doesn't exist (Linux)
    VOLUMES.mkdir(parents=True, exist_ok=True)

    # Clean slate
    print("\nCleaning previous test data...")
    clean_all()

    try:
        stage_1()
        stage_2()
        stage_3()
        stage_4()
        stage_5()
    except Exception as e:
        print(f"\n  FATAL ERROR: {e}")
        import traceback
        traceback.print_exc()
        results["failed"] += 1
        results["errors"].append(f"FATAL: {e}")

    elapsed = time.time() - start

    print("\n" + "=" * 60)
    print("FINAL RESULTS")
    print("=" * 60)
    print(f"  Passed: {results['passed']}")
    print(f"  Failed: {results['failed']}")
    print(f"  Time:   {elapsed:.1f}s")

    if results["errors"]:
        print(f"\n  FAILURES:")
        for err in results["errors"]:
            print(f"    • {err}")

    # Write report
    report_path = PROJECT / ".agents" / "integration-test-report.md"
    with open(report_path, "w") as f:
        f.write(f"# Integration Test Report\n\n")
        f.write(f"**Date:** {time.strftime('%Y-%m-%d %H:%M')}\n")
        f.write(f"**Duration:** {elapsed:.1f}s\n")
        f.write(f"**Passed:** {results['passed']}\n")
        f.write(f"**Failed:** {results['failed']}\n\n")
        if results["errors"]:
            f.write("## Failures\n\n")
            for err in results["errors"]:
                f.write(f"- {err}\n")
        f.write(f"\n## Summary\n\n")
        f.write(f"Tested: 2 small drives (mount/unmount), 5 large drives (hundreds of files),\n")
        f.write(f"big file handling (50MB), deletion tracking, backup integrity verification,\n")
        f.write(f"duplicate detection at scale (50 cross-drive duplicates), verified copy.\n")

    print(f"\n  Report: {report_path}")

    # Cleanup
    print("\nCleaning up test data...")
    for d in VOLUMES.glob("TestDrive*"):
        shutil.rmtree(d, ignore_errors=True)
    for d in VOLUMES.glob("_*"):
        shutil.rmtree(d, ignore_errors=True)
    if DB_PATH.exists():
        DB_PATH.unlink()

    return 0 if results["failed"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
