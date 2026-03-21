#!/usr/bin/env python3
"""Hash ordering benchmark for DriveCatalog.

Tests whether the order in which files are hashed affects throughput,
especially on HDDs where seek time dominates. Reads the file list from
the existing catalog database, applies different ordering strategies to
the same set of sampled files, and measures wall-clock throughput.

Usage:
    python benchmarks/hash_ordering.py --drive MyDrive
    python benchmarks/hash_ordering.py --drive MyDrive --sample 10000
    python benchmarks/hash_ordering.py --drive MyDrive --db /path/to/catalog.db

Interpreting results:
    - "vs Random" shows the percentage improvement over the random baseline.
    - On HDDs, path_sorted and directory_batched should show significant
      improvement because they reduce seek distance between consecutive reads.
    - On SSDs, all strategies should perform similarly since seek time is ~0.
    - If caches are warm (non-root), later strategies may appear faster.
      Run as root for cache-clearing between strategies, or interpret
      relative ordering with that caveat in mind.

The script is read-only: it never writes to the database.
"""

import argparse
import os
import platform
import random
import sqlite3
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path

import xxhash

# Match the chunk size used in drivecatalog.hasher
CHUNK_SIZE = 64 * 1024

WARMUP_FILES = 100
PROGRESS_INTERVAL = 500


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Benchmark file hashing throughput under different ordering strategies."
    )
    parser.add_argument(
        "--drive",
        required=True,
        help="Name of the drive to benchmark (must exist in catalog DB).",
    )
    parser.add_argument(
        "--sample",
        type=int,
        default=5000,
        help="Number of files to hash per strategy (default: 5000).",
    )
    parser.add_argument(
        "--db",
        type=str,
        default=None,
        help="Path to catalog.db (default: ~/.drivecatalog/catalog.db).",
    )
    return parser.parse_args()


def get_db_path(override: str | None) -> Path:
    if override:
        return Path(override)
    return Path.home() / ".drivecatalog" / "catalog.db"


def load_files(db_path: Path, drive_name: str) -> tuple[str, list[dict]]:
    """Load hashed files for a drive from the catalog database.

    Returns (mount_path, list of file dicts with keys: path, size_bytes).
    """
    conn = sqlite3.connect(str(db_path), timeout=30)
    conn.row_factory = sqlite3.Row
    try:
        row = conn.execute(
            "SELECT id, mount_path FROM drives WHERE name = ?", (drive_name,)
        ).fetchone()
        if row is None:
            available = conn.execute("SELECT name FROM drives").fetchall()
            names = ", ".join(r["name"] for r in available) if available else "(none)"
            print(f"Error: drive '{drive_name}' not found. Available drives: {names}")
            sys.exit(1)

        drive_id = row["id"]
        mount_path = row["mount_path"] or ""

        rows = conn.execute(
            """
            SELECT path, size_bytes
            FROM files
            WHERE drive_id = ? AND partial_hash IS NOT NULL
            """,
            (drive_id,),
        ).fetchall()

        files = [{"path": r["path"], "size_bytes": r["size_bytes"]} for r in rows]
        return mount_path, files
    finally:
        conn.close()


def hash_file(file_path: Path, size_bytes: int) -> bool:
    """Hash a single file using the same algorithm as drivecatalog.hasher.

    Returns True if hashing succeeded, False on error.
    """
    try:
        hasher = xxhash.xxh64()
        with open(file_path, "rb") as f:
            if size_bytes < CHUNK_SIZE * 2:
                content = f.read()
                hasher.update(content)
            else:
                first_chunk = f.read(CHUNK_SIZE)
                hasher.update(first_chunk)
                f.seek(-CHUNK_SIZE, 2)
                last_chunk = f.read(CHUNK_SIZE)
                hasher.update(last_chunk)
        hasher.update(str(size_bytes).encode())
        return True
    except (OSError, PermissionError):
        return False


def bytes_read_for_file(size_bytes: int) -> int:
    """How many bytes we actually read from this file."""
    if size_bytes < CHUNK_SIZE * 2:
        return size_bytes
    return CHUNK_SIZE * 2


def seeks_for_file(size_bytes: int) -> int:
    """Number of seek operations for this file (1 for small, 2 for large)."""
    if size_bytes < CHUNK_SIZE * 2:
        return 1  # single sequential read
    return 2  # read head, seek to tail, read tail


def drop_caches() -> bool:
    """Try to drop filesystem caches. Returns True if successful."""
    system = platform.system()
    if system == "Linux":
        try:
            subprocess.run(
                ["sync"],
                check=True,
                capture_output=True,
            )
            Path("/proc/sys/vm/drop_caches").write_text("3")
            return True
        except (PermissionError, OSError):
            return False
    elif system == "Darwin":
        try:
            subprocess.run(
                ["sync"],
                check=True,
                capture_output=True,
            )
            subprocess.run(
                ["purge"],
                check=True,
                capture_output=True,
            )
            return True
        except (PermissionError, OSError, FileNotFoundError):
            return False
    return False


def apply_strategy(files: list[dict], strategy: str) -> list[dict]:
    """Return a reordered copy of the file list according to the strategy."""
    if strategy == "random":
        result = files.copy()
        random.shuffle(result)
        return result

    if strategy == "path_sorted":
        return sorted(files, key=lambda f: f["path"])

    if strategy == "path_reverse":
        return sorted(files, key=lambda f: f["path"], reverse=True)

    if strategy == "size_asc":
        return sorted(files, key=lambda f: f["size_bytes"])

    if strategy == "size_desc":
        return sorted(files, key=lambda f: f["size_bytes"], reverse=True)

    if strategy == "directory_batched":
        by_dir: dict[str, list[dict]] = defaultdict(list)
        for f in files:
            parent = str(Path(f["path"]).parent)
            by_dir[parent].append(f)
        result = []
        for dir_path in sorted(by_dir.keys()):
            dir_files = sorted(by_dir[dir_path], key=lambda f: f["path"])
            result.extend(dir_files)
        return result

    raise ValueError(f"Unknown strategy: {strategy}")


