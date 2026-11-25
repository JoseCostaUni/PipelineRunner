"""python -m lisa.supervise <log file> -- <command...>

Runs the command, appends its output to the log file, and starts it again 5 s after it exits, until
this process is stopped (lisa.adapters.processes stops its whole process group)."""
import subprocess
import sys
import time


def main() -> None:
    log, sep, *command = sys.argv[1:]
    if sep != "--" or not command:
        sys.exit("usage: python -m lisa.supervise <log file> -- <command...>")
    while True:
        with open(log, "a") as out:
            code = subprocess.call(command, stdin=subprocess.DEVNULL, stdout=out, stderr=out)
            out.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')} exited with {code}, restarting in 5 s\n")
        time.sleep(5)


if __name__ == "__main__":
    main()
