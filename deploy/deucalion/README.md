# Trying the split executor on Deucalion

This folder turns the split executor (`../../setup/hpc/split-executor/`, explained in
`../../APPROACH.md`) on and off over **Isabel Moutinho's existing deployment**: Kubernetes, Argo and
interLink on Ulisses, the interLink Slurm sidecar on a Deucalion login node, and her MinIO as the
Global Storage. Nothing is installed by an administrator, nothing changes in Deucalion's network,
and every change has an undo.

**What the trial shows.** Plain Argo workflows (native artifacts, no sync modules) run on an
air-gapped `normal-*` partition. `init` and `wait` run on the login node, and only `main` runs in
the Slurm job. Every result is checked in the Global Storage itself, not only in the Argo UI.

| File | Runs on | As |
|---|---|---|
| `deucalion.env.example` | both | copy to `deucalion.env` and fill in (ignored by git: it holds keys) |
| `hpc-side.sh` | the Deucalion login node where the sidecar runs (`ln01`) | the account that runs the sidecar |
| `k8s-side.sh` | Ulisses | root |

## What changes, and how to undo it

| Where | Change | Undo |
|---|---|---|
| Deucalion, `$HPC_PROJECT_ROOT/.interlink/SlurmConfig.yaml` | `SbatchPath`/`SqueuePath`/`ScancelPath` point to the wrappers; `CommandPrefix: ""` (her data wrapper off); `ImagePrefix` = pre-pulled images; `--no-eval --contain` added to `SingularityDefaultOptions`. Backup saved as `SlurmConfig.yaml.pre-split` | `./hpc-side.sh disable` |
| Deucalion, `$HPC_PROJECT_ROOT/split-executor/`, `images/` | wrapper scripts, relay, pulled images | delete the folders |
| Deucalion, user units | `split-api-relay` (only with the relay) | `./hpc-side.sh relay off` |
| Ulisses, Argo `workflow-controller-configmap` | `workflowDefaults` send every workflow's pods to the interLink node, partition `SLURM_PARTITION` | `./k8s-side.sh offload off` |
| Ulisses, `/opt/interlink/VirtualKubeletConfig.yaml` | API address given to offloaded containers (backup `.pre-split`) | `./k8s-side.sh api off` |
| Ulisses, units | `split-relay-tunnel`, `split-relay-agent` (only with the relay) | `./k8s-side.sh api off` |
| Ulisses, namespace `ARGO_NAMESPACE` | `artifact-repositories` ConfigMap (an existing one is saved in `/var/lib/split-executor/`), secret `split-gs-creds`, WorkflowTemplate `lisa-modules` | `kubectl delete`; restore the saved ConfigMap |
| Global Storage | bucket `GS_BUCKET`, test data under `users/` and `t1/` | `mc rm` |

`./k8s-side.sh restore` + `./hpc-side.sh disable` put everything back. While offload is on,
**every** workflow of that Argo goes to Deucalion, Isabel's own tests included, so run the trial
when nobody else uses the cluster, and switch it off afterwards.

## Before you start

