# How to run

This guide runs plain Argo workflows on HPC compute nodes without network, through interLink 0.6.3 and
its reverse tunnel. It covers the local testbed first, then Deucalion through Ulisses. Both use the
same scripts (`deploy/deucalion`), the same workflows (`tests/argo-native`) and the same checks. How it
works is in [APPROACH.md](APPROACH.md).

## 1. Running it locally on the testbed

The testbed (`testbed/`) is a small copy of Deucalion on three Lima virtual machines:
- **`login`:** a login node, which cannot connect to `ulisses`;
- **`cn`:** a compute node without network;
- **`ulisses`:** Kubernetes and a MinIO, installed with Isabel's scripts.

It reproduces what matters for this work: Slurm 23.11.4, Apptainer, a shared NFS file system, a
compute node without network, and a login node that cannot connect to `ulisses`. Its README explains
it in detail.

On the testbed, the scripts run exactly as on Ulisses:
- on `ulisses`, as a user without root (`jcosta`) who has a cluster-admin kubeconfig;
- on the login node, as `lisa`.

### 1.1 Requirements

- **The Mac:** Apple Silicon, with Lima 1.0 or newer, about 35 GB of free disk and about 6.5 GB of
  free RAM. Stop Colima first with `colima stop`.
- **Isabel's repository** must sit next to this one (`../lisa-pipeline-runner`), because the testbed
  installs `ulisses` with her scripts.

### 1.2 Build, check and run

From the root of this repository (`make` alone lists every target):

```sh
make init              # builds the VMs if needed (first time about an hour, mostly downloads), then
                       # the trial user, this repository in its home, and 'make setup' as that user
make test-check        # checks that the testbed behaves like Deucalion
make test TESTS=00     # 'make up', then TC00; 'make test' runs all (about 45 minutes)
make trial T=evidence  # any target of deploy/deucalion/Makefile as the trial user
make trial T=restore
```

**`make init`:**
- **The VMs:** after a reboot, it only starts them, in a few minutes.
- **The trial user:** `testbed trial setup` creates it on `ulisses` with
  `testbed/guest/trial-user.sh`. That gives the user a kubeconfig with cluster-admin through a
  ServiceAccount token, as on Ulisses, and no sudo. The user's SSH key goes to `lisa` on the login
  node.
- **The settings:** it copies this repository, as it is on the Mac, to `~/PipelineRunner`. The
  settings are `deploy/deucalion/testbed.env`, made from `testbed.env.example`. That file gives the
  trial its own virtual node, namespace, ports and project folder. Run `make init` again after
  changing the scripts on the Mac.

**`make test-check`** writes a report in `testbed/logs/check-<time>.md`, and every check must pass. In
particular, the compute node must have no internet in `normal` mode (`make net-normal`), and the login
node must not reach the Kubernetes API.

**`make test`** runs TC00, Isabel's tests TC01 to TC10 (except TC08) and TC11, with the compute node
offline.
- **Where the checks run:** in Argo and in the Global Storage.
- **TC02 ends `Failed` on purpose,** because it reads a file that does not exist.
- **The results** are in the trial user's `~/PipelineRunner/deploy/deucalion/results/<time>/`
  (`make ssh-ulisses`, then `sudo -u jcosta -i`).

## 2. Running it on Deucalion through Ulisses

The commands, in order, are in [RUN_ON_ULISSES.md](RUN_ON_ULISSES.md). This section explains what they
do. Everything runs as your own accounts:
- **On Ulisses:** a user with a cluster-admin kubeconfig and no sudo. `deploy/deucalion/k8s-side.sh`
  runs there.
- **On Deucalion:** an account that submits Slurm jobs. `deploy/deucalion/hpc-side.sh` runs on the
  login node, called by `k8s-side.sh` over SSH.

The `Makefile` in the same folder wraps both. What it installs, and where, is listed in
[deploy/deucalion/README.md](deploy/deucalion/README.md).

### 2.1 What you need

- **On Ulisses:**
  - your own account, with a kubeconfig that has cluster-admin (`kubectl auth can-i '*' '*'` says
    `yes`). Isabel's base cluster gives this through a ServiceAccount;
  - access to github.com and go.dev, for `make setup`, and to ghcr.io, for the shadow image.
