# Testbed: a small Deucalion-like HPC environment

Lima VMs on an Apple Silicon Mac that reproduce the properties of Deucalion that matter for the
Pipeline Runner, so experiments that need an HPC system can run locally and repeatably.

- **Stage A:** a login node and a compute node (the HPC side).
- **Stage B:** adds `ulisses`, the Kubernetes side of the FEUP prototype (kubeadm, Argo, Dex,
  interLink) and its Global Storage (MinIO), all set up by Isabel Moutinho's own scripts.
- **Test T0:** runs her ten test workflows with the compute node online and offline.

## Requirements

- Apple Silicon Mac, Lima >= 1.0 (`limactl --version`; Colima installs it, otherwise `brew install lima`).
- Free disk: about 20 GB (Stage A) or 35 GB (Stage B).
- Free RAM: about 2.5 GB (Stage A) or 6.5 GB (Stage B). Stop Colima first (`colima stop`).
- Isabel's repository next to this folder (`../lisa-pipeline-runner`) for Stage B.

## Usage

Run `make` to list the shortcuts. The main ones:

```sh
make vm-build          # Stage A (first time about 15 minutes)
make test-check        # fidelity checks; report in logs/check-<time>.md
make vm-build-ulisses  # Stage B (first time about 20-40 minutes, mostly downloads)
make test-check        # now also checks ulisses, MinIO and the virtual node
make test-t0           # test T0 (about 1-1.5 hours); report in logs/t0-<time>/report.md
make report-t0         # print the latest T0 report
make test-t1           # test T1: plain Argo workflows + split executor (about 25 minutes)
make report-t1         # print the latest T1 report

make vm-status         # VMs, network mode, virtual node
make net-normal        # compute node without internet  (make net-dev: with internet)
make ssh-login         # shell as lisa on the login node (ssh-compute, ssh-ulisses, ssh-*-root)
make vm-stop           # stop everything, frees the RAM  (make vm-start to resume)
make vm-clean          # remove what tests and checks left in the VMs (jobs, data, images, caches)
make vm-remove         # delete the VMs (keys, the Slurm build cache and logs/ are kept)
```

Targets are grouped by prefix: `vm-*`, `net-*`, `ssh-*`, `test-*`, `report-*`. The old names
(`make up`, `make check`, `make t0`, ...) still work.

`check`, `t0` and `clean` refuse to run while another of them is running: each one switches the
compute node's network mode, so running two together mixes their results.

`make` calls `./testbed`, which you can also run directly (`./testbed help`). If a step fails,
its log is in `logs/`; the last lines are printed on the screen.

## What it reproduces

