"""lisa test [NN ...]: run the tests in tests/ and check what they produced, in Argo and in the Global
Storage, and where Slurm ran every step. The record goes to results/<run>/ (testing/report.py)."""
from .. import LisaError
from ..components import argo, artifacts, global_storage, interlink, offload, sidecar
from ..context import Context
from ..paths import RESULTS
from ..testing import runner, suite
from ..testing.expect import FEATURES
from ..testing.report import RunFolder


def test(ctx: Context, wanted: list[str], timeout: int = 1800) -> int:
    s = ctx.settings
    _ready(ctx)
    tests = suite.load_all()
    problems = [f"{t.title}: {p}" for t in tests for p in t.problems()]
    if problems:
        raise LisaError("the tests themselves are wrong:\n  " + "\n  ".join(problems))
    have = {"mirror"} if s.image_mirror else set()
    chosen = suite.select(tests, wanted) if wanted else tests
    out = RunFolder(ctx, RESULTS)
    if not wanted:              # all: those that need what this setup lacks are skipped
        out.skipped = [f"{t.title} (needs {FEATURES[t.expect.needs]})"
                       for t in chosen if t.expect.needs and t.expect.needs not in have]
        chosen = [t for t in chosen if not t.expect.needs or t.expect.needs in have]
    out.save_config({p.name: p.read_text() for p in sorted(s.home.conf.glob("*.yaml"))}
                    | {"login-node-status.txt": sidecar.status(ctx) + "\n"})
    ctx.say(f"run {out.id}: {' '.join('TC' + t.id for t in chosen)}, interLink {interlink.version(ctx)} with the "
            f"reverse tunnel, partition {s.slurm_partition} -> {out.path}")
    for skipped in out.skipped:
        ctx.say(f"skipped: {skipped}")
    runner.prepare(ctx, tests)
    current = {}
    try:
        for t in chosen:
            out.add(runner.run(ctx, t, timeout, on_submit=lambda name: current.update(name=name)))
            current.clear()
    except KeyboardInterrupt:
        if current:
            argo.stop(ctx, current["name"])
            ctx.say(f"\nstopped {current['name']}; 'make clean' deletes it and cancels its job")
        out.write()
        ctx.say(f"interrupted: what ran so far is in {out.path}/report.md")
        return 130
    partitions, nodes = out.places()
    ctx.say(f"passed: {out.summary()}")
    ctx.say(f"where: Slurm partitions {' '.join(partitions) or 'none recorded'}; compute nodes "
            f"{' '.join(nodes) or 'none recorded'}")
    ctx.say(f"report: {out.path}/report.md (keep the whole folder as evidence; then 'make evidence')")
    return 0 if all(r.passed for r in out.runs) else 1


def _ready(ctx: Context) -> None:
    """Both sides up, the artifact repository under the Service name, offload with the tunnel."""
    if not interlink.version(ctx):
        raise LisaError("interLink is not up on this side: run 'make up'")
    hs = sidecar.state(ctx)
    if hs != "on":
        raise LisaError(f"the sidecar on the login node is {hs}: run 'make up'")
    want, got = global_storage.endpoint_for_jobs(ctx), artifacts.endpoint_in_use(ctx)
    if got != want:
        raise LisaError(f"the artifact repository points to '{got}', the jobs need '{want}': run 'make up'")
    if offload.state(ctx) != "on":
        raise LisaError(f"offload is {offload.state(ctx)}: run 'make up'")
