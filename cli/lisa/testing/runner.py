"""Running the tests: put their inputs in the Global Storage, submit each workflow, wait for it, and
gather what it did (its steps, its pods, where Slurm ran them, their output) for the checks."""
import time
from dataclasses import dataclass, field

import yaml

from ..components import argo, global_storage, interlink, sidecar
from ..context import Context
from ..paths import TESTS
from .expect import Check, Outcome, Pod, evaluate
from .suite import Test

LABEL = {"lisa-test": "true"}       # every test workflow ('lisa clean' deletes them by it)


@dataclass
class TestRun:
    __test__ = False                # not a test case, for pytest
    test: Test
    workflow_name: str = ""
    workflow: dict = field(default_factory=dict)
    seconds: int = 0
    pods: list[Pod] = field(default_factory=list)
    checks: list[Check] = field(default_factory=list)
    logs: str = ""
    diag: str = ""
    error: str = ""                 # why it could not run at all

    @property
    def phase(self) -> str:
        return self.workflow.get("status", {}).get("phase", "not run")

    @property
    def message(self) -> str:
        """Argo's reason when the workflow did not succeed (e.g. a template or parameter it could not
        resolve, which ends it in Error before any pod)."""
        return self.workflow.get("status", {}).get("message", "") if self.phase != "Succeeded" else ""

    @property
    def passed(self) -> bool:
        return not self.error and bool(self.checks) and all(c.passed for c in self.checks)


def prepare(ctx: Context, tests: list[Test]) -> None:
    """The module library the workflows use, and the Global Storage as the tests expect it: their
    inputs, and nothing an earlier run wrote (which could make a check pass without this run)."""
    ctx.cluster.apply(_modules(), namespace=ctx.settings.namespace)
    store = global_storage.storage(ctx)
    gone = store.delete_prefix("tests/")
    n = 0
    for t in tests:
        for key, path in t.inputs().items():
            store.upload(path, key)
            n += 1
    ctx.say(f"Global Storage reset: {gone} objects of earlier runs deleted, {n} inputs uploaded under tests/")


def run(ctx: Context, test: Test, timeout: int, on_submit=lambda name: None) -> TestRun:
    r = TestRun(test)
    start = time.time()
    try:
        r.workflow_name = argo.submit(ctx, test.workflow, LABEL)
    except Exception as e:
        r.error = f"submission failed: {e}"
        return r
    on_submit(r.workflow_name)
    r.workflow = argo.wait(ctx, r.workflow_name, timeout)
    r.seconds = int(time.time() - start)
    pods = argo.step_pods(ctx, r.workflow_name)
    jobs = sidecar.jobs(ctx) if pods else {}
    r.pods = [Pod(p["metadata"]["name"], p["metadata"]["uid"], p["spec"].get("nodeName", ""),
                  jobs.get(p["metadata"]["uid"])) for p in pods]
    r.logs = "".join(_logs(ctx, p) for p in pods)
    store, cache = global_storage.storage(ctx), {}
    outcome = Outcome(r.phase, _steps(r.workflow), r.pods, ctx.settings.node, ctx.settings.slurm_partition,
                      read=lambda key: cache[key] if key in cache else cache.setdefault(key, store.read_text(key)))
    r.checks = evaluate(test.expect, outcome)
    if not r.passed:
        r.diag = interlink.diagnostics(ctx)
    _release(ctx, r, stuck(pods))
    return r


def stuck(pods: list[dict]) -> list[dict]:
    """Step pods still Pending or Running once the test is over (it ended, or timed out and was stopped).
    A pod whose main never started survives Argo's stop, even after the workflow is marked Failed, and
    its Slurm job keeps its node (a whole one with --exclusive)."""
    return [p for p in pods if (p.get("status") or {}).get("phase") in ("Pending", "Running")]


def _release(ctx: Context, r: TestRun, pods: list[dict]) -> None:
    """Delete such pods once the test is recorded, so interLink cancels their Slurm jobs."""
    for p in pods:
        ctx.cluster.delete("v1", "Pod", p["metadata"]["name"], ctx.settings.namespace)
    if pods:
        r.diag += (f"\n== the workflow is {r.phase} but these pods were still running: deleted "
                   f"({', '.join(p['metadata']['name'] for p in pods)}), so interLink cancels their Slurm jobs\n")


def _steps(workflow: dict) -> dict[str, str]:
    """The steps that ran as pods, and the phase each ended in."""
    nodes = sorted(workflow.get("status", {}).get("nodes", {}).values(), key=lambda n: n.get("displayName", ""))
    steps: dict[str, str] = {}
    for n in nodes:
        if n.get("type") == "Pod":
            steps.setdefault(n.get("displayName", ""), n.get("phase", ""))
    return steps


def _logs(ctx: Context, pod: dict) -> str:
    """Each container's own output, as the virtual kubelet serves it."""
    name, spec = pod["metadata"]["name"], pod["spec"]
    out = ""
    for c in spec.get("initContainers", []) + spec.get("containers", []):
        out += f"== {name} / {c['name']}\n" + ctx.cluster.pod_log(ctx.settings.namespace, name, c["name"])
    return out


def _modules() -> dict:
    return yaml.safe_load((TESTS / "modules.yaml").read_text())
