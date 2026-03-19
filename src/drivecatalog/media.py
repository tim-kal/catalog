"""Media metadata extraction via ffprobe for DriveCatalog."""

import json
import subprocess
from dataclasses import dataclass
from pathlib import Path

# Video file extensions to process for metadata extraction
MEDIA_EXTENSIONS = {
    # Common formats
    ".mp4",
    ".mov",
    ".mkv",
    ".avi",
    ".wmv",
    ".webm",
    ".m4v",
    # Professional formats
    ".mxf",
    ".r3d",
    ".braw",
    ".ari",
    ".prores",
}


def is_media_file(path: str | Path) -> bool:
    """Check if a file has a media extension.

    Args:
        path: File path to check (string or Path).

    Returns:
        True if file extension is in MEDIA_EXTENSIONS, False otherwise.
    """
    if isinstance(path, str):
        path = Path(path)
    return path.suffix.lower() in MEDIA_EXTENSIONS


@dataclass
class MediaMetadata:
    """Container for video metadata extracted via ffprobe."""

    duration_seconds: float | None = None
    codec_name: str | None = None
    width: int | None = None
    height: int | None = None
    frame_rate: str | None = None  # Stored as fraction like "24000/1001"
    bit_rate: int | None = None


@dataclass
class IntegrityResult:
    """Result of container integrity verification via ffprobe."""

    is_valid: bool
    errors: list[str]


def extract_metadata(file_path: Path) -> MediaMetadata | None:
    """Extract video metadata from a file using ffprobe.

    Args:
        file_path: Path to the video file.

    Returns:
        MediaMetadata with extracted values, or None on error.
        Returns None if ffprobe is not installed, file not found,
        or file has no video stream.
    """
    if not file_path.exists():
        return None

    try:
        result = subprocess.run(
            [
                "ffprobe",
                "-v",
                "quiet",
                "-print_format",
                "json",
                "-show_streams",
                "-show_format",
                str(file_path),
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )

        if result.returncode != 0:
            return None

        data = json.loads(result.stdout)

        # Find first video stream
        video_stream = None
        for stream in data.get("streams", []):
            if stream.get("codec_type") == "video":
                video_stream = stream
                break

        if video_stream is None:
            return None

        # Extract format info
        format_info = data.get("format", {})

        # Get duration from format (fallback to stream duration)
        duration_str = format_info.get("duration") or video_stream.get("duration")
        duration = float(duration_str) if duration_str else None

        # Get bit rate from format
        bit_rate_str = format_info.get("bit_rate")
        bit_rate = int(bit_rate_str) if bit_rate_str else None

        return MediaMetadata(
            duration_seconds=duration,
            codec_name=video_stream.get("codec_name"),
            width=video_stream.get("width"),
            height=video_stream.get("height"),
            frame_rate=video_stream.get("r_frame_rate"),
            bit_rate=bit_rate,
        )

    except FileNotFoundError:
        # ffprobe not installed
        return None
    except subprocess.TimeoutExpired:
        return None
    except json.JSONDecodeError:
        return None
    except (KeyError, ValueError, TypeError):
        return None


def check_integrity(file_path: Path) -> IntegrityResult | None:
    """Check video container integrity using ffprobe error detection.

    Runs ffprobe with error-level logging to detect container corruption,
    truncation, or other structural issues without fully decoding the video.

    Args:
        file_path: Path to the video file.

    Returns:
        IntegrityResult with validity status and any error messages,
        or None if ffprobe is not installed or the check failed.
    """
    if not file_path.exists():
        return None

    try:
        # Use -v error to capture corruption messages to stderr
        # -f null - sends output to null (we only care about errors)
        result = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-i",
                str(file_path),
                "-f",
                "null",
                "-",
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )

        # Parse stderr for error messages
        stderr = result.stderr.strip()

        if not stderr:
            # No errors - file is valid
            return IntegrityResult(is_valid=True, errors=[])
        else:
            # Parse error lines
            error_lines = [line.strip() for line in stderr.split("\n") if line.strip()]
            return IntegrityResult(is_valid=False, errors=error_lines)

    except FileNotFoundError:
        # ffprobe not installed
        return None
    except subprocess.TimeoutExpired:
        return None
    except (OSError, ValueError):
        return None
