"""lisa: the command line. The Makefile at the repository root calls it; 'make help' lists the targets."""
import argparse
import sys
import time
from pathlib import Path

from . import LisaError
from .commands import evidence, inspect, lifecycle, test
from .components import global_storage, image_mirror, sidecar
from .console import Console
from .context import Context
from .paths import REPO, RESULTS
from .settings import Settings

COMMANDS = {
    "setup": "Argo if the cluster has none, the MinIO (GS_ENDPOINT=cluster), interLink, the sidecar",
    "check": "read-only checks of this side, the login node and one compute node (kept in results/)",
    "up": "both sides up: the sidecar, interLink with the reverse tunnel, the artifact repository, offload",
    "test": "run the tests (default: all) and check what they produced; results in results/<run>/",
    "evidence": "configuration, versions, logs and Slurm's record of a run (default: the last)",
    "status": "what runs on both sides",
    "diag": "interLink's processes and logs, the shadow pods and their logs",
    "down": "offload off, interLink stopped, the tunnel's credentials deleted",
    "clean": "delete the test workflows (interLink then removes their job folders)",
    "restore": "clean, down, the sidecar stopped, the virtual node deleted",
    "minio": "on|off: a MinIO in the cluster as the Global Storage (GS_ENDPOINT=cluster)",
    "mirror": "on|off: the image mirror in the cluster (IMAGE_MIRROR=on; 'up' starts it)",
    "sync": "copy hpc.sh and the sidecar's files to the login node ('up' and 'check' do this too)",
    "hpc": "run hpc.sh <command> on the login node (check, probe, install, images, status, jobs ...)",
    "login": "a shell on the login node",
}


def parse(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="lisa", description=__doc__.splitlines()[0])
    p.add_argument("--settings", type=Path, default=REPO / "settings" / "deucalion.env",
                   help="the site's settings file (default: settings/deucalion.env)")
    sub = p.add_subparsers(dest="command", required=True, metavar="command")
    for name, help_ in COMMANDS.items():
        c = sub.add_parser(name, help=help_, description=help_)
        if name == "test":
            c.add_argument("tests", nargs="*", help="test numbers, e.g. 00 11 (default: all)")
            c.add_argument("--timeout", type=int, default=1800, help="seconds before a workflow is stopped")
        elif name == "evidence":
            c.add_argument("run", nargs="?", help="a folder in results/ (default: the last run)")
        elif name in ("minio", "mirror"):
            c.add_argument("switch", choices=("on", "off"))
        elif name == "hpc":
            c.add_argument("args", nargs="+", help="hpc.sh's command and its arguments")
    return p.parse_args(argv)


def run(ctx: Context, a: argparse.Namespace) -> int:
    match a.command:
        case "setup" | "up" | "down" | "clean" | "restore":
            getattr(lifecycle, a.command)(ctx)
        case "check":
            inspect.check(ctx)
        case "status" | "diag" | "login":
            getattr(inspect, a.command)(ctx)
        case "test":
            return test.test(ctx, a.tests, a.timeout)
        case "evidence":
            evidence.evidence(ctx, a.run)
        case "minio":
            (global_storage.minio_on if a.switch == "on" else global_storage.minio_off)(ctx)
        case "mirror":
            (image_mirror.on if a.switch == "on" else image_mirror.off)(ctx)
        case "sync":
            sidecar.sync(ctx)
        case "hpc":
            return 0 if sidecar.hpc(ctx, *a.args, check=False) else 1
    return 0


def main(argv: list[str] | None = None) -> None:
    a = parse(sys.argv[1:] if argv is None else argv)
    copy = None
    if a.command == "check":
        RESULTS.mkdir(exist_ok=True)
        copy = RESULTS / f"check-{time.strftime('%Y%m%d-%H%M%S')}.txt"
    console = Console(copy)
    ctx = None
    try:
        ctx = Context(Settings.load(a.settings), console)
        code = run(ctx, a)
    except LisaError as e:
        console.say(f"ERROR: {e}")
        code = 1
    except KeyboardInterrupt:
        console.say("\ninterrupted")
        code = 130
    finally:
        if ctx:
            ctx.close()
    if copy:
        print(f"(this output is kept in {copy})")
    sys.exit(code)
