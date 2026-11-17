# How to run

This guide gives the steps to run plain Argo workflows on HPC compute nodes without network, first on the local testbed and then on Deucalion through Ulisses. There are two ways to do it, called modes. Only one is on at a time, and one command switches between them:

| Mode | interLink | Where the pod runs | Our code on the HPC side |
|---|---|---|---|
| `split` | 0.6.1, Isabel's deployment as it is | `init` and `wait` on the login node, only `main` in the Slurm job | three wrappers (`sbatch`, `squeue`, `scancel`) and the API relay |
| `reverse` | 0.6.3, installed next to her 0.6.1 | the whole pod in the Slurm job, which reaches the Global Storage and the Kubernetes API through interLink's reverse tunnel | one wrapper (`sbatch`, the subPath fix) |

Both modes run the same workflows (`tests/argo-native`) with the same checks and the same scripts. How they work is explained in [APPROACH.md](APPROACH.md): section 4 for `split`, section 7 for `reverse`.

## 1. Running it locally on the testbed

The testbed (`testbed/`) is a small copy of Deucalion on three Lima virtual machines: a login node, an offline compute node, and `ulisses` with Isabel's Kubernetes side and MinIO. It reproduces what matters for this work: Slurm 23.11.4, Apptainer, a shared NFS file system, a compute node without network, and a login node that cannot connect to `ulisses`. Its README explains it in detail.

### 1.1 Requirements

You need an Apple Silicon Mac with Lima 1.0 or newer, about 35 GB of free disk and about 6.5 GB of free RAM. Stop Colima first with `colima stop`. Isabel's repository must be next to this one (`../lisa-pipeline-runner`), because the testbed installs `ulisses` with her scripts.

### 1.2 Build and check the testbed

Run these commands from the root of this repository. The first `make init-old` builds the three machines, which takes about an hour, mostly downloads. After a reboot, `make start` brings them back in a few minutes. `make` alone lists every target.

```sh
make init-old            # builds the VMs if needed; interLink 0.6.1, as on Ulisses today
make test-check          # checks that the testbed behaves like Deucalion
```

`make test-check` writes a report in `testbed/logs/check-<time>.md`, and every check must pass. In particular, the compute node must have no internet in `normal` mode, and the login node must not reach the Kubernetes API.

### 1.3 Run the automated tests

`make init-old` and `make init-new` switch the testbed between the two modes, and `make test` runs the tests of whichever mode is on:

```sh
make init-old && make test     # split, about 25 minutes
make init-new && make test     # reverse, about 45 minutes (the first init-new also builds interLink 0.6.3)
make report                    # the last result of each mode
```

Both run TC00 and Isabel's tests TC01 to TC10 (except TC08) as plain Argo workflows, with the compute node offline and the login node isolated, and check each test in Argo and in the Global Storage. TC02 ends `Failed` on purpose, because it reads a file that does not exist. `make test TESTS="00 05"` runs a subset. These runs use the testbed's own scripts (`testbed/testbed` and `experiments/reverse-tunnel/run.sh`), not the ones you will use on Deucalion; section 1.4 rehearses those.

### 1.4 Rehearse the Deucalion procedure on the testbed

Before going to Deucalion, run the exact scripts and steps of section 2 on the testbed, so that any problem shows up locally. The scripts read their settings from `deploy/deucalion/deucalion.env`, or from the file named in `SPLIT_ENV`. `deploy/deucalion/testbed.env.example` already holds the testbed's values.

Start from Isabel's setup, as on Ulisses, with `make init-old`. Then copy the repository into the two virtual machines from the `repositories` folder on your Mac:

