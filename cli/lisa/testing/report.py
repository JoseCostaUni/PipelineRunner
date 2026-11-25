"""What a test run leaves behind, in results/<run>/:

  report.md     for people: every test, every check with what it expected and what it got (an
                artifact's actual content too), and where each step ran
  results.json  the same, for programs
  where.tsv     every step pod: its Kubernetes node, Slurm job, partition, compute node and state
  config/       both sides' configuration as the run started
  TC<NN>/       workflow.yaml (as submitted), workflow.json (as it ended), logs.txt (each container's
                output), diag.txt (interLink's state, when the test failed)
"""
import json
import time
from dataclasses import asdict
from pathlib import Path

from ..context import Context
from ..templates import to_yaml
from .runner import TestRun


class RunFolder:
    def __init__(self, ctx: Context, root: Path):
        self.ctx = ctx
        self.id = time.strftime("%Y%m%d-%H%M%S")
        self.path = root / self.id
        (self.path / "config").mkdir(parents=True)
        self.runs: list[TestRun] = []
        self.skipped: list[str] = []

    def save_config(self, files: dict[str, str]) -> None:
        for name, text in files.items():
            (self.path / "config" / name).write_text(text)

    def add(self, r: TestRun) -> None:
        self.runs.append(r)
        d = self.path / f"TC{r.test.id}"
        d.mkdir(exist_ok=True)
        (d / "workflow.yaml").write_text(to_yaml(r.test.workflow))
        (d / "workflow.json").write_text(json.dumps(r.workflow, indent=2, default=str) + "\n")
        (d / "logs.txt").write_text(r.logs)
        if r.diag:
            (d / "diag.txt").write_text(r.diag)
        self._print(r)
        self.write()

    def _print(self, r: TestRun) -> None:
        say = self.ctx.say
        ok = sum(c.passed for c in r.checks)
        say(f"TC{r.test.id}  {'PASS' if r.passed else 'FAIL'}  {r.phase} in {r.seconds // 60}m{r.seconds % 60:02d}s, "
            f"checks {ok}/{len(r.checks)}  ({r.workflow_name or r.error})")
        for c in r.checks:
            say(f"      {'PASS' if c.passed else 'FAIL'}  {c.kind} {c.what}: expected {c.expected}, got {c.got}")

    # --- the files ---------------------------------------------------------------------------------
    def write(self) -> None:
        (self.path / "where.tsv").write_text(self._where())
        (self.path / "results.json").write_text(json.dumps(self._json(), indent=2, default=str) + "\n")
        (self.path / "report.md").write_text(self._markdown())

    def summary(self) -> str:
        passed = sum(r.passed for r in self.runs)
        return f"{passed} of {len(self.runs)} tests passed" + (f", {len(self.skipped)} skipped" if self.skipped else "")

    def places(self) -> tuple[list[str], list[str]]:
        jobs = [p.slurm for r in self.runs for p in r.pods if p.slurm]
        return sorted({j.partition for j in jobs}), sorted({j.nodes for j in jobs})

    def _where(self) -> str:
        rows = ["test\tpod\tkubernetes node\tslurm job\tpartition\tcompute node\tslurm state"]
        for r in self.runs:
            for p in r.pods:
                j = p.slurm
                slurm = [j.id, j.partition, j.nodes, j.state] if j else ["no Slurm record", "", "", ""]
                rows.append("\t".join([f"TC{r.test.id}", p.name, p.node, *slurm]))
        return "\n".join(rows) + "\n"

    def _json(self) -> dict:
        return {"run": self.id, "settings": self.ctx.settings.source.name, "summary": self.summary(),
                "skipped": self.skipped,
                "tests": [{"test": r.test.title, "passed": r.passed, "phase": r.phase, "seconds": r.seconds,
                           "workflow": r.workflow_name, "error": r.error,
                           "checks": [asdict(c) for c in r.checks],
                           "pods": [{"name": p.name, "node": p.node, "slurm": asdict(p.slurm) if p.slurm else None}
                                    for p in r.pods]} for r in self.runs]}

    def _markdown(self) -> str:
        s = self.ctx.settings
        partitions, nodes = self.places()
        out = [f"# Test run {self.id}", "",
               f"- **Result:** {self.summary()}",
               f"- **Settings:** `{s.source.name}`: login node {s.hpc_login_host}, partition {s.slurm_partition}, "
               f"virtual node {s.node}, interLink {s.il_version}, image mirror {'on' if s.image_mirror else 'off'}",
               f"- **Where the steps ran:** Slurm partitions {', '.join(partitions) or 'none recorded'}; "
               f"compute nodes {', '.join(nodes) or 'none recorded'}"]
        if self.skipped:
            out.append(f"- **Skipped:** {', '.join(self.skipped)}")
        out += ["", "| Test | Result | Workflow | Time | Checks |", "|---|---|---|---|---|"]
        for r in self.runs:
            out.append(f"| {r.test.title} | {'PASS' if r.passed else '**FAIL**'} | {r.phase} | "
                       f"{r.seconds // 60}m{r.seconds % 60:02d}s | {sum(c.passed for c in r.checks)}/{len(r.checks)} |")
        for r in self.runs:
            out += ["", f"## {r.test.title}: {'PASS' if r.passed else 'FAIL'}", ""]
            out.append(f"Workflow `{r.workflow_name}`, {r.phase} after {r.seconds} s." if r.workflow_name else r.error)
            out += ["", "| | Check | Expected | Got |", "|---|---|---|---|"]
            out += [f"| {'PASS' if c.passed else '**FAIL**'} | {c.kind} {_cell(c.what)} | {_cell(c.expected)} | "
                    f"{_cell(c.got)} |" for c in r.checks]
            if r.pods:
                out += ["", "| Step pod | Slurm job | Partition | Compute node | Slurm state |",
                        "|---|---|---|---|---|"]
                for p in r.pods:
                    j = p.slurm
                    cells = [j.id, j.partition, j.nodes, j.state] if j else ["no Slurm record", "", "", ""]
                    out.append(f"| {p.name} | {' | '.join(cells)} |")
        return "\n".join(out) + "\n"


def _cell(text: str) -> str:
    return text.replace("|", "\\|").replace("\n", " ")
