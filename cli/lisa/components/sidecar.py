"""The HPC side: interLink's Slurm plugin (the sidecar) on the login node, run by cli/hpc.sh there.

Everything is filled in here, from the settings and from what the login node says about itself, then
'sync' copies it to HPC_PROJECT_ROOT/runner; hpc.sh only installs and runs it. Layout on the login node:
  runner/   hpc.sh, hpc.env (settings, without keys), and the files below as 'sync' left them
  sidecar/  the plugin, SlurmConfig.yaml, sidecar.log, the subPath fix, resources.sh, the job folders
  sock/     the tunnel's socket folders (the plugin's SocketDirRoot)
  images/   images built beforehand (IMAGE_MIRROR=off)
"""
import shlex
from dataclasses import dataclass

from .. import LisaError
from ..context import Context
from ..paths import HPC_SCRIPT, RUNNER
from ..templates import render_text, render_yaml, to_yaml
from . import global_storage


@dataclass(frozen=True)
class SlurmJob:
    """Slurm's record of one job. interLink names a pod's job after the pod's UID."""
    id: str
    partition: str
    nodes: str
    state: str


def facts(ctx: Context) -> dict[str, str]:
    """What the plugin's configuration needs from the login node: where Slurm's commands are, and the
    CPU architecture (the plugin's binary)."""
    r = ctx.login.run("for c in sbatch squeue scancel sinfo; do echo \"$c=$(command -v $c)\"; done; "
                      "echo \"arch=$(uname -m)\"")
    f = dict(line.split("=", 1) for line in r.out.splitlines() if "=" in line)
    missing = [c for c in ("sbatch", "squeue", "scancel", "sinfo") if not f.get(c)]
    if missing:
        raise LisaError(f"not found on the login node, in a login shell: {', '.join(missing)}")
    f["arch"] = "arm64" if f.get("arch") in ("aarch64", "arm64") else "x86_64"
    return f


def plugin(ctx: Context, arch: str) -> str:
    return ctx.settings.hpc_path("sidecar", f"interlink-sidecar-slurm-{ctx.settings.il_version}_Linux_{arch}")


def rendered(ctx: Context) -> dict[str, str]:
    """The files 'sync' puts in runner/ on the login node, by name."""
    s, f = ctx.settings, facts(ctx)
    sidecar = s.hpc_path("sidecar")
    prefix = f"docker://{s.mirror_bind}:5000/" if s.image_mirror else s.hpc_path("images") + "/"
    (config,) = render_yaml("runner/hpc/SlurmConfig.yaml", port=s.sidecar_port, sidecar=sidecar, scancel=f["scancel"],
                            squeue=f["squeue"], sinfo=f["sinfo"], image_prefix=prefix, sockets=s.hpc_path("sock"))
    if s.image_mirror:
        config["SingularityDefaultOptions"].append("--no-https")    # the mirror speaks plain HTTP
    memory = ("Environment=SBATCH_MEM_PER_NODE=0" if s.image_mirror else
              "# Environment=SBATCH_MEM_PER_NODE=0   (IMAGE_MIRROR=off: each job asks for its pod's memory)")
    unit = render_text("runner/hpc/lisa-sidecar.service", version=s.il_version, sidecar=sidecar,
                       plugin=plugin(ctx, f["arch"]), mirror_memory=memory)
    gs = global_storage.endpoint_here(ctx)
    api = f"{s.k8s_api_host or ctx.cluster.server[0]}:{s.k8s_api_port or ctx.cluster.server[1]}"
    env = {
        "HPC_USER": s.hpc_user, "HPC_PROJECT_ROOT": s.hpc_project_root, "SLURM_ACCOUNT": s.slurm_account,
        "SLURM_PARTITION": s.slurm_partition, "SIDECAR_UNIT": s.sidecar_unit, "SIDECAR_PORT": s.sidecar_port,
        "IL_VERSION": s.il_version, "PLUGIN": plugin(ctx, f["arch"]), "ARGO_EXEC_IMAGE": s.argo_exec_image,
        "IMAGES": " ".join(s.images), "IMAGE_MIRROR": "on" if s.image_mirror else "off",
        # What the compute-node probe tries to reach: none of it should answer on an offline node.
        "PROBE_URLS": " ".join([f"{'http' if s.gs_insecure else 'https'}://{gs}/minio/health/live",
                                f"https://{api}/version", "https://quay.io", "https://pypi.org"]),
    }
    hpc_env = "# Written by 'lisa sync' from " + s.source.name + " (no keys). Read by hpc.sh.\n" + "".join(
        f"{k}={shlex.quote(str(v))}\n" for k, v in env.items())
    return {"SlurmConfig.yaml": to_yaml(config), f"{s.sidecar_unit}.service": unit, "hpc.env": hpc_env}


def sync(ctx: Context) -> None:
    """Copy hpc.sh and what it installs to HPC_PROJECT_ROOT/runner on the login node."""
    s, login = ctx.settings, ctx.login
    s.require()
    dest = s.hpc_path("runner")
    files = rendered(ctx)
    r = login.run(f"mkdir -p {shlex.quote(dest)} && chmod 700 {shlex.quote(dest)}")
    if not r.ok:
        raise LisaError(f"cannot create {dest} on the login node: {r.err.strip()}")
    login.put(f"{dest}/hpc.sh", path=HPC_SCRIPT, mode=0o755)
    login.put(f"{dest}/sbatch", path=RUNNER / "hpc/subpath-fix/sbatch", mode=0o755)
    login.put(f"{dest}/resources.sh", path=RUNNER / "hpc/resources.sh", mode=0o755)
    for name, text in files.items():
        login.put(f"{dest}/{name}", text=text, mode=0o600)
    ctx.say(f"copied hpc.sh and the sidecar's files to {dest} on {s.hpc_login_host}")


def hpc(ctx: Context, *args: str, check: bool = True) -> bool:
    """Run hpc.sh <args> on the login node, showing its output. check: stop if it fails."""
    ok = ctx.login.stream(ctx.login.hpc(*args), emit=lambda line: ctx.say("   " + line)) == 0
    if check and not ok:
        raise LisaError(f"on the login node: hpc.sh {' '.join(args)} failed (output above)")
    return ok


def state(ctx: Context) -> str:
    r = ctx.login.run(ctx.login.hpc("state"))
    last = (r.out.strip().splitlines() or [""])[-1]
    return last if last in ("on", "off") else "unknown (hpc.sh missing on the login node? run 'lisa sync')"


def status(ctx: Context) -> str:
    r = ctx.login.run(ctx.login.hpc("status"))
    return (r.out + r.err).rstrip()


def jobs(ctx: Context) -> dict[str, SlurmJob]:
    """Slurm's record of our recent jobs, by job name (squeue's line first, while it has one)."""
    out: dict[str, SlurmJob] = {}
    for line in ctx.login.run(ctx.login.hpc("jobs")).out.splitlines():
        f = line.split("|")
        if len(f) >= 5:
            out.setdefault(f[0], SlurmJob(*f[1:5]))
    return out


def evidence(ctx: Context, since_local: str, t0: str, t1: str) -> bytes:
    """A tar.gz of the login node's part of a run's evidence."""
    return ctx.login.run_bytes(ctx.login.hpc("evidence", since_local, t0, t1))
