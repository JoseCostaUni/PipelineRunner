"""The image mirror (IMAGE_MIRROR=on): zot in ARGO_NAMESPACE, which fetches images on demand from their
registries. Every pod gets a forward to it through the tunnel, so a job's Singularity pulls any image a
workflow names, on the compute node (runner/cluster/image-mirror.yaml; docs/architecture.md, "Any
image")."""
import time

from .. import LisaError
from ..adapters import web
from ..context import Context
from ..templates import render_yaml

NAME = "image-mirror"


def on(ctx: Context) -> None:
    s, c = ctx.settings, ctx.cluster
    if not c.get("v1", "Namespace", s.namespace):
        raise LisaError(f"no namespace {s.namespace}: run 'lisa setup' first")
    docs = render_yaml("runner/cluster/image-mirror.yaml", namespace=s.namespace)
    config = next(d for d in docs if d["kind"] == "ConfigMap")
    before = (c.get("v1", "ConfigMap", NAME, s.namespace) or {}).get("data")
    for obj in docs:
        c.apply(obj)
    if before is not None and before != config["data"]:
        c.restart_deployment(s.namespace, NAME)     # zot reads its configuration once, at start
    if not c.wait_deployment(s.namespace, NAME):
        raise LisaError(f"the image mirror did not start: kubectl -n {s.namespace} describe pod -l app={NAME}")
    here = f"{c.get('v1', 'Service', NAME, s.namespace)['spec']['clusterIP']}:5000"
    # Ask it for Argo's executor and for a bare Docker Hub name: it fetches them now, which shows that
    # it reaches the registries. Until kube-proxy routes the new Service, nothing answers (0).
    for image in (s.argo_exec_image, "alpine:3.20"):
        code = 0
        for _ in range(30):
            code = web.manifest_status(here, image)
            if code:
                break
            time.sleep(2)
        if code != 200:
            raise LisaError(f"the image mirror answered HTTP {code} for {image}: does the cluster reach its "
                            f"registry? kubectl -n {s.namespace} logs deploy/{NAME}")
    ctx.say(f"image mirror in {s.namespace}: {here} from here, {s.mirror_address} for the jobs; it fetched "
            f"{s.argo_exec_image} and alpine:3.20")
    if not s.image_mirror:
        ctx.console.warn(f"IMAGE_MIRROR is not 'on' in {s.source.name}, so the pods get no forward to it")


def off(ctx: Context) -> None:
    s, c = ctx.settings, ctx.cluster
    for obj in render_yaml("runner/cluster/image-mirror.yaml", namespace=s.namespace):
        c.delete(obj["apiVersion"], obj["kind"], obj["metadata"]["name"], s.namespace)
    ctx.say(f"image mirror in {s.namespace} deleted, with what it had fetched")


def ready(ctx: Context) -> str:
    d = ctx.cluster.get("apps/v1", "Deployment", NAME, ctx.settings.namespace)
    return f"{d.get('status', {}).get('readyReplicas', 0)}/1 ready" if d else "not there"