```sh
COPYFILE_DISABLE=1 tar czf /tmp/ze.tgz --no-xattrs --no-mac-metadata --exclude results --exclude .git \
  --exclude testbed/cache --exclude testbed/state --exclude testbed/logs lisa-pipeline-runner_ze
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

Make sure the compute node is offline with `make net-normal` on the Mac, then follow section 2 from step 2.3 onwards in these two shells. On the testbed, `hpc-side.sh check` reports that the Kubernetes API is not reachable, so `split` uses the relay, as it most likely will on Deucalion. At the end, run the clean-up of step 2.9 so the testbed is left as it was.

On 16 November 2026 this rehearsal passed all ten tests in `split` (run `20261116-220707`, 30 of 30 checks). On 17 November 2026 it passed again in both modes, switching between them with `k8s-side.sh mode` (see [APPROACH.md](APPROACH.md) section 7).

## 2. Running it on Deucalion through Ulisses

The trial runs over Isabel's existing deployment. Kubernetes, Argo and interLink run on Ulisses, the interLink sidecar runs on the Deucalion login node `ln01` under her account, and her MinIO is the Global Storage. Nothing is installed by an administrator, nothing changes in Deucalion's network, and every change can be undone. Two scripts do all the work: `deploy/deucalion/k8s-side.sh` runs as root on Ulisses, and `deploy/deucalion/hpc-side.sh` runs on the login node as the account that runs the sidecar. From Ulisses, `k8s-side.sh` also runs `hpc-side.sh` on the login node over SSH, so switching modes and putting everything back are single commands on Ulisses.

### 2.1 Before you start

You need root on Ulisses and the Deucalion account that runs the sidecar (`HPC_USER`, Isabel's account in her setup). Ulisses already holds that account's SSH key for interLink's tunnel, so once you are on Ulisses you can reach the login node with it. Ask the supervisor who holds these accesses now.

While offload is on, every workflow of that Argo instance goes to Deucalion, including Isabel's own tests, so agree on a time when nobody else uses the cluster. Her MinIO (`GS_ENDPOINT`) must be running. In `split` it must be reachable from the login node, and in `reverse` from Ulisses. If it has to be redeployed, use the `pgsty/minio` image, because MinIO stopped publishing free images in October 2025. Use an x86 partition (`normal-x86`) in both modes: the login nodes are x86, the images are pulled there, and `split` also copies the login node's `argoexec` into the pod.

`reverse` needs a little more. Ulisses must be able to download from GitHub, go.dev and ghcr.io, because interLink 0.6.3 was released without binaries and is built from its tag. A pod on Ulisses must be able to reach the login node's SSH port. On Deucalion, the account must be allowed `srun --overlap` into its own jobs, and the compute nodes need `python3` and `/usr/sbin/sshd`. The checks in step 2.3 test all of this.

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

The default values in `deucalion.env.example` come from Isabel's `.env` files, so usually only the Global Storage keys (`GS_ACCESS_KEY`, `GS_SECRET_KEY`) need to be filled in. The mode is not a setting: the same file serves both. `deucalion.env` is ignored by git because it holds those keys. If you change the scripts or the settings later, copy the folder to the login node again, because `k8s-side.sh` runs the copy that is there (`HPC_REPO_DIR`). From now on, open a shell on the login node from Ulisses like this:

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

Each `check` prints `PASS`, `FAIL` or `INFO` lines, first for what both modes need and then one section per mode, and ends with a non-zero code if anything failed. `check split` or `check reverse` checks only one mode. `executor-image` prints the `argoexec` image that Argo puts in every pod, and `ARGO_EXEC_IMAGE` in `deucalion.env` must be that exact value on both machines.

On the login node, a few lines decide what you can run:

- `split`: if the Global Storage is not reachable from the login node, `split` cannot work, because `init` and `wait` move the data from there. The line about the Kubernetes API tells you whether `split` needs the relay (`SPLIT_API=relay`, the default and the most likely case) or can reach the API directly (`SPLIT_API=direct`).
- `reverse`: `srun`, `squeue --me` and the download of the 0.6.3 plugin must pass.

`probe-compute` runs a short job on `SLURM_PARTITION` and prints what a compute node can reach. On an offline partition every URL must answer `000`, DNS must fail, and the project folder must be visible. Keep this output, because it is the evidence that the partition really has no network. It also prints whether the node has `python3` and `sshd`, and whether `srun --overlap` from the login node reaches the job, which `reverse` needs.

### 2.4 Install interLink 0.6.3 on Ulisses (only for `reverse`, once)

```sh
./k8s-side.sh install
```

This puts interLink 0.6.3 in `/opt/interlink-0.6.3` and pulls the image of the SSH shadow pod. The 0.6.3 release has no binaries, so `install` clones the tag and builds it with Go, which it downloads first. This takes a few minutes. Isabel's interLink is not touched: 0.6.3 only runs once `reverse` is switched on. `mode reverse` runs `install` itself if it was not done.

### 2.5 Switch to a mode

On Ulisses, run one of:

```sh
./k8s-side.sh mode reverse
./k8s-side.sh mode split
```

`mode` switches both sides in the right order and prints every step:

1. `offload off`, so no new pod goes to the HPC side while things change.
2. On the login node, over SSH: `hpc-side.sh disable` (the mode that was on, if any), `hpc-side.sh images` (pulls what is missing) and `hpc-side.sh enable <mode>`. The login node comes first, because the virtual node only becomes Ready once the plugin answers.
3. On Ulisses:
   - `reverse`: `api reverse` switches Isabel's units to interLink 0.6.3 (systemd drop-ins), sets up the reverse tunnel and checks that a pod reaches the login node's SSH port.
   - `split`: `hpc-side.sh relay on` and `api relay`, or `api direct` if `SPLIT_API=direct`.
4. `artifacts`: the Global Storage becomes Argo's default artifact repository and the test data is uploaded. In `reverse` the repository's endpoint is the Service name `global-storage.<namespace>.svc.cluster.local`, because the tunnel maps names, not IP addresses.
5. `offload on`: Argo's `workflowDefaults` send every workflow's pods to the interLink node, with the Slurm account and partition. In `reverse` they also ask for the tunnel (`interlink.eu/reverse-forwards`). This is what keeps the test workflows plain Argo.

If a step fails, `mode` stops and says which one. Fix the cause and run the same `mode` command again: every step can be repeated. `./k8s-side.sh status` shows the mode of each side and what is configured. The steps can also be run by hand, `hpc-side.sh` on the login node and `k8s-side.sh` on Ulisses, in the order above. Both scripts refuse to turn a mode on while the other one is still on.

The first SSH connection pins the login node's host key in `/var/lib/split-executor/known_hosts`, because Isabel's tunnel does not keep one. `api` restarts the virtual kubelet, so switch modes only while no pod is running on the interLink node.

### 2.6 Run the tests

On Ulisses, start with the simplest test and then run all of them:

```sh
./k8s-side.sh test 00
./k8s-side.sh test
```

Before it starts, `test` checks that both sides, the artifact repository and the offload settings are in the same mode, and says what to run if they are not. Each run first resets the test data in the Global Storage, so that results from an earlier run cannot make a check pass. Each test then prints `PASS` or `FAIL`, the workflow phase, the time and the number of checks passed. The checks (`tests/argo-native/checks.tsv`) are verified both in Argo and in the Global Storage. TC02 ends `Failed` on purpose. Everything is saved in `results/<time>-<mode>/`, and in `reverse` a failed test also gets `diag.txt` (the shadow pods and their logs). Expect each step to take longer than on the testbed, because the queue of `normal-x86` decides when the job starts. In `reverse`, each pod also waits for its tunnel, which took about 80 seconds on the testbed.

To see where each part ran, look in the job folders on the login node (under `DataRootFolder` in `SlurmConfig.yaml`):

- `split`: `split.log` shows what the `sbatch` wrapper did, `login.out` shows `init` and `wait` running on `ln01`, and `job.out` shows `main` running on a compute node.
- `reverse`: `subpath-fix.log` shows the binds the wrapper rewrote, `job.out` shows `interLink: reverse tunnel ready`, and `init-init.out`, `run-main.out` and `run-wait.out` come from the job itself, on the compute node. `./k8s-side.sh diag` shows the shadow pods and their logs.

### 2.7 Switch to the other mode

```sh
./k8s-side.sh clean
./k8s-side.sh mode split        # or: mode reverse
./k8s-side.sh test
```

`clean` deletes the workflows of the last run first, so no pod is running when the virtual kubelet restarts. The two runs end up in two folders, `results/<time>-reverse/` and `results/<time>-split/`, which can be compared test by test.

### 2.8 What to keep as evidence

Keep the output of `hpc-side.sh check` and `probe-compute`, the whole `results/<time>-<mode>/` folder of each mode, and for one pod of each mode its job folder. In `split`, compare `job.sh.orig` with `job.sh`. In `reverse`, keep `subpath-fix.log` and `job.out`.

### 2.9 Put everything back

On Ulisses, run:

```sh
./k8s-side.sh clean         # delete the trial's workflows and so their job folders
./k8s-side.sh restore       # both sides as before: offload off, login node's mode off, Isabel's interLink back
```

`clean` matters because the job folders hold copies of the data, the artifact keys and service-account tokens. `restore` switches offload off, runs `hpc-side.sh disable` on the login node (Isabel's `SlurmConfig.yaml` and plugin back, relay stopped), and puts back Isabel's interLink units and virtual kubelet configuration. In `reverse` it also deletes the Secret that holds the SSH key, including the copies interLink made in the shadow namespaces. It also restores the `artifact-repositories` ConfigMap that `artifacts` saved, if there was one. If the login node could not be reached, run `./hpc-side.sh disable` there yourself. `./hpc-side.sh status` on the login node and `./k8s-side.sh status` on Ulisses should both say mode `none`.

Delete the test data from the Global Storage if it is no longer needed. The folders `split-executor/`, `reverse-tunnel/` and `images/` stay in the project folder, and `/opt/interlink-0.6.3` stays on Ulisses, until you delete them.

## 3. If something fails

| Symptom | What to look at |
|---|---|
| `enable` stops because there is no `--no-eval` | The site's Singularity is too old. Ask whether Apptainer 1.1 or newer is available (`module avail`). |
| `mode` says the login node is `unknown` | The login node has no up-to-date copy of this repository in `HPC_REPO_DIR`. Copy the folder again (step 2.2). |
| A pod stays `Pending` (`split`) | `squeue -u $USER` for the queue, and `split.log` in the job folder. The job stays held until `init` has finished. |
| A pod stays `Pending` (`reverse`) | `./k8s-side.sh diag`: the shadow pod waits for the job to start, then reaches it with `srun --overlap`. An `srun` error there means the site refuses it. |
| `init` fails (`split`) | `login.out` in the job folder. The cause is usually the Global Storage endpoint or keys, or an image missing from `images/`. |
| `init` fails (`reverse`) | `job.out` in the job folder must say `reverse tunnel ready`. If it does, check the Global Storage Service: `kubectl get svc,endpointslice -l app.kubernetes.io/managed-by=deucalion-trial`. |
| A step never ends (`split`) | The relay: `./hpc-side.sh relay log` on the login node, and `./k8s-side.sh relay-health` and `relay-log` on Ulisses. |
| "image not found" | The pod names an image that is not in `IMAGES`. Add it and run `./hpc-side.sh images` again; no restart is needed. |
| `sbatch` is refused | The partition or account in `deucalion.env`; check them with `sinfo -s`. |
| The sidecar does not start after `enable` | `tail $HPC_PROJECT_ROOT/.interlink/sidecar.log`, then `./hpc-side.sh disable` to restore it. With `reverse`, a `SocketDirRoot` error there means the path is not valid for the plugin (`check reverse` tests it). |
| `install` cannot build interLink 0.6.3 | Ulisses needs to reach github.com and go.dev. Otherwise build it elsewhere (`GOOS=linux GOARCH=amd64 go build ./cmd/interlink ./cmd/virtual-kubelet` at tag 0.6.3) and copy both binaries to `/opt/interlink-0.6.3/` as `interlink` and `virtual-kubelet`. |
| `api reverse` says a pod does not reach the login node's sshd | The pod network on Ulisses cannot reach port 22 of `HPC_LOGIN_HOST`, although Ulisses itself can. Look at outgoing NAT for pods (Calico) and any firewall on Ulisses. |
| `interlink-node` not Ready after `api` | `journalctl -u interlink-vk -n 50` on Ulisses. `./k8s-side.sh api off` puts Isabel's configuration back. |
| An SSH step on Ulisses fails with a host key error | The login node's key changed. Remove its line from `/var/lib/split-executor/known_hosts` after confirming the change is expected. |
