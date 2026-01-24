"""Entry point for running the DriveCatalog API server.

Usage: python -m drivecatalog.api [--port PORT] [--host HOST]
"""

import argparse
import uvicorn


def main() -> None:
    """Parse arguments and run the API server."""
    parser = argparse.ArgumentParser(description="DriveCatalog API Server")
    parser.add_argument(
        "--port",
        type=int,
        default=8100,
        help="Port to run the server on (default: 8100)",
    )
    parser.add_argument(
        "--host",
        type=str,
        default="127.0.0.1",
        help="Host to bind to (default: 127.0.0.1)",
    )
    args = parser.parse_args()

    uvicorn.run(
        "drivecatalog.api.main:app",
        host=args.host,
        port=args.port,
        reload=False,
    )


if __name__ == "__main__":
    main()
