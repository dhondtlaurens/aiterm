"""The bearer-token representation shared by both Operator transports during activation."""
import re

_TOKEN = re.compile(r"[0-9a-fA-F]{64}")


def well_formed(token: str) -> bool:
    return _TOKEN.fullmatch(token) is not None
