# Trying the split executor on Deucalion

This folder turns the split executor (`../../setup/hpc/split-executor/`, explained in
`../../APPROACH.md`) on and off over **Isabel Moutinho's existing deployment**: Kubernetes, Argo and
interLink on Ulisses, the interLink Slurm sidecar on a Deucalion login node, and her MinIO as the
Global Storage. Nothing is installed by an administrator, nothing changes in Deucalion's network,
and every change has an undo.

**The step-by-step procedure is in [`../../HOW_TO_RUN.md`](../../HOW_TO_RUN.md)**, section 2
for Deucalion and section 1.4 for a rehearsal of the same steps on the local testbed.

| File | Runs on | As |
|---|---|---|
| `deucalion.env.example` | both | copy to `deucalion.env` and fill in (ignored by git: it holds keys) |
| `testbed.env.example` | both, on the testbed | the testbed's values; use with `SPLIT_ENV=$PWD/testbed.env` |
| `hpc-side.sh` | the Deucalion login node where the sidecar runs (`ln01`) | the account that runs the sidecar |
| `k8s-side.sh` | Ulisses | root |

Run either script without arguments to list its commands.

## What changes, and how to undo it

| Where | Change | Undo |
|---|---|---|
| Deucalion, `$HPC_PROJECT_ROOT/.interlink/SlurmConfig.yaml` | `SbatchPath`/`SqueuePath`/`ScancelPath` point to the wrappers; `CommandPrefix: ""` (her data wrapper off); `ImagePrefix` = pre-pulled images; `--no-eval --contain` added to `SingularityDefaultOptions`. Backup saved as `SlurmConfig.yaml.pre-split` | `./hpc-side.sh disable` |
| Deucalion, `$HPC_PROJECT_ROOT/split-executor/`, `images/` | wrapper scripts, relay, pulled images | delete the folders |
| Deucalion, user units | `split-api-relay` (only with the relay) | `./hpc-side.sh relay off` |
| Deucalion, job folders of the trial | data, artifact keys and tokens of each pod | `./k8s-side.sh clean` |
| Ulisses, Argo `workflow-controller-configmap` | `workflowDefaults` send every workflow's pods to the interLink node, partition `SLURM_PARTITION` | `./k8s-side.sh offload off` |
| Ulisses, `/opt/interlink/VirtualKubeletConfig.yaml` | API address given to offloaded containers (backup `.pre-split`) | `./k8s-side.sh api off` |
| Ulisses, units | `split-relay-tunnel`, `split-relay-agent` (only with the relay) | `./k8s-side.sh api off` |
| Ulisses, `/var/lib/split-executor/` | saved settings, relay CA, pinned host key of the login node | delete the folder after `restore` |
| Ulisses, namespace `ARGO_NAMESPACE` | `artifact-repositories` ConfigMap (an existing one is saved in `/var/lib/split-executor/`), secret `split-gs-creds`, WorkflowTemplate `lisa-modules` | `./k8s-side.sh restore` puts the saved ConfigMap back; `kubectl delete` the rest |
| Global Storage | bucket `GS_BUCKET`, test data under `users/` and `t1/` (reset before every test run) | `mc rm` |

`./k8s-side.sh clean`, `./k8s-side.sh restore` and `./hpc-side.sh disable` put everything back.
While offload is on, **every** workflow of that Argo goes to Deucalion, Isabel's own tests
included, so run the trial when nobody else uses the cluster, and switch it off afterwards.

## Tools

Ulisses needs `kubectl`, `jq`, `argo` (CLI), `mc`, `ssh` and `curl`. The login node needs only
bash, coreutils, sed, awk, grep, curl, openssl, Slurm and Apptainer/Singularity (>= 1.1 for
`--no-eval`). No Python, no jq on the HPC side.
