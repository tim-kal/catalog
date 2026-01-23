"""Rich console configuration and output utilities for DriveCatalog."""

from rich.console import Console
from rich.progress import BarColumn, Progress, SpinnerColumn, TaskProgressColumn, TextColumn
from rich.table import Table

# Module-level console instance for consistent output
console = Console()


def print_table(title: str, columns: list[str], rows: list[list[str]]) -> None:
    """Print a formatted Rich table.

    Args:
        title: Table title
        columns: List of column headers
        rows: List of row data (each row is a list of strings)
    """
    table = Table(title=title)
    for col in columns:
        table.add_column(col)
    for row in rows:
        table.add_row(*row)
    console.print(table)


def print_error(message: str) -> None:
    """Print an error message in red."""
    console.print(f"[red]Error:[/red] {message}")


def print_success(message: str) -> None:
    """Print a success message with green checkmark."""
    console.print(f"[green]✓[/green] {message}")


def print_warning(message: str) -> None:
    """Print a warning message in yellow."""
    console.print(f"[yellow]Warning:[/yellow] {message}")


def get_progress() -> Progress:
    """Return a configured Progress instance for file operations."""
    return Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        BarColumn(),
        TaskProgressColumn(),
        console=console,
    )
