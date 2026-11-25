"""What a test must produce (its expect.yaml), and the checks that compare it with what a run did.

expect.yaml:
  phase: Succeeded                  the workflow's final phase in Argo (required)
  steps: {<step>: <phase>}          steps that ran as pods, and the phase each ended in
  outputs: {<key>: <text or list>}  objects in the Global Storage after the run, and text each contains
  needs: mirror                     run only when the setup has it ('lisa test' with no numbers skips it)

Every test also gets the 'where' check: each step pod ran on the virtual node, as a Slurm job in the
partition. So no test can pass on Argo's word alone, nor with a step that ran on the Kubernetes side.
"""
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

import yaml

from .. import LisaError

FEATURES = {"mirror": "the image mirror (IMAGE_MIRROR=on)"}


@dataclass(frozen=True)
class Expectation:
    phase: str
    steps: dict[str, str] = field(default_factory=dict)
    outputs: dict[str, tuple[str, ...]] = field(default_factory=dict)
    needs: str | None = None

    @classmethod
    def load(cls, path: Path) -> "Expectation":
        d = yaml.safe_load(path.read_text()) or {}
        unknown = set(d) - {"phase", "steps", "outputs", "needs"}
        if unknown or "phase" not in d:
            raise LisaError(f"{path}: needs 'phase'; may have steps, outputs, needs; got {sorted(d)}")
        if d.get("needs") and d["needs"] not in FEATURES:
            raise LisaError(f"{path}: 'needs: {d['needs']}' is not one of {sorted(FEATURES)}")
        outputs = {k: tuple(v) if isinstance(v, list) else (str(v),) for k, v in (d.get("outputs") or {}).items()}
        return cls(str(d["phase"]), {str(k): str(v) for k, v in (d.get("steps") or {}).items()}, outputs,
                   d.get("needs"))


@dataclass(frozen=True)
class Pod:
    """A step pod, with Slurm's record of the job that ran it (None when Slurm has none)."""
    name: str
    uid: str
    node: str
    slurm: object = None        # components.sidecar.SlurmJob: .id .partition .nodes .state


@dataclass
class Outcome:
    """What one run of a test did, as the checks see it."""
    phase: str
    steps: dict[str, str]
    pods: list[Pod]
    node: str                       # the virtual node every step pod must be on
    partition: str                  # the Slurm partition every job must be in
    read: Callable[[str], str | None]   # an object's text in the Global Storage, None if missing


@dataclass(frozen=True)
class Check:
    kind: str
    what: str
    expected: str
    got: str
    passed: bool


def evaluate(e: Expectation, o: Outcome) -> list[Check]:
    checks = [Check("phase", "workflow", e.phase, o.phase, o.phase == e.phase)]
    for step, phase in e.steps.items():
        got = o.steps.get(step, "missing")
        checks.append(Check("step", step, phase, got, got == phase))
    for key, texts in e.outputs.items():
        body = o.read(key)
        for text in texts:
            found = body is not None and text in body
            checks.append(Check("output", key, f'contains "{text}"', _got(body, text), found))
    return checks + [ran_on_hpc(o)]


def ran_on_hpc(o: Outcome) -> Check:
    expected = f"each on {o.node}, a Slurm job in {o.partition}"
    wrong = []
    for p in o.pods:
        if p.node != o.node:
            wrong.append(f"{p.name} on node {p.node or 'none'}")
        elif p.slurm is None:
            wrong.append(f"{p.name}: no Slurm record")
        elif p.slurm.partition not in o.partition.split(","):
            wrong.append(f"{p.name}: partition {p.slurm.partition}")
    if not o.pods:
        wrong.append("no step pods")
    got = "; ".join(wrong) or f"{len(o.pods)} step pod{'s' if len(o.pods) != 1 else ''}, " + expected
    return Check("where", "step pods", expected, got, not wrong)


def _got(body: str | None, text: str, n: int = 100) -> str:
    """What the object holds, as read from the Global Storage: the line with the expected text when it
    is there, otherwise its beginning."""
    if body is None:
        return "no such object"
    lines = [x.strip() for x in body.splitlines() if x.strip()]
    hit = [x for x in lines if text in x]
    shown = hit[0] if hit else " / ".join(lines)
    return '"' + (shown[:n] + "..." if len(shown) > n else shown) + '"'
