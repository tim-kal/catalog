"""Audit log query endpoints for DriveCatalog API."""

from fastapi import APIRouter, Query

from drivecatalog.database import get_connection

router = APIRouter(prefix="/audit", tags=["audit"])


@router.get("")
async def get_audit_log(
    drive: str | None = Query(None, description="Filter by drive name"),
    event_type: str | None = Query(None, description="Filter by event type"),
    limit: int = Query(100, ge=1, le=1000, description="Max entries to return"),
    offset: int = Query(0, ge=0, description="Number of entries to skip"),
) -> dict:
    """Query the immutable audit log.

    Returns entries in reverse chronological order (newest first).
    """
    conn = get_connection()
    try:
        conditions = []
        params: list = []

        if drive:
            conditions.append("drive_name = ?")
            params.append(drive)
        if event_type:
            conditions.append("event_type = ?")
            params.append(event_type)

        where = f"WHERE {' AND '.join(conditions)}" if conditions else ""

        total = conn.execute(
            f"SELECT COUNT(*) FROM audit_log {where}", params
        ).fetchone()[0]

        rows = conn.execute(
            f"""SELECT id, timestamp, event_type, drive_name, operation_id,
                       detail, files_affected, bytes_affected
                FROM audit_log {where}
                ORDER BY id DESC LIMIT ? OFFSET ?""",
            params + [limit, offset],
        ).fetchall()

        return {
            "entries": [dict(r) for r in rows],
            "total": total,
            "limit": limit,
            "offset": offset,
        }
    finally:
        conn.close()
