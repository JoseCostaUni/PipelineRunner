# How to run the split executor

This guide gives the steps to run plain Argo workflows on HPC compute nodes without network, first on the local testbed and then on Deucalion through Ulisses. What the split executor is, and how its three scripts work, is explained in [APPROACH.md](APPROACH.md).

The alternative without the split executor, interLink 0.6.3 with its reverse tunnel, has its own steps in [experiments/reverse-tunnel/README.md](experiments/reverse-tunnel/README.md).

## 1. Running it locally on the testbed

The testbed (`../testbed`) is a small copy of Deucalion on three Lima virtual machines: a login node, an offline compute node, and `ulisses` with Isabel's Kubernetes side and MinIO. It reproduces what matters for this work: Slurm 23.11.4, Apptainer, a shared NFS file system, a compute node without network, and a login node that cannot connect to `ulisses`. Its README explains it in detail.

### 1.1 Requirements

You need an Apple Silicon Mac with Lima 1.0 or newer, about 35 GB of free disk and about 6.5 GB of free RAM. Stop Colima first with `colima stop`. Isabel's repository must be next to the testbed folder (`../lisa-pipeline-runner`), and this repository must be at `../lisa-pipeline-runner_ze`.

### 1.2 Build and check the testbed

Run these commands in `../testbed`. The first build takes about an hour, mostly downloads. After a reboot, `make vm-start` brings the machines back in a few minutes.

```sh
make vm-build            # login node and compute node
make vm-build-ulisses    # Kubernetes, Argo, interLink and MinIO, with Isabel's scripts
make test-check          # checks that the testbed behaves like Deucalion
```

`make test-check` writes a report in `logs/check-<time>.md`, and every check must pass. In particular, the compute node must have no internet in `normal` mode, and the login node must not reach the Kubernetes API.

### 1.3 Run the automated test

```sh
make test-t1             # about 25 minutes
make report-t1           # prints the report of the last run
```

This runs TC00 and Isabel's tests TC01 to TC10 (except TC08) as plain Argo workflows, with the compute node offline, the login node isolated, the split executor enabled and the API going through the relay. Each test is checked in Argo and in the Global Storage itself, and everything is restored afterwards. TC02 ends `Failed` on purpose, because it reads a file that does not exist. `T1_TESTS="00 05" make test-t1` runs a subset, and `T1_SPLIT=off make test-t1` runs the same workflows through interLink without the split executor, for comparison.

### 1.4 Rehearse the Deucalion procedure on the testbed

`make test-t1` uses the testbed's own scripts. Before going to Deucalion, run the exact scripts and steps of section 2 on the testbed, so that any problem shows up locally. The scripts read their settings from `deploy/deucalion/deucalion.env`, or from the file named in `SPLIT_ENV`. `deploy/deucalion/testbed.env.example` already holds the testbed's values.

Copy the repository into the two virtual machines from the `repositories` folder on your Mac:

```sh
COPYFILE_DISABLE=1 tar czf /tmp/ze.tgz --no-xattrs --no-mac-metadata --exclude results lisa-pipeline-runner_ze
limactl copy /tmp/ze.tgz tb-login:/tmp/ze.tgz
limactl copy /tmp/ze.tgz tb-ulisses:/tmp/ze.tgz
```

Open a shell as `lisa` on the login node with `make ssh-login` and prepare it:

```sh
cd /projects/EEHPC-DEV-2026D02-075/lisa-pipeline-runner
tar xzf /tmp/ze.tgz && cd lisa-pipeline-runner_ze/deploy/deucalion
cp testbed.env.example testbed.env && chmod 600 testbed.env
export SPLIT_ENV=$PWD/testbed.env
```

Open a second shell as root on Ulisses with `make ssh-ulisses` and do the same:

```sh
tar xzf /tmp/ze.tgz -C /opt && cd /opt/lisa-pipeline-runner_ze/deploy/deucalion
cp testbed.env.example testbed.env && chmod 600 testbed.env
export SPLIT_ENV=$PWD/testbed.env
```

Make sure the compute node is offline with `make net-normal` on the Mac, then follow section 2 from step 2.3 onwards in these two shells. On the testbed, `hpc-side.sh check` reports that the Kubernetes API is not reachable, so use the relay, as you most likely will on Deucalion. At the end, run the clean-up of step 2.9 so the testbed is left as it was.

