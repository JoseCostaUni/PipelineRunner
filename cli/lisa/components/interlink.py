"""interLink on the Kubernetes side, as your own processes: the SSH tunnel to the sidecar on the login
node, interLink's API and its virtual kubelet (runner/cluster/interlink/). Version IL_VERSION, in
<LISA_HOME>/interlink-<version>."""
import hashlib
import platform
import shutil
import time

from .. import LisaError
from ..adapters import web
from ..adapters.processes import run
from ..context import Context
from ..templates import render_text

PROCESSES = ("il-tunnel", "il-api", "il-vk")
REPO = "https://github.com/interlink-hq/interLink"


def _goarch() -> str:
    return "arm64" if platform.machine() in ("aarch64", "arm64") else "amd64"


def _bins(ctx: Context):
    d = ctx.settings.home.interlink(ctx.settings.il_version)
    return d / "interlink", d / "virtual-kubelet"


def installed(ctx: Context) -> bool:
    return all(b.exists() for b in _bins(ctx))


def install(ctx: Context) -> None:
    """The release's binaries, or, when the release has none (as 0.6.3), built from its tag."""
    v, (api, vk) = ctx.settings.il_version, _bins(ctx)
    if installed(ctx):
        ctx.say(f"interLink {v} already in {api.parent}")
        return
    api.parent.mkdir(parents=True, exist_ok=True)
    arch = {"amd64": "x86_64", "arm64": "arm64"}[_goarch()]
    base = f"{REPO}/releases/download/{v}"
    if web.exists(f"{base}/interlink_Linux_{arch}"):
        web.download(f"{base}/interlink_Linux_{arch}", api)
        web.download(f"{base}/virtual-kubelet_Linux_{arch}", vk)
        ctx.say(f"interLink {v}: release binaries in {api.parent}")
    else:
        _build(ctx, v)
    for b in (api, vk):
        b.chmod(0o755)


def _build(ctx: Context, v: str) -> None:
    """From the tag, with the Go version its go.mod asks for, all inside LISA_HOME (a few minutes)."""
    home, (api, vk) = ctx.settings.home.root, _bins(ctx)
    ctx.say(f"interLink {v}: the release has no binaries, building them from the tag")
    src = home / "src" / f"interlink-{v}"
    shutil.rmtree(src, ignore_errors=True)
    src.parent.mkdir(parents=True, exist_ok=True)
    _must(run(["git", "-c", "advice.detachedHead=false", "clone", "-q", "--depth", "1", "--branch", v,
               f"{REPO}.git", str(src)]), "git clone")
    gov = next(x.split()[1] for x in (src / "go.mod").read_text().splitlines() if x.startswith("go "))
    gov = gov if gov.count(".") == 2 else gov + ".0"
    goroot = home / f"go-{gov}"
    if not (goroot / "bin" / "go").exists():
        tgz = home / "go.tgz"
        web.download(f"https://go.dev/dl/go{gov}.linux-{_goarch()}.tar.gz", tgz)
        goroot.mkdir(parents=True, exist_ok=True)
        _must(run(["tar", "xzf", str(tgz), "-C", str(goroot), "--strip-components=1"]), "unpacking Go")
        tgz.unlink()
    env = {"PATH": f"{goroot}/bin:/usr/bin:/bin", "GOTOOLCHAIN": "local", "CGO_ENABLED": "0",
           "GOFLAGS": "-mod=mod", "GOPATH": str(home / "gopath"), "GOCACHE": str(home / "gocache")}
    for out, pkg in ((api, "./cmd/interlink"), (vk, "./cmd/virtual-kubelet")):
        _must(run([str(goroot / "bin" / "go"), "build", "-o", str(out), pkg], cwd=src, env=env), f"go build {pkg}")
    ctx.say(f"interLink {v} built with Go {gov} in {api.parent}")


def _must(p, what: str) -> None:
    if p.returncode != 0:
        raise LisaError(f"{what} failed:\n{p.stdout[-2000:]}")


# --- running it ------------------------------------------------------------------------------------
def _mode(ctx: Context):
    return ctx.settings.home.state / "interlink"


def version(ctx: Context) -> str | None:
    """The version running (as 'start' left it), or None."""
    f = _mode(ctx)
    return f.read_text().split()[-1] if f.exists() else None


def configure(ctx: Context) -> None:
    s, h = ctx.settings, ctx.settings.home
    socket = h.run / "interlink.sock"
    api = render_text("runner/cluster/interlink/InterLinkConfig.yaml", socket=socket, tunnel_port=s.tunnel_port,
                      data=f"{h.root}/data/")
    vk = render_text("runner/cluster/interlink/VirtualKubeletConfig.yaml", socket=socket, node=s.node,
                     namespace=s.node, login_host=s.hpc_login_host, hpc_user=s.hpc_user,
                     shadow_image=shadow_image(ctx))
    (h.conf / "InterLinkConfig.yaml").write_text(api)
    (h.conf / "VirtualKubeletConfig.yaml").write_text(vk)


def shadow_image(ctx: Context) -> str:
    return f"ghcr.io/interlink-hq/interlink/ssh-tunnel:{ctx.settings.il_version}"


