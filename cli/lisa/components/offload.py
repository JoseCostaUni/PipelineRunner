"""Offload: Argo's workflowDefaults send every workflow's pods to our virtual node, with the tunnel's
forwards (runner/cluster/workflow-defaults.yaml). 'off' puts back exactly what was there before."""
import json
import time

import yaml

from .. import LisaError
from ..context import Context
from ..templates import render_one, to_yaml
from .argo import ARGO_NS

CONFIGMAP = "workflow-controller-configmap"


def _saved(ctx: Context):
    return ctx.settings.home.state / "workflowDefaults.json"


def defaults(ctx: Context) -> dict:
    """What offload sets, from the template and the settings."""
    s = ctx.settings
    d = render_one("runner/cluster/workflow-defaults.yaml", node=s.node, account=s.slurm_account,
                   partition=s.slurm_partition, forwards=" ".join(s.forwards))
    if s.image_mirror:
        annotations = d["spec"]["podMetadata"]["annotations"]
        annotations["slurm-job.vk.io/flags"] += " --exclusive"
        annotations["interlink.eu/reverse-bind"] = s.mirror_bind
    return d


def current(ctx: Context) -> str | None:
    cm = ctx.cluster.get("v1", "ConfigMap", CONFIGMAP, ARGO_NS)
    if cm is None:
        raise LisaError(f"no ConfigMap {ARGO_NS}/{CONFIGMAP}: is Argo installed? ('lisa setup')")
    return (cm.get("data") or {}).get("workflowDefaults")


def on(ctx: Context) -> None:
    saved = _saved(ctx)
    if not saved.exists():      # keep what was there before the first 'on', to put it back
        saved.write_text(json.dumps(current(ctx)))
    ctx.cluster.merge_patch("v1", "ConfigMap", CONFIGMAP, {"data": {"workflowDefaults": to_yaml(defaults(ctx))}},
                            ARGO_NS)
    time.sleep(5)               # the controller reloads its ConfigMap
    s = ctx.settings
    ctx.say(f"offload ON: every workflow's pods go to {s.node}, partition {s.slurm_partition}, "
            f"tunnel to: {' '.join(s.forwards)}")
    if s.image_mirror:
        ctx.say(f"images from the image mirror, each pod on a node of its own (relay {s.mirror_bind}, --exclusive)")
    ctx.say("Note: this applies to ALL workflows of this Argo, other users' too. Switch off after the trial.")


def off(ctx: Context) -> None:
    saved = _saved(ctx)
    if not saved.exists():
        ctx.say("offload already off")
        return
    before = json.loads(saved.read_text())
    # A merge patch with null removes the key, as it was when nothing was there.
    ctx.cluster.merge_patch("v1", "ConfigMap", CONFIGMAP, {"data": {"workflowDefaults": before}}, ARGO_NS)
    saved.unlink()
    time.sleep(5)
    ctx.say("offload OFF: workflowDefaults put back as they were")


def state(ctx: Context) -> str:
    """'on' (to our node, with the tunnel), 'off', or what else is set."""
    value = current(ctx)
    if not value:
        return "off"
    spec = (yaml.safe_load(value) or {}).get("spec", {})
    to_us = spec.get("nodeSelector", {}).get("kubernetes.io/hostname") == ctx.settings.node
    forwards = "interlink.eu/reverse-forwards" in spec.get("podMetadata", {}).get("annotations", {})
    if to_us and forwards:
        return "on"
    return "on, without the tunnel's forwards" if to_us else "off (other workflowDefaults are set)"