On 16 November 2026 this rehearsal passed all ten tests (run `20261116-220707`, 30 of 30 checks), with the compute node offline and the API going through the relay. Each test took between 30 seconds and about 3 minutes.

## 2. Running it on Deucalion through Ulisses

The trial runs over Isabel's existing deployment. Kubernetes, Argo and interLink run on Ulisses, the interLink sidecar runs on the Deucalion login node `ln01` under her account, and her MinIO is the Global Storage. Nothing is installed by an administrator, nothing changes in Deucalion's network, and every change can be undone. Two scripts do all the work: `deploy/deucalion/k8s-side.sh` runs as root on Ulisses, and `deploy/deucalion/hpc-side.sh` runs on the login node as the account that runs the sidecar.

### 2.1 Before you start

You need root on Ulisses and the Deucalion account that runs the sidecar (`HPC_USER`, Isabel's account in her setup). Ulisses already holds that account's SSH key for interLink's tunnel, so once you are on Ulisses you can reach the login node with it. Ask the supervisor who holds these accesses now.

While offload is on, every workflow of that Argo instance goes to Deucalion, including Isabel's own tests, so agree on a time when nobody else uses the cluster. Her MinIO (`GS_ENDPOINT`) must be running and reachable from the login node. If it has to be redeployed, use the `pgsty/minio` image, because MinIO stopped publishing free images in October 2025. Use an x86 partition (`normal-x86`), because the login nodes are x86 and the `argoexec` copied from the login node would not run on the ARM partitions.

### 2.2 Copy the repository and fill in the settings

This repository lives inside the dissertation repository, so copy the folder. From your machine (on the FEUP network or VPN), copy it to Ulisses:

```sh
scp -r repositories/lisa-pipeline-runner_ze root@<ulisses>:/opt/
```

On Ulisses, fill in the settings, then copy the folder with the settings to the login node:

```sh
cd /opt/lisa-pipeline-runner_ze/deploy/deucalion
cp deucalion.env.example deucalion.env && chmod 600 deucalion.env && vi deucalion.env
chmod +x *.sh
source deucalion.env
scp -i "$SSH_KEY" -r /opt/lisa-pipeline-runner_ze "$HPC_USER@$HPC_LOGIN_HOST:$HPC_PROJECT_ROOT/"
```

The default values in `deucalion.env.example` come from Isabel's `.env` files, so usually only the Global Storage keys (`GS_ACCESS_KEY`, `GS_SECRET_KEY`) need to be filled in. `deucalion.env` is ignored by git because it holds those keys. From now on, open a shell on the login node from Ulisses like this:

```sh
ssh -i "$SSH_KEY" "$HPC_USER@$HPC_LOGIN_HOST"
cd "$HPC_PROJECT_ROOT/lisa-pipeline-runner_ze/deploy/deucalion"
```

### 2.3 Read-only checks

On Ulisses, run:

```sh
./k8s-side.sh check
./k8s-side.sh executor-image
```

On the login node, run:

```sh
./hpc-side.sh check
./hpc-side.sh probe-compute
```

Each `check` prints `PASS`, `FAIL` or `INFO` lines and ends with a non-zero code if anything failed. `executor-image` prints the `argoexec` image that Argo puts in every pod, and `ARGO_EXEC_IMAGE` in `deucalion.env` must be that exact value on both machines. On the login node, two lines decide the next steps. If the Global Storage is not reachable from the login node, stop here, because `init` and `wait` cannot move any data. The line about the Kubernetes API tells you whether to use the relay in step 2.5. `probe-compute` runs a one-minute job on `SLURM_PARTITION` and prints what a compute node can reach. On an offline partition every URL must answer `000`, DNS must fail, and the project folder must be visible. Keep this output, because it is the evidence that the partition really has no network.

### 2.4 Pull the images and enable the split executor

On the login node, run:

```sh
./hpc-side.sh images
./hpc-side.sh enable
./hpc-side.sh status
```

`images` pulls every image in `IMAGES` and `ARGO_EXEC_IMAGE` into `$HPC_PROJECT_ROOT/images`. `enable` saves `SlurmConfig.yaml` as `SlurmConfig.yaml.pre-split`, installs the wrappers in `$HPC_PROJECT_ROOT/split-executor`, makes the changes described in [APPROACH.md](APPROACH.md) section 4.4 and restarts the sidecar. `status` shows what is configured and running.

### 2.5 Choose the API path

If `hpc-side.sh check` said that the Kubernetes API is reachable from the login node, run this on Ulisses:

```sh
./k8s-side.sh api direct
```

Otherwise, which is the most likely case, start the relay on the login node first and then on Ulisses:

```sh
./hpc-side.sh relay on      # login node
./k8s-side.sh api relay     # Ulisses
```

`api relay` fetches the relay's certificate from the login node, opens the `ssh -L` tunnel and starts the agent as systemd units, points the virtual kubelet at the relay, and ends by checking that the relay answers through the tunnel. Both `api` commands restart the virtual kubelet, so run them while no pod is running on the interLink node. The first SSH connection pins the login node's host key in `/var/lib/split-executor/known_hosts`, because Isabel's tunnel does not keep one.

### 2.6 Configure Argo

On Ulisses, run:

```sh
./k8s-side.sh artifacts
./k8s-side.sh offload on
```

`artifacts` makes the Global Storage Argo's default artifact repository in `ARGO_NAMESPACE`, applies the module library of the tests (`lisa-modules`) and uploads the test data. An existing `artifact-repositories` ConfigMap is saved first in `/var/lib/split-executor/`. `offload on` sets Argo's `workflowDefaults` so that every workflow's pods go to the interLink node with the Slurm account and partition from `deucalion.env`. This is what keeps the test workflows plain Argo: nothing in them mentions the HPC side.

### 2.7 Run the tests

On Ulisses, start with the simplest test and then run all of them:

```sh
./k8s-side.sh test 00
./k8s-side.sh test
```

Each run first resets the test data in the Global Storage, so that results from an earlier run cannot make a check pass. Each test then prints `PASS` or `FAIL`, the workflow phase, the time and the number of checks passed. The checks (`tests/argo-native/checks.tsv`) are verified both in Argo and in the Global Storage. TC02 ends `Failed` on purpose. Everything is saved in `results/<time>/`. Expect each step to take longer than on the testbed, because the queue of `normal-x86` decides when `main` starts.

To see where each part ran, look in the job folders on the login node (under `DataRootFolder` in `SlurmConfig.yaml`). `split.log` shows what the `sbatch` wrapper did, `login.out` shows `init` and `wait` running on `ln01`, and `job.out` shows `main` running on a compute node.

### 2.8 What to keep as evidence

Keep the output of `hpc-side.sh check` and `probe-compute`, the whole `results/<time>/` folder, and for one pod its job folder, comparing `job.sh.orig` with `job.sh`. For a comparison, you can also run the same tests with the split executor disabled (`./hpc-side.sh disable`).

### 2.9 Put everything back

Run these commands in this order:

```sh
./k8s-side.sh clean         # Ulisses: delete the trial's workflows and so their job folders
./k8s-side.sh restore       # Ulisses: offload off, API address and artifact repository restored, relay stopped
./hpc-side.sh disable       # login node: SlurmConfig.yaml restored, relay stopped
```

`clean` matters because the job folders hold copies of the data, the artifact keys and service-account tokens. `restore` also puts back the `artifact-repositories` ConfigMap that `artifacts` saved, if there was one. Delete the test data from the Global Storage if it is no longer needed. The folders `split-executor/` and `images/` stay in the project folder until you delete them.

## 3. If something fails

| Symptom | What to look at |
|---|---|
| `enable` stops because there is no `--no-eval` | The site's Singularity is too old. Ask whether Apptainer 1.1 or newer is available (`module avail`). |
| A pod stays `Pending` | `squeue -u $USER` for the queue, and `split.log` in the job folder. The job stays held until `init` has finished. |
| `init` fails | `login.out` in the job folder. The cause is usually the Global Storage endpoint or keys, or an image missing from `images/`. |
| A step never ends | The relay: `./hpc-side.sh relay log` on the login node, and `./k8s-side.sh relay-health` and `relay-log` on Ulisses. |
| "image not found" | The pod names an image that is not in `IMAGES`. Add it and run `./hpc-side.sh images` again; no restart is needed. |
| `sbatch` is refused | The partition or account in `deucalion.env`; check them with `sinfo -s`. |
| The sidecar does not start after `enable` | `tail $HPC_PROJECT_ROOT/.interlink/sidecar.log`, then `./hpc-side.sh disable` to restore it. |
| An SSH step on Ulisses fails with a host key error | The login node's key changed. Remove its line from `/var/lib/split-executor/known_hosts` after confirming the change is expected. |
