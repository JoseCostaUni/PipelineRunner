# Plain Argo workflows on Deucalion

This folder runs plain Argo workflows on Deucalion's offline compute nodes, through interLink 0.6.3
and the reverse tunnel of its SSH shadow (`../../APPROACH.md`).
- **Your own accounts install everything.** On Ulisses you need a kubeconfig with cluster-admin and
  no sudo. On Deucalion you need an account that can submit Slurm jobs.
- **Nothing on the site changes.** Nothing is installed by an administrator, nothing changes in
  Deucalion's network, and `make restore` switches everything off again.

**The commands, in order, are in [`../../RUN_ON_ULISSES.md`](../../RUN_ON_ULISSES.md).** In short,
on Ulisses, in this folder:

```sh
make env && vi deucalion.env       # once
make setup && make check           # once
make up && make test               # then: make evidence
make restore                       # both sides off
```

| File | Runs on | As |
|---|---|---|
| `Makefile` | Ulisses | you; every target calls `k8s-side.sh` |
| `k8s-side.sh` | Ulisses | you (cluster-admin kubeconfig, no sudo); runs `hpc-side.sh` on the login node over SSH |
| `hpc-side.sh` | the Deucalion login node (`HPC_LOGIN_HOST`) | `HPC_USER`, which runs our own sidecar |
| `deucalion.env.example` | both | copy to `deucalion.env` (`make env`) and fill in. Ignored by git, because it holds the MinIO keys. `make sync` copies it to the login node without them |
| `testbed.env.example` | both, on the testbed | the same flow on `../../testbed` (`make init` and `make test` at the repository root use it) |

Run either script without arguments to list its commands.
- **The state of each side:** Ulisses is `on` while `~/lisa-trial/state/mode` exists (it holds
  `up <version>`). The login node is `on` while the sidecar runs with its configuration.
- **`make test` refuses to run** unless both sides are on and offload asks for the tunnel.

## How it runs

- **Ulisses.** interLink is three processes of yours: the SSH tunnel to the sidecar, the interLink
  API and the virtual kubelet.
  - **Why not systemd services:** user services stop at logout without linger, and linger needs
    root.
  - **How they run:** each runs in its own session (`setsid`) and is restarted 5 seconds after it
    exits. They survive the end of your SSH session, but not a reboot of Ulisses. Run `make up` again
    after one.
  - **Where their files live:** binaries, configs, logs (private to you), PID files and saved state
    are in `TRIAL_HOME` (`~/lisa-trial`).
- **Shared cluster.** Your virtual node (`INTERLINK_NODE_NAME`), namespace (`ARGO_NAMESPACE`) and
  ports (`TUNNEL_PORT`, `VK_PORT`) are settings, so another person can run the same next to you with
  other values.
  - Argo is installed once, in namespace `argo`.
  - Its `workflowDefaults` are global: while your offload is on, every workflow of that Argo goes to
    your node.
- **Deucalion.** The sidecar is interLink's Slurm plugin 0.6.3, run as your user service
  `SIDECAR_UNIT` (`lisa-sidecar`) on `SIDECAR_PORT`.
  - **Its configuration:** `hpc-side.sh install` writes it from the settings every time. It restarts
    the sidecar only if the configuration changed.
  - **Images:** `hpc-side.sh images` builds every image in `IMAGES`, plus Argo's executor, as one
    squashfs file each.
- **Through the tunnel:** the jobs reach the Global Storage, the Kubernetes API, and anything in
  `EXTRA_FORWARDS`.

## What changes, and how to undo it

