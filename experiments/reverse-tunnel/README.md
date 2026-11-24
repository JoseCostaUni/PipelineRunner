# Experiment: interLink 0.6.3's reverse tunnel instead of the split executor

This is the record of the first trial of interLink 0.6.3 on the testbed (16-17 Nov 2026), and the
plugin patch to propose upstream (`upstream/`). The approach it tried is now the only one in this
repository, and runs with `../../deploy/deucalion` everywhere, the testbed included. The experiment's
own runner (`run.sh`, `guest/`) worked by switching the testbed's installation of Isabel's prototype
to 0.6.3 and back. It was removed on 24 Nov 2026 and is in the tag `split-interlink-0.6.1`.

**Question.** Can plain Argo workflows run on an air-gapped compute node with stock interLink
0.6.3 and its Slurm plugin 0.6.3, without the split executor's wrappers?

**Why.** CNES does not want to maintain wrapper scripts. interLink 0.6.3 (released 16 Nov 2026)
adds a reverse tunnel to its ssh shadow (interLink PR #577): a pod running on a compute node can
open connections back into the cluster (the Kubernetes API, the Global Storage) through the login
node, with nothing to install on the site. Plugin 0.6.3 adds the per-job socket directory the
tunnel needs (#166) and fixes failed jobs being reported as successful (#169), the bug the split
executor's `squeue` worked around.

## How it works here

```
job on cn (offline) ──connect minio...:9000 / kubernetes...:6443──> relay on 127.x.y.z (started by the job)
   └─ unix socket in SocketDirRoot ── user-space sshd in the job (-R) ── srun --overlap on login ── ssh ──┐
shadow pod on ulisses (ssh-reverse) <─────────────────────────────────────────────────────────────────────┘
   └─ dials minio.default.svc.cluster.local:9000 and kubernetes.default.svc.cluster.local:443
```

- **The standard Argo executor runs on the compute node**: `init`, `main` and `wait` all stay in the
  Slurm job, as on any Kubernetes node. No split, no relay of ours, no `squeue`/`scancel` wrapper.
- **What the site must allow (Deucalion):** ssh from Ulisses to the login node (already there for
  interLink), `squeue` and `srun --jobid=<job> --overlap` on the login node, `python3` and an `sshd`
  binary on the compute nodes, and a shared folder for `SocketDirRoot`. Chosen carrier:
  `Reverse.NodeExec: srun` and `Reverse.Sshd: userspace`, the combination that needs neither ssh
  into compute nodes nor forwarding on the site's sshd. It is the slowest one (Slurm's I/O
  forwarding), which is fine for small artifacts and is part of what this experiment measures.
- **What is still ours:** one wrapper, `../../setup/hpc/subpath-fix/sbatch`. Plugin 0.6.3 still
  ignores `subPath` on emptyDir volumes, which Argo uses for every input artifact. `upstream/` has
  the plugin patch (a few lines and a unit test) to propose; once released, no wrapper is left.
- **Configuration only, everything else:**
  - virtual kubelet: `Network.EnableTunnel`, `ShadowMode: ssh`, `SSH.Reverse` (now written by
    `../../deploy/deucalion/k8s-side.sh`, `il_config`), and `KubernetesApiAddr: kubernetes.default.svc.cluster.local`,
    `KubernetesApiPort: 6443`, so the executor reaches the API through the tunnel;
  - Argo `workflowDefaults`: the pod annotation `interlink.eu/reverse-forwards:
    "minio.default.svc.cluster.local:9000 6443:kubernetes.default.svc.cluster.local:443"`, so
    workflows stay plain Argo;
  - plugin: `SocketDirRoot`, `CommandPrefix: ""` (Isabel's data wrapper off), `--no-eval
    --contain`, pre-pulled images (`ImagePrefix`).

The Global Storage (MinIO in Docker on ulisses) gets a Service name, because the tunnel maps names,
not IPs. The experiment's `ulisses.sh` also added a NAT rule for shadow pods, written for Calico's default pod range;
it turned out not to be needed, because Calico picked 172.16.0.0/16 on the testbed and a pod reaches
the login node without it (checked on 17 Nov 2026).

## Running it now

On the testbed, from the repository root: `make init`, then `make test` (`../../HOW_TO_RUN.md`,
section 1). On Deucalion: `../../RUN_ON_ULISSES.md`. Both make the same changes as this experiment did,
for any CPU architecture, and they delete the SSH key Secret and interLink's copies of it in
`make restore`.

The experiment's results are in `results/<time>/` on the Mac where it ran (not versioned):
- `summary.txt`: one line per test, with PASS/FAIL, the phase, the time, and the checks against Argo
  **and** the Global Storage;
- `argo/` and `jobs/`: the Argo objects and the job folders;
- `diag-TC<n>.txt` for every test that failed, and `run.log`.

## What to compare with the split executor (T1)

| | Split executor (T1) | Reverse tunnel (this) |
|---|---|---|
| Code we maintain | 3 wrappers + relay | 1 wrapper (subPath), until upstream |
| Where init/wait run | login node | compute node |
| Site needs | ssh to login | ssh to login, `srun --overlap`, python3 + sshd on nodes |
| Data path | login node ↔ Global Storage | compute node ↔ tunnel ↔ shadow ↔ Global Storage |
| Throughput | login node's network | Slurm I/O forwarding (srun carrier) |
| Isolation | same account, job folders hold keys | same, plus a relay that only accepts the job's user |

Measured: pass/fail and time per test against T1 (`../../APPROACH.md`, sections 4 and 6). Not
measured yet: the time of TC06/TC10 with a larger artifact, to see the srun carrier's throughput
(`../../NEXT_STEPS.md`).

## Results

Run on the testbed on 16 and 17 November 2026. interLink 0.6.3 had to be built from its tag (the
release has no binaries), and Isabel's configuration files worked with the 0.6.3 binaries. The
first runs found three problems, all fixed in this folder (now carried by `../../deploy/deucalion`) and in `setup/hpc/subpath-fix`:

1. the plugin refused a `SocketDirRoot` under `.interlink` (no path element may start with a dot);
2. plugin 0.6.3 reports the free memory it sees as the virtual node's capacity, which fell to
   200Mi, below one pod's request, so pods stayed `Pending` (TC05 stopped after 20 minutes in run
   `20261117-011154`); the plugin now reports a fixed capacity through `ResourceScriptPath`;
3. TC09 and TC10 failed in the same run (`main` exited with 1). Before the next run the subPath
   fix was changed to read `ARGO_TEMPLATE` from whichever container's env file has it (`main`'s
   does not) and to always hand Slurm a new `job.sh`, and both passed.

After the fixes all ten tests passed: TC00-TC04, TC06 and TC07 in `20261117-011154`, TC09 and TC10
in `20261117-022804`, TC05 in `20261117-024031`. The same mode then passed through the Deucalion
scripts, and later on Deucalion: `../../APPROACH.md`, section 4.
