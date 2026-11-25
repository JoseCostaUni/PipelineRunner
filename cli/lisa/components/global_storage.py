"""The Global Storage, Argo's artifact repository: a MinIO of ours in the cluster (GS_ENDPOINT=cluster)
or an S3 endpoint the Kubernetes side reaches. Either way the jobs reach it through the tunnel under the
Service name GS_SERVICE, because the tunnel maps names, not IP addresses."""
import ipaddress
import time

from .. import LisaError
from ..adapters.storage import Storage
from ..context import Context
from ..paths import OWNER
from ..templates import render_yaml

MINIO = "lisa-minio"


def endpoint_here(ctx: Context) -> str:
    """Where the Kubernetes side reaches it: the MinIO Service's cluster IP, or GS_ENDPOINT."""
    s = ctx.settings
    if not s.gs_in_cluster:
        return s.gs_endpoint
    svc = ctx.cluster.get("v1", "Service", s.gs_service, s.namespace)
    if not svc:
        raise LisaError("GS_ENDPOINT=cluster, but there is no MinIO yet: run 'lisa minio on' (make minio)")
    return f"{svc['spec']['clusterIP']}:9000"


def endpoint_for_jobs(ctx: Context) -> str:
    return f"{ctx.settings.gs_fqdn}:{ctx.settings.gs_port}"


def storage(ctx: Context) -> Storage:
    s = ctx.settings
    return Storage(endpoint_here(ctx), s.gs_access_key, s.gs_secret_key, s.gs_insecure, s.gs_bucket)


def ours(obj: dict | None) -> bool:
    return bool(obj) and obj["metadata"].get("labels", {}).get("app.kubernetes.io/managed-by") == OWNER


# --- a MinIO in the cluster ------------------------------------------------------------------------
def minio_on(ctx: Context) -> None:
    s, c = ctx.settings, ctx.cluster
    if not s.gs_in_cluster:
        raise LisaError(f"set GS_ENDPOINT=cluster in {s.source.name} to use a MinIO in the cluster")
    if len(s.gs_access_key) < 3 or len(s.gs_secret_key) < 8:
        raise LisaError("GS_ACCESS_KEY (3 or more characters) and GS_SECRET_KEY (8 or more) become "
                        "this MinIO's credentials: set them")
    secret, *rest = render_yaml("cli/manifests/minio.yaml", namespace=s.namespace,
                                service=s.gs_service, image=s.minio_image)
    secret["stringData"] = {"MINIO_ROOT_USER": s.gs_access_key, "MINIO_ROOT_PASSWORD": s.gs_secret_key}
    for obj in (secret, *rest):
        c.apply(obj)
    if not c.wait_deployment(s.namespace, MINIO):
        raise LisaError(f"MinIO did not start: kubectl -n {s.namespace} describe pod -l app={MINIO}")
    st = storage(ctx)
    for _ in range(30):         # the pod is ready before kube-proxy routes the new Service
        if st.problem() is None:
            break
        time.sleep(2)
    st.create_bucket()
    ctx.say(f"MinIO in {s.namespace}: {st.endpoint} from here, {endpoint_for_jobs(ctx)} for the jobs; "
            f"bucket {s.gs_bucket}")


def minio_off(ctx: Context) -> None:
    s, c = ctx.settings, ctx.cluster
    c.delete("apps/v1", "Deployment", MINIO, s.namespace)
    c.delete("v1", "Service", s.gs_service, s.namespace)
    c.delete("v1", "Secret", "lisa-minio-root", s.namespace)
    ctx.say(f"MinIO in {s.namespace} deleted, with its data")


# --- an S3 endpoint outside the cluster, under a Service name --------------------------------------
def service_on(ctx: Context) -> None:
    s, c = ctx.settings, ctx.cluster
    if s.gs_in_cluster:
        return                  # the MinIO's own Service is that name already
    existing = c.get("v1", "Service", s.gs_service, s.namespace)
    if existing and not ours(existing):
        raise LisaError(f"Service {s.namespace}/{s.gs_service} exists and is not ours: set GS_SERVICE "
                        "to another name")
    try:
        ipaddress.IPv4Address(s.gs_host)
        docs = render_yaml("runner/cluster/global-storage/external-ip.yaml", namespace=s.namespace,
                           service=s.gs_service, port=s.gs_port, address=s.gs_host)
    except ValueError:
        docs = render_yaml("runner/cluster/global-storage/external-name.yaml", namespace=s.namespace,
                           service=s.gs_service, port=s.gs_port, host=s.gs_host)
    for obj in docs:
        c.apply(obj)


def service_off(ctx: Context) -> None:
    s, c = ctx.settings, ctx.cluster
    if s.gs_in_cluster or not ours(c.get("v1", "Service", s.gs_service, s.namespace)):
        return
    c.delete("v1", "Service", s.gs_service, s.namespace)
    c.delete("discovery.k8s.io/v1", "EndpointSlice", f"{s.gs_service}-1", s.namespace)
