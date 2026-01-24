"""Command-line interface for DriveCatalog."""

from datetime import datetime
from pathlib import Path

import click
from rich.table import Table

from drivecatalog import __version__
from drivecatalog.console import console, get_progress, print_error, print_success
from drivecatalog.database import get_connection, get_db_path, init_db
from drivecatalog.drives import get_drive_info, validate_mount_path
from drivecatalog.hasher import compute_partial_hash
from drivecatalog.scanner import ScanResult, scan_drive


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
                "SELECT id, path, size_bytes FROM files WHERE drive_id = ? AND partial_hash IS NULL",
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
