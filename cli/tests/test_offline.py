"""What lisa writes, with stand-ins for the cluster and the login node: the sidecar's files, Argo's
workflowDefaults, and a run's report."""
import json
from dataclasses import replace
from types import SimpleNamespace

import yaml

from lisa.adapters.hpc import Result
from lisa.components import offload, sidecar
from lisa.components.sidecar import SlurmJob
from lisa.console import Console
from lisa.paths import REPO
from lisa.settings import Settings
from lisa.testing import suite
from lisa.testing.expect import Outcome, Pod, evaluate
from lisa.testing.report import RunFolder
from lisa.testing.runner import TestRun


class FakeLogin:
    def run(self, command, timeout=None):
        return Result(0, "sbatch=/usr/bin/sbatch\nsqueue=/usr/bin/squeue\nscancel=/usr/bin/scancel\n"
                         "sinfo=/usr/bin/sinfo\narch=x86_64\n", "")


class FakeCluster:
    server = ("10.0.0.1", 6443)

    def get(self, api_version, kind, name, namespace=None):
        return {"spec": {"clusterIP": "10.96.0.9"}} if kind == "Service" else None


def context(tmp_path, mirror: bool):
    text = (REPO / "settings/testbed.env.example").read_text() + f"IMAGE_MIRROR={'on' if mirror else 'off'}\n"
    (tmp_path / "s.env").write_text(text + f"LISA_HOME={tmp_path}/home\n")
    s = Settings.load(tmp_path / "s.env")
    console = Console()
    return SimpleNamespace(settings=s, login=FakeLogin(), cluster=FakeCluster(), console=console, say=console.say)


def test_the_sidecars_files_with_images_built_beforehand(tmp_path):
    files = sidecar.rendered(context(tmp_path, mirror=False))
    config = yaml.safe_load(files["SlurmConfig.yaml"])
    root = "/projects/EEHPC-DEV-2026D02-075/jcosta-trial"
    assert config["ImagePrefix"] == f"{root}/images/"
    assert config["SbatchPath"] == f"{root}/sidecar/subpath-fix/sbatch"
    assert config["SqueuePath"] == "/usr/bin/squeue"
    assert config["SingularityDefaultOptions"] == ["--no-eval", "--contain"]
    assert f"ExecStart={root}/sidecar/interlink-sidecar-slurm-0.6.3_Linux_x86_64" in files["lisa-sidecar.service"]
    env = files["hpc.env"]
    assert "IMAGE_MIRROR=off" in env and "GS_SECRET_KEY" not in env and "admin123" not in env
    assert "PROBE_URLS='http://192.168.104.4:9000/minio/health/live https://10.0.0.1:6443/version" in env


def test_the_sidecars_files_with_the_image_mirror(tmp_path):
    config = yaml.safe_load(sidecar.rendered(context(tmp_path, mirror=True))["SlurmConfig.yaml"])
    assert config["ImagePrefix"] == "docker://127.77.0.1:5000/"
    assert config["SingularityDefaultOptions"] == ["--no-eval", "--contain", "--no-https"]


def test_offload_with_and_without_the_mirror(tmp_path):
    plain = offload.defaults(context(tmp_path, mirror=False))["spec"]["podMetadata"]["annotations"]
    assert plain["slurm-job.vk.io/flags"] == "--account=testbed --partition=arm"
    assert "interlink.eu/reverse-bind" not in plain
    mirror = offload.defaults(context(tmp_path, mirror=True))["spec"]["podMetadata"]["annotations"]
    assert mirror["slurm-job.vk.io/flags"] == "--account=testbed --partition=arm --exclusive"
    assert mirror["interlink.eu/reverse-bind"] == "127.77.0.1"
    assert "image-mirror.lisa-jcosta.svc.cluster.local:5000" in mirror["interlink.eu/reverse-forwards"]


