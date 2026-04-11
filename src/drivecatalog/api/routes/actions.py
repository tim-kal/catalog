"""Planned actions queue — operations that wait for drives to come online."""

from __future__ import annotations

import os
from pathlib import Path

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel

from drivecatalog.database import get_connection
from drivecatalog.watcher import get_mounted_volumes

router = APIRouter(prefix="/actions", tags=["actions"])


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------


class PlannedAction(BaseModel):
    id: int
    action_type: str  # delete, copy, move
    source_drive: str
    source_path: str
    target_drive: str | None = None
    target_path: str | None = None
    status: str  # pending, ready, in_progress, completed, failed, cancelled
    priority: int = 0
    estimated_bytes: int = 0
    transfer_id: str | None = None
    depends_on: int | None = None
    error: str | None = None
    created_at: str
    started_at: str | None = None
    completed_at: str | None = None


class CreateActionRequest(BaseModel):
    action_type: str  # delete, copy, move
    source_drive: str
    source_path: str
    target_drive: str | None = None
    target_path: str | None = None
    priority: int = 0
    estimated_bytes: int = 0
    transfer_id: str | None = None
    depends_on: int | None = None


class ActionListResponse(BaseModel):
    actions: list[PlannedAction]
    total: int
    actionable: int  # how many can be executed right now


class ActionableResponse(BaseModel):
    actions: list[PlannedAction]
    mounted_drives: list[str]


class UpdateActionRequest(BaseModel):
    status: str | None = None
    priority: int | None = None
    target_drive: str | None = None
    target_path: str | None = None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _get_mounted_drive_names(conn) -> set[str]:
    """Return set of drive names that are currently mounted."""
    mounted_paths = {str(v) for v in get_mounted_volumes()}
    rows = conn.execute(
        "SELECT name, mount_path FROM drives"
    ).fetchall()
    return {r["name"] for r in rows if r["mount_path"] in mounted_paths}


def _row_to_action(row) -> PlannedAction:
    return PlannedAction(
        id=row["id"],
        action_type=row["action_type"],
        source_drive=row["source_drive"],
        source_path=row["source_path"],
        target_drive=row["target_drive"],
        target_path=row["target_path"],
        status=row["status"],
        priority=row["priority"],
        estimated_bytes=row["estimated_bytes"],
        transfer_id=row["transfer_id"],
        depends_on=row["depends_on"],
        error=row["error"],
        created_at=row["created_at"],
        started_at=row["started_at"],
        completed_at=row["completed_at"],
    )


