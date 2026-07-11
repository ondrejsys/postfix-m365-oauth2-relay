import time
from pathlib import Path
from typing import Any
from token_store import write_token_file
from config import ConfigurationError, load_config

import requests
import logging

class TokenRequestError(Exception):
    """Raised when an OAuth2 access token cannot be obtained."""


def request_access_token(application: dict[str, Any]) -> tuple[str, int]:
    try:
        client_secret = Path(
            application["client_secret_file"]
        ).read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise TokenRequestError(
            f"Cannot read client secret for "
            f"{application['name']}: {exc}"
        ) from exc

    if not client_secret:
        raise TokenRequestError(
            f"Client secret file is empty for {application['name']}."
        )

    token_endpoint = (
        "https://login.microsoftonline.com/"
        f"{application['tenant_id']}/oauth2/v2.0/token"
    )

    try:
        response = requests.post(
            token_endpoint,
            data={
                "client_id": application["client_id"],
                "client_secret": client_secret,
                "grant_type": "client_credentials",
                "scope": application["scope"],
            },
            timeout=30,
        )

        response.raise_for_status()
        result = response.json()

    except (OSError, requests.RequestException, ValueError) as exc:
        raise TokenRequestError(
            f"Token request failed for {application['name']}: {exc}"
        ) from exc

    access_token = result.get("access_token")
    expires_in = result.get("expires_in")

    if not isinstance(access_token, str) or not access_token:
        raise TokenRequestError(
            f"Token response for {application['name']} "
            "does not contain access_token."
        )

    try:
        expires_in = int(expires_in)
    except (TypeError, ValueError) as exc:
        raise TokenRequestError(
            f"Invalid expires_in for {application['name']}."
        ) from exc

    if expires_in <= 0:
        raise TokenRequestError(
            f"Invalid expires_in for {application['name']}."
        )

    expiry = int(time.time()) + expires_in

    return access_token, expiry

def refresh_application(application: dict[str, Any]) -> tuple[int, int]:
    access_token, expiry = request_access_token(application)

    written = 0

    for mailbox in application["mailboxes"]:
        write_token_file(
            path=mailbox["token_file"],
            access_token=access_token,
            expiry=expiry,
            user=mailbox["user"],
        )
        written += 1

    return written, expiry

def token_needs_refresh(
    expiry: int | None,
    refresh_before_expiry: int,
) -> bool:
    if expiry is None:
        return True

    return int(time.time()) >= expiry - refresh_before_expiry

def run_daemon(config: dict[str, Any]) -> None:
    logger = logging.getLogger("postfix-oauth2")
    expiries: dict[str, int] = {}

    while True:
        for application in config["applications"]:
            name = application["name"]
            expiry = expiries.get(name)

            if not token_needs_refresh(
                expiry,
                config["refresh_before_expiry"],
            ):
                continue

            try:
                written, expiry = refresh_application(application)
                expiries[name] = expiry
                
                logger.info(
                    "Token refreshed for application %s; files written: %d",
                    name,
                    written,
                )

            except Exception:
                logger.exception(
                    "Token refresh failed for application %s",
                    name,
                )

        time.sleep(config["check_interval"])    
        
def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(levelname)s %(message)s",
    )

    logger = logging.getLogger("postfix-oauth2")

    try:
        config = load_config("/etc/postfix-oauth2/config.yaml")
    except ConfigurationError:
        logger.exception("Configuration loading failed")
        return 1

    logger.info("Postfix OAuth2 token daemon started")
    run_daemon(config)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())        