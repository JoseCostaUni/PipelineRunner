# Trying both modes on Deucalion

This folder switches plain Argo workflows on Deucalion between two modes, over **Isabel Moutinho's
existing deployment**: Kubernetes, Argo and interLink on Ulisses, the interLink Slurm sidecar on a
Deucalion login node, and her MinIO as the Global Storage. Nothing is installed by an
administrator, nothing changes in Deucalion's network, and every change has an undo.

| Mode | interLink | What we add on the HPC side | Explained in |
|---|---|---|---|
| `split` | her 0.6.1 | the split executor: `sbatch`, `squeue`, `scancel` wrappers and the API relay (`../../setup/hpc/split-executor/`) | `../../APPROACH.md`, sections 2-4 |
| `reverse` | 0.6.3 next to her 0.6.1 | one wrapper, the subPath fix (`../../setup/hpc/subpath-fix/`); interLink's reverse tunnel does the rest | `../../APPROACH.md`, section 7 |

**The step-by-step procedure is in [`../../HOW_TO_RUN.md`](../../HOW_TO_RUN.md)**, section 2
for Deucalion and section 1.4 for a rehearsal of the same steps on the local testbed. In short, on
Ulisses:

```sh
./k8s-side.sh check && ./k8s-side.sh install   # install: reverse only, once
./k8s-side.sh mode reverse                     # or: mode split; switches both sides
./k8s-side.sh test
./k8s-side.sh clean && ./k8s-side.sh restore   # both sides back as they were
```

| File | Runs on | As |
|---|---|---|
| `deucalion.env.example` | both | copy to `deucalion.env` and fill in (ignored by git: it holds keys); the same file serves both modes |
| `testbed.env.example` | both, on the testbed | the testbed's values; use with `SPLIT_ENV=$PWD/testbed.env` |
| `hpc-side.sh` | the Deucalion login node where the sidecar runs (`ln01`) | the account that runs the sidecar |
| `k8s-side.sh` | Ulisses | root; `mode`, `status` and `restore` also run `hpc-side.sh` on the login node over SSH |

Run either script without arguments to list its commands. Only one mode is on at a time: each
side records which one in the name of its backup file (`*.pre-split` or `*.pre-reverse`), refuses
to turn the other on until it is off, and `k8s-side.sh test` refuses to run unless both sides, the
artifact repository and the offload settings agree.

## What changes, and how to undo it

Both modes:

| Where | Change | Undo |
|---|---|---|
| Deucalion, `$HPC_PROJECT_ROOT/images/` | pulled images (`hpc-side.sh images`) | delete the folder |
| Deucalion, job folders of the trial | data, artifact keys and tokens of each pod | `./k8s-side.sh clean` |
| Ulisses, Argo `workflow-controller-configmap` | `workflowDefaults` send every workflow's pods to the interLink node, partition `SLURM_PARTITION` (and, in `reverse`, ask for the tunnel) | `./k8s-side.sh offload off` |
| Ulisses, `/var/lib/split-executor/` | saved settings, relay CA, pinned host keys of the login node | delete the folder after `restore` |
| Ulisses, namespace `ARGO_NAMESPACE` | `artifact-repositories` ConfigMap (an existing one is saved in `/var/lib/split-executor/`), secret `split-gs-creds`, WorkflowTemplate `lisa-modules` | `./k8s-side.sh restore` puts the saved ConfigMap back; `kubectl delete` the rest |
| Global Storage | bucket `GS_BUCKET`, test data under `users/` and `t1/` (reset before every test run) | `mc rm` |

`split`:

| Where | Change | Undo |
|---|---|---|
| Deucalion, `$HPC_PROJECT_ROOT/.interlink/SlurmConfig.yaml` | `SbatchPath`/`SqueuePath`/`ScancelPath` point to the wrappers; `CommandPrefix: ""` (her data wrapper off); `ImagePrefix` = pre-pulled images; `--no-eval --contain` added to `SingularityDefaultOptions`. Backup saved as `SlurmConfig.yaml.pre-split` | `./hpc-side.sh disable` |
| Deucalion, `$HPC_PROJECT_ROOT/split-executor/` | wrapper scripts, relay | delete the folder |
| Deucalion, user units | `split-api-relay` (only with the relay) | `./hpc-side.sh relay off` |
| Ulisses, `/opt/interlink/VirtualKubeletConfig.yaml` | API address given to offloaded containers (backup `.pre-split`) | `./k8s-side.sh api off` |
| Ulisses, units | `split-relay-tunnel`, `split-relay-agent` (only with the relay) | `./k8s-side.sh api off` |

`reverse`:

| Where | Change | Undo |
|---|---|---|
| Deucalion, `$HPC_PROJECT_ROOT/.interlink/SlurmConfig.yaml` | `SbatchPath` points to the subPath fix; `CommandPrefix: ""`; `ImagePrefix` = pre-pulled images; `--no-eval --contain`; `SocketDirRoot` and `ResourceScriptPath` added. Backup saved as `SlurmConfig.yaml.pre-reverse` | `./hpc-side.sh disable` |
| Deucalion, user unit `interlink-sidecar` | drop-in `interlink-sidecar.service.d/trial-reverse.conf` runs the Slurm plugin 0.6.3; her unit file is not changed | `./hpc-side.sh disable` |
| Deucalion, `$HPC_PROJECT_ROOT/reverse-tunnel/` | plugin 0.6.3 binary, the subPath fix, `resources.sh`, the socket folder `sock/` | delete the folder |
| Ulisses, `/opt/interlink-0.6.3/` | interLink 0.6.3 binaries (`install`) | delete the folder |
| Ulisses, units `interlink-api`, `interlink-vk` | drop-ins `trial-reverse.conf` run the 0.6.3 binaries; her unit files are not changed | `./k8s-side.sh api off` |
| Ulisses, `/opt/interlink/VirtualKubeletConfig.yaml` | `Network.SSH` with the reverse tunnel, API address `kubernetes.default.svc.cluster.local:6443` (backup `.pre-reverse`) | `./k8s-side.sh api off` |
| Ulisses, namespace `interlink` | Secret `trial-hpc-ssh-key` (**the private key `SSH_KEY`**, for the shadow's SSH to the login node) and ConfigMap `trial-hpc-known-hosts`; interLink copies both into each shadow namespace (`<namespace>-shadow`) | `./k8s-side.sh api off` deletes them and every copy |
| Ulisses, namespace `ARGO_NAMESPACE` | Service and EndpointSlice `GS_SERVICE` (the Global Storage under a name) | `./k8s-side.sh api off` |
| Ulisses, containerd | image `ghcr.io/interlink-hq/interlink/ssh-tunnel:0.6.3` | `crictl rmi` |

`./k8s-side.sh clean` and `./k8s-side.sh restore` put everything back on both sides (`restore`
runs `./hpc-side.sh disable` on the login node over SSH; run it there yourself if that fails).
While offload is on, **every** workflow of that Argo goes to Deucalion, Isabel's own tests
included, so run the trial when nobody else uses the cluster, and switch it off afterwards.

## Tools

Ulisses needs `kubectl`, `jq`, `argo` (CLI), `mc`, `ssh` and `curl`; for `reverse` also
`ssh-keyscan`, and `git` plus internet access (github.com, go.dev, ghcr.io) for `install`. The
login node needs only bash, coreutils, sed, awk, grep, curl, openssl, Slurm and
Apptainer/Singularity (>= 1.1 for `--no-eval`); for `reverse` also `srun --overlap`, and the
compute nodes need `python3` (>= 3.6) and `/usr/sbin/sshd`. No Python, no jq on the login node.
