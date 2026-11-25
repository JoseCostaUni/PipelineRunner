"""What the commands print: plain lines, and PASS / FAIL / INFO lines for checks.

Every line can also go to a file (the output of 'check' is kept in results/)."""
import sys
from pathlib import Path


class Console:
    def __init__(self, copy_to: Path | None = None):
        self.failed = False
        self._copy = open(copy_to, "a") if copy_to else None    # noqa: SIM115 (open for the whole command)

    def say(self, line: str = "") -> None:
        print(line, flush=True)
        if self._copy:
            self._copy.write(line + "\n")
            self._copy.flush()

    def step(self, what: str) -> None:
        self.say(f"-- {what}")

    def ok(self, what: str) -> None:
        self.say(f"PASS  {what}")

    def fail(self, what: str) -> None:
        self.failed = True
        self.say(f"FAIL  {what}")

    def info(self, what: str) -> None:
        self.say(f"INFO  {what}")

    def check(self, passed: bool, if_passed: str, if_failed: str) -> bool:
        if passed:
            self.ok(if_passed)
        else:
            self.fail(if_failed)
        return passed

    def warn(self, what: str) -> None:
        print(f"WARNING: {what}", file=sys.stderr, flush=True)
        if self._copy:
            self._copy.write(f"WARNING: {what}\n")
