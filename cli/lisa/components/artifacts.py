"""The Global Storage as Argo's default artifact repository in ARGO_NAMESPACE, in the layout of CNES's
PipelineRunner (runner/cluster/artifact-repository.yaml), under the Service name the jobs reach through
the tunnel."""
import json

import yaml

from ..context import Context
from ..templates import render_yaml
from . import global_storage

CONFIGMAP = "artifact-repositories"
SERVER_FIELDS = ("resourceVersion", "uid", "creationTimestamp", "managedFields", "generation")


def _saved(ctx: Context):
    return ctx.settings.home.state / "artifact-repositories.json"


def manifests(ctx: Context) -> list[dict]:
    s = ctx.settings
    configmap, secret = render_yaml(
        "runner/cluster/artifact-repository.yaml", namespace=s.namespace, bucket=s.gs_bucket,
        endpoint=global_storage.endpoint_for_jobs(ctx), insecure=str(s.gs_insecure).lower(),
        protocol="http://" if s.gs_insecure else "https://", cache_bucket=s.gs_cache_bucket,
        global_prefix=s.gs_global_prefix)
    secret["stringData"] = {"accesskey": s.gs_access_key, "secretkey": s.gs_secret_key}
    return [configmap, secret]


def on(ctx: Context) -> None:
    s, c = ctx.settings, ctx.cluster
    store = global_storage.storage(ctx)
    store.create_bucket()
    store.create_bucket(s.gs_cache_bucket)     # CNES's ingest caches GlobalStorage objects here
    existing = c.get("v1", "ConfigMap", CONFIGMAP, s.namespace)
    if existing and not global_storage.ours(existing) and not _saved(ctx).exists():
        for f in SERVER_FIELDS:
            existing["metadata"].pop(f, None)
        _saved(ctx).write_text(json.dumps(existing))
        ctx.say(f"the existing {CONFIGMAP} saved to {_saved(ctx)}; 'lisa restore' puts it back")
    configmap, secret = manifests(ctx)
    c.apply(secret)
    c.apply(configmap)
    ctx.say(f"artifact repository: s3://{s.gs_bucket} at {global_storage.endpoint_for_jobs(ctx)}")


def endpoint_in_use(ctx: Context) -> str:
    cm = ctx.cluster.get("v1", "ConfigMap", CONFIGMAP, ctx.settings.namespace) or {}
    default = (cm.get("metadata", {}).get("annotations") or {}).get(
        "workflows.argoproj.io/default-artifact-repository", "")
    repo = yaml.safe_load((cm.get("data") or {}).get(default) or "{}") or {}
    return (repo.get("s3") or {}).get("endpoint", "")


def restore(ctx: Context) -> None:
    saved = _saved(ctx)
    if saved.exists():
        # Applied by us with what it held before: what we had added and it did not hold is removed.
        ctx.cluster.apply(json.loads(saved.read_text()))
        saved.unlink()
        ctx.say(f"{CONFIGMAP} put back as it was")