- **On Deucalion:**
  - your own account (`HPC_USER`) and a Slurm account. The account's private key must be on Ulisses
    (`SSH_KEY`). New keys can take hours to be accepted;
  - a folder of yours for the trial (`HPC_PROJECT_ROOT`, at most 59 characters). Make it private:
    job folders hold the MinIO keys and service-account tokens while a pod runs;
  - `srun --overlap` into your own jobs, and `python3` and `/usr/sbin/sshd` on the compute nodes;
  - a pod on Ulisses must reach the login node's SSH port.
- **The Global Storage:** either `GS_ENDPOINT=cluster`, a MinIO of ours inside the cluster, or an S3
  endpoint that Ulisses reaches, with its keys. A MinIO uses the `pgsty/minio` image, because MinIO
  stopped publishing free images in October 2025.
- **An x86 partition** (`normal-x86`), because the images are pulled on the login nodes, which are
  x86.

`make check` tests all of this.

**The cluster is shared with Gustavo.** That is why the virtual node (`INTERLINK_NODE_NAME`), the
namespace (`ARGO_NAMESPACE`) and the ports are settings. Argo's `workflowDefaults`, which offload uses,
apply to every workflow of that Argo.

### 2.2 Settings

`make env` copies `deucalion.env.example` to `deucalion.env`. Fill in `HPC_PROJECT_ROOT` and the MinIO
keys, and check the rest.
- **The Kubernetes API address** comes from your kubeconfig.
- **`deucalion.env` is ignored by git,** because it holds the keys.
- **`make sync`** copies the scripts and the settings to `HPC_REPO_DIR` on the login node, without the
  keys, which `hpc-side.sh` doesn't need. Run it again after changing a script or the settings,
  because `k8s-side.sh` runs the copy that is there.

### 2.3 Set up (once)

`make setup` runs these steps, each of which does nothing if already done:
1. **`argo`:** installs Argo Workflows `ARGO_VERSION` in namespace `argo` if the cluster has none. It
   then creates `ARGO_NAMESPACE`, with the role Argo's executor needs there (Isabel's
   `argo-workflow-role`).
