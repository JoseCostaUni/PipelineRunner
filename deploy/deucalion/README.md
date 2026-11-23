# Trying both modes on Deucalion

This folder runs plain Argo workflows on Deucalion in one of two modes, with everything installed
by **your own accounts**. On Ulisses you need a kubeconfig with cluster-admin and no sudo. On
Deucalion you need an account that can submit Slurm jobs. Nothing is installed by an administrator,
nothing changes in Deucalion's network, and `make restore` switches everything off again.

| Mode | interLink | What we add on the HPC side | Explained in |
|---|---|---|---|
| `split` | 0.6.1 | the split executor: `sbatch`, `squeue`, `scancel` wrappers and the API relay (`../../setup/hpc/split-executor/`) | `../../APPROACH.md`, sections 2-4 |
| `reverse` | 0.6.3 | one wrapper, the subPath fix (`../../setup/hpc/subpath-fix/`); interLink's reverse tunnel does the rest | `../../APPROACH.md`, section 7 |

**The commands, in order, are in [`../../RUN_ON_ULISSES.md`](../../RUN_ON_ULISSES.md).** In short,
on Ulisses, in this folder:

```sh
make env && vi deucalion.env       # once
make setup && make check           # once
make reverse && make test          # or: make split
make restore                       # both sides off
```

| File | Runs on | As |
|---|---|---|
| `Makefile` | Ulisses | you; every target calls `k8s-side.sh` |
| `k8s-side.sh` | Ulisses | you (cluster-admin kubeconfig, no sudo); runs `hpc-side.sh` on the login node over SSH |
| `hpc-side.sh` | the Deucalion login node (`HPC_LOGIN_HOST`) | `HPC_USER`, which runs our own sidecar |
| `deucalion.env.example` | both | copy to `deucalion.env` (`make env`) and fill in; ignored by git, because it holds the MinIO keys. `make sync` copies it to the login node without them |
| `testbed.env.example` | both, on the testbed | the same flow on `../../testbed`, with `ENV_FILE=testbed.env` |

Run either script without arguments to list its commands. Only one mode is on at a time. The
login node records which one in the name of its backup file (`*.pre-split` or `*.pre-reverse`);
Ulisses records it in `~/lisa-trial/state/mode`. Each side refuses to turn the other mode on until
it is off, and `make test` refuses to run unless both sides, the artifact repository and the
offload settings agree.

## How it runs

- **Ulisses.** interLink is three processes of yours: the SSH tunnel to the sidecar, the interLink
  API and the virtual kubelet. They are not systemd services, because user services stop at logout
  without linger, and linger needs root. Each runs in its own session (`setsid`) and is restarted 5
  seconds after it exits. They survive the end of your SSH session, but not a reboot of Ulisses:
  run `make reverse` or `make split` again after one. Binaries, configs, logs, PID files and saved
  state are in `TRIAL_HOME` (`~/lisa-trial`).
- **Shared cluster.** Your virtual node (`INTERLINK_NODE_NAME`), namespace (`ARGO_NAMESPACE`) and
  ports (`TUNNEL_PORT`, `VK_PORT`, `RELAY_CTL_PORT`) are settings, so another person can run the
  same next to you with other values. Argo is installed once, in namespace `argo`, and its
  `workflowDefaults` are global: while your offload is on, every workflow of that Argo goes to your
  node.
- **Deucalion.** The sidecar is the Slurm plugin of interLink, run as your user service
  `SIDECAR_UNIT` (`lisa-sidecar`) on `SIDECAR_PORT`. `hpc-side.sh install` sets it up in
  `HPC_PROJECT_ROOT` with a plain `SlurmConfig.yaml`. `enable` changes that configuration for a mode
  (with a backup) and `disable` puts it back.

## What changes, and how to undo it

Both modes:

