"""lisa evidence [RUN]: what shows how a test run ran (by default the last one), into
results/<run>/evidence/: both sides' configuration, the versions (interLink's build commit, the plugin's
checksum against the release's), interLink's and the sidecar's logs of the run's time, and Slurm's
record of its jobs. Every secret is blanked, and the folder is checked for any left before it is kept."""
import base64
import io
import re
import shutil
import tarfile
from datetime import UTC, datetime, timedelta
from pathlib import Path

from .. import LisaError
from ..components import argo, interlink, sidecar
from ..context import Context
from ..paths import RESULTS

TOKEN = re.compile(r"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+")
SECRET_DATA = re.compile(r'(\\*"data\\*":\{)[^}]*')
README = """Evidence for run {run} (collected {now} by 'lisa evidence'). Window: {t0} to {t1} UTC.
Secrets were blanked (Secret data, service-account tokens) and the folder checked for the Global Storage keys.

../report.md                 what passed: every check, with what it expected and what it got
../where.tsv                 every step pod -> its Slurm job, partition, compute node, state
../config/                   both sides' configuration as the run started
kubernetes/*Config.yaml      interLink's configuration as used (Network.SSH.Reverse: the tunnel)
kubernetes/versions.txt      interLink: the tag's commit, each binary's sha256 and Go build information;
                             Argo; Kubernetes
kubernetes/il-vk.log         the virtual kubelet: pods, the tunnel's shadow pods, node status
kubernetes/il-api.log        interLink's API: its calls to the sidecar on the login node
kubernetes/il-tunnel.log     the SSH tunnel to the sidecar
login-node/SlurmConfig.yaml  the plugin's configuration (SocketDirRoot, the subPath fix as SbatchPath)
login-node/sidecar-unit.txt  the user service that runs the plugin
login-node/versions.txt      the plugin's sha256 next to the release's published checksum; Singularity; Slurm
login-node/slurm-jobs.txt    Slurm's record of the jobs since the run started (job name = pod UID)
login-node/sidecar.log       the plugin's log of the run: submissions, the per-pod socket folders, deletions
login-node/probe-compute.out the last probe of a compute node of the partition (network, python3, sshd)
"""


def evidence(ctx: Context, run: str | None) -> None:
    folder = _run_folder(run)
    started = datetime.strptime(folder.name[:15], "%Y%m%d-%H%M%S")                  # local time
    t0 = started.astimezone(UTC)
    t1 = datetime.fromtimestamp((folder / "report.md").stat().st_mtime, UTC) + timedelta(minutes=5)
    fmt = "%Y-%m-%dT%H:%M:%S"
    e = folder / "evidence"
    shutil.rmtree(e, ignore_errors=True)
    (e / "kubernetes").mkdir(parents=True)
    home = ctx.settings.home
    for p in home.conf.glob("*.yaml"):
        shutil.copy(p, e / "kubernetes" / p.name)
    (e / "kubernetes" / "versions.txt").write_text(
        interlink.versions(ctx) + f"\n== Argo's executor: {argo.executor_image(ctx)}\n== {ctx.cluster.version()}\n")
    for name in interlink.PROCESSES:
        log = home.log / f"{name}.log"
        if log.exists():
            window = (t0.strftime(fmt), t1.strftime(fmt))
            lines = [x for x in log.read_text(errors="replace").splitlines() if window[0] <= _time(x) <= window[1]]
            (e / "kubernetes" / log.name).write_text("".join(_blank(x) + "\n" for x in lines))
    try:
        data = sidecar.evidence(ctx, started.strftime(fmt), t0.strftime(fmt), t1.strftime(fmt))
        with tarfile.open(fileobj=io.BytesIO(data)) as tar:
            tar.extractall(e, **({"filter": "data"} if hasattr(tarfile, "data_filter") else {}))
    except LisaError as err:
        ctx.console.warn(f"could not collect the login node's part: {err}")
    leaks = _leaks(ctx, e)
    if leaks:
        shutil.rmtree(e)
        raise LisaError(f"{leaks} found in the evidence: removed it, nothing kept")
    (e / "README.txt").write_text(README.format(run=folder.name, now=datetime.now().isoformat(timespec="seconds"),
                                                t0=t0.strftime(fmt), t1=t1.strftime(fmt)))
    ctx.say(f"evidence in {e}:")
    for p in sorted(e.rglob("*")):
        if p.is_file():
            ctx.say(f"   {p.relative_to(e)}")


def _run_folder(run: str | None) -> Path:
    runs = sorted(p.parent for p in RESULTS.glob("2*/report.md"))
    if run:
        runs = [p for p in runs if p.name == Path(run).name]
    if not runs:
        raise LisaError(f"no test run {'named ' + run if run else ''} in {RESULTS}")
    return runs[-1]


def _b64(value: str) -> str:
    return base64.b64encode(value.encode()).decode()


def _time(line: str) -> str:
    m = re.search(r'time="([^"]{19})', line)
    return m[1] if m else ""


def _blank(line: str) -> str:
    return TOKEN.sub("<token>", SECRET_DATA.sub(r"\1<redacted>", line))


def _leaks(ctx: Context, folder: Path) -> str:
    """What secret is still in the folder: the secret key (plain or base64), the access key in base64 (the
    form Secret data takes; the plain one is a user name, like 'lisa' in 'lisa-jcosta'), a service-account
    token, or the image mirror's registry token."""
    s = ctx.settings
    found = []
    text = "\n".join(p.read_text(errors="replace") for p in folder.rglob("*") if p.is_file())
    if s.gs_secret_key and (s.gs_secret_key in text or _b64(s.gs_secret_key) in text):
        found.append("the Global Storage secret key")
    if s.gs_access_key and _b64(s.gs_access_key) in text:
        found.append("the access key in base64")
    if "eyJhbGciOi" in text:
        found.append("a token")
    if s.mirror_private_token and s.mirror_private_token in text:
        found.append("the image mirror's registry token")
    return " and ".join(found)
