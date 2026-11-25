# Testbed: a small Deucalion-like HPC environment

Lima VMs on an Apple Silicon Mac that reproduce the properties of Deucalion that matter for the
Pipeline Runner, so experiments that need an HPC system can run locally and repeatably.

- **Stage A:** a login node and a compute node (the HPC side).
- **Stage B:** adds `ulisses`, the Kubernetes side of the FEUP prototype (kubeadm, Argo, Dex,
  interLink) and its Global Storage (MinIO), all set up by Isabel Moutinho's own scripts.
- **The trial:** the runner is set up and tested here exactly as on Ulisses (`make` at the repository
  root, with `settings/testbed.env`), as a user without root on `ulisses` and as `lisa` on the login
  node. Plain Argo workflows then run on the offline
  compute node through interLink 0.6.3 and its reverse tunnel.

## Requirements

- Apple Silicon Mac, Lima >= 1.0 (`limactl --version`; Colima installs it, otherwise `brew install lima`).
- Free disk: about 20 GB (Stage A) or 35 GB (Stage B).
- Free RAM: about 2.5 GB (Stage A) or 6.5 GB (Stage B). Stop Colima first (`colima stop`).
- Isabel's repository next to the repository that holds this folder (`../../lisa-pipeline-runner`
  from here) for Stage B.

## Usage

The `Makefile` at the root of the repository is the entry point (`make` there lists every target,
`../docs/operations.md` section 3 explains them):

```sh
make testbed-init             # build the VMs if needed (Stage A, then B), the trial user, 'make setup'
make testbed-check            # fidelity checks; report in logs/check-<time>.md
make testbed-test T=00        # 'make up' and the tests, as the trial user
make testbed A=restore        # any site target of the Makefile as the trial user

make testbed-status           # VMs and network mode (make testbed A=status: the trial's state)
make testbed-net N=normal     # compute node without internet  (N=dev: with internet; N=status)
make testbed-shell VM=login   # shell as lisa on the login node (VM=cn; VM=ulisses as root; ROOT=1 for root)
make testbed-stop             # stop everything, frees the RAM  (make testbed-start to resume)
make testbed-clean            # remove what tests and checks left in the VMs (jobs, images, caches)
make testbed-destroy          # delete the VMs and their state
```

`make` calls `./testbed`, which you can also run directly (`./testbed help`). If a step fails, its
log is in `logs/`, and the last lines are printed on the screen.

`check` and `clean` refuse to run while the other is running: each one switches the compute node's
network mode, so running both together mixes their results.

**The trial user.** `./testbed trial setup` (part of `make testbed-init`):
- runs `guest/trial-user.sh` on `ulisses`, which creates `jcosta` with a kubeconfig that has
  cluster-admin through a ServiceAccount token and no sudo, as on Ulisses;
- gives that user's SSH key to `lisa` on the login node;
- copies this repository, without settings files, results or git, to `~jcosta/PipelineRunner`;
- runs `make setup SITE=testbed` there.

`./testbed trial make <targets>` runs any target of the repository's `Makefile` as that user, with
`SITE=testbed`. The trial has its own virtual node, namespace, ports, project folder and sidecar
(`settings/testbed.env.example`), next to the testbed's own installation of Isabel's prototype.

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

## The login node and the Kubernetes side

On Deucalion the login node most likely cannot reach `ulisses` (a private FEUP address); `ulisses`
reaches the login node by SSH (interLink's `ssh -L` tunnel). The testbed always reproduces that
(`guest/loginnet.sh`, applied at start-up and before every test): the login node cannot open
connections to `ulisses`; connections `ulisses` opens keep working. Only MinIO stays reachable,
because it stands for the Global Storage, a separate host on Deucalion (her Azure VM) that the login
node reaches. `make testbed-check` verifies it (U5-U7, and U1 for MinIO).

## Earlier tests (T0, T1)

Until 24 Nov 2026 the testbed also ran two tests of its own. Their code is in the tag
`split-interlink-0.6.1`, and their results are summarised in `../docs/results.md` and
`../docs/CHANGELOG.md`.
- **T0:** Isabel's ten workflows, with her sync modules, in three modes: compute node online,
  offline, and offline with images pulled beforehand. It showed that her design cannot move data on
  an offline node, because her wrapper runs inside the Slurm job.
- **T1:** the plain Argo workflows with the split executor (interLink 0.6.1). It passed all tests.

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
- **Calico's default pod range (192.168.0.0/16) would overlap the VM network (192.168.104.0/24)**,
  as her script does not set one, so Calico picked 172.16.0.0/16 instead, with outgoing NAT. Pods
  reach the login node through that NAT, which the reverse tunnel's shadow pods need (checked on
  17 Nov 2026).

## Checks (`make testbed-check`)

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
- After a Mac reboot or sleep: `make testbed-start` (it re-syncs hosts, clocks and the network mode),
  not `limactl start`. If switching the network mode ever hangs Lima's SSH:
  `limactl stop -f tb-cn; make testbed-start`. interLink of the trial then needs `make testbed-test`
  (or `make testbed A=up`) again.
- Lima's user-v2 network: cn `192.168.104.1`, login `.3`, ulisses `.4` (`state/ips.env`). Port 111
  forwarding warnings are harmless.
- Only one of `check` and `clean` can run at a time (a lock enforces it). `make testbed-clean`
  resets the VMs after interrupted runs.
- Root on the VMs cannot write in `lisa`'s home on the login node, because `/home` is NFS with root
  squash: use `sudo -u lisa`.

## Layout

- `testbed`: the commands (macOS bash 3.2), driven by `../Makefile`.
- `guest/`: scripts copied into the VMs at `/opt/testbed/guest` and run there.
- `state/`: generated keys, VM configs, IP addresses (not versioned).
- `cache/`: the built Slurm packages, so rebuilding takes minutes (not versioned).
- `logs/`: step logs and check reports (not versioned).
