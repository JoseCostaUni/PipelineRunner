# Operations: running the runner

Everything runs as your own accounts, from the repository's root, with `make`:
- **Ulisses:** `jcosta`, with a cluster-admin kubeconfig and no sudo;
- **Deucalion:** `jcosta.up`, which submits Slurm jobs.

How it works is in [architecture.md](architecture.md); why each thing is the way it is, in the
[CHANGELOG](CHANGELOG.md).

## 1. On Ulisses, step by step

### Machines and accounts

| What | Where |
|---|---|
| Ulisses | `ssh ulisses` from the Mac with the FEUP VPN on (`jcosta@10.227.63.27`, key `~/.ssh/id_ed25519_work_key`). No sudo; cluster-admin kubeconfig from Isabel. Repository in `~/PipelineRunner`, the tool's state in `~/lisa-runner` |
| Deucalion | `jcosta.up@ln01.deucalion.macc.fccn.pt`, from Ulisses with `~/.ssh/id_ed25519`. Slurm account `F202500007HPCVLABUPORTOX`, partition `normal-x86`, `HPC_PROJECT_ROOT=/home/jcosta.up/lisa`. 150 processes and threads per user on the login node; no linger; compute nodes have `python3` 3.6.8 and `sshd` |
| Settings | `settings/deucalion.env` on Ulisses (not in git: it holds the MinIO keys), `GS_ENDPOINT=cluster` |
| Testbed | Lima VMs `tb-cn`, `tb-login`, `tb-ulisses` on the Mac; section 3 |

### Before you start

- **Kubernetes:** `kubectl get nodes` lists the node `ulisses`.
- **Deucalion from Ulisses:** `ssh -i ~/.ssh/id_ed25519 jcosta.up@ln01.deucalion.macc.fccn.pt hostname`
  works. New keys can take hours to be accepted.
- **Internet from Ulisses:** github.com, go.dev and pypi.org (for `make setup`), ghcr.io (the shadow
  image).
- **The cluster is shared with Gustavo.** While offload is on (`make up` until `make down`), every
  workflow of that Argo goes to your virtual node.

### From the Mac

With the FEUP VPN on, and in `~/.ssh/config`:

```
Host ulisses
    HostName 10.227.63.27
    User jcosta
    IdentityFile ~/.ssh/id_ed25519_work_key
```

Then `ssh ulisses`.

### The commands

```sh
screen -S trial                         # detach: Ctrl+A then D; back: screen -R trial
cd ~/PipelineRunner && git pull
make settings && vi settings/deucalion.env   # once: HPC_PROJECT_ROOT, GS_ACCESS_KEY, GS_SECRET_KEY; check the rest
                                        # (with the image mirror, for ESA's images: MIRROR_PRIVATE_USER and _TOKEN)
make setup                              # once
make check                              # fix every FAIL first
make up                                 # if a step fails: fix it, run it again
make test T=00                          # the simplest test
make test                               # all; Ctrl-C stops it
make evidence                           # versions, configuration, logs, Slurm's record of the last run
make restore                            # everything off
make results                            # ~/results.tgz; on the Mac: scp ulisses:results.tgz ~/Documents/Dissertation/
```

The first `make` fetches `uv` into `~/lisa-runner/bin` if it is missing, and `uv` brings the pinned
Python dependencies into `.venv` (Python 3.11, Ulisses's own).

### What each step does

**`make setup`** (each part does nothing if already done):
1. Argo `ARGO_VERSION` in namespace `argo`, only if the cluster has none, and the workflows' namespace
   `ARGO_NAMESPACE` with the role Argo's executor needs there.
2. With `GS_ENDPOINT=cluster`, a MinIO in that namespace, under the Service name `GS_SERVICE`, with its
   data in an `emptyDir`.
3. interLink `IL_VERSION` in `~/lisa-runner`. Its 0.6.3 release has no binaries, so it is built from its
   tag with Go, downloaded first (a few minutes).
4. On the login node, in `HPC_PROJECT_ROOT`: `runner/` gets `hpc.sh` and the files it installs, filled in
   from the settings (without the keys); `sidecar/` gets the Slurm plugin, its configuration and the
   subPath fix; the plugin starts as your user service `lisa-sidecar`.

**`make check`** changes nothing but `HPC_PROJECT_ROOT/runner`, and keeps its output in
`results/check-<time>.txt`:
- **Ulisses:** the settings, cluster-admin, Argo's executor image against `ARGO_EXEC_IMAGE`, the Global
  Storage, free ports, the API server's certificate for the name the jobs use.
- **The login node:** Slurm, `squeue --me`, Singularity with `--no-eval`, room in `HPC_PROJECT_ROOT`, the
  sidecar's port, the plugin's download, the partition (`OverSubscribe`, `ProctrackType`).
- **A compute node:** a short job on `SLURM_PARTITION`. On an offline partition every URL answers `000`
  or nothing; the project folder must be visible; `python3`, `sshd` and `srun --overlap` must work.
  Keep this output: it shows that the partition really has no network.

**`make up`** prints each step and stops at the first that fails; every step can be repeated:
1. offload off, so no new pod goes to the HPC side while things change;
2. the sidecar's files to the login node, the sidecar (restarted only if its configuration changed),
   and the images (built beforehand, `IMAGE_MIRROR=off`);
3. with `IMAGE_MIRROR=on`, the image mirror;
4. the tunnel's credentials (the SSH key as a Secret, the login node's host keys as a ConfigMap), the
   Global Storage under a Service name, then interLink: the SSH tunnel to the sidecar, the API, the
   virtual kubelet. Its serving certificate request is approved, or container logs would not work;
