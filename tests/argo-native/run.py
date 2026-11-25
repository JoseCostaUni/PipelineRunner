#!/usr/bin/env python3
"""Run the test workflows of this folder and check what they produced.

deploy/deucalion/k8s-side.sh test calls this once both sides are up and the test data in the Global
Storage is reset. For every test NN it submits NN-*.yaml to Argo and waits for it to end. It then
records the workflow, its steps, its pods, their output and where Slurm ran them, and runs the
checks of checks.py, in Argo AND in the Global Storage. Into --out (results/<run>/):

  summary.txt   one line per test, its failed checks, the tests passed, and last where the steps ran
  where.tsv     every step pod: its Kubernetes node, Slurm job, partition, compute node and state
  TC<NN>/       workflow.yaml, workflow.json, steps.tsv, pods.tsv, logs.txt, where.tsv, checks.tsv,
                and diag.txt when the test failed

Exit status 0 when every test passed. Python 3.6 or newer, standard library only: argo, kubectl and
mc do the talking (mc with an alias for the Global Storage, which the caller sets).
"""
import argparse
import json
import shutil
import subprocess
import sys
import time
from collections import namedtuple
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import checks  # noqa: E402  (checks.py, next to this file)

SlurmJob = namedtuple("SlurmJob", "id partition nodes state")
Pod = namedtuple("Pod", "name uid node slurm")


def run(cmd, timeout=None, merge=False):
    """Run a command and return it finished, whatever its exit status. merge: stderr into stdout."""
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT if merge else subprocess.PIPE,
                          universal_newlines=True, timeout=timeout)


def as_json(p):
    """A finished command's output as JSON, or {} when it failed or printed something else."""
    try:
        return json.loads(p.stdout) if p.returncode == 0 else {}
    except ValueError:
        return {}


class Result:
    """One test's outcome, as the checks see it (checks.py describes it)."""

    def __init__(self, workflow, pods, seconds, args):
        status = workflow.get("status") or {}
        self.phase = status.get("phase") or "Unknown"
        self.steps = {}
        for n in sorted((status.get("nodes") or {}).values(), key=lambda n: n.get("displayName", "")):
            if n.get("type") == "Pod":
                self.steps.setdefault(n.get("displayName"), n.get("phase"))
        self.pods = pods
        self.seconds = seconds
        self.node = args.node
        self.partition = args.partition
        self._store = args.store
        self._objects = {}

    def object(self, key):
        if key not in self._objects:
            p = run(["mc", "cat", self._store + "/" + key], timeout=60)
            self._objects[key] = p.stdout if p.returncode == 0 else None
        return self._objects[key]


