"""The HPC login node, over SSH as HPC_USER (paramiko; the login node has no Python, so what runs there
is cli/hpc.sh).

Commands run in a login shell (bash -l), so Slurm and Singularity are on the PATH as in an interactive
session. The login node's host keys are pinned on first contact (ssh-keyscan) into a file of ours, and
every later connection, the shadow pods' too, is checked strictly against it.
"""
import os
import shlex
import subprocess
import sys
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

import paramiko

from .. import LisaError


@dataclass
class Result:
    code: int
    out: str
    err: str

    @property
    def ok(self) -> bool:
        return self.code == 0


class LoginNode:
    def __init__(self, host: str, user: str, key: Path, known_hosts: Path, script: str):
        self.host, self.user, self.key = host, user, key
        self.known_hosts = known_hosts
        self.script = script                # hpc.sh on the login node
        self._ssh: paramiko.SSHClient | None = None

    @property
    def target(self) -> str:
        return f"{self.user}@{self.host}"

    # --- the connection ---------------------------------------------------------------------------
    def pin_host_keys(self) -> None:
        """Trust on first use: the keys the login node shows now, kept for every later connection."""
        try:
            p = subprocess.run(["ssh-keyscan", "-T", "10", self.host], capture_output=True, text=True,
                               timeout=60)
        except (OSError, subprocess.TimeoutExpired) as e:
            raise LisaError(f"ssh-keyscan {self.host} failed: {e}") from None
        if not p.stdout.strip():
            raise LisaError(f"ssh-keyscan {self.host} returned no host key: is it reachable on port 22?")
        self.known_hosts.parent.mkdir(parents=True, exist_ok=True)
        self.known_hosts.write_text(p.stdout)
        self.known_hosts.chmod(0o600)

    def _client(self) -> paramiko.SSHClient:
        if self._ssh:
            return self._ssh
        known = self.known_hosts.read_text() if self.known_hosts.exists() else ""
        if not any(line.split(" ", 1)[0] == self.host for line in known.splitlines()):
            self.pin_host_keys()
        c = paramiko.SSHClient()
        c.load_host_keys(str(self.known_hosts))
        c.set_missing_host_key_policy(paramiko.RejectPolicy())
        try:
            c.connect(self.host, username=self.user, key_filename=str(self.key), look_for_keys=False,
                      allow_agent=False, timeout=20, banner_timeout=30, auth_timeout=30)
        except paramiko.BadHostKeyException:
            raise LisaError(f"the host key of {self.host} changed. If that is expected, delete its lines "
                            f"from {self.known_hosts}") from None
        except (paramiko.SSHException, OSError) as e:
            raise LisaError(f"ssh to {self.target} with {self.key} failed: {e}") from None
        c.get_transport().set_keepalive(30)
        self._ssh = c
        return c

    def close(self) -> None:
        if self._ssh:
            self._ssh.close()
            self._ssh = None

    # --- running commands -------------------------------------------------------------------------
    def run(self, command: str, timeout: float | None = 120) -> Result:
        """Run and collect the output."""
        _, out, err = self._client().exec_command("bash -lc " + shlex.quote(command), timeout=timeout)
        o, e = out.read().decode(errors="replace"), err.read().decode(errors="replace")
        return Result(out.channel.recv_exit_status(), o, e)

    def run_bytes(self, command: str) -> bytes:
        """Run and return its standard output as bytes (a tar file, say)."""
        _, out, err = self._client().exec_command("bash -lc " + shlex.quote(command))
        data = out.read()
        if out.channel.recv_exit_status() != 0:
            raise LisaError(f"on {self.host}: {command}: {err.read().decode(errors='replace').strip()}")
        return data

    def stream(self, command: str, emit: Callable[[str], None] = print) -> int:
        """Run and hand each line of its output to emit as it comes; the exit status."""
        chan = self._client().get_transport().open_session()
        chan.set_combine_stderr(True)
        chan.exec_command("bash -lc " + shlex.quote(command))
        buf = b""
        while data := chan.recv(4096):
            buf += data
            *lines, buf = buf.split(b"\n")
            for line in lines:
                emit(line.decode(errors="replace"))
        if buf:
            emit(buf.decode(errors="replace"))
        return chan.recv_exit_status()

    def hpc(self, *args: str) -> str:
        """The command line of cli/hpc.sh on the login node."""
        return " ".join(shlex.quote(a) for a in ("bash", self.script) + args)

    # --- files ------------------------------------------------------------------------------------
    def put(self, remote: str, *, text: str | None = None, path: Path | None = None, mode: int = 0o644) -> None:
        sftp = self._client().open_sftp()
        try:
            data = text.encode() if text is not None else path.read_bytes()
            with sftp.open(remote + ".part", "wb") as f:
                f.write(data)
            sftp.chmod(remote + ".part", mode)
            sftp.posix_rename(remote + ".part", remote)
        finally:
            sftp.close()

    # --- an interactive shell ---------------------------------------------------------------------
    def shell(self, folder: str) -> None:
        """Replace this process with an interactive ssh session in the folder (OpenSSH, for the terminal)."""
        args = ["ssh", "-t", "-i", str(self.key), "-o", f"UserKnownHostsFile={self.known_hosts}",
                "-o", "StrictHostKeyChecking=yes", self.target, f"cd {shlex.quote(folder)} && exec bash -l"]
        sys.stdout.flush()
        os.execvp("ssh", args)
