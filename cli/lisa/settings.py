"""The settings of one site (settings/<site>.env), read once into a Settings object.

The file is KEY=VALUE lines, as bash would source them, because the login node's script reads the same
values: '#' starts a comment, values may be quoted, and $NAME or ${NAME} is replaced by an earlier key
or an environment variable. Every key is described in settings/deucalion.env.example.
"""
import os
import re
import shlex
from dataclasses import dataclass, field
from pathlib import Path

from . import LisaError
from .paths import Home

_VAR = re.compile(r"\$(\w+)|\$\{(\w+)\}")

# Keys this version reads; anything else in the file is reported by 'check' and otherwise ignored.
KNOWN = {
    "HPC_LOGIN_HOST", "HPC_USER", "HPC_PROJECT_ROOT", "SLURM_ACCOUNT", "SLURM_PARTITION", "SIDECAR_UNIT",
    "SIDECAR_PORT", "SSH_KEY", "INTERLINK_NODE_NAME", "ARGO_NAMESPACE", "TUNNEL_PORT", "VK_PORT", "VK_IP",
    "K8S_API_HOST", "K8S_API_PORT", "GS_ENDPOINT", "GS_BUCKET", "GS_INSECURE", "GS_ACCESS_KEY",
    "GS_SECRET_KEY", "GS_SERVICE", "GS_GLOBAL_PREFIX", "CNES_DIR", "MINIO_SIZE",
    "EXTRA_FORWARDS", "IL_VERSION",
    "ARGO_VERSION", "ARGO_EXEC_IMAGE",
    "IMAGES", "IMAGE_MIRROR", "MIRROR_BIND", "MIRROR_PRIVATE_REGISTRY", "MIRROR_PRIVATE_USER",
    "MIRROR_PRIVATE_TOKEN", "MINIO_IMAGE", "LISA_HOME", "KUBECONFIG",
}
REQUIRED = ("HPC_LOGIN_HOST", "HPC_USER", "HPC_PROJECT_ROOT", "SLURM_ACCOUNT", "SLURM_PARTITION", "SSH_KEY",
            "INTERLINK_NODE_NAME", "ARGO_NAMESPACE", "GS_ENDPOINT", "GS_BUCKET", "GS_ACCESS_KEY",
            "GS_SECRET_KEY", "ARGO_EXEC_IMAGE")


def read_env_file(path: Path) -> dict[str, str]:
    """KEY=VALUE lines into a dict, with comments, quotes and $NAME references handled as bash does."""
    values: dict[str, str] = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, rest = line.partition("=")
        if not sep or not re.fullmatch(r"[A-Za-z_]\w*", key):
            raise LisaError(f"{path}, line {number}: expected KEY=VALUE, got: {line}")
        try:
            words = shlex.split(rest, comments=True)
        except ValueError as e:
            raise LisaError(f"{path}, line {number}: {e}") from None
        value = " ".join(words)
        values[key] = _VAR.sub(lambda m: values.get(m[1] or m[2], os.environ.get(m[1] or m[2], "")), value)
    return values


