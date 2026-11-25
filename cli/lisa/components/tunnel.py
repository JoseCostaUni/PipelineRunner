"""The reverse tunnel's credentials (runner/cluster/interlink/shadow-credentials.yaml): for every pod,
interLink's shadow pod logs in to the login node with them. They live in the virtual kubelet's
namespace, named after the virtual node, and interLink copies them into every shadow namespace."""
import time

from ..context import Context
from ..paths import OWNER
from ..templates import render_one, render_yaml

SECRET, KNOWN_HOSTS = "lisa-hpc-ssh-key", "lisa-hpc-known-hosts"
KEY_TYPES = ("ssh-ed25519", "ssh-rsa", "ecdsa-sha2")


def _created_marker(ctx: Context):
    return ctx.settings.home.state / f"created-namespace-{ctx.settings.node}"


def credentials_on(ctx: Context) -> None:
    s, c, ns = ctx.settings, ctx.cluster, ctx.settings.node
    if not c.get("v1", "Namespace", ns):
        c.create({"apiVersion": "v1", "kind": "Namespace",
                  "metadata": {"name": ns, "labels": {"app.kubernetes.io/managed-by": OWNER}}})
        _created_marker(ctx).touch()
    ctx.login.run("true")       # pins the login node's host keys, and proves they and the key work
    secret, known = render_yaml("runner/cluster/interlink/shadow-credentials.yaml", namespace=ns)
    secret["stringData"] = {"id_ed25519": s.ssh_key.read_text()}
    known["data"] = {"known_hosts": s.home.known_hosts.read_text()}
    c.apply(secret)
    c.apply(known)


def credentials_off(ctx: Context) -> None:
    c, ns = ctx.cluster, ctx.settings.node
    for kind, name in (("Secret", SECRET), ("ConfigMap", KNOWN_HOSTS)):
        c.delete("v1", kind, name, ns)
        for obj in c.list("v1", kind, fields=f"metadata.name={name}"):
            if "interlink.eu/replicated-from" in (obj["metadata"].get("annotations") or {}):
                c.delete("v1", kind, name, obj["metadata"]["namespace"])
                ctx.say(f"deleted {kind} {obj['metadata']['namespace']}/{name} (interLink's copy)")
    if _created_marker(ctx).exists():
        c.delete("v1", "Namespace", ns)
        _created_marker(ctx).unlink()


def probe(ctx: Context, shadow_image: str) -> bool:
    """A pod with the shadow's image reads the login node's host keys, as every shadow does first."""
    s, c, ns = ctx.settings, ctx.cluster, ctx.settings.node
    pod = render_one("cli/manifests/shadow-probe.yaml", namespace=ns, image=shadow_image,
                     login_host=s.hpc_login_host)
    name = pod["metadata"]["name"]
    c.delete("v1", "Pod", name, ns)
    while c.get("v1", "Pod", name, ns):
        time.sleep(1)
    c.create(pod)
    phase = ""
    for _ in range(150):
        phase = (c.get("v1", "Pod", name, ns) or {}).get("status", {}).get("phase", "")
        if phase in ("Succeeded", "Failed"):
            break
        time.sleep(2)
    out = c.pod_log(ns, name, "probe")
    c.delete("v1", "Pod", name, ns)
    reached = any(t in out for t in KEY_TYPES)
    ctx.console.check(reached, f"a pod on this cluster reaches the sshd of {s.hpc_login_host} (as the shadow will)",
                      f"a pod on this cluster does not reach the sshd of {s.hpc_login_host} "
                      f"(pod {phase or 'not started'}): {out.strip()[-200:]}")
    return reached