| Deucalion / FEUP prototype | Testbed | Why it matters |
|---|---|---|
| Separate login and compute nodes | Two VMs, so two kernels | Cross-node effects (file notifications, caching) only appear with separate machines |
| Login nodes and `dev-*` partitions reach the internet; `normal-*` partitions do not ([changelog, 19 Feb 2025](https://docs.macc.fccn.pt/)) | One compute node with a switch: `make net-dev` / `make net-normal`. In `normal`, only the login node is reachable: no internet, no DNS, no Kubernetes side, no MinIO | Dev and normal nodes differ only in network access, so the network is the only variable |
| Shared file systems: Lustre on `/projects`, NFSv4 on `/home` | NFSv4 served by the compute node, mounted on the login node without attribute or lookup caching (close to Lustre's coherent view) | The login node is a client, so it gets no inotify events for files written on the compute node, as on a real cluster |
| Slurm 23.11.4 | Slurm 23.11.4, built from SchedMD's source | Same commands and job behaviour |
| Singularity, no Docker, no root for users | Apptainer (provides the `singularity` command), user `lisa` without sudo | Same way jobs run containers |
| Only SSH into the login node; `ssh -R` not allowed | `AllowTcpForwarding local` for `lisa` | Reproduces why the FEUP prototype uses `ssh -L` |
| Project folder `/projects/EEHPC-DEV-2026D02-075` | Same path | Isabel's scripts keep their defaults |
| Ulisses: Debian, kubeadm 1.35, Calico, Argo 3.7.12, Dex, interLink 0.6.1 + SSH tunnel | Debian 13 VM set up by her `setup/kubernetes/main.sh` | Same Kubernetes side |
| Global Storage: MinIO in Docker on an Azure VM | MinIO in Docker set up by her `setup/global_storage/main.sh`, on `ulisses` (saves a VM) | Reachable from the login node, not from an offline compute node |
| Sidecar and data wrapper on Deucalion | Her `setup/hpc/main.sh`, run as `lisa` on the login node | Same HPC side |

## Changes made to Isabel's setup (Stage B)

Only these. The exact diff is printed in `logs/<time>-provision-ulisses.log`.

1. **CPU architecture of downloads**: `_Linux_x86_64` -> `_Linux_arm64` (interLink API, virtual
   kubelet, Slurm sidecar) and `linux-amd64/mc` -> `linux-arm64/mc`. Same versions.
2. **`.env` values** (her scripts read them): this testbed's IP addresses, user `lisa`, partition
   `arm`, account `testbed`. MinIO keeps her default credentials.
3. **Initial data folders** `data/users/{admin,alice,system}` are created before the tests, because
   her sidecar bind-mounts `data/users/system` into every job and the wrapper bind-mounts the user's
   folder (on Deucalion they existed from earlier use).
4. **Tools for running the tests**, outside her stack: the `argo` CLI and `mc` on `ulisses`.
5. **MinIO downloads.** MinIO stopped distributing free images and binaries in October 2025, so
   her `quay.io/minio/minio` image is refused. The testbed uses the first MinIO image that can still
   be pulled (`docker.io/minio/minio`, then the `pgsty/minio` fork) and, if `dl.min.io` is gone,
   serves the same `mc` client from `ulisses` to her `2-data.sh`. Both changes are printed in the
   step logs. Her setup can no longer be reproduced exactly as written, which is worth a sentence
   in the thesis.

## Test T0

Her ten tests (`tests/workflows`, TC01-TC10), submitted with `argo submit`, in three modes:

| Mode | Compute node | Images | Question |
|---|---|---|---|
| `dev` | online | `docker://` (her setting) | Baseline: as on Deucalion's `dev-x86` |
| `normal` | offline | `docker://` (her setting) | Does her design work on an isolated node? |
| `normal-images` | offline | pulled beforehand on the login node (only the sidecar's `ImagePrefix` changes) | With images out of the way, do her data transfers work on an isolated node? |

Before each mode the Global Storage and the HPC data folder are reset and the queue is emptied
(Kubernetes Jobs, Slurm jobs, interLink job folders). After each test its leftover Jobs are removed:
her Jobs keep the default `backoffLimit` of 6, so a failed Job keeps retrying after Argo has moved on
and would otherwise run into the next test. While a test runs, the runner also records what
Kubernetes reports for each HPC pod (`argo/<mode>/pods.tsv`) and, after it, what is in the Global
Storage (`argo/<mode>/<test>.minio.txt`); the report joins the pods with their Slurm job output and
lists every job that failed on the HPC side while its pod was reported `Succeeded`. The report compares each
test with the `dev` baseline (TC02 and TC08 contain steps that are meant to fail), and classifies
every Slurm job from its `job.out`: `OK`, `IMAGE_PULL`, `DATA_SYNC_IN`, `DATA_SYNC_OUT`,
`SYNC_OUT_SILENT` (upload failed but `mc` exited 0), `TASK_ERROR` or `OTHER`. The findings are in
the git history of `../lisa-pipeline-runner_ze/APPROACH.md` (section 2 of the version before 16 Nov 2026).

Expected if the analysis is right: everything as in her thesis in `dev`; in `normal`, input syncs
fail with `DATA_SYNC_IN` and TC01 with `IMAGE_PULL`; in `normal-images`, TC01 passes but every
sync still fails, because her wrapper runs inside the Slurm job, on the compute node
(interLink Slurm plugin 0.6.1, `pkg/slurm/prepare.go`: `CommandPrefix` is written into `job.slurm`).

## The login node and the Kubernetes side

On Deucalion the login node most likely cannot reach `ulisses` (a private FEUP address); `ulisses`
reaches the login node by SSH (interLink's `ssh -L` tunnel). The testbed always reproduces that
(`guest/loginnet.sh`, applied at start-up and before every test): the login node cannot open
connections to `ulisses`; connections `ulisses` opens keep working. Only MinIO stays reachable,
because it stands for the Global Storage, a separate host on Deucalion (her Azure VM) that the login
node reaches. `make test-check` verifies it (U5-U7, and U1 for MinIO).

## Test T1

Plain Argo workflows on the offline compute node, with the split executor
(`../lisa-pipeline-runner_ze/setup/hpc/split-executor`):

- TC00: one container template with a native input and output artifact.
- TC01-TC07, TC09, TC10: Isabel's tests rewritten as plain Argo workflows
  (`../lisa-pipeline-runner_ze/tests/argo-native`: her six compute modules as a WorkflowTemplate with
  native artifacts). TC08 is not ported; see that folder's README.

The workflows are submitted as written: no sync modules, nothing about the HPC side. The platform
sends them to interLink (Argo `workflowDefaults`, set for the run). Argo's `init` (downloads inputs)
and `wait` (uploads outputs, reports to Kubernetes) run on the login node; only `main` runs in the
Slurm job. Data moves through the pod's emptyDirs, which the plugin puts in the job folder on the
shared FS. Their Kubernetes API calls go through the relay (`split-executor/api-relay`): `wait` calls
a local HTTPS endpoint on the login node; an agent on `ulisses` pulls the calls through its own
`ssh -L` tunnel and answers them from the real API. Her data wrapper is switched off; the sidecar
gets `--no-eval` and `--contain`. Everything is restored after the run.

Every test is checked against Argo and against what is actually in the Global Storage
(`tests/argo-native/checks.tsv`). The report shows, per test, the checks, the pods, and where `main`
and `init`/`wait` ran, plus a network probe from the compute node and the login node.

`make test-t1` (mode `normal-images`, about 25 minutes). `T1_TESTS="00 05" make test-t1` runs a
subset; `T1_MODES="normal"` and `"dev"` also work; `T1_SPLIT=off` runs the same workflows through
interLink as is (the "before").

## Known differences

- **Rocky Linux 9 instead of 8** on the HPC nodes. Rocky 8's arm64 kernel uses 64K memory pages,
  which Apple Silicon does not support ([Lima note](https://github.com/lima-vm/lima/issues/841)).
- **ARM instead of x86.** Matches Deucalion's ARM partitions; emulating x86 would be too slow.
- **Apptainer instead of Singularity 3.11.** Same command line for what the jobs use.
- **NFS instead of Lustre**, and the compute node is also the file server, so on the compute node
  the files are local. The login node, which is what the experiments watch, is a client.
- **One compute node, no InfiniBand, no accounting database.** The testbed shows whether
  mechanisms work, not how fast they are.
- **MinIO on the same VM as Kubernetes** (separate VM in the FEUP deployment).
- **Calico's default pod range (192.168.0.0/16) overlaps the VM network (192.168.104.0/24)**, as
  her script does not set one. It does not affect the prototype (only host processes talk to the
  HPC side), but it is worth knowing if pods ever need to reach the login node.

## Checks (`make test-check`)

| ID | Expectation |
|---|---|
| L1-L4 | Login node has internet; `lisa` has no sudo; `ssh -L` accepted, `ssh -R` refused |
| N1-N3 | `normal`: compute node has no internet and no DNS, but reaches the login node |
| F1-F2 | Files written on one node are visible on the other |
| I1-I3 | A file created on the compute node does **not** trigger inotify on the login node (I1), but is visible there (I2); a file created on the login node does (I3, control) |
| S1-S5 | Slurm runs jobs from the login node on the compute node; in `normal`, a job runs an image pulled beforehand on the login node, but cannot pull a `docker://` image itself |
| U1-U4 | (Stage B) login reaches MinIO; an offline compute node reaches neither MinIO nor the Kubernetes API; the virtual node is Ready |
| U5-U7 | (Stage B) the login node cannot reach ulisses: no Kubernetes API (U5), no SSH or Argo web UI (U6); ulisses can still SSH into the login node (U7). U1: the login node reaches the Global Storage (MinIO runs on the ulisses VM only to save a VM; on Deucalion it is a separate host the login node reaches) |
| D1-D3 | `dev`: compute node has internet, can pull images and reach MinIO |
| C1 | Clocks agree (Munge needs it) |

## Working on the testbed

- The host scripts run under the macOS system **bash 3.2**: no associative arrays, and no `-u`
  (an empty `"$@"` counts as unbound).
- After a Mac reboot or sleep: `make vm-start` (it re-syncs hosts, clocks and the network mode), not
  `limactl start`. If switching the network mode ever hangs Lima's SSH:
  `limactl stop -f tb-cn; make vm-start`.
- Lima's user-v2 network: cn `192.168.104.1`, login `.3`, ulisses `.4` (`state/ips.env`). Port 111
  forwarding warnings are harmless.
- Only one of `check`, `t0`, `t1` and `clean` can run at a time (a lock enforces it); `make vm-clean`
  resets the VMs after interrupted runs and saves any results still inside them.
- Editing from a Claude session through the desktop bridge: copied files can lose their execute bit
  (the makefile calls `bash ./testbed`; `chmod +x` the rest), and the file-copy tool refuses to
  write `makefile`. Compare `md5sum` after writes.

## Layout

- `Makefile`, `testbed`: the commands (macOS bash 3.2).
- `guest/`: scripts copied into the VMs at `/opt/testbed/guest` and run there.
- `state/`: generated keys, VM configs, IP addresses (not versioned).
- `cache/`: the built Slurm packages, so rebuilding takes minutes (not versioned).
- `logs/`: step logs, check reports, T0 results (not versioned).
