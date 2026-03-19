"""Command-line interface for DriveCatalog."""

import threading
from datetime import datetime
from pathlib import Path

import click
from rich.table import Table

from drivecatalog import __version__
from drivecatalog.console import console, get_progress, print_error, print_success
from drivecatalog.copier import copy_file_verified, log_copy_operation
from drivecatalog.database import get_connection, get_db_path, init_db
from drivecatalog.drives import get_drive_info, validate_mount_path
from drivecatalog.duplicates import get_duplicate_clusters, get_duplicate_stats
from drivecatalog.hasher import compute_partial_hash
from drivecatalog.media import MEDIA_EXTENSIONS, check_integrity, extract_metadata
from drivecatalog.scanner import ScanResult, scan_drive
from drivecatalog.search import search_files
from drivecatalog.watcher import auto_scan_on_mount, get_mounted_volumes, run_watcher


@click.group(invoke_without_command=True)
@click.version_option(version=__version__, prog_name="drivecatalog")
@click.pass_context
def main(ctx):
    """DriveCatalog - Catalog external drives and detect duplicates."""
    # Initialize database on every invocation (safe to call multiple times)
    init_db()

    # Show help if no subcommand provided
    if ctx.invoked_subcommand is None:
        click.echo(ctx.get_help())


@main.group()
def drives():
    """Manage drive registrations."""
    pass


@drives.command()
@click.argument("path", type=click.Path(exists=True, file_okay=False, resolve_path=True))
@click.option("--name", "-n", help="Custom name for drive (defaults to volume name)")
def add(path: str, name: str | None) -> None:
    """Register a drive for cataloging.

    PATH should be a mount point under /Volumes/ (e.g., /Volumes/MyDrive).
    """
    path_obj = Path(path)

    # Validate mount path
    if not validate_mount_path(path_obj):
        print_error(f"'{path}' is not a valid mount point. Must be under /Volumes/.")
        return

    # Get drive information
    drive_info = get_drive_info(path_obj)
    drive_name = name if name else drive_info["name"]

    conn = get_connection()
    try:
        # Check if already registered by UUID or mount_path
        existing = conn.execute(
            "SELECT name FROM drives WHERE uuid = ? OR mount_path = ?",
            (drive_info["uuid"], drive_info["mount_path"]),
        ).fetchone()

        if existing:
            print_error(f"Drive already registered as '{existing['name']}'.")
            return

        # Insert new drive
        conn.execute(
            """
            INSERT INTO drives (name, uuid, mount_path, total_bytes)
            VALUES (?, ?, ?, ?)
            """,
            (drive_name, drive_info["uuid"], drive_info["mount_path"], drive_info["total_bytes"]),
        )
        conn.commit()

        uuid_display = drive_info["uuid"][:8] if drive_info["uuid"] else "N/A"
        print_success(f"Registered drive '{drive_name}' (UUID: {uuid_display}...)")
    finally:
        conn.close()


@drives.command("list")
def list_drives():
    """List all registered drives."""
    conn = get_connection()
    try:
        rows = conn.execute(
            """
            SELECT d.*, (SELECT COUNT(*) FROM files WHERE drive_id = d.id) as file_count
            FROM drives d ORDER BY d.name
            """
        ).fetchall()

        if not rows:
            print_error("No drives registered. Use 'drives add <path>' to add one.")
            return

        table = Table(title="Registered Drives")
        table.add_column("Name", style="bold")
        table.add_column("Mount Path")
        table.add_column("UUID")
        table.add_column("Files", justify="right")
        table.add_column("Last Scan")

        for row in rows:
            uuid_display = row["uuid"][:8] if row["uuid"] else "N/A"
            last_scan = _format_relative_time(row["last_scan"]) if row["last_scan"] else "Never"
            table.add_row(
                row["name"],
                row["mount_path"] or "",
                uuid_display,
                str(row["file_count"]),
                last_scan,
            )

        console.print(table)
    finally:
        conn.close()


