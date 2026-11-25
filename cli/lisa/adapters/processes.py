"""Long-running processes of ours on the Kubernetes side (interLink's three), without systemd: user
services stop at logout without linger, and linger needs root.

Each runs under lisa.supervise in a session of its own, which restarts it 5 s after it exits and
appends its output to <home>/log/<name>.log. They survive the end of the SSH session that started
them, not a reboot. Also: running a program once (builds, version queries).
"""
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

from ..paths import Home


class Processes:
    def __init__(self, home: Home):
        self.home = home

    def _pidfile(self, name: str) -> Path:
        return self.home.run / f"{name}.pid"

    def start(self, name: str, argv: list[str], env: dict[str, str] | None = None) -> None:
        self.stop(name)
        log = self.home.log / f"{name}.log"
        p = subprocess.Popen(
            [sys.executable, "-m", "lisa.supervise", str(log), "--", *argv],
            cwd=self.home.root, env={**os.environ, **(env or {})}, start_new_session=True,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self._pidfile(name).write_text(str(p.pid))

    def pid(self, name: str) -> int | None:
        try:
            pid = int(self._pidfile(name).read_text())
            os.kill(pid, 0)
            return pid
        except (OSError, ValueError):
            return None

    def running(self, name: str) -> bool:
        return self.pid(name) is not None

    def stop(self, name: str) -> None:
        """Stop the supervisor and what it runs: the whole process group of its session."""
        pid = self.pid(name)
        if pid:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(pid, sig)
                except ProcessLookupError:
                    break
                time.sleep(1)
        self._pidfile(name).unlink(missing_ok=True)

    def tail(self, name: str, lines: int = 30) -> str:
        try:
            text = (self.home.log / f"{name}.log").read_text()
            return "\n".join(line[:300] for line in text.splitlines()[-lines:])
        except OSError:
            return "(no log)"


def run(argv: list[str], *, cwd: Path | None = None, env: dict[str, str] | None = None,
        timeout: float | None = None) -> subprocess.CompletedProcess:
    """Run a program once and collect its output (stdout and stderr together)."""
    return subprocess.run(argv, cwd=cwd, env={**os.environ, **(env or {})}, timeout=timeout, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
