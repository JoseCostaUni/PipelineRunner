"""Plain HTTP from the Kubernetes side: downloads, and asking the image mirror for a manifest."""
import socket
import ssl
import urllib.error
import urllib.request
from pathlib import Path

from .. import LisaError

MANIFEST_TYPES = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


def download(url: str, dest: Path) -> None:
    """To dest, atomically (a failed download leaves nothing)."""
    part = dest.with_name(dest.name + ".part")
    try:
        with urllib.request.urlopen(url, timeout=60) as r, open(part, "wb") as f:
            while chunk := r.read(1 << 20):
                f.write(chunk)
    except (urllib.error.URLError, OSError) as e:
        part.unlink(missing_ok=True)
        raise LisaError(f"download of {url} failed: {e}") from None
    part.replace(dest)


def exists(url: str) -> bool:
    try:
        with urllib.request.urlopen(urllib.request.Request(url, method="HEAD"), timeout=30):
            return True
    except (urllib.error.URLError, OSError):
        return False


def text(url: str) -> str:
    try:
        with urllib.request.urlopen(url, timeout=60) as r:
            return r.read().decode()
    except (urllib.error.URLError, OSError) as e:
        raise LisaError(f"could not fetch {url}: {e}") from None


def manifest_status(registry: str, image: str) -> int:
    """HTTP status of the image's manifest at a registry (host:port, plain HTTP); 0 when nothing answers.
    A bare name means Docker Hub, as for Kubernetes: alpine:3.20 is library/alpine there."""
    repo, _, tag = image.rpartition(":")
    req = urllib.request.Request(f"http://{registry}/v2/{repo}/manifests/{tag}",
                                 headers={"Accept": MANIFEST_TYPES})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except (urllib.error.URLError, OSError):
        return 0


def tls_name_valid(host: str, port: int, ca_file: str | None, name: str) -> bool:
    """Whether the TLS server at host:port shows a certificate, signed by the CA, valid for name: what a
    client reaching it under that name (through the tunnel) will check."""
    ctx = ssl.create_default_context(cafile=ca_file)
    try:
        with socket.create_connection((host, port), timeout=10) as s, ctx.wrap_socket(s, server_hostname=name):
            return True
    except (ssl.SSLError, OSError):
        return False


def port_free(port: int) -> bool:
    """Whether nothing listens on this port here (any address)."""
    with socket.socket() as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(("0.0.0.0", port))
            return True
        except OSError:
            return False