def start(ctx: Context) -> None:
    s, h, p = ctx.settings, ctx.settings.home, ctx.processes
    if not installed(ctx):
        raise LisaError(f"interLink {s.il_version} is not installed: run 'lisa setup'")
    stop(ctx)
    configure(ctx)
    api_host = s.k8s_api_host or ctx.cluster.server[0]
    api, vk = _bins(ctx)
    p.start("il-tunnel", [
        "ssh", "-N", "-i", str(s.ssh_key), "-o", "BatchMode=yes", "-o", "LogLevel=ERROR",
        "-o", "ServerAliveInterval=30", "-o", "ExitOnForwardFailure=yes", "-o", "StrictHostKeyChecking=yes",
        "-o", f"UserKnownHostsFile={h.known_hosts}",
        "-L", f"127.0.0.1:{s.tunnel_port}:127.0.0.1:{s.sidecar_port}", f"{s.hpc_user}@{s.hpc_login_host}"])
    p.start("il-api", [str(api)], {"INTERLINKCONFIGPATH": str(h.conf / "InterLinkConfig.yaml")})
    time.sleep(3)
    p.start("il-vk", [str(vk), "--nodename", s.node, "--configpath", str(h.conf / "VirtualKubeletConfig.yaml")],
            {"KUBECONFIG": str(s.kubeconfig), "KUBELET_PORT": str(s.vk_port), "POD_IP": s.vk_ip or api_host})
    _mode(ctx).write_text(f"up {s.il_version}\n")
    for _ in range(48):
        if ctx.cluster.node_ready(s.node):
            break
        time.sleep(5)
    else:
        raise LisaError(f"{s.node} not Ready after 4 minutes; the end of {h.log}/il-vk.log:\n"
                        + p.tail("il-vk", 15))
    ctx.say(f"{s.node} Ready")
    approve_certificate(ctx)
    ctx.say(f"interLink {s.il_version} up; logs in {h.log}")


def stop(ctx: Context) -> None:
    for name in reversed(PROCESSES):
        ctx.processes.stop(name)
    (ctx.settings.home.run / "interlink.sock").unlink(missing_ok=True)
    _mode(ctx).unlink(missing_ok=True)


def approve_certificate(ctx: Context) -> None:
    """The virtual kubelet asks for its serving certificate and waits for it indefinitely: nothing
    approves such requests on a kubeadm cluster, and without it the API server cannot fetch container
    logs from it. Approve only the request of our node, made by us, not yet decided."""
    c, me = ctx.cluster, ctx.cluster.whoami()
    for _ in range(30):
        for csr in c.list("certificates.k8s.io/v1", "CertificateSigningRequest"):
            spec, name = csr["spec"], csr["metadata"]["name"]
            if (name.startswith(f"vk-{ctx.settings.node}-") and spec.get("username") == me
                    and spec.get("signerName") == "kubernetes.io/kubelet-serving"
                    and not csr.get("status", {}).get("conditions")):
                c.approve_csr(name)
                ctx.say(f"approved the virtual kubelet's serving certificate ({name}): container logs work")
                return
        time.sleep(2)
    ctx.console.warn("no certificate request of the virtual kubelet to approve: container logs will not work")


def delete_node(ctx: Context) -> None:
    c, node = ctx.cluster, ctx.settings.node
    if c.delete("v1", "Node", node):
        ctx.say(f"virtual node {node} deleted")
    for csr in c.list("certificates.k8s.io/v1", "CertificateSigningRequest"):
        if csr["metadata"]["name"].startswith(f"vk-{node}-"):
            c.delete("certificates.k8s.io/v1", "CertificateSigningRequest", csr["metadata"]["name"])


def diagnostics(ctx: Context) -> str:
    """interLink's processes, the end of their logs, and the shadow pods with their logs."""
    s, p = ctx.settings, ctx.processes
    out = [f"== Kubernetes side: interLink {version(ctx) or 'not up'}, {s.node} Ready: "
           f"{ctx.cluster.node_ready(s.node)}"]
    out += [f"   {n}: {'running' if p.running(n) else 'not running'}" for n in PROCESSES]
    for n in PROCESSES:
        out += [f"== {s.home.log}/{n}.log (last 30 lines)", p.tail(n)]
    shadows = [x for x in ctx.cluster.list("v1", "Pod") if x["metadata"]["namespace"].endswith("-shadow")]
    out.append("== shadow pods: " + (", ".join(f"{x['metadata']['namespace']}/{x['metadata']['name']} "
                                              f"{x.get('status', {}).get('phase')}" for x in shadows) or "none"))
    for x in shadows[-3:]:
        ns, name = x["metadata"]["namespace"], x["metadata"]["name"]
        for c in x["spec"]["containers"]:
            out += [f"== logs {ns}/{name} {c['name']}", ctx.cluster.pod_log(ns, name, c["name"], tail=40)]
    return "\n".join(out) + "\n"


def versions(ctx: Context) -> str:
    """For the evidence: the tag's commit, and each binary's checksum and Go build information."""
    v = ctx.settings.il_version
    tag = run(["git", "ls-remote", REPO, f"refs/tags/{v}"], timeout=60).stdout[:40]
    lines = [f"== interLink {v}, tag commit: {tag or 'unknown'}"]
    go = sorted(ctx.settings.home.root.glob("go-*/bin/go"))
    for b in _bins(ctx):
        if b.exists():
            lines.append(f"{hashlib.sha256(b.read_bytes()).hexdigest()}  {b}")
            if go:
                info = run([str(go[-1]), "version", "-m", str(b)]).stdout.splitlines()
                lines += [x for x in info if not x.startswith("\t") or any(
                    k in x for k in ("path", "vcs.revision", "vcs.time", "vcs.modified"))]
    return "\n".join(lines)