@drives.command()
@click.argument("name")
def scan(name: str) -> None:
    """Scan a drive and catalog all files.

    NAME is the registered name of the drive to scan.
    """
    conn = get_connection()
    try:
        # Look up drive by name
        drive = conn.execute(
            "SELECT id, name, mount_path FROM drives WHERE name = ?",
            (name,),
        ).fetchone()

        if not drive:
            print_error(f"Drive '{name}' not found. Use 'drives list' to see registered drives.")
            return

        mount_path = drive["mount_path"]
        if not mount_path:
            print_error(f"Drive '{name}' has no mount path configured.")
            return

        # Check if mount path is accessible
        mount_path_obj = Path(mount_path)
        if not mount_path_obj.exists():
            print_error(f"Drive '{name}' is not mounted at '{mount_path}'.")
            return

        if not mount_path_obj.is_dir():
            print_error(f"Mount path '{mount_path}' is not a directory.")
            return

        # Scan with progress display
        console.print(f"[bold]Scanning drive '{name}'...[/bold]")
        with get_progress() as progress:
            task = progress.add_task("Scanning...", total=None)
            files_found = 0

            def update_progress(current_dir: str, stats: dict | None = None) -> None:
                nonlocal files_found
                if stats:
                    files_found = stats.get("total", files_found)
                # Truncate long directory paths for display
                display_dir = current_dir if len(current_dir) <= 50 else "..." + current_dir[-47:]
                progress.update(
                    task,
                    description=f"[cyan]{display_dir}[/cyan] ({files_found} files)",
                )

            result = scan_drive(drive["id"], mount_path, conn, progress_callback=update_progress)

        # Update last_scan timestamp
        conn.execute(
            "UPDATE drives SET last_scan = datetime('now') WHERE id = ?",
            (drive["id"],),
        )
        conn.commit()

        # Print summary
        _print_scan_summary(result)
        print_success(f"Scan complete. {result.total_scanned} files cataloged.")
    finally:
        conn.close()


@drives.command()
@click.argument("name")
@click.option("--force", is_flag=True, help="Re-hash all files, even those already hashed")
def hash(name: str, force: bool) -> None:
    """Compute partial hashes for all files on a drive.

    NAME is the registered name of the drive to hash.
    """
    conn = get_connection()
    try:
        # Look up drive by name
        drive = conn.execute(
            "SELECT id, name, mount_path FROM drives WHERE name = ?",
            (name,),
        ).fetchone()

        if not drive:
            print_error(f"Drive '{name}' not found. Use 'drives list' to see registered drives.")
            return

        mount_path = drive["mount_path"]
        if not mount_path:
            print_error(f"Drive '{name}' has no mount path configured.")
            return

        # Check if mount path is accessible
        mount_path_obj = Path(mount_path)
        if not mount_path_obj.exists():
            print_error(f"Drive '{name}' is not mounted at '{mount_path}'.")
            return

        # Query files needing hashing
        if force:
            files = conn.execute(
                "SELECT id, path, size_bytes FROM files WHERE drive_id = ?",
                (drive["id"],),
            ).fetchall()
        else:
            files = conn.execute(
                "SELECT id, path, size_bytes FROM files "
                "WHERE drive_id = ? AND partial_hash IS NULL",
                (drive["id"],),
            ).fetchall()

        total_files = len(files)
        if total_files == 0:
            print_success(f"All files on '{name}' already have hashes. Use --force to re-hash.")
            return

        # Hash files with progress display
        console.print(f"[bold]Hashing {total_files} files on '{name}'...[/bold]")
        hashed_count = 0
        error_count = 0

        with get_progress() as progress:
            task = progress.add_task("Hashing...", total=total_files)

            for file_row in files:
                file_id = file_row["id"]
                rel_path = file_row["path"]
                size_bytes = file_row["size_bytes"]
                full_path = mount_path_obj / rel_path

                # Truncate filename for display
                display_name = rel_path if len(rel_path) <= 50 else "..." + rel_path[-47:]
                progress.update(task, description=f"[cyan]{display_name}[/cyan]")

                # Compute hash
                partial_hash = compute_partial_hash(full_path, size_bytes)

                if partial_hash:
                    conn.execute(
                        "UPDATE files SET partial_hash = ? WHERE id = ?",
                        (partial_hash, file_id),
                    )
                    hashed_count += 1
                else:
                    error_count += 1

                progress.advance(task)

        conn.commit()

        # Print summary
        table = Table(title="Hash Summary")
        table.add_column("Category", style="bold")
        table.add_column("Count", justify="right")
        table.add_row("Files hashed", str(hashed_count))
        table.add_row("Errors", str(error_count))
        table.add_row("Total processed", str(total_files), style="bold")
        console.print(table)

        print_success(f"Hashing complete. {hashed_count} files hashed.")
    finally:
        conn.close()


