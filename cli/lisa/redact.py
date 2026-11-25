"""Blanking secrets in what the tool keeps or hands out (evidence, diagnostics).

interLink's verbose logs record pods as it passes them on, with Secret data (base64), service-account
tokens, and, for a container that takes a secret into its environment (CNES's ingest and dispatch take
the storage keys that way), the secret's plain value. So the known secrets are blanked by value, in every
form they may take, as well as by shape."""
import base64
import re

from .settings import Settings

TOKEN = re.compile(r"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+")
SECRET_DATA = re.compile(r'(\\*"data\\*":\{)[^}]*')
BLANK = "<redacted>"


def b64(value: str) -> str:
    return base64.b64encode(value.encode()).decode()


def known(s: Settings) -> list[str]:
    """The secrets in the settings, plain and in base64; the plain access key is left alone (it is a user
    name, like 'lisa' in 'lisa-jcosta', and blanking it would blank ordinary words)."""
    values = [v for v in (s.gs_secret_key, s.mirror_private_token) if v]
    values += [b64(v) for v in (s.gs_secret_key, s.gs_access_key, s.mirror_private_token) if v]
    return sorted(set(values), key=len, reverse=True)


def text(value: str, s: Settings) -> str:
    for secret in known(s):
        value = value.replace(secret, BLANK)
    return TOKEN.sub("<token>", SECRET_DATA.sub(r"\1" + BLANK, value))