class Runner:
    def __init__(self, args):
        self.a = args
        self.out = Path(args.out)
        self.current = None                 # the workflow running now, for Ctrl-C

    def say(self, line=""):
        """A line on the terminal and in summary.txt."""
        print(line, flush=True)
        with open(str(self.out / "summary.txt"), "a") as f:
            f.write(line + "\n")

    def slurm_jobs(self):
        """Slurm's record of the user's jobs, by job name: interLink names each job after its pod's UID."""
        p = run(["bash", self.a.helper, "slurm-jobs"], timeout=120)
        jobs = {}
        for line in p.stdout.splitlines():
            f = line.split("|")
            if len(f) >= 5:
                jobs.setdefault(f[0], SlurmJob(*f[1:5]))   # squeue's line first, while it has one
        return jobs

    def wait(self, name):
        """Wait for the workflow to end; stop it after --timeout seconds."""
        try:
            run(["argo", "wait", "-n", self.a.namespace, name], timeout=self.a.timeout)
        except subprocess.TimeoutExpired:
            run(["argo", "stop", "-n", self.a.namespace, name])
            time.sleep(10)

    def test(self, t):
        """Run test t; True when it passed."""
        files = sorted(HERE.glob(t + "-*.yaml"))
        if not files:
            self.say("TC{}  FAIL  no workflow file {}-*.yaml".format(t, t))
            return False
        d = self.out / ("TC" + t)
        d.mkdir(parents=True, exist_ok=True)
        shutil.copy(str(files[0]), str(d / "workflow.yaml"))
        ns = self.a.namespace

        start = time.time()
        p = run(["argo", "submit", "-n", ns, str(files[0]), "-l", self.a.label, "-o", "json"])
        if p.returncode != 0:
            self.say("TC{}  FAIL  submit failed: {}".format(t, p.stderr.strip()[:200]))
            return False
        name = as_json(p).get("metadata", {}).get("name")
        if not name:
            self.say("TC{}  FAIL  submit gave no workflow name: {}".format(t, p.stdout.strip()[:200]))
            return False
        self.current = name
        self.wait(name)
        self.current = None
        secs = int(time.time() - start)

        p = run(["argo", "get", "-n", ns, name, "-o", "json"])
        workflow = as_json(p)
        (d / "workflow.json").write_text(json.dumps(workflow, indent=2) + "\n")

        # Its pods, and the Slurm job that ran each (named after the pod's UID), as Slurm records it.
        p = run(["kubectl", "-n", ns, "get", "pods", "-l", "workflows.argoproj.io/workflow=" + name, "-o", "json"])
        items = as_json(p).get("items", [])
        jobs = self.slurm_jobs() if items else {}
        pods = [Pod(i["metadata"]["name"], i["metadata"]["uid"], i["spec"].get("nodeName", ""),
                    jobs.get(i["metadata"]["uid"])) for i in items]
        (d / "pods.tsv").write_text("".join("{}\t{}\t{}\n".format(x.name, x.uid, x.node) for x in pods))
        where = ""
        for x in pods:
            j = "\t".join(x.slurm) if x.slurm else "no Slurm record"
            where += "TC{}\t{}\t{}\t{}\n".format(t, x.name, x.node, j)
        (d / "where.tsv").write_text(where)
        with open(str(self.out / "where.tsv"), "a") as f:
            f.write(where)

        # Each step's output, as the virtual kubelet serves it. Not 'argo logs': it asks for
        # timestamps, which the virtual kubelet does not give, and turns every line into a parse error.
        with open(str(d / "logs.txt"), "w") as f:
            for x in pods:
                f.write("== {}\n".format(x.name))
                f.write(run(["kubectl", "-n", ns, "logs", x.name, "--all-containers", "--prefix"], merge=True).stdout)

        r = Result(workflow, pods, secs, self.a)
        (d / "steps.tsv").write_text("".join("{}\t{}\n".format(k, v) for k, v in sorted(r.steps.items())))
        own = checks.CHECKS.get(t, [])
        rows = []
        for c in own + checks.EVERY_TEST:
            try:
                got = str(c.got(r))
            except Exception as e:          # a mistake in a check fails that check, not the run
                got = "error in the check: {!r}".format(e)
            rows.append(("PASS" if got == c.expected else "FAIL", c.kind, c.what, c.expected, got))
        (d / "checks.tsv").write_text("".join("\t".join(x) + "\n" for x in rows))

        ok = sum(1 for x in rows if x[0] == "PASS")
        passed = bool(own) and ok == len(rows)       # a test without checks of its own does not pass
        self.say("TC{}  {}  {} in {}m{:02d}s, checks {}/{}  ({})".format(
            t, "PASS" if passed else "FAIL", r.phase, secs // 60, secs % 60, ok, len(rows), name))
        if not own:
            self.say("        failed: no checks for TC{} in checks.py".format(t))
        for res, kind, what, exp, got in rows:
            if res == "FAIL":
                self.say("        failed: {} {} (expected {}, got {})".format(kind, what, exp, got))
        if not passed:
            with open(str(d / "diag.txt"), "w") as f:
                f.write(run(["bash", self.a.helper, "diag"], merge=True, timeout=300).stdout)
        return passed

    def main(self, tests, explicit):
        self.out.mkdir(parents=True, exist_ok=True)
        with open(str(self.out / "where.tsv"), "w") as f:
            f.write("test\tpod\tkubernetes node\tslurm job\tpartition\tcompute node\tslurm state\n")
        print("run {} (interLink {}, reverse tunnel): tests {} -> {}".format(
            self.out.name, self.a.interlink, " ".join(tests), self.out), flush=True)
        self.say("interLink {} with the reverse tunnel, partition {}".format(self.a.interlink, self.a.partition))
        skipped = []
        if not explicit:              # all tests: those that need what this setup lacks are skipped
            for t in tests:
                need = checks.NEEDS.get(t)
                if need and need not in self.a.feature:
                    skipped.append(t)
                    self.say("TC{}  skipped: needs {}".format(t, checks.FEATURES.get(need, need)))
            tests = [t for t in tests if t not in skipped]
        try:
            passed = sum(1 for t in tests if self.test(t))
        except KeyboardInterrupt:
            print("\ninterrupted: results so far in {}/summary.txt.".format(self.out))
            if self.current:
                run(["argo", "stop", "-n", self.a.namespace, self.current], timeout=30)
                print("Stopped {}; make clean (./k8s-side.sh clean) deletes it and cancels its job.".format(self.current))
            return 130
        self.say("passed: {} of {} tests{}".format(passed, len(tests),
                                                   ", {} skipped".format(len(skipped)) if skipped else ""))
        rows = [line.split("\t") for line in (self.out / "where.tsv").read_text().splitlines()[1:]]
        parts = sorted({x[4] for x in rows if len(x) >= 7 and x[4]})
        hosts = sorted({x[5] for x in rows if len(x) >= 7 and x[5]})
        self.say("where: {} step pods; Slurm partitions: {}; compute nodes: {}  ({})".format(
            len(rows), " ".join(parts) or "none recorded", " ".join(hosts) or "none recorded", self.out / "where.tsv"))
        print("summary: {}/summary.txt  (keep the whole folder as evidence)".format(self.out))
        return 0 if passed == len(tests) else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("tests", nargs="*", help="test numbers, e.g. 00 11 (default: every NN-*.yaml here)")
    ap.add_argument("--out", required=True, help="folder for this run's results")
    ap.add_argument("--namespace", required=True, help="where the test workflows run")
    ap.add_argument("--label", default="lisa-test=true", help="label of the test workflows")
    ap.add_argument("--node", required=True, help="the virtual node the step pods must run on")
    ap.add_argument("--partition", required=True, help="the Slurm partition the jobs must run in")
    ap.add_argument("--store", required=True, help="the bucket for mc, as alias/bucket")
    ap.add_argument("--interlink", default="?", help="interLink's version, for the summary")
    ap.add_argument("--helper", required=True, help="k8s-side.sh, for 'slurm-jobs' and 'diag'")
    ap.add_argument("--timeout", type=int, default=1800, help="seconds before a workflow is stopped")
    ap.add_argument("--feature", action="append", default=[],
                    help="what this setup has besides the default, e.g. mirror (checks.NEEDS)")
    a = ap.parse_args()
    tests = [t.upper().replace("TC", "").zfill(2) for t in a.tests] or \
        sorted({f.name[:2] for f in HERE.glob("[0-9][0-9]-*.yaml")})
    sys.exit(Runner(a).main(tests, explicit=bool(a.tests)))


if __name__ == "__main__":
    main()
