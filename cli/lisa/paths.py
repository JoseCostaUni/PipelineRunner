"""Where things are: in this repository, and in your home folder on the Kubernetes side."""
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
RUNNER = REPO / "runner"            # what gets installed: templates and files
TESTS = REPO / "tests"              # the test workflows and what each must produce
RESULTS = REPO / "results"          # one folder per test run (not in git)
HPC_SCRIPT = REPO / "cli" / "hpc.sh"

# Label of everything this tool creates in the cluster (also written in runner/cluster/*.yaml).
OWNER = "lisa-runner"
OWNER_LABEL = "app.kubernetes.io/managed-by=" + OWNER


@dataclass(frozen=True)
class Home:
    """Everything the tool keeps on the Kubernetes side (LISA_HOME, default ~/lisa-runner): interLink's
    binaries and configuration, its logs, the PID files of its processes and saved state. Private:
    interLink's logs hold service-account tokens, and state/ the login node's pinned host keys."""
    root: Path

    @property
    def bin(self) -> Path:
        return self.root / "bin"

    @property
    def conf(self) -> Path:
        return self.root / "conf"

    @property
    def log(self) -> Path:
        return self.root / "log"

    @property
    def run(self) -> Path:
        return self.root / "run"

    @property
    def state(self) -> Path:
        return self.root / "state"

    @property
    def known_hosts(self) -> Path:
        return self.state / "known_hosts"

    def interlink(self, version: str) -> Path:
        return self.root / f"interlink-{version}"

    def create(self) -> None:
        for d in (self.root, self.bin, self.conf, self.log, self.run, self.state):
            d.mkdir(parents=True, exist_ok=True)
            d.chmod(0o700)
