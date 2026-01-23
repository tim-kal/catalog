"""Command-line interface for DriveCatalog."""

import click
from rich.table import Table

from pathlib import Path

from drivecatalog import __version__
from drivecatalog.console import console, print_error, print_success
from drivecatalog.database import get_connection, get_db_path, init_db
from drivecatalog.drives import get_drive_info, validate_mount_path


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
    # Placeholder - implemented in Phase 2
    pass


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