@drives.command()
def duplicates() -> None:
    """Find duplicate files across all drives.

    Shows files with matching partial hashes and calculates reclaimable space.
    """
    conn = get_connection()
    try:
        # Get duplicate statistics
        stats = get_duplicate_stats(conn)

        if stats["total_clusters"] == 0:
            print_success("No duplicates found.")
            return

        # Get duplicate clusters
        clusters = get_duplicate_clusters(conn)

        # Stats summary table
        stats_table = Table(title="Duplicate Statistics", show_header=False)
        stats_table.add_column("Metric", style="bold")
        stats_table.add_column("Value")
        stats_table.add_row("Duplicate groups", str(stats["total_clusters"]))
        stats_table.add_row("Files with duplicates", str(stats["total_duplicate_files"]))
        stats_table.add_row("Total size", _format_bytes(stats["total_bytes"]))
        stats_table.add_row(
            "Reclaimable space",
            f"[green]{_format_bytes(stats['reclaimable_bytes'])}[/green]",
        )
        console.print(stats_table)

        # Clusters table (top 20)
        clusters_table = Table(title="Top Duplicate Clusters (by reclaimable space)")
        clusters_table.add_column("Hash", style="dim")
        clusters_table.add_column("Copies", justify="right")
        clusters_table.add_column("Size", justify="right")
        clusters_table.add_column("Reclaimable", justify="right", style="green")
        clusters_table.add_column("Files")

        for cluster in clusters[:20]:
            # Truncate hash to 8 chars
            hash_display = cluster["partial_hash"][:8]

            # Format files as "drive:path" pairs
            file_strs = []
            for f in cluster["files"]:
                path = f["path"]
                # Truncate path for display
                if len(path) > 30:
                    path = "..." + path[-27:]
                file_strs.append(f"{f['drive_name']}:{path}")

            files_display = ", ".join(file_strs)
            # Truncate if too long
            if len(files_display) > 60:
                files_display = files_display[:57] + "..."

            clusters_table.add_row(
                hash_display,
                str(cluster["count"]),
                _format_bytes(cluster["size_bytes"]),
                _format_bytes(cluster["reclaimable_bytes"]),
                files_display,
            )

        console.print(clusters_table)

        if len(clusters) > 20:
            console.print(f"[dim]... and {len(clusters) - 20} more duplicate groups[/dim]")

    finally:
        conn.close()


@drives.command()
@click.argument("pattern")
@click.option("--drive", "-d", help="Filter by drive name")
@click.option("--min-size", help="Minimum file size (e.g., 10M, 1G)")
@click.option("--max-size", help="Maximum file size (e.g., 100M, 5G)")
@click.option("--ext", "-e", help="Filter by extension (without dot, e.g., mp4)")
@click.option("--limit", "-l", default=100, help="Maximum results (default 100)")
def search(
    pattern: str,
    drive: str | None,
    min_size: str | None,
    max_size: str | None,
    ext: str | None,
    limit: int,
) -> None:
    """Search for files by pattern.

    PATTERN is a glob-style pattern (e.g., "*.mp4", "*vacation*").
    Use * for any characters, ? for single character.

    Examples:
        drives search "*.mp4"              # Find all MP4 files
        drives search "*vacation*" -d MyDrive  # Search specific drive
        drives search "*" --min-size 100M  # Files over 100MB
    """
    conn = get_connection()
    try:
        # Parse size filters
        min_bytes = _parse_size(min_size) if min_size else None
        max_bytes = _parse_size(max_size) if max_size else None

        # Execute search
        results = search_files(
            conn,
            pattern,
            drive_name=drive,
            min_size=min_bytes,
            max_size=max_bytes,
            extension=ext,
            limit=limit,
        )

        if not results:
            print_error(f"No files found matching '{pattern}'.")
            return

        # Display results table
        table = Table(title=f"Search Results for '{pattern}'")
        table.add_column("Drive", style="bold")
        table.add_column("Path")
        table.add_column("Size", justify="right")
        table.add_column("Modified")

        for row in results:
            # Truncate path for display
            path = row["path"]
            if len(path) > 50:
                path = "..." + path[-47:]

            # Format modification time
            mtime = row["mtime"]
            mtime_display = _format_relative_time(mtime) if mtime else "-"

            table.add_row(
                row["drive_name"],
                path,
                _format_bytes(row["size_bytes"]),
                mtime_display,
            )

        console.print(table)

        # Show result count
        if len(results) >= limit:
            console.print(
                f"[dim]Showing {len(results)} results (limit reached, more may exist)[/dim]"
            )
        else:
            console.print(f"[dim]Found {len(results)} file(s)[/dim]")

    finally:
        conn.close()


