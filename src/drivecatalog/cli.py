"""Command-line interface for DriveCatalog."""

import click

from drivecatalog import __version__


@click.group()
@click.version_option(version=__version__, prog_name="drivecatalog")
def main():
    """Catalog external drives and detect duplicates."""
    pass
