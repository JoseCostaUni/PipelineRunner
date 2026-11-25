"""Looking without changing: check (both sides and a compute node), status, diag, a shell on the login node."""
import shutil
from datetime import UTC, datetime

from .. import LisaError
from ..adapters import web
from ..components import argo, artifacts, global_storage, image_mirror, interlink, offload, sidecar
from ..context import Context
from .lifecycle import OLD_HOME, old_version_up


def check(ctx: Context) -> None:
    """Read-only checks of the Kubernetes side, the login node and one compute node. (It copies hpc.sh to
    HPC_PROJECT_ROOT/runner on the login node first, and changes nothing else.)"""
    c = ctx.console
    _kubernetes_side(ctx)
    if ctx.settings.missing:
        raise LisaError("fill in the settings first")
    sidecar.sync(ctx)
    if not sidecar.hpc(ctx, "check", check=False):
        c.fail("the login node's checks (above)")
    c.say(f"== a compute node of {ctx.settings.slurm_partition} (a short Slurm job)")
    if not sidecar.hpc(ctx, "probe", check=False):
        c.fail("the compute node probe (above)")
    if c.failed:
        raise LisaError("some checks failed: fix every FAIL above")


def _kubernetes_side(ctx: Context) -> None:
    s, c = ctx.settings, ctx.console
    c.say(f"== the Kubernetes side, settings {s.source}, LISA_HOME {s.home.root}")
    for key in s.missing:
        c.fail(f"{key} is empty in {s.source.name}")
    if s.unknown:
        c.info(f"not read by this version, ignored: {', '.join(s.unknown)}")
    c.check(not old_version_up(), "the version before the restructure is off",
            f"the version before the restructure is still on ({OLD_HOME}/state): switch it off first")
    c.check(s.hpc_project_root.startswith("/"), f"HPC_PROJECT_ROOT {s.hpc_project_root}",
            f"HPC_PROJECT_ROOT must be an absolute path; it is '{s.hpc_project_root}'")
    c.check(s.ssh_key.is_file(), f"SSH_KEY {s.ssh_key} readable", f"SSH_KEY {s.ssh_key} not readable")
    for tool in ("ssh", "ssh-keyscan", "git", "tar"):
        c.check(bool(shutil.which(tool)), f"found {tool}", f"missing {tool}")
    cl = ctx.cluster
    c.check(cl.is_cluster_admin(), f"kubeconfig {s.kubeconfig} has cluster-admin",
            f"kubeconfig {s.kubeconfig} does not reach the cluster with cluster-admin")
    if argo.installed(ctx):
        image = argo.executor_image(ctx)
        c.check(image == s.argo_exec_image, f"Argo found; ARGO_EXEC_IMAGE matches its executor ({image})",
                f"ARGO_EXEC_IMAGE ({s.argo_exec_image}) differs from Argo's executor ({image})")
        c.info(f"offload now: {offload.state(ctx)}")
    else:
        c.info("no Argo in namespace argo yet: 'make setup' installs it")
    if not cl.get("v1", "Namespace", s.namespace):
        c.info(f"namespace {s.namespace} not there yet ('make setup' creates it)")
    try:
        store = global_storage.storage(ctx)
        problem = store.problem()
        c.check(problem is None, f"Global Storage {store.endpoint} answers and accepts the keys", problem or "")
        if problem is None and not store.bucket_exists():
            c.info(f"bucket {s.gs_bucket} not there yet ('make up' creates it)")
    except LisaError as e:
        c.info(str(e))
    c.check(s.gs_port >= 1024, f"Global Storage port {s.gs_port} can be bound by the job's unprivileged relay",
            f"Global Storage port {s.gs_port} is below 1024: the job's relay cannot bind it")
    gs = cl.get("v1", "Service", s.gs_service, s.namespace)
    c.check(not gs or global_storage.ours(gs), f"Service name {s.gs_fqdn} free, or ours",
            f"Service {s.namespace}/{s.gs_service} exists and is not ours: set GS_SERVICE to another name")
    for port in (s.tunnel_port, s.vk_port):
        if web.port_free(port):
            c.ok(f"port {port} free here")
        elif interlink.version(ctx):
            c.info(f"port {port} in use, by our interLink")
        else:
            c.fail(f"port {port} already in use here: pick another (TUNNEL_PORT, VK_PORT)")
    if cl.get("v1", "Node", s.node) and not ctx.processes.running("il-vk"):
        c.info(f"a node {s.node} exists but our virtual kubelet is not running: left by an earlier run, or "
               "someone else's (INTERLINK_NODE_NAME)")
    host, port = s.k8s_api_host or cl.server[0], int(s.k8s_api_port or cl.server[1])
    name = "kubernetes.default.svc.cluster.local"
    if web.tls_name_valid(host, port, cl.ca_file, name):
        c.ok(f"the API server's certificate is valid for {name} (the name jobs use through the tunnel)")
    else:
        c.info(f"could not confirm that the API server's certificate is valid for {name}")
    if interlink.installed(ctx):
        c.ok(f"interLink {s.il_version} installed in {s.home.interlink(s.il_version)}")
    else:
        c.info(f"interLink {s.il_version} not installed yet: 'make setup' builds it")
    login = ctx.login
    c.say(f"== the login node {s.hpc_login_host} (host keys pinned in {s.home.known_hosts})")
    c.check(login.run("true").ok, f"ssh to {login.target} with {s.ssh_key}", f"ssh to {login.target} failed")


