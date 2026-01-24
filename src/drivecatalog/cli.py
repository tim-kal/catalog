"""Command-line interface for DriveCatalog."""

from datetime import datetime
from pathlib import Path

import click
from rich.table import Table

from drivecatalog import __version__
from drivecatalog.console import console, get_progress, print_error, print_success
from drivecatalog.database import get_connection, get_db_path, init_db
from drivecatalog.drives import get_drive_info, validate_mount_path
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
        table.add_row("Status", "[green]✓ Initialized[/green]")
        conn = get_connection()
        try:
            drives_count = conn.execute("SELECT COUNT(*) FROM drives").fetchone()[0]
            files_count = conn.execute("SELECT COUNT(*) FROM files").fetchone()[0]
            table.add_row("Drives", str(drives_count))
            table.add_row("Files", str(files_count))
        finally:
            conn.close()
    else:
        table.add_row("Status", "[red]Not found[/red]")

    console.print(table)
