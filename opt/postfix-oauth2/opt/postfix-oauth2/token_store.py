import json
import os
import tempfile
from pathlib import Path


class TokenStoreError(Exception):
    """Raised when a token file cannot be written safely."""


def write_token_file(
    path: str,
    access_token: str,
    expiry: int,
    user: str,
) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)

    payload = {
        "access_token": access_token,
        "expiry": expiry,
        "user": user,
        "refresh_token": "NA",
    }

    temp_path: str | None = None

    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=target.parent,
            prefix=f".{target.name}.",
            delete=False,
        ) as handle:
            temp_path = handle.name

            json.dump(payload, handle, separators=(",", ":"))
            handle.write("\n")
            handle.flush()

            os.fchmod(handle.fileno(), 0o640)
            os.fsync(handle.fileno())

        os.replace(temp_path, target)

        directory_fd = os.open(
            target.parent,
            os.O_RDONLY | os.O_DIRECTORY,
        )

        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)

    except OSError as exc:
        if temp_path:
            try:
                os.unlink(temp_path)
            except FileNotFoundError:
                pass

        raise TokenStoreError(
            f"Cannot write token file {target}: {exc}"
        ) from exc