| Where | Change | Undo |
|---|---|---|
| Ulisses, `~/lisa-trial/` | interLink 0.6.3 binaries, the Go toolchain and sources for building them, configs, logs, saved settings, the login node's pinned host key, `argo` and `mc` if they were missing | `rm -rf ~/lisa-trial` after `make restore` |
| Ulisses, namespace `argo` | Argo Workflows `ARGO_VERSION`, only if the cluster had none (`make setup`) | `kubectl delete -n argo -f <Argo's install.yaml>`, if nobody else uses it |
| Ulisses, Argo `workflow-controller-configmap` | `workflowDefaults` send every workflow's pods to your node, partition `SLURM_PARTITION`, with the annotation `interlink.eu/reverse-forwards` | `make restore` (offload off) puts back exactly what was there |
| Ulisses, namespace `ARGO_NAMESPACE` | the namespace itself, if it did not exist; Role and RoleBinding `argo-workflow-role` for its `default` service account; `artifact-repositories` ConfigMap (an existing one is saved first), Secret `lisa-gs-creds`, WorkflowTemplate `lisa-modules` | `make restore` puts a saved ConfigMap back; `kubectl delete ns ARGO_NAMESPACE` removes the rest |
| Ulisses, namespace `ARGO_NAMESPACE` | Service and EndpointSlice `GS_SERVICE` (the Global Storage under a name), when it is outside the cluster | `make restore` |
| Ulisses, namespace `ARGO_NAMESPACE`, with `GS_ENDPOINT=cluster` | Deployment `lisa-minio`, Service `GS_SERVICE`, Secret `lisa-minio-root`: a MinIO as the Global Storage, data in an `emptyDir` (lost when the pod restarts) | `make minio-off` (`make restore` leaves it) |
| Ulisses, namespace `INTERLINK_NODE_NAME` | Secret `trial-hpc-ssh-key` (**the private key `SSH_KEY`**, for the shadow's SSH to the login node) and ConfigMap `trial-hpc-known-hosts`; interLink copies both into each shadow namespace (`<namespace>-shadow`) | `make restore` deletes them and every copy |
| Ulisses, node `INTERLINK_NODE_NAME` | the virtual node, registered by the virtual kubelet, and its approved serving certificate request | `make restore` deletes both |
| Ulisses, containerd | image `ghcr.io/interlink-hq/interlink/ssh-tunnel:0.6.3`, pulled by the kubelet | stays (it needs root to remove) |
| Deucalion, `HPC_PROJECT_ROOT/.interlink/` | Slurm plugin 0.6.3, `SlurmConfig.yaml`, `sidecar.log`, the job folders (`jobs/`) | delete the folder after `make restore` |
| Deucalion, `HPC_PROJECT_ROOT/reverse-tunnel/` | the subPath fix, `resources.sh`, the socket folder `sock/` | delete the folder |
| Deucalion, `HPC_PROJECT_ROOT/images/` | the pre-built images | delete the folder |
| Deucalion, `HPC_PROJECT_ROOT/lisa-pipeline-runner_ze/` | these scripts and `setup/hpc`, with the settings but without the MinIO keys (`make sync`) | delete the folder |
| Deucalion, `~/.config/systemd/user/` | the user service `lisa-sidecar` (enabled); linger if the site allows it | `make restore` stops and removes the service |
| Deucalion, job folders | data, artifact keys and tokens of each pod while it runs | `make clean` (part of `make restore`). Plugin 0.6.3 leaves an empty folder per pod |
| Global Storage | bucket `GS_BUCKET`, test data under `users/` and `t1/` (reset before every test run) | `mc rm`, or `make minio-off` |

## Tools

- **Ulisses:**
  - `kubectl`, `jq`, `curl`, `ssh`, `ssh-keyscan`, `setsid`, `openssl`, `git` and `tar`;
  - internet access to github.com and go.dev, for `make setup`, and to ghcr.io, for the shadow image;
  - `argo` and `mc` are fetched into `~/lisa-trial/bin` if missing.
- **Login node:**
  - bash, coreutils, sed, awk, grep, curl, openssl and `systemctl --user`;
  - Slurm with `srun --overlap`;
  - Apptainer/Singularity, 1.1 or newer for `--no-eval`, with `mksquashfs`;
  - no Python and no jq.
- **Compute nodes:** `python3` (3.6 or newer) and `/usr/sbin/sshd`.

## Before 24 Nov 2026

This folder also ran the split executor (interLink 0.6.1), as a second mode.
- **The commands:** `make split` / `make reverse`. A mode file and backups of `SlurmConfig.yaml`
  (`*.pre-split`, `*.pre-reverse`) recorded which mode was on.
- **What was removed:** that mode, and the settings it needed (`SPLIT_API`, `RELAY_*`,
  `SPLIT_IL_VERSION`). An old `deucalion.env` still works, and `REVERSE_IL_VERSION` is still read
  when `IL_VERSION` is not set.
- **Where it is now:** the code is in the tag `split-interlink-0.6.1`.