| Where | Change | Undo |
|---|---|---|
| Ulisses, `~/lisa-trial/` | interLink 0.6.1 and 0.6.3 binaries, Go toolchain and sources for the 0.6.3 build, configs, logs, saved settings, the login node's pinned host key, `argo` and `mc` if they were missing | `rm -rf ~/lisa-trial` after `make restore` |
| Ulisses, namespace `argo` | Argo Workflows `ARGO_VERSION`, only if the cluster had none (`make setup`) | `kubectl delete -n argo -f <Argo's install.yaml>`, if nobody else uses it |
| Ulisses, Argo `workflow-controller-configmap` | `workflowDefaults` send every workflow's pods to your node, partition `SLURM_PARTITION` (and, in `reverse`, ask for the tunnel) | `make restore` (offload off) puts back exactly what was there |
| Ulisses, namespace `ARGO_NAMESPACE` | the namespace itself, if it did not exist; Role and RoleBinding `argo-workflow-role` for its `default` service account; `artifact-repositories` ConfigMap (an existing one is saved first), secret `split-gs-creds`, WorkflowTemplate `lisa-modules` | `make restore` puts a saved ConfigMap back; `kubectl delete ns ARGO_NAMESPACE` removes the rest |
| Ulisses, node `INTERLINK_NODE_NAME` | the virtual node, registered by the virtual kubelet | `make restore` deletes it |
| Deucalion, `HPC_PROJECT_ROOT/.interlink/` | Slurm plugin 0.6.1, `SlurmConfig.yaml`, `sidecar.log`, the job folders (`jobs/`) | delete the folder after `make restore` |
| Deucalion, `~/.config/systemd/user/` | the user service `lisa-sidecar` (enabled); linger if the site allows it | `make restore` stops and removes the service |
| Deucalion, `HPC_PROJECT_ROOT/lisa-pipeline-runner_ze/` | this repository, with the settings but without the MinIO keys (`make sync`) | delete the folder |
| Deucalion, `HPC_PROJECT_ROOT/images/` | pulled images | delete the folder |
| Deucalion, job folders of the trial | data, artifact keys and tokens of each pod | `make clean` |
| Global Storage | bucket `GS_BUCKET`, test data under `users/` and `t1/` (reset before every test run) | `mc rm` |

`split`:

| Where | Change | Undo |
|---|---|---|
| Deucalion, `SlurmConfig.yaml` | `SbatchPath`/`SqueuePath`/`ScancelPath` point to the wrappers; `ImagePrefix` = pre-pulled images; `--no-eval --contain` added to `SingularityDefaultOptions`. Backup `SlurmConfig.yaml.pre-split` | `make restore` (`hpc-side.sh disable`) |
| Deucalion, `HPC_PROJECT_ROOT/split-executor/` | wrapper scripts, relay and its certificates | delete the folder |
| Deucalion, user unit `split-api-relay` | the login side of the relay (only with `SPLIT_API=relay`) | `make restore` |
| Ulisses, processes `relay-tunnel`, `relay-agent` | the Ulisses side of the relay | `make restore` |

`reverse`:

| Where | Change | Undo |
|---|---|---|
| Deucalion, `SlurmConfig.yaml` | `SbatchPath` points to the subPath fix; `ImagePrefix` = pre-pulled images; `--no-eval --contain`; `SocketDirRoot` and `ResourceScriptPath` added. Backup `SlurmConfig.yaml.pre-reverse` | `make restore` |
| Deucalion, `lisa-sidecar.service.d/trial-reverse.conf` | a drop-in that runs the Slurm plugin 0.6.3 | `make restore` |
| Deucalion, `HPC_PROJECT_ROOT/reverse-tunnel/` | plugin 0.6.3 binary, the subPath fix, `resources.sh`, the socket folder `sock/` | delete the folder |
| Ulisses, namespace `INTERLINK_NODE_NAME` | Secret `trial-hpc-ssh-key` (**the private key `SSH_KEY`**, for the shadow's SSH to the login node) and ConfigMap `trial-hpc-known-hosts`; interLink copies both into each shadow namespace (`<namespace>-shadow`) | `make restore` deletes them and every copy |
| Ulisses, namespace `ARGO_NAMESPACE` | Service and EndpointSlice `GS_SERVICE` (the Global Storage under a name) | `make restore` |
| Ulisses, containerd | image `ghcr.io/interlink-hq/interlink/ssh-tunnel:0.6.3`, pulled by the kubelet | stays (it needs root to remove) |

## Tools

- **Ulisses:** `kubectl`, `jq`, `curl`, `ssh`, `ssh-keyscan`, `setsid`, `openssl`, `git` and `tar`, and internet
  access to github.com and go.dev (for `make setup`) and ghcr.io (the shadow image).
  `argo` and `mc` are fetched into `~/lisa-trial/bin` if missing.
- **Login node:** bash, coreutils, sed, awk, grep, curl, openssl, Slurm, Apptainer/Singularity
  (1.1 or newer, for `--no-eval`) and `systemctl --user`. For `reverse` also `srun --overlap`.
  No Python and no jq.
- **Compute nodes, for `reverse`:** `python3` (3.6 or newer) and `/usr/sbin/sshd`.
