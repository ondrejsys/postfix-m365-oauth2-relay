from pathlib import Path
from typing import Any

import yaml


class ConfigurationError(Exception):
    """Raised when the daemon configuration is invalid."""


def load_config(path: str) -> dict[str, Any]:
    config_path = Path(path)

    if not config_path.is_file():
        raise ConfigurationError(f"Configuration file does not exist: {path}")

    try:
        with config_path.open("r", encoding="utf-8") as handle:
            config = yaml.safe_load(handle)
    except (OSError, yaml.YAMLError) as exc:
        raise ConfigurationError(f"Cannot read configuration: {exc}") from exc

    if not isinstance(config, dict):
        raise ConfigurationError("Configuration root must be a YAML mapping.")

    check_interval = config.get("check_interval", 60)
    refresh_before_expiry = config.get("refresh_before_expiry", 600)
    applications = config.get("applications")

    if not isinstance(check_interval, int) or check_interval <= 0:
        raise ConfigurationError("check_interval must be a positive integer.")

    if not isinstance(refresh_before_expiry, int) or refresh_before_expiry <= 0:
        raise ConfigurationError(
            "refresh_before_expiry must be a positive integer."
        )

    if not isinstance(applications, list) or not applications:
        raise ConfigurationError(
            "applications must be a non-empty YAML list."
        )

    for index, application in enumerate(applications):
        _validate_application(application, index)

    config["check_interval"] = check_interval
    config["refresh_before_expiry"] = refresh_before_expiry

    return config


def _validate_application(application: Any, index: int) -> None:
    prefix = f"applications[{index}]"

    if not isinstance(application, dict):
        raise ConfigurationError(f"{prefix} must be a YAML mapping.")

    required_fields = (
        "name",
        "tenant_id",
        "client_id",
        "client_secret_file",
        "scope",
        "mailboxes",
    )

    for field in required_fields:
        if field not in application:
            raise ConfigurationError(f"{prefix}.{field} is required.")

    for field in required_fields[:-1]:
        value = application[field]
        if not isinstance(value, str) or not value.strip():
            raise ConfigurationError(
                f"{prefix}.{field} must be a non-empty string."
            )

    secret_path = Path(application["client_secret_file"])
    if not secret_path.is_file():
        raise ConfigurationError(
            f"{prefix}.client_secret_file does not exist: {secret_path}"
        )

    mailboxes = application["mailboxes"]

    if not isinstance(mailboxes, list) or not mailboxes:
        raise ConfigurationError(
            f"{prefix}.mailboxes must be a non-empty list."
        )

    for mailbox_index, mailbox in enumerate(mailboxes):
        mailbox_prefix = f"{prefix}.mailboxes[{mailbox_index}]"

        if not isinstance(mailbox, dict):
            raise ConfigurationError(
                f"{mailbox_prefix} must be a YAML mapping."
            )

        for field in ("user", "token_file"):
            value = mailbox.get(field)

            if not isinstance(value, str) or not value.strip():
                raise ConfigurationError(
                    f"{mailbox_prefix}.{field} must be a non-empty string."
                )