@drives.command()
@click.argument("source_drive")
@click.argument("source_path")
@click.argument("dest_drive")
@click.option("--dest-path", "-d", help="Destination path (defaults to same as source)")
def copy(source_drive: str, source_path: str, dest_drive: str, dest_path: str | None) -> None:
    """Copy a file between drives with integrity verification.

    SOURCE_DRIVE is the registered name of the source drive.
    SOURCE_PATH is the relative path of the file on the source drive.
    DEST_DRIVE is the registered name of the destination drive.

    The file must already be cataloged (run 'drives scan' first).
    After copying, verifies the copy matches the source via SHA256.
    """
    conn = get_connection()
    try:
        # Look up source drive
        src_drive = conn.execute(
            "SELECT id, name, mount_path FROM drives WHERE name = ?",
            (source_drive,),
        ).fetchone()

        if not src_drive:
            print_error(
                f"Source drive '{source_drive}' not found. "
                "Use 'drives list' to see registered drives."
            )
            return

        # Look up destination drive
        dst_drive = conn.execute(
            "SELECT id, name, mount_path FROM drives WHERE name = ?",
            (dest_drive,),
        ).fetchone()

        if not dst_drive:
            print_error(
                f"Destination drive '{dest_drive}' not found. "
                "Use 'drives list' to see registered drives."
            )
            return

        # Validate source drive is mounted
        src_mount = src_drive["mount_path"]
        if not src_mount:
            print_error(f"Source drive '{source_drive}' has no mount path configured.")
            return

        src_mount_path = Path(src_mount)
        if not src_mount_path.exists():
            print_error(f"Source drive '{source_drive}' is not mounted at '{src_mount}'.")
            return

        # Validate source file exists on disk
        src_full_path = src_mount_path / source_path
        if not src_full_path.exists():
            print_error(f"Source file not found: {src_full_path}")
            return

        if not src_full_path.is_file():
            print_error(f"Source path is not a file: {src_full_path}")
            return

        # Validate destination drive is mounted
        dst_mount = dst_drive["mount_path"]
        if not dst_mount:
            print_error(f"Destination drive '{dest_drive}' has no mount path configured.")
            return

        dst_mount_path = Path(dst_mount)
        if not dst_mount_path.exists():
            print_error(f"Destination drive '{dest_drive}' is not mounted at '{dst_mount}'.")
            return

        # Look up source file in database (must be cataloged)
        src_file = conn.execute(
            "SELECT id, path, size_bytes FROM files WHERE drive_id = ? AND path = ?",
            (src_drive["id"], source_path),
        ).fetchone()

        if not src_file:
            print_error(f"File '{source_path}' not found in catalog for drive '{source_drive}'.")
            print_error("Run 'drives scan' to catalog files first.")
            return

        # Determine destination path
        final_dest_path = dest_path if dest_path else source_path

        # Build full destination path
        dst_full_path = dst_mount_path / final_dest_path

        # Check if destination file already exists
        if dst_full_path.exists():
            print_error(f"Destination file already exists: {dst_full_path}")
            print_error("Use --force to overwrite (not implemented yet).")
            return

        # Copy with progress display
        file_size = src_file["size_bytes"]
        console.print(
            f"[bold]Copying '{source_path}' from {source_drive} to {dest_drive}...[/bold]"
        )

        started_at = datetime.now()

        with get_progress() as progress:
            task = progress.add_task(f"Copying {Path(source_path).name}...", total=file_size)

            def update_progress(bytes_written: int) -> None:
                progress.update(task, completed=bytes_written)

            result = copy_file_verified(
                src_full_path, dst_full_path, progress_callback=update_progress
            )

        completed_at = datetime.now()

        # Handle error
        if result.error:
            print_error(f"Copy failed: {result.error}")
            return

        # Log operation to database
        log_copy_operation(
            conn,
            source_file_id=src_file["id"],
            dest_drive_id=dst_drive["id"],
            dest_path=final_dest_path,
            result=result,
            started_at=started_at,
            completed_at=completed_at,
        )

        # Display result table
        result_table = Table(title="Copy Result")
        result_table.add_column("Field", style="bold")
        result_table.add_column("Value")

        result_table.add_row("Source", f"{source_drive}:{source_path}")
        result_table.add_row("Destination", f"{dest_drive}:{final_dest_path}")
        result_table.add_row("Bytes copied", _format_bytes(result.bytes_copied))
        result_table.add_row("Source SHA256", result.source_hash[:16] + "...")
        result_table.add_row("Dest SHA256", result.dest_hash[:16] + "...")

        if result.verified:
            result_table.add_row("Verified", "[green]✓ Hashes match[/green]")
        else:
            result_table.add_row("Verified", "[red]✗ MISMATCH[/red]")

        console.print(result_table)

        # Final status message
        if result.verified:
            print_success("Copy verified successfully.")
        else:
            print_error("VERIFICATION FAILED - hashes do not match!")

    finally:
        conn.close()


