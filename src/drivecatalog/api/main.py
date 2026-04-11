"""FastAPI application for DriveCatalog.

Provides HTTP API access to the DriveCatalog CLI functionality.
"""

from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from drivecatalog.database import init_db

from . import __version__
from .routes import actions, bug_report, consolidation, copy, drives, duplicates, errors, files, folder_duplicates, insights, migrations, operations, search, status


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
app.include_router(errors.router)
app.include_router(bug_report.router)


# Map HTTP error patterns to error codes for structured error responses.
_STATUS_TO_ERROR_CODE: dict[int, str] = {
    404: "DC-E002",  # Not found → drive/resource not found
    409: "DC-E009",  # Conflict → operation already running
    400: "DC-E010",  # Bad request → invalid parameters
}


@app.exception_handler(StarletteHTTPException)
async def http_exception_handler(request: Request, exc: StarletteHTTPException) -> JSONResponse:
    """Override default HTTPException handler to include error_code field."""
    detail = exc.detail if isinstance(exc.detail, str) else str(exc.detail)

    # Determine error code from status or detail content
    error_code = _STATUS_TO_ERROR_CODE.get(exc.status_code)
    if error_code and "not mounted" in detail.lower():
        error_code = "DC-E003"

    body: dict = {"detail": detail}
    if error_code:
        body["error_code"] = error_code

    return JSONResponse(status_code=exc.status_code, content=body)


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