def status(ctx: Context) -> None:
    s, say = ctx.settings, ctx.say
    say(f"== Kubernetes side: interLink {interlink.version(ctx) or 'off'}, {s.node} Ready: "
        f"{ctx.cluster.node_ready(s.node)}")
    for n in interlink.PROCESSES:
        say(f"   {n}: {'running' if ctx.processes.running(n) else 'not running'}")
    if s.gs_in_cluster:
        say(f"   Global Storage: the MinIO in the cluster, {_ready(ctx, global_storage.MINIO)}")
    say(f"   artifact repository endpoint: {artifacts.endpoint_in_use(ctx) or 'none'}")
    if s.image_mirror:
        say(f"   image mirror: {image_mirror.ready(ctx)}, {s.mirror_address} for the jobs")
    say(f"   offload: {offload.state(ctx) if argo.installed(ctx) else 'no Argo'}")
    say(f"== login node {s.hpc_login_host}:")
    for line in sidecar.status(ctx).splitlines():
        say("   " + line)


def _ready(ctx: Context, deployment: str) -> str:
    d = ctx.cluster.get("apps/v1", "Deployment", deployment, ctx.settings.namespace)
    return f"{d.get('status', {}).get('readyReplicas', 0)}/1 ready" if d else "not there"


def diag(ctx: Context) -> None:
    ctx.say(interlink.diagnostics(ctx))


def login(ctx: Context) -> None:
    ctx.login.shell(ctx.settings.hpc_path("runner"))


def progress(ctx: Context) -> None:
    """The workflows running in ARGO_NAMESPACE (or the last one): each step's pod, when it started and
    ended, its phase, and the Slurm job that ran it on the HPC side."""
    ns = ctx.settings.namespace
    wfs = sorted(ctx.cluster.list(*argo.WORKFLOW, ns), key=lambda w: w["metadata"]["creationTimestamp"])
    running = [w for w in wfs if (w.get("status") or {}).get("phase") in (None, "", "Pending", "Running")]
    if not wfs:
        ctx.say(f"no workflow in {ns}")
        return
    pods = ctx.cluster.list("v1", "Pod", ns)
    jobs = sidecar.jobs(ctx)
    for w in running or wfs[-1:]:
        for line in progress_lines(w, pods, jobs):
            ctx.say(line)


def progress_lines(workflow: dict, pods: list[dict], jobs: dict) -> list[str]:
    """One workflow's steps, as 'progress' prints them (a pure function, for the tests)."""
    s = workflow.get("status") or {}
    uid = {p["metadata"].get("annotations", {}).get("workflows.argoproj.io/node-name"): p["metadata"]["uid"]
           for p in pods}
    out = [f"{workflow['metadata']['name']}  {s.get('phase') or 'Pending'}  {s.get('progress', '')}"
           + (f"  {s['message']}" if s.get("message") else "")]
    for n in sorted((n for n in (s.get("nodes") or {}).values() if n.get("type") == "Pod"),
                    key=lambda n: n.get("startedAt") or "~"):
        start, end = n.get("startedAt") or "", n.get("finishedAt") or ""
        took = _seconds(start, end)
        job = jobs.get(uid.get(n.get("name")))
        slurm = f"Slurm {job.id} {job.state} on {job.nodes}" if job else "no Slurm job yet"
        out.append(f"   {start[11:19] or '--:--:--'}  {took:>8}  {n.get('phase', ''):<9}  "
                   f"{n.get('displayName', '')}  ({slurm})")
    return out


def _seconds(start: str, end: str) -> str:
    """How long a step took, or has been running ('...' when it has not started)."""
    if not start:
        return "..."
    t0 = datetime.fromisoformat(start.replace("Z", "+00:00"))
    t1 = datetime.fromisoformat(end.replace("Z", "+00:00")) if end else datetime.now(UTC)
    m, sec = divmod(int((t1 - t0).total_seconds()), 60)
    return f"{m}m{sec:02d}s" + ("" if end else "+")