@drives.command()
def watch() -> None:
    """Monitor /Volumes for drive mount/unmount events.

    Runs as a foreground daemon, detecting when drives are connected
    or disconnected. Registered drives are identified by name.

    Use Ctrl+C to stop the watcher.
    """
    db_path = get_db_path()
    conn = get_connection()

    try:
        console.print("[bold]Watching /Volumes for mount/unmount events...[/bold]")
        console.print("[dim]Press Ctrl+C to stop[/dim]")
        console.print()

        def on_mount(path):
            """Handle volume mount event."""
            # Check if this is a registered drive
            drive = conn.execute(
                "SELECT name FROM drives WHERE mount_path = ?",
                (str(path),),
            ).fetchone()

            if drive:
                console.print(
                    f"[green]Mount detected:[/green] {path} "
                    f"(registered as {drive['name']})"
                )
                # Trigger auto-scan in background thread to keep watcher responsive
                # Use a separate connection for thread safety
                def scan_in_background():
                    scan_conn = get_connection()
                    try:
                        auto_scan_on_mount(path, scan_conn)
                    finally:
                        scan_conn.close()

                thread = threading.Thread(target=scan_in_background, daemon=True)
                thread.start()
            else:
                console.print(f"[yellow]Mount detected:[/yellow] {path} (not registered)")

        def on_unmount(path):
            """Handle volume unmount event."""
            # Check if this was a registered drive
            drive = conn.execute(
                "SELECT name FROM drives WHERE mount_path = ?",
                (str(path),),
            ).fetchone()

            if drive:
                console.print(f"[red]Unmount detected:[/red] {path} (was {drive['name']})")
            else:
                console.print(f"[dim]Unmount detected:[/dim] {path}")

        # Check existing mounts on startup
        existing_volumes = get_mounted_volumes()
        if existing_volumes:
            console.print("[bold]Currently mounted volumes:[/bold]")
            for vol in existing_volumes:
                drive = conn.execute(
                    "SELECT name FROM drives WHERE mount_path = ?",
                    (str(vol),),
                ).fetchone()

                if drive:
                    console.print(f"  [green]●[/green] {vol} (registered as {drive['name']})")
                else:
                    console.print(f"  [dim]●[/dim] {vol}")
            console.print()

        # Run watcher (blocking until interrupted)
        run_watcher(db_path, on_mount, on_unmount)

    except KeyboardInterrupt:
        console.print("\n[bold]Watcher stopped.[/bold]")
    finally:
        conn.close()


