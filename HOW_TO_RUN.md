# How to run

This guide gives the steps to run plain Argo workflows on HPC compute nodes without network, first on the local testbed and then on Deucalion through Ulisses. There are two ways to do it, called modes. Only one is on at a time, and one command switches between them:

| Mode | interLink | Where the pod runs | Our code on the HPC side |
|---|---|---|---|
| `split` | 0.6.1 | `init` and `wait` on the login node, only `main` in the Slurm job | three wrappers (`sbatch`, `squeue`, `scancel`) and the API relay |
| `reverse` | 0.6.3 | the whole pod in the Slurm job, which reaches the Global Storage and the Kubernetes API through interLink's reverse tunnel | one wrapper (`sbatch`, the subPath fix) |

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

Before going to Deucalion, run the same Makefile on the testbed as a user without root, as on Ulisses. `deploy/deucalion/testbed.env.example` holds the testbed's values. It uses its own virtual node, namespace, ports, project folder and sidecar service, so the rehearsal runs next to the testbed's own installation without touching it.

Prepare a user like `jcosta` on Ulisses, and copy this repository to its home. From the `repositories` folder on your Mac:

```sh
limactl copy lisa-pipeline-runner_ze/testbed/guest/trial-user.sh tb-ulisses:/tmp/trial-user.sh
limactl shell tb-ulisses sudo bash /tmp/trial-user.sh jcosta      # prints the user's public key
limactl shell tb-login sudo -u lisa bash -c 'cat >>~/.ssh/authorized_keys' <<<'<the printed key>'
COPYFILE_DISABLE=1 tar czf /tmp/ze.tgz --no-xattrs --no-mac-metadata --exclude results --exclude .git \
  --exclude testbed/cache --exclude testbed/state --exclude testbed/logs -C lisa-pipeline-runner_ze .
limactl copy /tmp/ze.tgz tb-ulisses:/tmp/ze.tgz
limactl shell tb-ulisses sudo bash -c 'mkdir -p /home/jcosta/PipelineRunner && tar xzf /tmp/ze.tgz -C /home/jcosta/PipelineRunner && chown -R jcosta: /home/jcosta/PipelineRunner'
```

`trial-user.sh` gives the user a kubeconfig with cluster-admin through a ServiceAccount token, as Isabel set up Ulisses, and no sudo. The key goes to `lisa` through `sudo -u lisa`, because the testbed's `/home` is on NFS and root cannot write there.

Then, as that user (`limactl shell tb-ulisses sudo -u jcosta -i`), make sure the compute node is offline (`make net-normal` on the Mac) and follow [RUN_ON_ULISSES.md](RUN_ON_ULISSES.md) from step 3, adding `ENV_FILE=testbed.env` to every `make`:

```sh
cd ~/PipelineRunner/deploy/deucalion && cp testbed.env.example testbed.env
make setup ENV_FILE=testbed.env && make check ENV_FILE=testbed.env
make reverse ENV_FILE=testbed.env && make test ENV_FILE=testbed.env
make clean split ENV_FILE=testbed.env && make test ENV_FILE=testbed.env
make restore ENV_FILE=testbed.env
```

On the testbed, the login node cannot reach the Kubernetes API, so `split` uses the relay, as it most likely will on Deucalion. The results of each rehearsal are listed in [CHANGELOG.md](CHANGELOG.md), with the earlier ones in [APPROACH.md](APPROACH.md), sections 5 and 7.

## 2. Running it on Deucalion through Ulisses

The commands, in order, are in [RUN_ON_ULISSES.md](RUN_ON_ULISSES.md). This section explains what they do. Everything runs as your own accounts:
- **On Ulisses:** a user with a cluster-admin kubeconfig and no sudo. `deploy/deucalion/k8s-side.sh` runs there.
- **On Deucalion:** an account that submits Slurm jobs. `deploy/deucalion/hpc-side.sh` runs on the login node, called by `k8s-side.sh` over SSH.

The `Makefile` in the same folder wraps both. What each mode installs, and where, is listed in [deploy/deucalion/README.md](deploy/deucalion/README.md).

### 2.1 What you need

