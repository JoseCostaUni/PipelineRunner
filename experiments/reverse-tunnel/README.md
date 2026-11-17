# Experiment: interLink 0.6.3's reverse tunnel instead of the split executor

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
  - virtual kubelet: `Network.EnableTunnel`, `ShadowMode: ssh`, `SSH.Reverse` (see
    `guest/ulisses.sh reverse on`), and `KubernetesApiAddr: kubernetes.default.svc.cluster.local`,
    `KubernetesApiPort: 6443`, so the executor reaches the API through the tunnel;
  - Argo `workflowDefaults`: the pod annotation `interlink.eu/reverse-forwards:
    "minio.default.svc.cluster.local:9000 6443:kubernetes.default.svc.cluster.local:443"`, so
    workflows stay plain Argo;
  - plugin: `SocketDirRoot`, `CommandPrefix: ""` (Isabel's data wrapper off), `--no-eval
    --contain`, pre-pulled images (`ImagePrefix`).

The Global Storage (MinIO in Docker on ulisses) gets a Service name, because the tunnel maps names,
not IPs. `ulisses.sh` also adds a NAT rule for shadow pods, written for Calico's default pod range;
it turned out not to be needed, because Calico picked 172.16.0.0/16 on the testbed and a pod reaches
the login node without it (checked on 17 Nov 2026).

**On Deucalion** this mode is run with the trial scripts, not with this folder:
`../../deploy/deucalion/k8s-side.sh mode reverse` (steps in `../../HOW_TO_RUN.md`, section 2). They
make the same changes, for any CPU architecture, with Isabel's MinIO under a Service name, and they
delete the SSH key Secret and interLink's copies of it when the mode is switched off.

## Running it (on the Mac)

From the repository root, `make init-new` runs `install` and `enable`, `make test` runs the tests
and `make init-old` runs `disable`. The same steps by hand:

```sh
cd experiments/reverse-tunnel   # from the repository root
./run.sh install          # once: interLink 0.6.3 on ulisses (built from the tag if no release
                          # binaries: the 0.6.3 release has none yet), plugin 0.6.3 on login
./run.sh enable           # switch both sides to 0.6.3 + reverse tunnel
./run.sh test 00          # one workflow with an input and an output artifact
./run.sh test             # all plain-Argo tests (TC00-TC10, TC08 not ported)
./run.sh diag             # shadow pods and their logs, virtual kubelet log, plugin settings
./run.sh disable          # back to Isabel's 0.6.1 and her settings
```

Results go to `results/<time>/`: `summary.txt` (one line per test: PASS/FAIL, phase, time,
checks against Argo **and** the Global Storage), `argo/` and `jobs/` (Argo objects, job folders),
and `diag-TC<n>.txt` for every test that failed. Logs of each step are in `results/<time>/run.log`.

`install` and `enable` leave Isabel's 0.6.1 files in place: 0.6.3 runs through systemd drop-ins
and backups of the two configuration files (`VirtualKubeletConfig.yaml.pre-rt`,
`SlurmConfig.yaml.pre-rt`), which `disable` puts back.

## What to compare with the split executor (T1)

| | Split executor (T1) | Reverse tunnel (this) |
|---|---|---|
| Code we maintain | 3 wrappers + relay | 1 wrapper (subPath), until upstream |
| Where init/wait run | login node | compute node |
| Site needs | ssh to login | ssh to login, `srun --overlap`, python3 + sshd on nodes |
| Data path | login node ↔ Global Storage | compute node ↔ tunnel ↔ shadow ↔ Global Storage |
| Throughput | login node's network | Slurm I/O forwarding (srun carrier) |
| Isolation | same account, job folders hold keys | same, plus a relay that only accepts the job's user |

Measure at least: pass/fail per test, time per test against T1 (`../../testbed/logs/t1-*`),
and the time of TC06/TC10 with a larger artifact to see the srun carrier's throughput (not done
yet).

## Results

Run on the testbed on 16 and 17 November 2026. interLink 0.6.3 had to be built from its tag (the
release has no binaries), and Isabel's configuration files worked with the 0.6.3 binaries. The
first runs found three problems, all fixed in this folder and in `setup/hpc/subpath-fix`:

1. the plugin refused a `SocketDirRoot` under `.interlink` (no path element may start with a dot);
2. plugin 0.6.3 reports the free memory it sees as the virtual node's capacity, which fell to
   200Mi, below one pod's request, so pods stayed `Pending` (TC05 stopped after 20 minutes in run
   `20261117-011154`); the plugin now reports a fixed capacity through `ResourceScriptPath`;
3. TC09 and TC10 failed in the same run (`main` exited with 1). Before the next run the subPath
   fix was changed to read `ARGO_TEMPLATE` from whichever container's env file has it (`main`'s
   does not) and to always hand Slurm a new `job.sh`, and both passed.

After the fixes all ten tests passed: TC00-TC04, TC06 and TC07 in `20261117-011154`, TC09 and TC10
in `20261117-022804`, TC05 in `20261117-024031`. The same mode then passed through the Deucalion
scripts, see `../../APPROACH.md`, section 7.

`./run.sh diag` and `results/<time>/run.log` are the first places to look.
