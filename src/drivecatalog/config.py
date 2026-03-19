"""Configuration file support for DriveCatalog."""

import os
from dataclasses import dataclass
from pathlib import Path

import yaml

# Environment variable for custom config path (useful for testing)
CONFIG_PATH_ENV = "DRIVECATALOG_CONFIG"


@dataclass
class Config:
    """DriveCatalog configuration settings."""

    auto_scan_enabled: bool = True
    auto_scan_drives: list[str] | None = None  # None means all drives


def get_config_path() -> Path:
    """Return path to config file, creating parent directory if needed.

    Default location: ~/.drivecatalog/config.yaml
    Override with DRIVECATALOG_CONFIG environment variable.
    """
    if env_path := os.environ.get(CONFIG_PATH_ENV):
        config_path = Path(env_path)
    else:
        config_path = Path.home() / ".drivecatalog" / "config.yaml"

    # Create parent directory with secure permissions if it doesn't exist
    config_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)

    return config_path


def load_config() -> Config:
    """Load configuration from YAML file.

    Creates default config file if it doesn't exist.

    Returns:
        Config object with loaded or default settings.
    """
    config_path = get_config_path()

    if not config_path.exists():
        # Create default config
        config = Config()
        save_config(config)
        return config

    try:
        with open(config_path) as f:
            data = yaml.safe_load(f)

        if data is None:
            # Empty file, return defaults
            return Config()

        return Config(
            auto_scan_enabled=data.get("auto_scan_enabled", True),
            auto_scan_drives=data.get("auto_scan_drives", None),
        )
    except (yaml.YAMLError, OSError):
        # On error, return defaults
        return Config()


def save_config(config: Config) -> None:
    """Save configuration to YAML file.

    Args:
        config: Config object to save.
    """
    config_path = get_config_path()

    data = {
        "auto_scan_enabled": config.auto_scan_enabled,
    }

    # Only include auto_scan_drives if it's set (not None)
    if config.auto_scan_drives is not None:
        data["auto_scan_drives"] = config.auto_scan_drives

    with open(config_path, "w") as f:
        yaml.safe_dump(data, f, default_flow_style=False)