def test_the_report_shows_what_each_check_expected_and_got(tmp_path):
    ctx = context(tmp_path, mirror=False)
    t = suite.select(suite.load_all(), ["00"])[0]
    pod = Pod("native-00-abc", "uid", "interlink-jcosta", SlurmJob("481", "arm", "cn", "COMPLETED"))
    outcome = Outcome("Succeeded", {}, [pod], "interlink-jcosta", "arm",
                      read={"tests/00/result.txt": "HELLO FROM THE GLOBAL STORAGE\n"}.get)
    good = TestRun(t, "native-00-abc", {"status": {"phase": "Succeeded"}}, 75, [pod], evaluate(t.expect, outcome))
    bad = replace(good, checks=evaluate(t.expect, replace(outcome, read={}.get)), diag="interLink's state")
    out = RunFolder(ctx, tmp_path / "results")
    out.add(good)
    out.add(bad)
    report = (out.path / "report.md").read_text()
    assert "1 of 2 tests passed" in report
    assert '| PASS | output tests/00/result.txt | contains "HELLO FROM THE GLOBAL STORAGE" | ' \
           '"HELLO FROM THE GLOBAL STORAGE" |' in report
    assert "| **FAIL** | output tests/00/result.txt |" in report and "no such object" in report
    assert "| native-00-abc | 481 | arm | cn | COMPLETED |" in report
    where = (out.path / "where.tsv").read_text().splitlines()[1].split("\t")
    assert where == ["TC00", "native-00-abc", "interlink-jcosta", "481", "arm", "cn", "COMPLETED"]
    assert (out.path / "TC00" / "diag.txt").read_text() == "interLink's state"


def test_the_mirror_reaches_ecr_and_the_private_registry(tmp_path):
    from lisa.components import image_mirror
    ctx = context(tmp_path, mirror=True)
    docs = {d["kind"]: d for d in image_mirror.manifests(ctx.settings)}
    rules = json.loads(docs["ConfigMap"]["data"]["config.json"])["extensions"]["sync"]["registries"]
    where = {r["urls"][0]: r["content"][0].get("destination") for r in rules}
    assert where["https://public.ecr.aws"] == "/public.ecr.aws"
    assert where["https://gitlab.esa.int:4567"] == "/gitlab.esa.int"
    assert rules[-1]["content"][0] == {"prefix": "**"}          # bare names last, from Docker Hub
    assert docs["Secret"]["stringData"] == {"credentials.json": "{}"}


def test_the_mirror_logs_in_with_the_token_and_restarts_when_it_changes(tmp_path):
    from lisa.components import image_mirror
    without = image_mirror.manifests(context(tmp_path, mirror=True).settings)
    env = tmp_path / "s.env"
    env.write_text(env.read_text() + "MIRROR_PRIVATE_USER=jcosta\nMIRROR_PRIVATE_TOKEN=glpat-example\n")
    s = Settings.load(env)
    docs = {d["kind"]: d for d in image_mirror.manifests(s)}
    assert json.loads(docs["Secret"]["stringData"]["credentials.json"]) == {
        "gitlab.esa.int:4567": {"username": "jcosta", "password": "glpat-example"}}
    stamp = lambda ds: next(d for d in ds if d["kind"] == "Deployment")[  # noqa: E731
        "spec"]["template"]["metadata"]["annotations"]["lisa-runner/configuration"]
    assert stamp(without) != stamp(list(docs.values()))


def test_with_the_mirror_every_job_asks_for_its_whole_node_memory(tmp_path):
    """Singularity converts images inside the job; Slurm would kill it at the pod's memory limit."""
    active = "\nEnvironment=SBATCH_MEM_PER_NODE=0\n"
    assert active in sidecar.rendered(context(tmp_path, mirror=True))["lisa-sidecar.service"]
    assert active not in sidecar.rendered(context(tmp_path, mirror=False))["lisa-sidecar.service"]


def test_a_workflow_still_running_after_its_timeout_has_its_pods_deleted(tmp_path):
    """Its Slurm jobs would otherwise hold their nodes (TC13: a pod whose main never started)."""
    from lisa.testing import runner
    ctx = context(tmp_path, mirror=True)
    deleted = []
    ctx.cluster.delete = lambda api, kind, name, ns=None: deleted.append((kind, name))
    t = suite.select(suite.load_all(), ["13"])[0]
    r = TestRun(t, "native-13-x", {"status": {"phase": "Running"}}, diag="state\n")
    runner._release(ctx, r, [{"metadata": {"name": "native-13-x"}}])
    assert deleted == [("Pod", "native-13-x")]
    assert "deleted its pods (native-13-x)" in r.diag