@drives.command()
@click.argument("name")
@click.option("--force", is_flag=True, help="Re-extract metadata for all media files")
def media(name: str, force: bool) -> None:
    """Extract metadata for video files on a drive.

    NAME is the registered name of the drive.
    Requires ffprobe to be installed (`brew install ffmpeg`).
    """
    conn = get_connection()
    try:
        # Look up drive by name
        drive = conn.execute(
            "SELECT id, name, mount_path FROM drives WHERE name = ?",
            (name,),
        ).fetchone()

        if not drive:
            print_error(f"Drive '{name}' not found. Use 'drives list' to see registered drives.")
            return

        mount_path = drive["mount_path"]
        if not mount_path:
            print_error(f"Drive '{name}' has no mount path configured.")
            return

        # Check if mount path is accessible
        mount_path_obj = Path(mount_path)
        if not mount_path_obj.exists():
            print_error(f"Drive '{name}' is not mounted at '{mount_path}'.")
            return

        # Build extension list for SQL query
        ext_list = [ext.lstrip(".") for ext in MEDIA_EXTENSIONS]
        ext_placeholders = ",".join("?" * len(ext_list))

        # Query media files: either force mode (all media files) or incremental (no metadata yet)
        if force:
            # All files with media extensions
            query = f"""
                SELECT f.id, f.path, f.filename
                FROM files f
                WHERE f.drive_id = ?
                AND LOWER(SUBSTR(f.filename, INSTR(f.filename, '.') + 1)) IN ({ext_placeholders})
            """
            files = conn.execute(query, (drive["id"], *ext_list)).fetchall()
        else:
            # Files with media extensions that don't have metadata yet
            query = f"""
                SELECT f.id, f.path, f.filename
                FROM files f
                LEFT JOIN media_metadata m ON f.id = m.file_id
                WHERE f.drive_id = ?
                AND m.id IS NULL
                AND LOWER(SUBSTR(f.filename, INSTR(f.filename, '.') + 1)) IN ({ext_placeholders})
            """
            files = conn.execute(query, (drive["id"], *ext_list)).fetchall()

        total_files = len(files)
        if total_files == 0:
            if force:
                print_success(f"No media files found on '{name}'.")
            else:
                print_success(
                    f"All media files on '{name}' already have metadata. "
                    "Use --force to re-extract."
                )
            return

        # Extract metadata with progress display
        console.print(
            f"[bold]Extracting metadata for {total_files} media files on '{name}'...[/bold]"
        )
        extracted_count = 0
        error_count = 0

        with get_progress() as progress:
            task = progress.add_task("Extracting...", total=total_files)

            for file_row in files:
                file_id = file_row["id"]
                rel_path = file_row["path"]
                full_path = mount_path_obj / rel_path

                # Truncate filename for display
                display_name = rel_path if len(rel_path) <= 50 else "..." + rel_path[-47:]
                progress.update(task, description=f"[cyan]{display_name}[/cyan]")

                # Update is_media flag
                conn.execute("UPDATE files SET is_media = 1 WHERE id = ?", (file_id,))

                # Extract metadata
                metadata = extract_metadata(full_path)

                if metadata:
                    # Insert or replace metadata
                    conn.execute(
                        """
                        INSERT OR REPLACE INTO media_metadata
                        (file_id, duration_seconds, codec_name, width, height, frame_rate, bit_rate)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            file_id,
                            metadata.duration_seconds,
                            metadata.codec_name,
                            metadata.width,
                            metadata.height,
                            metadata.frame_rate,
                            metadata.bit_rate,
                        ),
                    )
                    extracted_count += 1
                else:
                    error_count += 1

                progress.advance(task)

        conn.commit()

        # Print summary
        table = Table(title="Media Metadata Summary")
        table.add_column("Category", style="bold")
        table.add_column("Count", justify="right")
        table.add_row("Metadata extracted", str(extracted_count))
        table.add_row("Errors (ffprobe failed)", str(error_count))
        table.add_row("Total processed", str(total_files), style="bold")
        console.print(table)

        if error_count > 0 and extracted_count == 0:
            print_error("No metadata extracted. Is ffprobe installed? (brew install ffmpeg)")
        else:
            print_success(f"Metadata extraction complete. {extracted_count} files processed.")
    finally:
        conn.close()


@drives.command()
@click.argument("name")
@click.option("--force", is_flag=True, help="Re-verify all media files")
@click.option("--show-errors", is_flag=True, help="Display full error messages for corrupted files")
def verify(name: str, force: bool, show_errors: bool) -> None:
    """Verify integrity of video files on a drive.

    NAME is the registered name of the drive.
    Requires ffprobe to be installed (`brew install ffmpeg`).

    Uses ffprobe to detect container corruption, truncation, or other
    structural issues without fully decoding the video.
    """
    conn = get_connection()
    try:
        # Look up drive by name
        drive = conn.execute(
            "SELECT id, name, mount_path FROM drives WHERE name = ?",
            (name,),
        ).fetchone()

        if not drive:
            print_error(f"Drive '{name}' not found. Use 'drives list' to see registered drives.")
            return

        mount_path = drive["mount_path"]
        if not mount_path:
            print_error(f"Drive '{name}' has no mount path configured.")
            return

        # Check if mount path is accessible
        mount_path_obj = Path(mount_path)
        if not mount_path_obj.exists():
            print_error(f"Drive '{name}' is not mounted at '{mount_path}'.")
            return

        # Query media files: files with is_media=1 flag (set by `drives media`)
        if force:
            # All media files
            files = conn.execute(
                """
                SELECT f.id, f.path, f.filename
                FROM files f
                WHERE f.drive_id = ? AND f.is_media = 1
                """,
                (drive["id"],),
            ).fetchall()
        else:
            # Media files without integrity verification yet
            files = conn.execute(
                """
                SELECT f.id, f.path, f.filename
                FROM files f
                JOIN media_metadata m ON f.id = m.file_id
                WHERE f.drive_id = ? AND f.is_media = 1 AND m.integrity_verified_at IS NULL
                """,
                (drive["id"],),
            ).fetchall()

        total_files = len(files)
        if total_files == 0:
            # Check if there are any media files at all
            media_count = conn.execute(
                "SELECT COUNT(*) FROM files WHERE drive_id = ? AND is_media = 1",
                (drive["id"],),
            ).fetchone()[0]

            if media_count == 0:
                print_error(f"No media files found on '{name}'. Run 'drives media {name}' first.")
            elif force:
                print_success(f"No media files found on '{name}'.")
            else:
                print_success(
                    f"All media files on '{name}' already verified. "
                    "Use --force to re-verify."
                )
            return

        # Verify files with progress display
        console.print(
            f"[bold]Verifying integrity of {total_files} media files "
            f"on '{name}'...[/bold]"
        )
        verified_ok = 0
        verified_errors = 0
        ffprobe_failed = 0
        files_with_errors: list[tuple[str, list[str]]] = []

        with get_progress() as progress:
            task = progress.add_task("Verifying...", total=total_files)

            for file_row in files:
                file_id = file_row["id"]
                rel_path = file_row["path"]
                full_path = mount_path_obj / rel_path

                # Truncate filename for display
                display_name = rel_path if len(rel_path) <= 50 else "..." + rel_path[-47:]
                progress.update(task, description=f"[cyan]{display_name}[/cyan]")

                # Check integrity
                result = check_integrity(full_path)

                if result is None:
                    ffprobe_failed += 1
                elif result.is_valid:
                    verified_ok += 1
                    # Update database
                    conn.execute(
                        """
                        UPDATE media_metadata
                        SET integrity_verified_at = datetime('now'), integrity_errors = NULL
                        WHERE file_id = ?
                        """,
                        (file_id,),
                    )
                else:
                    verified_errors += 1
                    files_with_errors.append((rel_path, result.errors))
                    # Update database with errors
                    errors_text = "\n".join(result.errors)
                    conn.execute(
                        """
                        UPDATE media_metadata
                        SET integrity_verified_at = datetime('now'), integrity_errors = ?
                        WHERE file_id = ?
                        """,
                        (errors_text, file_id),
                    )

                progress.advance(task)

        conn.commit()

        # Print summary
        table = Table(title="Integrity Verification Summary")
        table.add_column("Category", style="bold")
        table.add_column("Count", justify="right")
        ok_style = "green" if verified_ok > 0 else None
        err_style = "red" if verified_errors > 0 else None
        warn_style = "yellow" if ffprobe_failed > 0 else None
        table.add_row("Verified OK", str(verified_ok), style=ok_style)
        table.add_row("Integrity errors", str(verified_errors), style=err_style)
        table.add_row("FFprobe failures", str(ffprobe_failed), style=warn_style)
        table.add_row("Total processed", str(total_files), style="bold")
        console.print(table)

        # Show files with errors if requested
        if verified_errors > 0 and show_errors:
            console.print()
            console.print("[bold red]Files with integrity errors:[/bold red]")
            for path, errors in files_with_errors:
                console.print(f"\n[bold]{path}[/bold]")
                for error in errors:
                    console.print(f"  [red]•[/red] {error}")

        if ffprobe_failed > 0 and verified_ok == 0 and verified_errors == 0:
            print_error("No files verified. Is ffprobe installed? (brew install ffmpeg)")
        elif verified_errors > 0:
            print_error(f"Found {verified_errors} file(s) with integrity issues.")
        else:
            print_success(f"Verification complete. {verified_ok} files verified OK.")
    finally:
        conn.close()


def _format_bytes(size_bytes: int) -> str:
    """Format bytes as human-readable string.

    Args:
        size_bytes: Size in bytes.

    Returns:
        Human-readable size string (e.g., "1.2 GB", "456 MB").
    """
    if size_bytes < 1024:
        return f"{size_bytes} B"
    elif size_bytes < 1024 * 1024:
        return f"{size_bytes / 1024:.1f} KB"
    elif size_bytes < 1024 * 1024 * 1024:
        return f"{size_bytes / (1024 * 1024):.1f} MB"
    elif size_bytes < 1024 * 1024 * 1024 * 1024:
        return f"{size_bytes / (1024 * 1024 * 1024):.1f} GB"
    else:
        return f"{size_bytes / (1024 * 1024 * 1024 * 1024):.1f} TB"


def _parse_size(size_str: str) -> int:
    """Parse a size string with optional suffix to bytes.

    Args:
        size_str: Size string like "10M", "1G", "500K", or "1024".

    Returns:
        Size in bytes.

    Raises:
        click.BadParameter: If the size string is invalid.
    """
    if not size_str:
        raise click.BadParameter("Size cannot be empty")

    size_str = size_str.strip().upper()

    suffixes = {
        "K": 1024,
        "M": 1024 * 1024,
        "G": 1024 * 1024 * 1024,
        "T": 1024 * 1024 * 1024 * 1024,
    }

    # Check if last character is a suffix
    if size_str[-1] in suffixes:
        try:
            number = float(size_str[:-1])
            return int(number * suffixes[size_str[-1]])
        except ValueError as err:
            raise click.BadParameter(f"Invalid size: {size_str}") from err
    else:
        # No suffix, assume bytes
        try:
            return int(size_str)
        except ValueError as err:
            raise click.BadParameter(f"Invalid size: {size_str}") from err


def _print_scan_summary(result: ScanResult) -> None:
    """Print a summary table of scan results."""
    table = Table(title="Scan Summary")
    table.add_column("Category", style="bold")
    table.add_column("Count", justify="right")

    table.add_row("New files", str(result.new_files))
    table.add_row("Modified files", str(result.modified_files))
    table.add_row("Unchanged files", str(result.unchanged_files))
    table.add_row("Errors", str(result.errors))
    table.add_row("Total scanned", str(result.total_scanned), style="bold")

    console.print(table)


def _format_relative_time(timestamp: str) -> str:
    """Format a timestamp as a relative time string.

    Args:
        timestamp: ISO format timestamp string from database

    Returns:
        Human-readable relative time (e.g., "2 hours ago")
    """
    dt = datetime.fromisoformat(timestamp)
    now = datetime.now()
    delta = now - dt

    if delta.days > 365:
        years = delta.days // 365
        return f"{years} year{'s' if years > 1 else ''} ago"
    elif delta.days > 30:
        months = delta.days // 30
        return f"{months} month{'s' if months > 1 else ''} ago"
    elif delta.days > 0:
        return f"{delta.days} day{'s' if delta.days > 1 else ''} ago"
    elif delta.seconds > 3600:
        hours = delta.seconds // 3600
        return f"{hours} hour{'s' if hours > 1 else ''} ago"
    elif delta.seconds > 60:
        minutes = delta.seconds // 60
        return f"{minutes} minute{'s' if minutes > 1 else ''} ago"
    else:
        return "Just now"


@main.command()
def status():
    """Show database status and statistics."""
    db_path = get_db_path()
    exists = db_path.exists()

    table = Table(title="DriveCatalog Status", show_header=False)
    table.add_column("Field", style="bold")
    table.add_column("Value")

    table.add_row("Database", str(db_path))

    if exists:
        table.add_row("Status", "[green]Initialized[/green]")
        conn = get_connection()
        try:
            drives_count = conn.execute("SELECT COUNT(*) FROM drives").fetchone()[0]
            files_count = conn.execute("SELECT COUNT(*) FROM files").fetchone()[0]
            table.add_row("Drives", str(drives_count))
            table.add_row("Files", str(files_count))

            # Hash coverage statistics
            hashed_count = conn.execute(
                "SELECT COUNT(*) FROM files WHERE partial_hash IS NOT NULL"
            ).fetchone()[0]
            if files_count > 0:
                hash_pct = (hashed_count / files_count) * 100
                table.add_row(
                    "Hash coverage",
                    f"{hashed_count}/{files_count} files ({hash_pct:.1f}%)",
                )
            else:
                table.add_row("Hash coverage", "No files")

            console.print(table)

            # Per-drive breakdown if drives exist
            if drives_count > 0:
                drive_stats = conn.execute(
                    """
                    SELECT
                        d.name,
                        COUNT(f.id) as total_files,
                        COUNT(f.partial_hash) as hashed_files
                    FROM drives d
                    LEFT JOIN files f ON f.drive_id = d.id
                    GROUP BY d.id
                    ORDER BY d.name
                    """
                ).fetchall()

                drive_table = Table(title="Per-Drive Hash Status")
                drive_table.add_column("Drive", style="bold")
                drive_table.add_column("Files", justify="right")
                drive_table.add_column("Hashed", justify="right")
                drive_table.add_column("Coverage", justify="right")

                for row in drive_stats:
                    total = row["total_files"]
                    hashed = row["hashed_files"]
                    if total > 0:
                        pct = (hashed / total) * 100
                        coverage_str = f"{pct:.1f}%"
                        if pct < 100:
                            coverage_str = f"[yellow]{coverage_str}[/yellow]"
                        else:
                            coverage_str = f"[green]{coverage_str}[/green]"
                    else:
                        coverage_str = "-"
                    drive_table.add_row(
                        row["name"],
                        str(total),
                        str(hashed),
                        coverage_str,
                    )

                console.print(drive_table)
        finally:
            conn.close()
    else:
        table.add_row("Status", "[red]Not found[/red]")
        console.print(table)
