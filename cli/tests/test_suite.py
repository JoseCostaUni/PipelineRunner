"""The tests of the tests: each test in tests/ is well formed, and none can pass on a run that did not do
its work. If one of these fails, a PASS of that test on a real run would not mean what it says."""
from dataclasses import replace

import pytest

from lisa.components.sidecar import SlurmJob
from lisa.testing import suite
from lisa.testing.expect import Expectation, Outcome, Pod, evaluate

TESTS = suite.load_all()
NODE, PARTITION = "interlink-x", "normal-x86"


def on_hpc(*names: str) -> list[Pod]:
    return [Pod(n, f"uid-{n}", NODE, SlurmJob("1", PARTITION, "cnx001", "COMPLETED")) for n in names]


def outcome(e: Expectation, objects: dict[str, str], **kw) -> Outcome:
    """A run that did exactly what e expects, unless changed with kw."""
    o = Outcome(phase=e.phase, steps=dict(e.steps), pods=on_hpc("step-a", "step-b"), node=NODE,
                partition=PARTITION, read=objects.get)
    return replace(o, **kw)


def perfect(t: suite.Test) -> dict[str, str]:
    return {k: " ".join(v) for k, v in t.expect.outputs.items()}


def test_the_suite_is_all_there():
    assert [t.id for t in TESTS] == ["00", "01", "02", "03", "04", "05", "06", "07", "09", "10", "11", "12", "13"]


@pytest.mark.parametrize("t", TESTS, ids=lambda t: t.title)
def test_well_formed(t):
    assert t.problems() == []
    assert t.workflow["metadata"]["generateName"].startswith(f"native-{t.id}-")


@pytest.mark.parametrize("t", TESTS, ids=lambda t: t.title)
def test_passes_when_the_run_did_its_work(t):
    checks = evaluate(t.expect, outcome(t.expect, perfect(t)))
    assert all(c.passed for c in checks), [c for c in checks if not c.passed]


@pytest.mark.parametrize("t", TESTS, ids=lambda t: t.title)
def test_fails_on_a_run_that_did_nothing(t):
    nothing = outcome(t.expect, {}, phase="Error", steps={}, pods=[])
    assert not all(c.passed for c in evaluate(t.expect, nothing))


@pytest.mark.parametrize("t", [t for t in TESTS if t.expect.outputs], ids=lambda t: t.title)
def test_fails_when_argo_says_it_worked_but_nothing_was_written(t):
    assert not all(c.passed for c in evaluate(t.expect, outcome(t.expect, {})))


@pytest.mark.parametrize("t", [t for t in TESTS if t.expect.outputs], ids=lambda t: t.title)
def test_fails_when_an_object_has_other_content(t):
    wrong = {k: "something else" for k in t.expect.outputs}
    assert not all(c.passed for c in evaluate(t.expect, outcome(t.expect, wrong)))


@pytest.mark.parametrize("pods, why", [
    ([], "no step pods"),
    ([Pod("s", "u", "ulisses", None)], "on node ulisses"),
    ([Pod("s", "u", NODE, None)], "no Slurm record"),
    ([Pod("s", "u", NODE, SlurmJob("1", "dev-x86", "n", "COMPLETED"))], "partition dev-x86"),
])
@pytest.mark.parametrize("t", TESTS, ids=lambda t: t.title)
def test_fails_when_a_step_did_not_run_on_the_hpc_side(t, pods, why):
    checks = evaluate(t.expect, outcome(t.expect, perfect(t), pods=pods))
    where = [c for c in checks if c.kind == "where"]
    assert len(where) == 1 and not where[0].passed and why in where[0].got


def test_a_test_whose_output_is_one_of_its_inputs_is_wrong(tmp_path):
    d = tmp_path / "50-bad"
    (d / "input").mkdir(parents=True)
    (d / "input" / "out.txt").write_text("x")
    (d / "workflow.yaml").write_text("kind: Workflow\nspec: {key: tests/51/other}\n")
    (d / "expect.yaml").write_text("phase: Succeeded\noutputs: {tests/50/out.txt: x, tests/49/y: z}\n")
    problems = suite.load(d).problems()
    assert any("tests/51/other, outside tests/50" in p for p in problems)
    assert any("tests/49/y, outside tests/50" in p for p in problems)
    assert any("tests/50/out.txt, which is one of its inputs" in p for p in problems)


def test_select_by_number():
    assert [t.id for t in suite.select(TESTS, ["0", "TC11", "05"])] == ["00", "05", "11"]


def test_an_output_check_shows_the_line_it_found():
    """So a reader of report.md sees the evidence itself, not only the word PASS."""
    t = suite.select(TESTS, ["11"])[0]
    record = "node: cnx017\ndns: cannot resolve quay.io\nnot reachable: 1.1.1.1:443\ninternet: blocked\n"
    (check,) = [c for c in evaluate(t.expect, outcome(t.expect, {"tests/11/network.txt": record}))
                if c.kind == "output"]
    assert check.passed and check.got == '"internet: blocked"'
    (check,) = [c for c in evaluate(t.expect, outcome(t.expect, {"tests/11/network.txt": "internet: OPEN"}))
                if c.kind == "output"]
    assert not check.passed and check.got == '"internet: OPEN"'


def test_steps_need_a_dag_or_steps_entrypoint(tmp_path):
    """A single-template workflow's pod is named after the workflow: a step check there can never pass."""
    d = tmp_path / "51-single"
    d.mkdir()
    (d / "workflow.yaml").write_text("kind: Workflow\nspec:\n  entrypoint: one\n  templates:\n"
                                     "  - name: one\n    container: {image: alpine}\n")
    (d / "expect.yaml").write_text("phase: Succeeded\nsteps: {one: Succeeded}\n")
    assert any("single template" in p for p in suite.load(d).problems())