2. **`minio on`,** with `GS_ENDPOINT=cluster:** a MinIO in `ARGO_NAMESPACE`, under the Service name
   `GS_SERVICE`, with an `emptyDir` for its data.
3. **`tools`:** fetches the `argo` CLI (the controller's version) and `mc` into `~/lisa-trial/bin` if
   they are missing.
4. **`install`:** puts interLink 0.6.3 in `~/lisa-trial`. Its release has no binaries, so it is built
   from its tag with Go, which is downloaded first. This takes a few minutes.
5. **`sync`:** copies the scripts and settings to the login node (section 2.2).
6. **`hpc install`:** on the login node:
   - downloads the Slurm plugin 0.6.3;
   - puts the subPath fix and a fixed node capacity (`resources.sh`) in
     `HPC_PROJECT_ROOT/reverse-tunnel`;
   - writes `SlurmConfig.yaml` in `HPC_PROJECT_ROOT/.interlink`;
   - starts the plugin as your user service `lisa-sidecar` on `SIDECAR_PORT`. It enables linger if
     the site allows it (Deucalion doesn't). Without linger, the sidecar runs while you have a
     session on the login node, and the tunnel from Ulisses is one.

### 2.4 Read-only checks

`make check` runs three checks, and keeps their output in `results/`:
- **`k8s-side.sh check`, on Ulisses:**
  - the kubeconfig has cluster-admin;
  - SSH to the login node works, and `ssh-keyscan` pins its host key;
  - the ports are free;
  - Argo's executor image is the one in `ARGO_EXEC_IMAGE`.
- **`hpc-side.sh check`, on the login node:**
  - Slurm, `squeue --me` and Singularity with `--no-eval` are there;
  - the project folder is writable and has room;
  - the sidecar port is free;
  - the plugin's download works.
- **`hpc-side.sh probe-compute`:** a short job on `SLURM_PARTITION`.
  - On an offline partition every URL must answer `000`, and the project folder must be visible.
    Keep this output: it shows that the partition really has no network.
  - It also says whether the node has `python3` and `sshd`, and whether `srun --overlap` from the
    login node reaches the job.

Each line says `PASS`, `FAIL` or `INFO`.

### 2.5 Bring it up

`make up` runs `k8s-side.sh up`, which prints every step:
1. **`offload off`,** so that no new pod goes to the HPC side while things change.
2. **On the login node, over SSH:**
   - **`hpc install`:** rewrites the sidecar's configuration from the settings, and restarts it only
     if something changed.
   - **`hpc images`:** builds the images that are missing, as single files in `HPC_PROJECT_ROOT/images`.

   The login node comes first, because the virtual node only becomes Ready once the plugin answers.
3. **`tunnel on`:** interLink starts on Ulisses as three processes of yours: the SSH tunnel to the
   sidecar, the interLink API and the virtual kubelet.
   - **Configuration:** it is written from the settings into `~/lisa-trial/conf`, with the reverse
     tunnel on. The logs go to `~/lisa-trial/log`.
   - **What the tunnel needs:** the SSH key goes into a Secret, the login node's host keys into a
     ConfigMap, and the Global Storage gets a Service name.
   - **The certificate:** the virtual kubelet's serving certificate request is approved.
   - **A test pod** checks that it reaches the login node's SSH port.
4. **`artifacts`:** the Global Storage becomes Argo's default artifact repository in
   `ARGO_NAMESPACE`, and the test data is uploaded. The repository's endpoint is the Service name
   `<GS_SERVICE>.<namespace>.svc.cluster.local`, because the tunnel maps names, not IP addresses.
5. **`offload on`:** Argo's `workflowDefaults` send every workflow's pods to your virtual node, with
   the Slurm account and partition and the annotation `interlink.eu/reverse-forwards`. This is what
   keeps the test workflows plain Argo.

If a step fails, `up` stops and says which one. Fix the cause and run `make up` again: every step can
be repeated. `make status` shows each side and the processes that run.
- **After a reboot:** the processes on Ulisses survive the end of your SSH session, but not a reboot
  of Ulisses. Run `make up` again after one.
- **`make down`** switches offload off and stops interLink, but leaves the sidecar running.

### 2.6 Run the tests

`make test T=00` runs the simplest test, `make test` all of them.

**Before it starts,** `test` checks that both sides are up and that offload asks for the tunnel. It
then resets the test data in the Global Storage, so that results from an earlier run cannot make a
check pass.

**Each test** prints `PASS` or `FAIL`, the workflow phase, the time and the number of checks passed.
- **The checks** (`tests/argo-native/checks.tsv`) are verified both in Argo and in the Global Storage.
- **TC02** ends `Failed` on purpose.
- **TC11** tries, from inside a step's container, to open connections to the internet, and passes
  only if none opens. It keeps what it tried, with the node's name, in the Global Storage
  (`users/admin/test-11/network.txt`).
- **Expect each step to take longer than on the testbed,** because the queue of `normal-x86` decides
  when the job starts, and each pod waits about a minute for its tunnel.

**Ctrl-C** stops the run and deletes the workflow that was running.

Everything goes to `results/<time>/`:
- **`summary.txt`:** one line per test, and a last line with the partitions and nodes used.
- **`config/`:** both sides' configuration as the run started.
- **`TC<nn>/`, for each test:**
  - `workflow.json` and `pods.tsv`;
  - `logs.txt`: every container's own output. Each of `init`, `main` and `wait` starts with
    `interLink: reverse tunnel ready after <n>s`;
  - `where.tsv`: for every step pod, the Slurm job it became, its partition, the compute node and its
    final state. Slurm names the job after the pod's UID, and gives this through `squeue` for a few
    minutes after a job ends, and through `sacct` where the site keeps accounting, as Deucalion does;
  - for a failed test, `diag.txt`: interLink's logs and the shadow pods.

### 2.7 What to keep as evidence

`make evidence` collects the evidence of a run, by default the last one, into
`results/<run>/evidence/`. It holds:
- **The configuration** of both sides.
- **The versions:**
  - the `vcs.revision` of the interLink binaries, against the commit of the tag;
  - the sha256 of the Slurm plugin, against the checksums published with the release;
  - Slurm and Singularity.
- **The logs** of interLink and the sidecar for the run's time.
- **Slurm's record** of the run's jobs (`sacct`).

Every secret is blanked, and the result is checked for any that is left. Keep the evidence together
with the outputs of `make check`. `make results` packs `results/` into `~/results.tgz`.

### 2.8 Put everything back

`make restore` runs `k8s-side.sh restore`, which:
1. deletes the test workflows and waits for their pods to go (`clean`). This matters because the job
   folders hold copies of the data, the artifact keys and service-account tokens;
2. switches offload off, putting back exactly the `workflowDefaults` that were there;
3. stops interLink on Ulisses, and deletes the Secret with the SSH key, with the copies interLink made
   in the shadow namespaces;
4. stops and removes the sidecar's service on the login node;
5. deletes the virtual node and its certificate requests;
6. restores an `artifact-repositories` ConfigMap that `artifacts` saved.

Some things stay until you delete them:
- Argo, the namespace `ARGO_NAMESPACE` and the MinIO (`make minio-off` removes it);
- `~/lisa-trial` on Ulisses;
- the folders under `HPC_PROJECT_ROOT`.

## 3. If something fails

| Symptom | What to look at |
|---|---|
| `make check`: `kubeconfig ... does not reach the cluster with cluster-admin` | `kubectl get nodes` as your user. The kubeconfig comes from Isabel (`~/.kube/config`). |
| `make check`: `ssh to ... failed` | The key in `SSH_KEY` must be the one whose `.pub` is on Deucalion's portal. New keys can take hours to work. |
| `make check`: `port ... already in use` | Someone else uses it on that machine: pick another `TUNNEL_PORT`, `VK_PORT` or `SIDECAR_PORT`, then `make sync`. |
| `make check`: no `--no-eval` | The site's Singularity is too old. Ask whether Apptainer 1.1 or newer is available (`module avail`). |
| `up` says the login node is `unknown` | The login node has no up-to-date copy of the scripts in `HPC_REPO_DIR`: `make sync`. |
| The sidecar does not start | `make login`, then `tail $HPC_PROJECT_ROOT/.interlink/sidecar.log` and `systemctl --user status lisa-sidecar`. A `SocketDirRoot` error there means the path is not valid for the plugin (`check` tests it). |
| `hpc images` fails with `pthread_create` or `Resource temporarily unavailable` | The limit of 150 processes and threads per user on the login node. Look for leftover processes of yours there (`ps -u $USER`). |
| The virtual node is not Ready after `up` | `make diag`, or the logs in `~/lisa-trial/log/`. `il-tunnel.log` shows SSH problems (the key, the sidecar's port), `il-api.log` the API's calls to the sidecar, and `il-vk.log` the node and the pods. |
| `logs.txt` says `remote error: tls: internal error` | The virtual kubelet's serving certificate was not approved. `kubectl get csr`, then run `make up` again, which approves it. |
| A pod stays `Pending` | `make diag`: the shadow pod waits for the job to start, then reaches it with `srun --overlap`. An `srun` error there means the site refuses it. `squeue -u $USER` on the login node shows the queue. |
| `init` fails | `job.out` in the job folder must say `reverse tunnel ready`. If it does, check the Global Storage Service: `kubectl -n <ARGO_NAMESPACE> get svc,endpointslice -l app.kubernetes.io/managed-by=deucalion-trial`. |
| `main` finds a folder where it expects a file | The subPath fix did not run. `subpath-fix.log` in the job folder lists the binds it rewrote, and `SbatchPath` in `SlurmConfig.yaml` must point to it. |
| "image not found" | The pod names an image that is not in `IMAGES`. Add it, run `make sync`, then `./k8s-side.sh hpc images`. No restart is needed. |
| `sbatch` is refused | The partition or account in `deucalion.env`. Check them with `sinfo -s` on the login node. |
| `make setup` cannot build interLink 0.6.3 | Ulisses needs to reach github.com and go.dev. Otherwise, build it elsewhere: `GOOS=linux GOARCH=amd64 go build ./cmd/interlink ./cmd/virtual-kubelet` at tag 0.6.3. Copy both binaries to `~/lisa-trial/interlink-0.6.3/` as `interlink` and `virtual-kubelet`. |
| `tunnel on` says a pod does not reach the login node's sshd | The pod network on Ulisses cannot reach port 22 of `HPC_LOGIN_HOST`, although Ulisses itself can. Look at outgoing NAT for pods (Calico) and any firewall on Ulisses. |
| New pods stay `ContainerCreating` with `connection is unauthorized` in their events | Calico's token expired (seen once on the testbed). Restarting `calico-node` fixes it: `kubectl -n kube-system delete pod -l k8s-app=calico-node`. It is a shared cluster, so tell the others. |
| An SSH step fails with a host key error | The login node's key changed. After confirming the change is expected, remove its line from `~/lisa-trial/state/known_hosts`. |
| Everything stopped after Ulisses rebooted | interLink runs as your processes, not as services: `make up` again. |
