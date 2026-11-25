"""Putting the runner in place and taking it away: setup, up, down, clean, restore, and the optional
MinIO and image mirror. Every step can be repeated: a step that is already done does nothing."""
import time
from pathlib import Path

from .. import LisaError
from ..components import argo, artifacts, global_storage, image_mirror, interlink, offload, sidecar, tunnel
from ..context import Context
from ..testing.runner import LABEL

# Where the version before the restructure (tag before-restructure) kept its state.
OLD_HOME = Path.home() / "lisa-trial"


def old_version_up() -> bool:
    return any((OLD_HOME / "state" / f).exists() for f in ("mode", "workflowDefaults.json"))


def refuse_old_version() -> None:
    if old_version_up():
        raise LisaError(f"the version before the restructure is still on ({OLD_HOME}/state): switch it off "
                        "first with its own scripts (docs/operations.md, 'Moving from the old scripts')")


def steps(ctx: Context, *todo) -> None:
    """Run (title, function) pairs in order; stop at the first that fails, saying which."""
    for title, fn in todo:
        ctx.console.step(title)
        try:
            fn(ctx)
        except LisaError as e:
            raise LisaError(f"{e}\nin step: {title}. Fix it and run the command again: every step can be "
                            "repeated. 'make status' shows where each side is.") from None


def setup(ctx: Context) -> None:
    ctx.settings.require()
    refuse_old_version()
    todo = [("Argo, and the namespace the workflows run in", argo.install)]
    if ctx.settings.gs_in_cluster:
        todo.append(("a MinIO in the cluster as the Global Storage", global_storage.minio_on))
    todo += [("interLink on this side", interlink.install),
             ("the sidecar's files to the login node", sidecar.sync),
             ("the sidecar on the login node", lambda c: sidecar.hpc(c, "install"))]
    steps(ctx, *todo)
    ctx.say("== set up. Next: make check")


def up(ctx: Context) -> None:
    s = ctx.settings
    s.require()
    refuse_old_version()
    if not argo.installed(ctx):
        raise LisaError("no Argo in the cluster: run 'make setup' first")
    if s.gs_port < 1024:
        raise LisaError(f"Global Storage port {s.gs_port} is below 1024: the job's unprivileged relay cannot bind it")
    now = f"interLink {interlink.version(ctx) or 'off'}, offload {offload.state(ctx)}"
    ctx.say(f"== bringing both sides up (now: {now})")
    todo = [("offload off, so no new pod goes to the HPC side while things change", offload.off),
            # The login node first: the virtual node only becomes Ready once the plugin answers.
            ("the sidecar's files to the login node", sidecar.sync),
            ("the sidecar on the login node (restarted only if its configuration changed)",
             lambda c: sidecar.hpc(c, "install")),
            ("images built beforehand on the login node", lambda c: sidecar.hpc(c, "images")),
            ("interLink on this side", interlink.install)]
    if s.image_mirror:
        todo.append(("the image mirror in the cluster", image_mirror.on))
    todo += [("the tunnel's credentials for the shadow pods", tunnel.credentials_on),
             ("the Global Storage under a Service name", global_storage.service_on),
             ("interLink: the tunnel to the sidecar, the API, the virtual kubelet", interlink.start),
             ("a pod reaches the login node's sshd, as the shadows will", _probe),
             ("the Global Storage as Argo's artifact repository", artifacts.on),
             ("offload on", offload.on)]
    steps(ctx, *todo)
    ctx.say("== both sides up. Next: make test T=00")


def _probe(ctx: Context) -> None:
    if not tunnel.probe(ctx, interlink.shadow_image(ctx)):
        raise LisaError("the pod network cannot reach the login node's SSH port: look at outgoing NAT for "
                        "pods and any firewall on this side")


def down(ctx: Context) -> None:
    offload.off(ctx)
    interlink.stop(ctx)
    tunnel.credentials_off(ctx)
    global_storage.service_off(ctx)
    ctx.say("interLink stopped; the tunnel's credentials and the Global Storage's Service deleted")


def clean(ctx: Context) -> None:
    """Delete the test workflows, and wait until interLink has removed their job folders on the login
    node (they hold data, artifact keys and service-account tokens while a pod runs)."""
    s, c = ctx.settings, ctx.cluster
    n = argo.delete_labelled(ctx, ",".join(f"{k}={v}" for k, v in LABEL.items()))
    ctx.say(f"{n} test workflows deleted")
    left = []
    for _ in range(40 if ctx.processes.running("il-vk") else 1):
        left = c.list("v1", "Pod", fields=f"spec.nodeName={s.node}")
        if not left:
            break
        time.sleep(3)
    if left:
        ctx.console.warn(f"{len(left)} pods still on {s.node}: their job folders stay on the login node until "
                         "interLink deletes them")
    else:
        ctx.say(f"no pod left on {s.node}: interLink removed their job folders")


def restore(ctx: Context) -> None:
    clean(ctx)
    down(ctx)
    try:
        sidecar.hpc(ctx, "uninstall")
    except LisaError as e:
        ctx.console.warn(f"could not stop the sidecar on the login node ({e}): run 'make hpc A=uninstall'")
    interlink.delete_node(ctx)
    artifacts.restore(ctx)
    ctx.say(f"== off. Argo, namespace {ctx.settings.namespace}, the MinIO and the image mirror (if any; "
            f"make minio-off, make mirror-off) and {ctx.settings.home.root} stay.")