5. a pod with the shadow's image reaches the login node's SSH port;
6. the Global Storage as Argo's artifact repository in `ARGO_NAMESPACE`;
7. offload on: Argo's `workflowDefaults` send every workflow's pods to your virtual node.

interLink's processes survive the end of your SSH session, not a reboot of Ulisses: run `make up`
again after one. `make down` switches offload off and stops interLink, but leaves the sidecar running.

**`make test`** first checks that both sides are up, then resets the test data in the Global Storage
(everything under `tests/` deleted, each test's `input/` uploaded), so that an earlier run cannot make a
check pass. Each test prints `PASS` or `FAIL`, and every check under it with what it expected and what it
got. `make test` fails unless every test passed. TC02 ends `Failed` on purpose; TC12 runs only with the
image mirror, and TC13 (an image from ESA's GitLab) only with the mirror and a registry token.

**`make restore`** deletes the test workflows and waits for their pods to go (their job folders hold
data, keys and tokens), switches offload off (putting back exactly the `workflowDefaults` that were
there), stops interLink, deletes the SSH key's Secret with every copy, stops and removes the sidecar's
service, deletes the virtual node and its certificate requests, and puts back an `artifact-repositories`
ConfigMap that was there before. Argo, the namespace, the MinIO, the image mirror and `~/lisa-runner`
stay (`make minio-off`, `make mirror-off`).

## 2. Reading a test run

Everything goes to `results/<time>/`:

| File | What it holds |
|---|---|
| `report.md` | Start here. Every test, every check with what it expected and what it got (an artifact's actual content too), and for each step pod its Slurm job, partition and compute node |
| `where.tsv` | Every step pod: its Kubernetes node, Slurm job, partition, compute node and state |
| `results.json` | The same as the report, for programs |
| `config/` | Both sides' configuration as the run started |
| `TC<NN>/` | `workflow.yaml` as submitted, `workflow.json` as it ended, `logs.txt` (every container's own output; each starts with `interLink: reverse tunnel ready after <n>s`), `diag.txt` for a failed test |
| `evidence/` | After `make evidence`: versions, configuration, logs of the run's time, Slurm's record. Secrets blanked and checked |

**Checking a result by hand,** without the tool:

```sh
kubectl -n lisa-jcosta get wf                       # Ulisses: what Argo says
make login                                          # then, on the login node:
sacct -X --starttime today -o JobID,JobName%40,Partition,NodeList,State
```

A test's checks are in its `tests/NN-name/expect.yaml`; `make unit` runs the tool's own tests, which show
that no test can pass on a run that did not do its work.

## 3. The testbed (on the Mac)

`testbed/` is a small copy of Deucalion on three Lima VMs: a login node that cannot reach `ulisses`, a
compute node without network, and `ulisses` with Kubernetes and a MinIO (installed with Isabel's
scripts, from Isabel's repository next to this one). Details in [testbed/README.md](../testbed/README.md).

```sh
make testbed-init                 # the VMs (first time about an hour), the trial user, this repository there, 'make setup'
make testbed-check                # the testbed behaves like Deucalion
make testbed-test T="00 11"       # 'make up', then the tests, as the trial user
make testbed A=evidence           # any site target, as the trial user (A=restore, A=status, ...)
```

The trial user is `jcosta` on `tb-ulisses`, with a cluster-admin kubeconfig and no sudo, as on Ulisses;
the HPC user is `lisa`. `make testbed-init` copies this repository as it is on the Mac, so run it again
after changing the code. The results are in the trial user's `~/PipelineRunner/results/`
(`make testbed-shell VM=ulisses`, then `sudo -u jcosta -i`). Requirements: Apple Silicon, Lima 1.0 or
newer, about 35 GB of disk and 6.5 GB of RAM free (stop Colima first).

## 4. What changes, and how to undo it

| Where | Change | Undo |
|---|---|---|
| Ulisses, `~/lisa-runner/` | interLink's binaries, the Go toolchain and sources to build them, its configuration, logs, saved state, the login node's pinned host keys, `uv` if it was missing | `rm -rf ~/lisa-runner` after `make restore` |
| Ulisses, this repository | `.venv` (Python dependencies), `results/` | delete them |
| Ulisses, namespace `argo` | Argo `ARGO_VERSION`, only if the cluster had none | `kubectl delete -n argo -f <Argo's install.yaml>`, if nobody else uses it |
| Ulisses, ConfigMap `argo/workflow-controller-configmap` | `workflowDefaults` while offload is on | `make down` or `make restore` puts back exactly what was there |
| Ulisses, namespace `ARGO_NAMESPACE` | the namespace, if it did not exist; Role and RoleBinding `argo-workflow-role`; ConfigMap `artifact-repositories` (an existing one is saved first) and Secret `lisa-gs-creds`; WorkflowTemplate `lisa-modules`; the test workflows | `make restore` puts a saved ConfigMap back; `kubectl delete ns ARGO_NAMESPACE` removes the rest |
| Ulisses, namespace `ARGO_NAMESPACE` | Service (and EndpointSlice) `GS_SERVICE`, for a Global Storage outside the cluster | `make down` |
| Ulisses, namespace `ARGO_NAMESPACE`, `GS_ENDPOINT=cluster` | Deployment `lisa-minio`, Service `GS_SERVICE`, Secret `lisa-minio-root`: data in an `emptyDir` | `make minio-off` |
| Ulisses, namespace `ARGO_NAMESPACE`, `IMAGE_MIRROR=on` | Deployment, Service and ConfigMap `image-mirror`; Secret `image-mirror-credentials` (**your registry token**, if `MIRROR_PRIVATE_TOKEN` is set) | `make mirror-off` |
| Ulisses, namespace `INTERLINK_NODE_NAME` | Secret `lisa-hpc-ssh-key` (**the private key `SSH_KEY`**) and ConfigMap `lisa-hpc-known-hosts`; interLink copies both into each shadow namespace | `make down` deletes them and every copy |
| Ulisses, node `INTERLINK_NODE_NAME` | the virtual node and its approved serving certificate request | `make restore` |
| Ulisses, containerd | image `ghcr.io/interlink-hq/interlink/ssh-tunnel:0.6.3` | stays (removing it needs root) |
| Deucalion, `HPC_PROJECT_ROOT/runner/` | `hpc.sh`, `hpc.env` (settings without keys) and the files below, as `sync` left them | delete the folder |
| Deucalion, `HPC_PROJECT_ROOT/sidecar/` | the Slurm plugin, `SlurmConfig.yaml`, `sidecar.log`, the subPath fix, `resources.sh`, the job folders (`jobs/`: a pod's data, keys and tokens while it runs; plugin 0.6.3 leaves an empty folder per pod) | delete the folder after `make restore` |
| Deucalion, `HPC_PROJECT_ROOT/sock/`, `images/` | the tunnel's socket folders; the images built beforehand | delete the folders |
| Deucalion, `~/.config/systemd/user/lisa-sidecar.service` | the sidecar's user service; linger if the site allows it | `make restore` |
| Deucalion, `~/.singularity/cache` | images the jobs pulled from the mirror (`IMAGE_MIRROR=on`) | `singularity cache clean` |
| Global Storage | bucket `GS_BUCKET`, test data under `tests/` (reset before every run) | `make minio-off`, or delete them |

## 5. Moving from the old scripts (once)

The version before the restructure (tag `before-restructure`) ran from `deploy/deucalion` and kept its
state in `~/lisa-trial`. `lisa` refuses to start while that version is on. On Ulisses:

```sh
cd ~/PipelineRunner/deploy/deucalion && make results     # with the old code: its runs into ~/results.tgz
make restore                                              # still the old code, before pulling
cd ~/PipelineRunner && git pull
cp deploy/deucalion/deucalion.env settings/deucalion.env  # if git left it there; or: make settings
make setup && make check                                  # rebuilds interLink in ~/lisa-runner
```

`IMAGE_MIRROR` is now off unless set to `on`. The old settings `HPC_REPO_DIR` and the split mode's are
ignored (`make check` lists them). On Deucalion the old folders (`.interlink/`, `reverse-tunnel/`,
`lisa-pipeline-runner_ze/` under `HPC_PROJECT_ROOT`) can be deleted, and on Ulisses `~/lisa-trial`.

## 6. If something fails

Start with `make status` and `make diag`. interLink's logs are in `~/lisa-runner/log/` (`il-vk.log`,
`il-api.log`, `il-tunnel.log`); `make login` opens a shell on the login node, in `HPC_PROJECT_ROOT/runner`.

| Symptom | What to look at |
|---|---|
| `make check`: `does not reach the cluster with cluster-admin` | `kubectl get nodes` as your user; the kubeconfig is `~/.kube/config` (or `KUBECONFIG`) |
| `ssh to ... failed` | `SSH_KEY` must be the key whose `.pub` is on Deucalion's portal. New keys can take hours |
| `the host key of ... changed` | After confirming the change is expected, delete the login node's lines from `~/lisa-runner/state/known_hosts` |
| `port ... already in use` | Someone else uses it on that machine: pick another `TUNNEL_PORT`, `VK_PORT` or `SIDECAR_PORT` |
| `singularity exec has no --no-eval` | The site's Singularity is too old: ask for Apptainer 1.1 or newer (`module avail`) |
| `the version before the restructure is still on` | Section 5 |
| The sidecar does not start | `make login`, then `tail ../sidecar/sidecar.log` and `systemctl --user status lisa-sidecar`. A `SocketDirRoot` error means the path is not valid for the plugin (`check` tests it) |
| `hpc.sh images` fails with `pthread_create` or `Resource temporarily unavailable` | The limit of 150 processes and threads per user on the login node: look for leftover processes of yours there (`ps -u $USER`) |
| The virtual node is not Ready after `up` | `make diag`; `il-tunnel.log` shows SSH problems, `il-api.log` the calls to the sidecar, `il-vk.log` the node and the pods |
| `logs.txt` says `tls: internal error` | The virtual kubelet's serving certificate was not approved: `kubectl get csr`, then `make up` again |
| A pod stays `Pending` | `make diag`: the shadow waits for the job to start, then reaches it with `srun --overlap`; an `srun` error means the site refuses it. `make hpc A=status` shows the queue |
| `init` fails | `job.out` in the job folder must say `reverse tunnel ready`. If it does, check the Global Storage Service: `kubectl -n <ARGO_NAMESPACE> get svc,endpointslice` |
| `main` finds a folder where it expects a file | The subPath fix did not run: `subpath-fix.log` in the job folder lists the binds it rewrote, and `SbatchPath` in `sidecar/SlurmConfig.yaml` must point to it |
| "image not found" | `IMAGE_MIRROR=off`: the pod names an image that is not in `IMAGES`. Add it, then `make hpc A=images` |
| `IMAGE_MIRROR=on`: a pull fails in `job.out` | `kubectl -n <ARGO_NAMESPACE> logs deploy/image-mirror`. A `mksquashfs` or thread error means the compute node's process limit is below its CPU count (the probe's `processes` line) |
| `IMAGE_MIRROR=on`: an image of ESA's GitLab is not found, or `unauthorized` | Name it `gitlab.esa.int/<path>:<tag>`, without the port. The token in `MIRROR_PRIVATE_TOKEN` needs the `read_registry` scope and must not have expired; after changing it, `make up` (the mirror restarts by itself) |
| `IMAGE_MIRROR=on`: a relay says the address is in use | Another relay holds it on that node: a pod sharing the node (the Slurm flags in `workflowDefaults` need `--exclusive`), or the relay of a job that just ended (`make check`: `ProctrackType`). Use `IMAGE_MIRROR=off` there |
| `sbatch` is refused | The partition or account in the settings: `sinfo -s` on the login node |
| `make setup` cannot build interLink | Ulisses needs github.com and go.dev. Otherwise build it elsewhere (`GOOS=linux GOARCH=amd64 go build ./cmd/interlink ./cmd/virtual-kubelet` at tag 0.6.3) and copy both binaries to `~/lisa-runner/interlink-0.6.3/` |
| `up` says a pod does not reach the login node's sshd | The pod network on Ulisses cannot reach port 22 of `HPC_LOGIN_HOST`, although Ulisses can: outgoing NAT for pods (Calico), or a firewall |
| New pods stay `ContainerCreating` with `connection is unauthorized` | Calico's token expired (seen once on the testbed): `kubectl -n kube-system delete pod -l k8s-app=calico-node`. A shared cluster: tell the others |