def _is_actionable(action: PlannedAction, mounted: set[str], completed_ids: set[int]) -> bool:
    """Check if an action can be executed right now."""
    if action.status != "pending":
        return False
    # Source drive must be mounted
    if action.source_drive not in mounted:
        return False
    # Target drive must be mounted (for copy/move)
    if action.action_type in ("copy", "move") and action.target_drive:
        if action.target_drive not in mounted:
            return False
    # Dependencies must be completed
    if action.depends_on is not None and action.depends_on not in completed_ids:
        return False
    return True


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@router.post("", response_model=PlannedAction, status_code=201)
async def create_action(req: CreateActionRequest) -> PlannedAction:
    """Queue a new planned action."""
    if req.action_type not in ("delete", "copy", "move"):
        raise HTTPException(400, f"Invalid action_type: {req.action_type}")
    if req.action_type in ("copy", "move") and not req.target_drive:
        raise HTTPException(400, f"{req.action_type} requires target_drive")

    conn = get_connection()
    try:
        # Estimate bytes from database if not provided
        estimated = req.estimated_bytes
        if estimated == 0:
            row = conn.execute(
                """
                SELECT COALESCE(SUM(f.size_bytes), 0) as total
                FROM files f
                JOIN drives d ON f.drive_id = d.id
                WHERE d.name = ? AND f.path LIKE ? || '/%'
                """,
                (req.source_drive, req.source_path),
            ).fetchone()
            estimated = row["total"] if row else 0

        cursor = conn.execute(
            """
            INSERT INTO planned_actions
                (action_type, source_drive, source_path, target_drive,
                 target_path, priority, estimated_bytes, transfer_id, depends_on)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                req.action_type,
                req.source_drive,
                req.source_path,
                req.target_drive,
                req.target_path or req.source_path,
                req.priority,
                estimated,
                req.transfer_id,
                req.depends_on,
            ),
        )
        conn.commit()
        action_id = cursor.lastrowid

        row = conn.execute(
            "SELECT * FROM planned_actions WHERE id = ?", (action_id,)
        ).fetchone()
        return _row_to_action(row)
    finally:
        conn.close()


@router.get("", response_model=ActionListResponse)
async def list_actions(
    status: str | None = Query(None, description="Filter by status"),
    source_drive: str | None = Query(None, description="Filter by source drive"),
) -> ActionListResponse:
    """List all planned actions with optional filtering."""
    conn = get_connection()
    try:
        conditions = []
        params: list = []
        if status:
            conditions.append("status = ?")
            params.append(status)
        if source_drive:
            conditions.append("source_drive = ?")
            params.append(source_drive)

        where = " AND ".join(conditions) if conditions else "1=1"
        rows = conn.execute(
            f"""
            SELECT * FROM planned_actions
            WHERE {where}
            ORDER BY priority DESC, created_at ASC
            """,
            params,
        ).fetchall()

        actions = [_row_to_action(r) for r in rows]

        # Count actionable
        mounted = _get_mounted_drive_names(conn)
        completed_ids = {
            r["id"]
            for r in conn.execute(
                "SELECT id FROM planned_actions WHERE status = 'completed'"
            ).fetchall()
        }
        actionable = sum(
            1 for a in actions if _is_actionable(a, mounted, completed_ids)
        )

        return ActionListResponse(
            actions=actions, total=len(actions), actionable=actionable
        )
    finally:
        conn.close()


@router.get("/actionable", response_model=ActionableResponse)
async def get_actionable() -> ActionableResponse:
    """Get actions that can be executed right now (required drives mounted, deps met)."""
    conn = get_connection()
    try:
        mounted = _get_mounted_drive_names(conn)
        completed_ids = {
            r["id"]
            for r in conn.execute(
                "SELECT id FROM planned_actions WHERE status = 'completed'"
            ).fetchall()
        }

        rows = conn.execute(
            "SELECT * FROM planned_actions WHERE status = 'pending' "
            "ORDER BY priority DESC, created_at ASC"
        ).fetchall()

        actions = [_row_to_action(r) for r in rows]
        actionable = [a for a in actions if _is_actionable(a, mounted, completed_ids)]

        return ActionableResponse(
            actions=actionable, mounted_drives=sorted(mounted)
        )
    finally:
        conn.close()


@router.patch("/{action_id}", response_model=PlannedAction)
async def update_action(action_id: int, req: UpdateActionRequest) -> PlannedAction:
    """Update a planned action (status, priority, reason, target)."""
    conn = get_connection()
    try:
        existing = conn.execute(
            "SELECT * FROM planned_actions WHERE id = ?", (action_id,)
        ).fetchone()
        if not existing:
            raise HTTPException(404, f"Action {action_id} not found")

        updates = []
        params: list = []
        if req.status is not None:
            updates.append("status = ?")
            params.append(req.status)
            if req.status == "in_progress":
                updates.append("started_at = datetime('now')")
            elif req.status == "completed":
                updates.append("completed_at = datetime('now')")
        if req.priority is not None:
            updates.append("priority = ?")
            params.append(req.priority)
        if req.target_drive is not None:
            updates.append("target_drive = ?")
            params.append(req.target_drive)
        if req.target_path is not None:
            updates.append("target_path = ?")
            params.append(req.target_path)

        if not updates:
            return _row_to_action(existing)

        params.append(action_id)
        conn.execute(
            f"UPDATE planned_actions SET {', '.join(updates)} WHERE id = ?",
            params,
        )
        conn.commit()

        row = conn.execute(
            "SELECT * FROM planned_actions WHERE id = ?", (action_id,)
        ).fetchone()
        return _row_to_action(row)
    finally:
        conn.close()


@router.delete("/{action_id}")
async def delete_action(action_id: int) -> dict:
    """Remove a planned action from the queue."""
    conn = get_connection()
    try:
        existing = conn.execute(
            "SELECT * FROM planned_actions WHERE id = ?", (action_id,)
        ).fetchone()
        if not existing:
            raise HTTPException(404, f"Action {action_id} not found")

        # Check if other actions depend on this one
        dependents = conn.execute(
            "SELECT id FROM planned_actions WHERE depends_on = ? AND status = 'pending'",
            (action_id,),
        ).fetchall()
        if dependents:
            dep_ids = [r["id"] for r in dependents]
            raise HTTPException(
                409,
                f"Cannot delete: actions {dep_ids} depend on this action. "
                f"Delete or reassign them first.",
            )

        conn.execute("DELETE FROM planned_actions WHERE id = ?", (action_id,))
        conn.commit()
        return {"deleted": action_id}
    finally:
        conn.close()


class VerifyResult(BaseModel):
    action_id: int
    source_exists: bool
    auto_completed: bool


class VerifyResponse(BaseModel):
    results: list[VerifyResult]


@router.post("/verify", response_model=VerifyResponse)
async def verify_actions() -> VerifyResponse:
    """Check pending actionable actions against the filesystem.

    For delete actions: if the source path no longer exists on a mounted drive,
    automatically mark the action as completed.
    """
    conn = get_connection()
    try:
        mounted = _get_mounted_drive_names(conn)

        # Get mount paths for ALL drives (not just mounted ones — we need to
        # distinguish "drive mounted but path gone" from "drive not mounted").
        drive_mounts: dict[str, str] = {}
        for row in conn.execute("SELECT name, mount_path FROM drives").fetchall():
            drive_mounts[row["name"]] = row["mount_path"]

        rows = conn.execute(
            "SELECT * FROM planned_actions WHERE status = 'pending' "
            "ORDER BY priority DESC, created_at ASC"
        ).fetchall()

        results: list[VerifyResult] = []
        for row in rows:
            action = _row_to_action(row)
            mount_path = drive_mounts.get(action.source_drive)
            if not mount_path:
                continue

            # Only verify if the drive is actually mounted — if the drive
            # isn't mounted, we can't distinguish "deleted" from "unplugged".
            drive_mounted = os.path.isdir(mount_path)
            if not drive_mounted:
                continue

            full_path = os.path.join(mount_path, action.source_path)
            source_exists = os.path.exists(full_path)
            auto_completed = False

            # Auto-complete delete actions when source is gone on a mounted drive
            if action.action_type == "delete" and not source_exists:
                conn.execute(
                    "UPDATE planned_actions SET status = 'completed', "
                    "completed_at = datetime('now') WHERE id = ?",
                    (action.id,),
                )
                conn.commit()
                auto_completed = True

            results.append(VerifyResult(
                action_id=action.id,
                source_exists=source_exists,
                auto_completed=auto_completed,
            ))

        return VerifyResponse(results=results)
    finally:
        conn.close()
