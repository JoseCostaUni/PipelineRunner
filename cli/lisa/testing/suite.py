"""The tests in tests/: one folder per test, NN-name/, with
  workflow.yaml   a plain Argo Workflow, nothing in it about interLink, Slurm or the HPC side
  expect.yaml     what it must produce (testing/expect.py)
  input/          files it reads, uploaded to the Global Storage as tests/NN/<file> before every run

A test keeps everything it reads and writes under the key prefix tests/NN, so tests cannot pass on each
other's data, and 'reset' deletes every earlier result before a run.
"""
from dataclasses import dataclass
from pathlib import Path

import yaml

from .. import LisaError
from ..paths import TESTS
from .expect import Expectation


@dataclass(frozen=True)
class Test:
    id: str
    name: str
    folder: Path
    workflow: dict
    expect: Expectation

    @property
    def title(self) -> str:
        return f"TC{self.id} {self.name}"

    @property
    def prefix(self) -> str:
        return f"tests/{self.id}"

    def inputs(self) -> dict[str, Path]:
        """Key in the Global Storage -> file."""
        d = self.folder / "input"
        return {f"{self.prefix}/{p.relative_to(d).as_posix()}": p for p in sorted(d.rglob("*")) if p.is_file()}

    def owns(self, key: str) -> bool:
        return key == self.prefix or key.startswith(self.prefix + "/")

    def problems(self) -> list[str]:
        """What would make this test unable to tell a working run from a broken one."""
        p = []
        if self.workflow.get("kind") != "Workflow":
            p.append("workflow.yaml is not an Argo Workflow")
        p += [f"workflow.yaml uses {k}, outside {self.prefix}" for k in _keys(self.workflow) if not self.owns(k)]
        p += [f"expect.yaml checks {k}, outside {self.prefix}" for k in self.expect.outputs if not self.owns(k)]
        p += [f"expect.yaml checks {k}, which is one of its inputs: it would pass without the workflow "
              "writing anything" for k in self.expect.outputs if k in self.inputs()]
        if self.expect.steps and not self._has_steps():
            p.append("expect.yaml checks steps, but the entrypoint is a single template: Argo names its pod "
                     "after the workflow, so no step name can match")
        return p

    def _has_steps(self) -> bool:
        spec = self.workflow.get("spec", {})
        entry = next((t for t in spec.get("templates", []) if t.get("name") == spec.get("entrypoint")), {})
        return "dag" in entry or "steps" in entry


def load(folder: Path) -> Test:
    num, _, name = folder.name.partition("-")
    for f in ("workflow.yaml", "expect.yaml"):
        if not (folder / f).is_file():
            raise LisaError(f"{folder}: no {f}")
    return Test(num, name, folder, yaml.safe_load((folder / "workflow.yaml").read_text()),
                Expectation.load(folder / "expect.yaml"))


def load_all(root: Path = TESTS) -> list[Test]:
    return [load(d) for d in sorted(root.glob("[0-9][0-9]-*")) if d.is_dir()]


def select(tests: list[Test], wanted: list[str]) -> list[Test]:
    """By number: '00', '5', 'TC11'."""
    ids = [w.upper().removeprefix("TC").zfill(2) for w in wanted]
    unknown = sorted(set(ids) - {t.id for t in tests})
    if unknown:
        raise LisaError(f"no test {', '.join(unknown)} in tests/ (there are {' '.join(t.id for t in tests)})")
    return [t for t in tests if t.id in ids]


def _keys(obj) -> list[str]:
    """Every Global Storage key a workflow names (the strings that start with 'tests/')."""
    if isinstance(obj, dict):
        return [k for v in obj.values() for k in _keys(v)]
    if isinstance(obj, list):
        return [k for v in obj for k in _keys(v)]
    return [obj] if isinstance(obj, str) and obj.startswith("tests/") else []
