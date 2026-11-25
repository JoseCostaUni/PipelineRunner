"""Argo Workflows: installed once per cluster (namespace argo) if it is not there, the namespace the
workflows run in (ARGO_NAMESPACE), and the Workflows themselves."""
import time

import yaml

from ..adapters import web
from ..context import Context
from ..paths import OWNER
from ..templates import render_yaml

ARGO_NS = "argo"
CONTROLLER = "workflow-controller"
WORKFLOW = ("argoproj.io/v1alpha1", "Workflow")
DONE = ("Succeeded", "Failed", "Error")


def installed(ctx: Context) -> bool:
    return ctx.cluster.get("apps/v1", "Deployment", CONTROLLER, ARGO_NS) is not None


def install(ctx: Context) -> None:
    """Argo ARGO_VERSION from its release, only if the cluster has none: it is shared."""
    s, c = ctx.settings, ctx.cluster
    if installed(ctx):
        ctx.say(f"Argo already installed in namespace {ARGO_NS} ({executor_image(ctx)}): not touched")
    else:
        url = f"https://github.com/argoproj/argo-workflows/releases/download/{s.argo_version}/install.yaml"
        ctx.say(f"installing Argo {s.argo_version} in namespace {ARGO_NS} from {url}")
        if not c.get("v1", "Namespace", ARGO_NS):
            c.create({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": ARGO_NS}})
        for obj in yaml.safe_load_all(web.text(url)):
            if obj:
                c.apply(obj, namespace=ARGO_NS)
        if not c.wait_deployment(ARGO_NS, CONTROLLER):
            ctx.console.warn(f"Argo's controller is not ready yet: kubectl -n {ARGO_NS} get pods")
    prepare_namespace(ctx)


def prepare_namespace(ctx: Context) -> None:
    ns, c = ctx.settings.namespace, ctx.cluster
    if not c.get("v1", "Namespace", ns):
        c.create({"apiVersion": "v1", "kind": "Namespace",
                  "metadata": {"name": ns, "labels": {"app.kubernetes.io/managed-by": OWNER}}})
    for obj in render_yaml("cli/manifests/argo-namespace.yaml", namespace=ns):
        c.apply(obj)
    ctx.say(f"namespace {ns} ready for the workflows (role argo-workflow-role for its default account)")


def executor_image(ctx: Context) -> str:
    """The argoexec image Argo's controller puts in every pod."""
    d = ctx.cluster.get("apps/v1", "Deployment", CONTROLLER, ARGO_NS) or {}
    containers = d.get("spec", {}).get("template", {}).get("spec", {}).get("containers") or [{}]
    args = containers[0].get("args") or []
    if "--executor-image" in args[:-1]:
        return args[args.index("--executor-image") + 1]
    return (containers[0].get("image") or "").replace("workflow-controller", "argoexec")


# --- Workflows -------------------------------------------------------------------------------------
def submit(ctx: Context, workflow: dict, labels: dict[str, str]) -> str:
    """Create the Workflow (as 'argo submit' does) and return its name."""
    wf = {**workflow, "metadata": {**workflow.get("metadata", {})}}
    wf["metadata"]["labels"] = {**wf["metadata"].get("labels", {}), **labels}
    wf["metadata"]["namespace"] = ctx.settings.namespace
    return ctx.cluster.create(wf)["metadata"]["name"]


def get(ctx: Context, name: str) -> dict:
    return ctx.cluster.get(*WORKFLOW, name, ctx.settings.namespace) or {}


def wait(ctx: Context, name: str, timeout: int) -> dict:
    """Until it has ended; stopped after timeout seconds. Returns it as it ended."""
    end = time.time() + timeout
    while time.time() < end:
        wf = get(ctx, name)
        status = wf.get("status", {})
        if status.get("phase") in DONE and status.get("finishedAt"):
            return wf
        time.sleep(5)
    stop(ctx, name)
    time.sleep(10)
    return get(ctx, name)


def stop(ctx: Context, name: str) -> None:
    """As 'argo stop': running steps end, and the workflow fails."""
    ctx.cluster.merge_patch(*WORKFLOW, name, {"spec": {"shutdown": "Stop"}}, ctx.settings.namespace)


def step_pods(ctx: Context, name: str) -> list[dict]:
    return ctx.cluster.list("v1", "Pod", ctx.settings.namespace,
                            labels=f"workflows.argoproj.io/workflow={name}")


def delete_labelled(ctx: Context, label: str) -> int:
    return ctx.cluster.delete_all(*WORKFLOW, ctx.settings.namespace, label)
