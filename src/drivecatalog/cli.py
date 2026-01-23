"""Command-line interface for DriveCatalog."""

import click

from drivecatalog import __version__
from drivecatalog.database import init_db


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
def list():
    """List all registered drives."""
    # Placeholder - implemented in Phase 2
    pass