- **On Ulisses**, your own account with a kubeconfig that has cluster-admin (`kubectl auth can-i '*' '*'` says `yes`). Isabel's base cluster gives this through a ServiceAccount. Ulisses must reach github.com and go.dev (`make setup`) and ghcr.io (the shadow image in `reverse`).
- **On Deucalion**, your own account (`HPC_USER`) and a Slurm account. The account's private key must be on Ulisses (`SSH_KEY`). New keys can take hours to be accepted. You also need a folder of yours for the trial (`HPC_PROJECT_ROOT`, at most 59 characters). If it is a shared folder, as Isabel suggests, its members can read the job folders, which hold the MinIO keys and service-account tokens while a pod runs.
- **The Global Storage** (Isabel's MinIO, `GS_ENDPOINT`) and its keys. In `split` it must be reachable from the login node, and in `reverse` from Ulisses. If it has to be redeployed, use the `pgsty/minio` image, because MinIO stopped publishing free images in October 2025.
- **An x86 partition** (`normal-x86`) in both modes. The login nodes are x86, the images are pulled there, and `split` also copies the login node's `argoexec` into the pod.
- **For `reverse`:**
  - the account must be allowed `srun --overlap` into its own jobs;
  - the compute nodes need `python3` and `/usr/sbin/sshd`;
  - a pod on Ulisses must reach the login node's SSH port.

`make check` tests all of this. The cluster is shared with Gustavo, which is why the virtual node (`INTERLINK_NODE_NAME`), the namespace (`ARGO_NAMESPACE`) and the ports are settings. Argo's `workflowDefaults`, which offload uses, apply to every workflow of that Argo.

### 2.2 Settings

`make env` copies `deucalion.env.example` to `deucalion.env`. Fill in `HPC_PROJECT_ROOT` and the MinIO keys, and check the rest. The Kubernetes API address comes from your kubeconfig. `deucalion.env` is ignored by git because it holds the keys. `make sync` copies the repository and the settings to `HPC_REPO_DIR` on the login node, without the keys, which `hpc-side.sh` doesn't need. Run `make sync` again after changing a script or the settings, because `k8s-side.sh` runs the copy that is there.

### 2.3 Set up (once)

`make setup` runs these steps, each of which does nothing if already done:
1. **`argo`**: installs Argo Workflows `ARGO_VERSION` in namespace `argo` if the cluster has none. It then creates `ARGO_NAMESPACE`, with the role Argo's executor needs there (Isabel's `argo-workflow-role`).
2. **`tools`**: fetches the `argo` CLI (the controller's version) and `mc` into `~/lisa-trial/bin` if they are missing.
3. **`install`**: puts interLink 0.6.1 (release binaries) and 0.6.3 in `~/lisa-trial`. 0.6.3 is built from its tag with Go, which is downloaded first, because its release has no binaries. This takes a few minutes.
4. **`sync`**: copies the repository and settings to the login node (section 2.2).
5. **`hpc install`**: on the login node, downloads the Slurm plugin 0.6.1 and writes a plain `SlurmConfig.yaml` in `HPC_PROJECT_ROOT/.interlink`. It then starts the plugin as your user service `lisa-sidecar` on `SIDECAR_PORT`, and enables linger if the site allows it. Without linger, the sidecar runs while you have a session on the login node, and the tunnel from Ulisses is one.

### 2.4 Read-only checks

`make check` runs three checks:
- `k8s-side.sh check` on Ulisses;
- `hpc-side.sh check` on the login node;
- `hpc-side.sh probe-compute`, a short job on `SLURM_PARTITION`.

It keeps all three outputs in `results/`. Each check prints `PASS`, `FAIL` or `INFO` lines, first for what both modes need and then one section per mode. A few lines decide what you can run:

- **`split`:** if the Global Storage is not reachable from the login node, `split` cannot work, because `init` and `wait` move the data from there. The line about the Kubernetes API says whether `split` needs the relay (`SPLIT_API=relay`, the default and the most likely case) or can reach the API directly (`SPLIT_API=direct`).
- **`reverse`:** `srun`, `squeue --me` and the download of the 0.6.3 plugin must pass.
- **The compute node** (`probe-compute`): on an offline partition every URL must answer `000`, DNS must fail, and the project folder must be visible. Keep this output: it is the evidence that the partition really has no network. It also says whether the node has `python3` and `sshd`, and whether `srun --overlap` from the login node reaches the job, which `reverse` needs.

### 2.5 Switch to a mode

`make reverse` or `make split` runs `k8s-side.sh mode`. It switches both sides in order and prints every step:

1. **`offload off`**, so no new pod goes to the HPC side while things change.
2. **On the login node, over SSH:**
   - `hpc-side.sh disable` (the mode that was on, if any);
   - `install` (the sidecar, if it isn't running);
   - `images` (pulls what is missing);
   - `enable <mode>`.

   The login node comes first, because the virtual node only becomes Ready once the plugin answers.
3. **On Ulisses**, interLink starts as three processes of yours: the SSH tunnel to the sidecar, the interLink API and the virtual kubelet. Their configuration is written from the settings into `~/lisa-trial/conf`, and their logs go to `~/lisa-trial/log`.
   - In `reverse`, interLink 0.6.3 also gets the reverse tunnel. Its SSH key goes into a Secret and the login node's host keys into a ConfigMap. The Global Storage gets a Service name, and a test pod checks that it reaches the login node's SSH port.
   - In `split`, interLink 0.6.1 runs, and the relay's two halves start, unless `SPLIT_API=direct`.
4. **`artifacts`**: the Global Storage becomes Argo's default artifact repository in `ARGO_NAMESPACE`, and the test data is uploaded. In `reverse` the repository's endpoint is the Service name `global-storage.<namespace>.svc.cluster.local`, because the tunnel maps names, not IP addresses.
5. **`offload on`**: Argo's `workflowDefaults` send every workflow's pods to your virtual node, with the Slurm account and partition. In `reverse` they also ask for the tunnel (`interlink.eu/reverse-forwards`). This is what keeps the test workflows plain Argo.

If a step fails, `mode` stops and says which one. Fix the cause and run the same command again: every step can be repeated. `make status` shows the mode of each side and the processes that run. The processes on Ulisses survive the end of your SSH session but not a reboot of Ulisses. After a reboot, run `make reverse` or `make split` again. Switch modes only while no pod runs on your virtual node, which is what `make clean` makes sure of.

### 2.6 Run the tests

`make test T=00` runs the simplest test, `make test` all of them. Before it starts, `test` checks that both sides, the artifact repository and the offload settings are in the same mode, and says what to run if they are not. Each run first resets the test data in the Global Storage, so that results from an earlier run cannot make a check pass. Each test then prints `PASS` or `FAIL`, the workflow phase, the time and the number of checks passed. The checks (`tests/argo-native/checks.tsv`) are verified both in Argo and in the Global Storage. TC02 ends `Failed` on purpose. Everything is saved in `results/<time>-<mode>/`, and a failed test also gets `diag.txt` (interLink's logs and, in `reverse`, the shadow pods). Expect each step to take longer than on the testbed, because the queue of `normal-x86` decides when the job starts. In `reverse`, each pod also waits for its tunnel, which took about 80 seconds on the testbed.

To see where each part ran, look in the job folders on the login node (`make login`, then `HPC_PROJECT_ROOT/.interlink/jobs/`):

- **`split`:** `split.log` shows what the `sbatch` wrapper did, `login.out` shows `init` and `wait` running on the login node, and `job.out` shows `main` running on a compute node.
- **`reverse`:**
  - `subpath-fix.log` shows the binds the wrapper rewrote;
  - `job.out` shows `interLink: reverse tunnel ready`;
  - `init-init.out`, `run-main.out` and `run-wait.out` come from the job itself, on the compute node.

### 2.7 Switch to the other mode

`make clean split` (or `make clean reverse`), then `make test`. `clean` deletes the workflows of the last run first, so no pod is running when interLink restarts. The two runs end up in two folders, `results/<time>-reverse/` and `results/<time>-split/`, which can be compared test by test.

### 2.8 What to keep as evidence

Keep these:
- the three outputs of `make check` in `results/`;
- the whole `results/<time>-<mode>/` folder of each mode;
- for one pod of each mode, its job folder. In `split`, compare `job.sh.orig` with `job.sh`. In `reverse`, keep `subpath-fix.log` and `job.out`.

`make results` packs `results/` into `~/results.tgz`.

### 2.9 Put everything back

`make restore` runs `clean` and then `k8s-side.sh restore`, which:
- switches offload off, putting back exactly the `workflowDefaults` that were there;
- disables the mode on the login node, putting back the plain `SlurmConfig.yaml` and stopping the relay;
- stops and removes the sidecar's service;
- stops interLink on Ulisses;
- deletes the virtual node, and in `reverse` the Secret with the SSH key, including the copies interLink made in the shadow namespaces;
- restores an `artifact-repositories` ConfigMap that `artifacts` saved.

`clean` matters because the job folders hold copies of the data, the artifact keys and service-account tokens. At the end, `make status` should say mode `none` on both sides.

Argo, the namespace `ARGO_NAMESPACE`, `~/lisa-trial` on Ulisses and the folders under `HPC_PROJECT_ROOT` stay until you delete them. Delete the test data from the Global Storage if it is no longer needed.

## 3. If something fails

| Symptom | What to look at |
|---|---|
| `make check`: `kubeconfig ... does not reach the cluster with cluster-admin` | `kubectl get nodes` as your user. The kubeconfig comes from Isabel (`~/.kube/config`). |
| `make check`: `ssh to ... failed` | The key in `SSH_KEY` must be the one whose `.pub` is on Deucalion's portal. New keys can take hours to work. |
| `make check`: `port ... already in use` | Someone else uses it on that machine: pick another `TUNNEL_PORT`, `VK_PORT`, `RELAY_*_PORT` or `SIDECAR_PORT`, then `make sync`. |
| `enable` stops because there is no `--no-eval` | The site's Singularity is too old. Ask whether Apptainer 1.1 or newer is available (`module avail`). |
| `mode` says the login node is `unknown` | The login node has no up-to-date copy of this repository in `HPC_REPO_DIR`: `make sync`. |
| The sidecar does not start (`hpc install` or `enable`) | `make login`, then `tail $HPC_PROJECT_ROOT/.interlink/sidecar.log` and `systemctl --user status lisa-sidecar`. With `reverse`, a `SocketDirRoot` error there means the path is not valid for the plugin (`check` tests it). |
| The virtual node is not Ready after `mode` | `make diag`, or the logs in `~/lisa-trial/log/`. `il-tunnel.log` shows SSH problems (key, port of the sidecar), `il-api.log` the API's calls to the sidecar, `il-vk.log` the node and the pods. |
| A pod stays `Pending` (`split`) | `squeue -u $USER` on the login node for the queue, and `split.log` in the job folder. The job stays held until `init` has finished. |
| A pod stays `Pending` (`reverse`) | `make diag`: the shadow pod waits for the job to start, then reaches it with `srun --overlap`. An `srun` error there means the site refuses it. |
| `init` fails (`split`) | `login.out` in the job folder. The cause is usually the Global Storage endpoint or keys, or an image missing from `images/`. |
| `init` fails (`reverse`) | `job.out` in the job folder must say `reverse tunnel ready`. If it does, check the Global Storage Service: `kubectl -n <ARGO_NAMESPACE> get svc,endpointslice -l app.kubernetes.io/managed-by=deucalion-trial`. |
| A step never ends (`split`) | The relay: `./k8s-side.sh hpc relay log`, `./k8s-side.sh relay-health` and `./k8s-side.sh relay-log`. |
| "image not found" | The pod names an image that is not in `IMAGES`. Add it, `make sync`, then `./k8s-side.sh hpc images`; no restart is needed. |
| `sbatch` is refused | The partition or account in `deucalion.env`; check them with `sinfo -s` on the login node. |
| `make setup` cannot build interLink 0.6.3 | Ulisses needs to reach github.com and go.dev. Otherwise build it elsewhere (`GOOS=linux GOARCH=amd64 go build ./cmd/interlink ./cmd/virtual-kubelet` at tag 0.6.3) and copy both binaries to `~/lisa-trial/interlink-0.6.3/` as `interlink` and `virtual-kubelet`. |
| `api reverse` says a pod does not reach the login node's sshd | The pod network on Ulisses cannot reach port 22 of `HPC_LOGIN_HOST`, although Ulisses itself can. Look at outgoing NAT for pods (Calico) and any firewall on Ulisses. |
| New pods stay `ContainerCreating` with `connection is unauthorized` in their events | Calico's token expired (seen once on the testbed). Restarting `calico-node` fixes it: `kubectl -n kube-system delete pod -l k8s-app=calico-node`. It is a shared cluster, so tell the others. |
| An SSH step fails with a host key error | The login node's key changed. Remove its line from `~/lisa-trial/state/known_hosts` after confirming the change is expected. |
| Everything stopped after Ulisses rebooted | interLink runs as your processes, not as services: `make reverse` or `make split` again. |