@dataclass(frozen=True)
class Settings:
    source: Path
    hpc_login_host: str
    hpc_user: str
    hpc_project_root: str
    slurm_account: str
    slurm_partition: str
    sidecar_unit: str
    sidecar_port: int
    ssh_key: Path
    node: str                       # INTERLINK_NODE_NAME: our virtual node
    namespace: str                  # ARGO_NAMESPACE: where the workflows run
    tunnel_port: int
    vk_port: int
    gs_endpoint: str                # "cluster" (a MinIO of ours) or host:port of an S3 endpoint
    gs_bucket: str
    gs_insecure: bool
    gs_access_key: str
    gs_secret_key: str
    gs_service: str
    gs_global_prefix: str           # buckets of CNES's GlobalStorage, on the same endpoint
    cnes_dir: str                   # where CNES's WorkflowTemplate files are (not in this public repository)
    extra_forwards: tuple[str, ...]
    il_version: str
    argo_version: str
    argo_exec_image: str
    images: tuple[str, ...]
    image_mirror: bool
    mirror_bind: str
    mirror_private_registry: str    # host:port of a registry the mirror logs in to (ESA's GitLab)
    mirror_private_user: str
    mirror_private_token: str       # a GitLab personal access token with read_registry
    minio_image: str
    minio_size: str                 # the MinIO's emptyDir limit (GS_ENDPOINT=cluster)
    kubeconfig: Path
    home: Home
    k8s_api_host: str = ""          # empty: taken from the kubeconfig
    k8s_api_port: str = ""
    vk_ip: str = ""
    missing: tuple[str, ...] = ()   # required keys left empty
    unknown: tuple[str, ...] = ()   # keys this version does not read
    raw: dict = field(default_factory=dict, repr=False)

    @classmethod
    def load(cls, path: Path) -> "Settings":
        if not path.is_file():
            raise LisaError(f"no settings file {path}: copy it from {path.name}.example ('make settings')")
        v = read_env_file(path)
        get = v.get
        home = Path(get("LISA_HOME") or Path.home() / "lisa-runner")
        kubeconfig = Path(get("KUBECONFIG") or os.environ.get("KUBECONFIG") or Path.home() / ".kube/config")
        return cls(
            source=path,
            hpc_login_host=get("HPC_LOGIN_HOST", ""),
            hpc_user=get("HPC_USER", ""),
            hpc_project_root=get("HPC_PROJECT_ROOT", "").rstrip("/"),
            slurm_account=get("SLURM_ACCOUNT", ""),
            slurm_partition=get("SLURM_PARTITION", ""),
            sidecar_unit=get("SIDECAR_UNIT") or "lisa-sidecar",
            sidecar_port=_int(path, "SIDECAR_PORT", get("SIDECAR_PORT") or "4100"),
            ssh_key=Path(get("SSH_KEY", "")),
            node=get("INTERLINK_NODE_NAME", ""),
            namespace=get("ARGO_NAMESPACE", ""),
            tunnel_port=_int(path, "TUNNEL_PORT", get("TUNNEL_PORT") or "5100"),
            vk_port=_int(path, "VK_PORT", get("VK_PORT") or "5830"),
            gs_endpoint=get("GS_ENDPOINT", ""),
            gs_bucket=get("GS_BUCKET") or "argo-artifacts",
            gs_insecure=(get("GS_INSECURE") or "true").lower() == "true",
            gs_access_key=get("GS_ACCESS_KEY", ""),
            gs_secret_key=get("GS_SECRET_KEY", ""),
            gs_service=get("GS_SERVICE") or "global-storage",
            gs_global_prefix=get("GS_GLOBAL_PREFIX") or "globalstorage-",
            cnes_dir=get("CNES_DIR") or str(Path.home() / "cnes"),
            extra_forwards=tuple(get("EXTRA_FORWARDS", "").split()),
            il_version=get("IL_VERSION") or "0.6.3",
            argo_version=get("ARGO_VERSION") or "v3.7.12",
            argo_exec_image=get("ARGO_EXEC_IMAGE", ""),
            images=tuple(get("IMAGES", "").split()),
            image_mirror=(get("IMAGE_MIRROR") or "off") == "on",
            mirror_bind=get("MIRROR_BIND") or "127.77.0.1",
            mirror_private_registry=get("MIRROR_PRIVATE_REGISTRY") or "gitlab.esa.int:4567",
            mirror_private_user=get("MIRROR_PRIVATE_USER", ""),
            mirror_private_token=get("MIRROR_PRIVATE_TOKEN", ""),
            minio_image=get("MINIO_IMAGE") or "docker.io/pgsty/minio:RELEASE.2026-08-04T00-00-00Z",
            minio_size=get("MINIO_SIZE") or "50Gi",
            kubeconfig=kubeconfig.absolute(),   # the virtual kubelet refuses a relative path
            home=Home(home),
            k8s_api_host=get("K8S_API_HOST", ""),
            k8s_api_port=get("K8S_API_PORT", ""),
            vk_ip=get("VK_IP", ""),
            missing=tuple(k for k in REQUIRED if not get(k)),
            unknown=tuple(sorted(set(v) - KNOWN)),
            raw=v,
        )

    def require(self) -> None:
        """Stop with a clear message when the settings cannot work at all."""
        if self.missing:
            raise LisaError(f"empty in {self.source}: {', '.join(self.missing)}")
        if not self.hpc_project_root.startswith("/"):
            raise LisaError(f"HPC_PROJECT_ROOT must be an absolute path; it is '{self.hpc_project_root}'")

    # --- the Global Storage -----------------------------------------------------------------------
    @property
    def gs_in_cluster(self) -> bool:
        return self.gs_endpoint == "cluster"

    @property
    def gs_port(self) -> int:
        if self.gs_in_cluster:
            return 9000
        if ":" in self.gs_endpoint:
            return int(self.gs_endpoint.rsplit(":", 1)[1])
        return 80 if self.gs_insecure else 443

    @property
    def gs_host(self) -> str:
        """The external endpoint's host (not used with GS_ENDPOINT=cluster)."""
        return self.gs_endpoint.rsplit(":", 1)[0]

    @property
    def gs_cache_bucket(self) -> str:
        """Where CNES's ingest keeps GlobalStorage objects it has copied (their globalstoragecache)."""
        return f"{self.gs_bucket}-globalstoragecache"

    @property
    def gs_fqdn(self) -> str:
        """The Global Storage's Service name: what the jobs reach through the tunnel."""
        return f"{self.gs_service}.{self.namespace}.svc.cluster.local"

    # --- the tunnel -------------------------------------------------------------------------------
    @property
    def mirror_address(self) -> str:
        return f"image-mirror.{self.namespace}.svc.cluster.local:5000"

    @property
    def mirror_private_name(self) -> str:
        """How images of the private registry are named behind the mirror: its host, without the port."""
        return self.mirror_private_registry.split(":")[0]

    @property
    def forwards(self) -> list[str]:
        """What every pod asks the reverse tunnel for: the Global Storage, the Kubernetes API on a port an
        unprivileged sshd can bind, the image mirror if on, and EXTRA_FORWARDS."""
        f = [f"{self.gs_fqdn}:{self.gs_port}", "6443:kubernetes.default.svc.cluster.local:443"]
        if self.image_mirror:
            f.append(self.mirror_address)
        return f + list(self.extra_forwards)

    # --- the login node ---------------------------------------------------------------------------
    def hpc_path(self, *parts: str) -> str:
        """A path under HPC_PROJECT_ROOT on the login node: runner/ (what 'sync' copies there), sidecar/
        (the Slurm plugin, its configuration, log and job folders), sock/ (the tunnel's sockets), images/."""
        return "/".join((self.hpc_project_root,) + parts)


def _int(path: Path, key: str, value: str) -> int:
    try:
        return int(value)
    except ValueError:
        raise LisaError(f"{path}: {key} must be a number, not '{value}'") from None