def run_benchmark(
    files: list[dict],
    mount_path: str,
    label: str,
) -> dict:
    """Hash all files and return timing statistics."""
    total_bytes_read = 0
    total_seeks = 0
    errors = 0
    hashed = 0

    start = time.perf_counter()
    for i, f in enumerate(files):
        file_path = Path(mount_path) / f["path"] if mount_path else Path(f["path"])
        size = f["size_bytes"]

        ok = hash_file(file_path, size)
        if ok:
            hashed += 1
            total_bytes_read += bytes_read_for_file(size)
            total_seeks += seeks_for_file(size)
        else:
            errors += 1

        if (i + 1) % PROGRESS_INTERVAL == 0:
            elapsed = time.perf_counter() - start
            rate = (i + 1) / elapsed if elapsed > 0 else 0
            print(f"  [{label}] {i + 1}/{len(files)} files  ({rate:.0f} files/s)", flush=True)

    elapsed = time.perf_counter() - start
    return {
        "strategy": label,
        "files": len(files),
        "hashed": hashed,
        "errors": errors,
        "time_s": elapsed,
        "files_per_s": hashed / elapsed if elapsed > 0 else 0,
        "mb_per_s": (total_bytes_read / (1024 * 1024)) / elapsed if elapsed > 0 else 0,
        "total_seeks": total_seeks,
        "total_bytes_read": total_bytes_read,
    }


def main() -> None:
    args = parse_args()
    db_path = get_db_path(args.db)

    if not db_path.exists():
        print(f"Error: database not found at {db_path}")
        sys.exit(1)

    print(f"Database: {db_path}")
    print(f"Drive: {args.drive}")
    print(f"Sample size: {args.sample}")
    print()

    # Load files from database
    mount_path, all_files = load_files(db_path, args.drive)
    print(f"Mount path: {mount_path}")
    print(f"Total hashed files in DB: {len(all_files)}")

    if not all_files:
        print("Error: no hashed files found for this drive.")
        sys.exit(1)

    # Sample files
    if len(all_files) <= args.sample:
        sample = all_files
        print(f"Using all {len(sample)} files (fewer than sample size)")
    else:
        random.seed(42)  # reproducible sample across strategies
        sample = random.sample(all_files, args.sample)
        print(f"Sampled {len(sample)} files (seed=42 for reproducibility)")

    # Compute expected read volume
    total_read = sum(bytes_read_for_file(f["size_bytes"]) for f in sample)
    print(f"Expected read per strategy: {total_read / (1024 * 1024):.1f} MB")
    print()

    # Check cache clearing
    can_clear = drop_caches()
    if can_clear:
        print("Cache clearing: enabled (running with sufficient privileges)")
    else:
        print(
            "Cache clearing: DISABLED (not running as root / purge unavailable). "
            "Results may be affected by warm caches — later strategies could "
            "appear faster. Consider running as root for accurate comparison."
        )
    print()

    strategies = [
        "random",
        "path_sorted",
        "path_reverse",
        "size_asc",
        "size_desc",
        "directory_batched",
    ]

    results: list[dict] = []

    for strategy in strategies:
        ordered = apply_strategy(sample, strategy)
        warmup_set = ordered[:WARMUP_FILES]
        bench_set = ordered  # full set including warmup files, timed from scratch

        # Drop caches before each strategy
        if can_clear:
            print(f"Dropping caches before '{strategy}'...")
            drop_caches()
            time.sleep(1)  # brief pause for cache drop to take effect

        # Warmup run (not timed)
        print(f"Warming up '{strategy}' ({WARMUP_FILES} files)...")
        for f in warmup_set:
            file_path = Path(mount_path) / f["path"] if mount_path else Path(f["path"])
            hash_file(file_path, f["size_bytes"])

        # Drop caches again after warmup so the timed run starts cold
        if can_clear:
            drop_caches()
            time.sleep(1)

        print(f"Running '{strategy}' ({len(bench_set)} files)...")
        result = run_benchmark(bench_set, mount_path, strategy)
        results.append(result)
        print(
            f"  Done: {result['time_s']:.1f}s, "
            f"{result['files_per_s']:.0f} files/s, "
            f"{result['mb_per_s']:.1f} MB/s, "
            f"{result['errors']} errors"
        )
        print()

    # Print results table
    print("=" * 82)
    print(f"{'Strategy':<20} {'Files':>6} {'Time(s)':>8} {'Files/s':>8} {'MB/s':>8} {'Seeks':>7} {'vs Random':>10}")
    print("-" * 82)

    baseline_time = results[0]["time_s"] if results else 1

    for r in results:
        if r["strategy"] == "random":
            vs = "baseline"
        else:
            if baseline_time > 0:
                pct = ((baseline_time - r["time_s"]) / baseline_time) * 100
                vs = f"{pct:+.1f}%"
            else:
                vs = "n/a"

        print(
            f"{r['strategy']:<20} "
            f"{r['hashed']:>6} "
            f"{r['time_s']:>8.1f} "
            f"{r['files_per_s']:>8.1f} "
            f"{r['mb_per_s']:>8.1f} "
            f"{r['total_seeks']:>7} "
            f"{vs:>10}"
        )

    print("=" * 82)

    # Error summary
    total_errors = sum(r["errors"] for r in results)
    if total_errors > 0:
        print(f"\nNote: {total_errors} total errors across all strategies (missing/unreadable files).")

    print("\nDone.")


if __name__ == "__main__":
    main()
