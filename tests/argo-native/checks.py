"""What every test in this folder must produce, checked in Argo AND in the Global Storage (not in the
Argo UI alone). run.py runs these after each workflow ends.

A check looks at the result r of one test and returns what it found. It passes when that equals what
it expects. r holds:

  r.phase          the workflow's phase in Argo: Succeeded, Failed, Error
  r.steps          {step name: phase} of the steps that ran as pods
  r.pods           the step pods: .name, .node (Kubernetes) and .slurm, Slurm's record of the job that
                   ran it (.id, .partition, .nodes, .state), or None when Slurm has none
  r.object(key)    the text of an object in the Global Storage's bucket, or None when there is none
  r.node           the virtual node the pods must run on, r.partition the Slurm partition
  r.seconds        how long the workflow took

Each test has its list in CHECKS; every test also gets EVERY_TEST. A test in NEEDS needs more than the
default setup: 'make test' (all) skips it unless the setup has it. Standard library only, Python 3.6.
"""
from collections import namedtuple

# kind and what: how the check shows in checks.tsv and the summary. got(r) must return expected.
Check = namedtuple("Check", "kind what expected got")


def phase(expected):
    """The workflow ended in this phase."""
    return Check("phase", "-", expected, lambda r: r.phase)


def step(name, expected):
    """The step ran as a pod and ended in this phase."""
    return Check("step", name, expected, lambda r: r.steps.get(name, "missing"))


def contains(key, text):
    """The object exists in the bucket and contains the text."""
    def got(r):
        body = r.object(key)
        if body is None:
            return "no such object"
        return text if text in body else "content: " + body[:60].replace("\n", " ")
    return Check("object", key, text, got)


ON_HPC = "each on the virtual node, a Slurm job in the partition"


def ran_on_hpc():
    """Every step pod went to the virtual node, and Slurm ran it in the partition. No step ran on
    Ulisses, and a test cannot pass on Argo's word alone."""
    def got(r):
        if not r.pods:
            return "no step pods"
        wrong = []
        for p in r.pods:
            if p.node != r.node:
                wrong.append("{} on node {}".format(p.name, p.node or "none"))
            elif p.slurm is None:
                wrong.append(p.name + ": no Slurm record")
            elif p.slurm.partition not in r.partition.split(","):
                wrong.append("{}: partition {}".format(p.name, p.slurm.partition))
        return "; ".join(wrong) or ON_HPC
    return Check("where", "step pods", ON_HPC, got)


EVERY_TEST = [ran_on_hpc()]

# What a test needs besides the default setup (run.py --feature, which k8s-side.sh sets).
NEEDS = {"12": "mirror"}
FEATURES = {"mirror": "the image mirror (IMAGE_MIRROR=on)"}

CHECKS = {
    # One step with a native input and output artifact.
    "00": [phase("Succeeded"),
           contains("t1/result.txt", "HELLO FROM THE GLOBAL STORAGE")],
    "01": [phase("Succeeded"),
           step("compute", "Succeeded")],
    # The second step reads an input that does not exist: the workflow must fail, and fail there.
    "02": [phase("Failed"),
           step("compute-read-success", "Succeeded"),
           step("compute-read-fail", "Failed")],
    "03": [phase("Succeeded"),
           contains("users/admin/test-03/new-file.txt", "This file was created by the compute-write module.")],
    "04": [phase("Succeeded"),
           contains("users/admin/test-04/write-file.txt", "THIS TEXT IS IN LOWER CASE.")],
    # Three parallel writes, then an aggregate of the key prefix holding all three.
    "05": [phase("Succeeded"),
           contains("users/admin/test-05/write-file-1.txt", "test-05-file-1"),
           contains("users/admin/test-05/aggregate-file.txt", "test-05-file-1"),
           contains("users/admin/test-05/aggregate-file.txt", "test-05-file-2"),
           contains("users/admin/test-05/aggregate-file.txt", "test-05-file-3")],
    "06": [phase("Succeeded"),
           contains("users/admin/test-06/simulation.txt", "completed after 120 seconds")],
    # Each step's output is kept as a checkpoint: the first written, then transformed twice.
    "07": [phase("Succeeded"),
           contains("users/admin/test-07/file-1.txt", "test-07-file"),
           contains("users/admin/test-07/file-2.txt", "TEST-07-FILE"),
           contains("users/admin/test-07/file-3.txt", "TEST-07-FILE")],
    "09": [phase("Succeeded"),
           step("compute-read", "Succeeded"),
           contains("users/admin/test-09/new-file.txt", "test-09")],
    "10": [phase("Succeeded"),
           contains("users/system/test-10/transformed-file.txt", "TEST-03"),
           contains("users/system/test-10/simulation.txt", "completed after 60 seconds"),
           contains("users/system/test-10/aggregate-file.txt", "TEST-03"),
           step("compute-read", "Succeeded")],
    # The step's record of what it could reach from inside its container: no connection opened.
    "11": [phase("Succeeded"),
           contains("users/admin/test-11/network.txt", "internet: blocked")],
    # Images nobody built beforehand, pulled while the job runs from the image mirror in the cluster.
    "12": [phase("Succeeded"),
           contains("users/admin/test-12/image.txt", "image: BusyBox v1.37")],
}