- **Access:** the Deucalion account that runs the sidecar (`HPC_USER`, Isabel's in her `.env`), and
  root on Ulisses. Ask the supervisor who holds them now.
- **Re-run the testbed first.** The wrappers changed after the last full pass (no Python or jq,
  `APPROACH.md` section 7.9): `cd ../../../testbed && make test-t1` must pass again.
- **Global Storage:** her MinIO (`GS_ENDPOINT`) must be up and reachable from the Deucalion login
  node; MinIO stopped free images in Oct 2025, so if it has to be redeployed, use the
  `pgsty/minio` fork (see the testbed README).
- **Tools:** Ulisses needs `kubectl`, `jq`, `argo` (CLI) and `mc`; the login node needs only bash,
  coreutils, sed, awk, grep, curl, openssl, Slurm and Apptainer/Singularity.
- **Architecture:** Deucalion's login nodes are x86, so use an x86 partition (`normal-x86`). On ARM
  partitions the `argoexec` copied from the login node would not run (APPROACH.md, problem 2).

## Steps

### 1. Copy this repository to both machines and fill in the settings

`lisa-pipeline-runner_ze` has no repository of its own (it lives in the dissertation repository),
so copy the folder:

```sh
# from your machine, to both
scp -r repositories/lisa-pipeline-runner_ze root@<ulisses>:/opt/
scp -r repositories/lisa-pipeline-runner_ze <HPC_USER>@ln01.deucalion.macc.fccn.pt:<HPC_PROJECT_ROOT>/

# then on each of them
cd <where you copied it>/lisa-pipeline-runner_ze/deploy/deucalion
cp deucalion.env.example deucalion.env && chmod 600 deucalion.env && $EDITOR deucalion.env
chmod +x *.sh ../../setup/hpc/split-executor/{sbatch,squeue,scancel}
```

Use the same `deucalion.env` on both. Copies made through the desktop bridge can lose their
execute bit, hence the `chmod`.

### 2. Checks (read-only, a few minutes)

```sh
# Ulisses
./k8s-side.sh check
./k8s-side.sh executor-image        # put this value in ARGO_EXEC_IMAGE on both machines

# Deucalion login node
./hpc-side.sh check
./hpc-side.sh probe-compute         # 1-minute job: what a compute node of SLURM_PARTITION reaches
```

`check` ends with `FAIL` lines for anything missing. Two of its lines decide the next steps:

- **Kubernetes API** reachable from the login node → step 4 uses `api direct`; not reachable (most
  likely, Ulisses has a private FEUP address) → step 4 uses the relay.
- **Global Storage** must be reachable from the login node; if it is not, stop here.

`probe-compute` is the evidence that the partition is air-gapped: every URL should give no answer
and DNS should fail, while the project folder is visible. Keep its output for the thesis.

### 3. Images and the split executor (Deucalion)

```sh
./hpc-side.sh images                # pulls IMAGES and ARGO_EXEC_IMAGE into $HPC_PROJECT_ROOT/images
./hpc-side.sh enable                # backup, install, restart the sidecar
./hpc-side.sh status
```

### 4. API path

If the API is reachable from the login node:

```sh
./k8s-side.sh api direct            # Ulisses
```

Otherwise, the relay (the login node never connects to Ulisses; Ulisses pulls the calls through
its own `ssh -L` tunnel, as interLink already does):

```sh
./hpc-side.sh relay on              # Deucalion, first
./k8s-side.sh api relay             # Ulisses: tunnel + agent + virtual kubelet; ends with relay-health
```

`api` restarts the virtual kubelet: do it while no pod is running on the interLink node.

### 5. Artifacts and offload (Ulisses)

```sh
./k8s-side.sh artifacts             # Global Storage as Argo's default artifact repository + test data
./k8s-side.sh offload on            # every workflow's pods to the interLink node, SLURM_PARTITION
```

### 6. Run the tests (Ulisses)

```sh
./k8s-side.sh test 00               # one plain workflow with an input and an output artifact
./k8s-side.sh test                  # all of tests/argo-native (TC00-TC10 except TC08)
```

Each test prints `PASS`/`FAIL`, the phase, the time and the checks (`tests/argo-native/checks.tsv`,
checked in Argo **and** in the Global Storage). TC02 ends `Failed` on purpose. Results, Argo
objects and logs are in `results/<time>/`. Expect each step to take longer than in the testbed:
the queue of `normal-x86` decides when `main` starts.

To see where things ran, on the login node: `./hpc-side.sh status`, and in each job folder
(`DataRootFolder` of the sidecar) `split.log`, `login.out` and `job.out`. `main` must have run on
a compute node, `init` and `wait` on `ln01`.

### 7. Put everything back

```sh
./k8s-side.sh restore               # Ulisses: offload off, API address restored, relay stopped
./hpc-side.sh disable               # Deucalion: SlurmConfig.yaml restored, relay stopped
```

Then remove the job folders of the trial (they hold copies of the data, the artifact keys and
service-account tokens; APPROACH.md problem 3 and 5), and delete the test data from the Global
Storage if you no longer need it.

## What to keep as evidence

- `hpc-side.sh check` and `probe-compute` output (the partition is air-gapped);
- `results/<time>/summary.txt` and the folder around it;
- for one pod, its job folder: `job.sh.orig` (as generated) vs `job.sh` (main only), `split.log`,
  `login.out`, `job.out` (which node ran what);
- the same tests with the split executor off (`./hpc-side.sh disable`, plus Isabel's
  `CommandPrefix`) for the "before" column.

## If something fails

| Symptom | Look at |
|---|---|
| `enable` stops: no `--no-eval` | the site's Singularity is too old; ask whether Apptainer >= 1.1 is available (`module avail`) |
| pods stay `Pending` | `squeue -u $USER` (queue), `split.log` in the job folder; the job is held until `init` finishes |
| `init` fails | `login.out`: usually the Global Storage (endpoint, keys) or a missing image in `images/` |
| `wait` hangs or the step never ends | relay: `./hpc-side.sh relay log`, `./k8s-side.sh relay-health`, `relay-log` |
| image not found | the pod names an image not in `IMAGES`: add it, `./hpc-side.sh images` (no restart needed) |
| `sbatch` refused | partition or account in `deucalion.env`; `sinfo -s` |
| sidecar does not start after `enable` | `tail $HPC_PROJECT_ROOT/.interlink/sidecar.log`; `./hpc-side.sh disable` restores it |

## Known limits of the trial

From `APPROACH.md` section 11, the ones that matter on Deucalion:

- images have to be listed and pulled by hand;
- x86 partitions only;
- all pipeline jobs share one Deucalion account, and job folders keep keys and tokens;
- every byte goes through the login node, and `init`/`wait` live on it for the whole job (a reboot
  of `ln01` loses running pods);
- the relay's ports listen on `127.0.0.1` of a shared login node, where other users could reach them;
- the wrappers depend on the exact job script of interLink 0.6.1 and on Slurm's `--hold`; an
  upgrade of either can break them.
