"""FastAPI application for DriveCatalog.

Provides HTTP API access to the DriveCatalog CLI functionality.
"""

from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from drivecatalog.database import init_db

from . import __version__
from .routes import actions, consolidation, copy, drives, duplicates, files, folder_duplicates, insights, migrations, operations, search, status


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    """Initialize database on startup."""
    init_db()
    yield


app = FastAPI(
    title="DriveCatalog API",
    description="HTTP API for DriveCatalog - catalog external drives and detect duplicates",
    version=__version__,
    lifespan=lifespan,
)

# Allow CORS for local desktop app access
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# Include routers
app.include_router(status.router)
app.include_router(drives.router)
app.include_router(files.router)
app.include_router(duplicates.router)
app.include_router(search.router)
app.include_router(operations.router)
app.include_router(copy.router)
app.include_router(consolidation.router)
app.include_router(migrations.router)
app.include_router(actions.router)
app.include_router(insights.router)
app.include_router(folder_duplicates.router)


@app.get("/health")
async def health() -> dict:
    """Health check endpoint."""
    return {"status": "ok"}


@app.get("/migration-status")
async def migration_status() -> dict:
    """Return current migration progress.

    Registered directly on the app (not via lifespan-dependent router)
    so it is available before init_db() completes.
    """
    from drivecatalog.migrations import read_migration_status

    return read_migration_status()
