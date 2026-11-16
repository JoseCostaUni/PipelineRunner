# Approach: plain Argo workflows on HPC compute nodes without network (RQ2)

José Costa, MSc thesis (FEUP), LISA DDPC Pipeline Runner. This repository is a fork of Isabel
Moutinho's FEUP prototype (`../lisa-pipeline-runner`). All results come from the testbed in
`../testbed`, a small copy of Deucalion on Lima VMs.

**Status, 18 Oct 2026.** The approach works in the testbed. In run `t1-20261018-005325`, TC00 and
Isabel's tests TC01-07, TC09 and TC10 ran as plain Argo workflows and every check passed (30/30,
checked in MinIO and Argo). The compute node was offline, and the login node could not open
connections to the Kubernetes side. Since that run, the HPC side no longer needs Python or jq
(section 7.9). That change still needs a new `make test-t1` run to confirm it.

## 1. Context

- **Two prototypes** of the Pipeline Runner exist:
  - **FEUP** (Isabel Moutinho's thesis, 2026): Argo Workflows, interLink 0.6.1 with the Slurm
    sidecar, and a data-sync wrapper.
  - **CNES**: more robust, but it reaches the outside from compute nodes through an HTTP proxy.
- **Thesis scope:**
  - RQ1: merge the two prototypes.
  - RQ2: run standard Argo workflows on HPC compute nodes **without internet**. This document is
    about RQ2.
  - RQ3 is covered in part; RQ4 and RQ5 are future work. See
    `JoseCosta_Dissertation/body/chapter1.tex`.
- **Deucalion's network.** Login nodes reach the internet; compute nodes in the `normal-*`
  partitions do not. Two entries in the changelog (docs.macc.fccn.pt) matter here:
  - 13 Aug 2024: only the login nodes and `dev-arm` had internet.
  - 19 Feb 2025: `dev-x86` was connected to the internet.

## 2. The problem

### 2.1 What the FEUP prototype claims

Isabel's thesis says three times that the data wrapper runs on the **login node**:

- §6.1, p. 46: "This prefix script executes on the HPC login node - where internet connectivity is
  available - rather than on the compute node".
- §6.2, p. 51: "This wrapper executes on the HPC login node in place of the generated job script".
- §6.3, p. 55: "The wrapper runs on the login node … and then calls sbatch to submit job.sh".

§7.1.2 (p. 58) also says that Deucalion has "air-gapped compute nodes" and that "data
synchronisation via the login-node wrapper … functioned correctly end-to-end".

### 2.2 What actually happens

We tested this in the testbed with her own scripts (test T0, `../testbed/README.md`). We ran her ten
tests with the compute node online (`dev`), offline (`normal`), and offline with images pulled
beforehand (`normal-images`). We also read the interLink and `mc` sources.

1. **The wrapper runs on the compute node.** The interLink Slurm plugin writes `CommandPrefix` into
   the batch script (`pkg/slurm/prepare.go` at v0.6.1: `prefix + " " + job.sh` goes into
   `job.slurm`), so the wrapper runs inside the Slurm job.
   - The saved `job.slurm` files contain `sync-data.sh .../job.sh`.
   - The wrapper's own messages (`[wrapper] starting`, `input sync ongoing`) appear in the job's
     `job.out`, followed by `mc` failing to reach MinIO (`dial tcp 192.168.104.4:9000: i/o
     timeout`). MinIO is reachable from the login node (check U1), so the `mc` that failed ran on
     the compute node.
   - Her `sync-data.sh` never calls `sbatch`; it runs `/bin/bash "$JOB_SCRIPT"`. Her configuration
     also sets `Tsocks: false`.
2. **Offline, every input sync fails.** In run `20261016-134021`, all 14 input-sync jobs (`normal`
   and `normal-images`) ended with `mc: <ERROR> Unable to stat source ... i/o timeout`. In `dev`,
   the same tests pass (run `20261016-015748`).
3. **Output sync fails silently.** On network errors, `mc mirror` only prints "Unable to list
   comparison retrying.." and exits 0 (`cmd/difference.go`; still the case in current `mc`). Her
   wrapper uses `set -euo pipefail`, yet it printed `output sync complete`. In MinIO, TC03's folder
   held only the placeholder written at the data reset; the `new-file.txt` that compute-write had
   written was never uploaded.
4. **Failed steps are reported as successes.**
   - Cause: `squeue -O exit_code` prints `1:0` (Slurm 23.11, `print.c`: `"%u:%u"`), and the
     plugin's `SlurmExitCodePattern` picks up the signal half, `0`. With no `.status` file, the
     plugin then writes `init-main.status` = `0`, and the pod is reported `Succeeded`.
   - The plugin's unit tests use the line `1   F`, a format squeue never prints. The bug is in
     0.6.1, 0.6.3-pre2 and `main`; to be reported upstream.
   - Effect: all 14 failed input syncs were `Succeeded` in Kubernetes. TC03 and TC05 in
     `normal-images` finished `Succeeded` without moving any data.
5. **Offline, images cannot be pulled either.** In `normal` (her `ImagePrefix: "docker://"`), all
   10 tests failed. With images pulled beforehand on the login node (`normal-images`), TC01, which
   needs no data, passes.
6. **Failed Jobs keep retrying after Argo has moved on.**
   - Her resource templates create `batch/v1` Jobs with `setOwnerReference: false`.
   - Argo fails the step at the first failure (`failureCondition: status.failed == 1`), but the Job
     keeps its default `backoffLimit` of 6. It goes on creating pods and using Slurm, which spills
     into later tests (107 job folders in one `normal` run). `ttlSecondsAfterFinished: 300` only
     cleans up afterwards.
7. **Why her validation passed (probably).**
   - Her `setup/kubernetes/.env.example` has `SLURM_PARTITION=dev-x86`, the only partition value in
     her whole git history, and `dev-x86` has been online since 19 Feb 2025.
   - The thesis never mentions dev partitions. A search for "partition" finds only "ARM, x86, and
     GPU compute partitions" (§6.2.1, p. 50).
   - If she ever ran offline, the false successes, stale data on the HPC side, and checking results
     in the Argo UI only (p. 63) would have hidden the failure.
   - To confirm with Isabel.
8. **Workflows had to be rewritten.** Her design needs resource templates and sync modules
   instead of Argo's native artifacts, so scientists cannot submit ordinary Argo workflows.

Side findings about reproducing her setup:

- MinIO stopped distributing free images and binaries in Oct 2025, so her `quay.io/minio/minio` is
  refused. The testbed uses `pgsty/minio`. Her setup can no longer be reproduced exactly as
  written.
- interLink 0.6.1 refuses `localhost` or `127.0.0.1` as the sidecar URL ("potential SSRF
  detected"), so `SidecarURL` must be the machine's own IP.
- TC10 fails in her setup even in `dev`, for two reasons:
  - compute-simulate writes to `/users/system`, which her `1-bridge.sh` binds read-only;
  - her `main.sh` runs `envsubst` over the templates, which blanks `$END_TS`, and the same
    `envsubst` also breaks the TC06 loop.

  It may be a misconfiguration on our side; to ask Isabel. The native port of TC10 (section 8)
  passes.

T0 runs (S = Succeeded, F = Failed):

| Run | Mode | Result |
|---|---|---|
| `20261016-015748` | dev | TC01 S, TC02 F (by design), TC03-07 S, TC08 F (by design), TC09 S |
| `20261016-022407` | dev | TC10 F: read-only `/users/system` |
| `20261016-134021` | normal | all 10 F |
| `20261016-134021` | normal-images | TC01 S; TC03 S and TC05 S, both **false successes**; TC02 and TC04 F |

### 2.3 Conclusion on the FEUP design

Her design is most likely **not correct for air-gapped compute nodes**, the case it claims to
solve:

- The thesis says the data wrapper runs on the login node, but the plugin puts it in the batch
  script, so it runs on the compute node. This is confirmed by the plugin's source and by the
  wrapper's own output in the Slurm jobs (item 1).
- With the compute node offline, every transfer fails (items 2 and 5). Two bugs then hide the
  failures (items 3 and 4), so a broken run can look successful in Argo.
- Her validation most likely passed because it ran on `dev-x86`, which has internet (item 7).

Two things are confirmed: where the wrapper runs, and that offline runs fail. Two are probable,
not confirmed: which partition she used, and how she checked her results. A Deucalion deployment
different from her repository (another plugin version or configuration) could change the
conclusion. Asking her and running her scripts on a `normal-*` partition would settle it.

### 2.4 What has to be solved

- **Data:** the data has to move where there is network (the login node), not inside the Slurm
  job.
- **Workflows:** the workflows have to stay plain Argo.
- **Reporting:** the pod has to report its results to Kubernetes from an HPC side that most likely
  cannot open connections to the Kubernetes side.

## 3. Requirement: workflows stay plain Argo

Scientists write ordinary Argo workflows (container or script templates, native artifacts) that
would run on any Kubernetes cluster. Nothing HPC-specific goes in them: no sync modules, no
resource templates, no `nodeSelector`, tolerations or `slurm-job.vk.io/*` annotations.

Sending pods to the HPC side is a platform decision:

- In the testbed, it is set in Argo's controller-wide `workflowDefaults` (nodeSelector, toleration,
  and a `slurm-job.vk.io/flags` annotation in `podMetadata`).
- For a data computing centre (DCC) that also runs workloads on Kubernetes, the target could come
  from the namespace (a controller per namespace, or instance IDs) or from an admission policy.
  Still to decide.

## 4. The idea: split the Argo executor between the login node and the compute node

An Argo 3.7 container-template pod has three containers (emissary executor):

| Container | Does | Needs |
|---|---|---|
| `init` (init container) | downloads input artifacts into emptyDirs, copies `argoexec` into `/var/run/argo` | artifact repository (network) |
| `main` | the user's command, wrapped by `argoexec emissary` | nothing outside the pod |
| `wait` (sidecar) | waits for `main`, uploads output artifacts, reports outputs (`WorkflowTaskResult`) | artifact repository **and Kubernetes API** |

The idea is to run `init` and `wait` on the **login node**, which has network, and only `main` on
the **compute node**:

```
sidecar (login)                                   compute node
  1. run init  -> emptyDirs on /projects
  2. sbatch job.sh (main only)  ------------------> main: argoexec emissary -- <cmd>
  3. start wait in background                       writes /var/run/argo/ctr/main/exitcode,
     wait polls exitcode (os.Stat every 1 s)  <---   stdout, outputs  (all on /projects)
  4. wait uploads outputs, reports to Kubernetes
```

Isabel's thesis proposes the same direction as future work (§8.3, p. 70): "execute Argo's init and
wait containers on the HPC login node … while executing only the main computation container on the
Slurm-managed compute nodes … would likely require extensions to the InterLink Slurm plugin". In
the end, no extension was needed.

Why it fits without changing Argo:

- `init` finishes before `main` starts, which is the natural "stage, then submit" boundary.
- `main` and `wait` share only files under `/var/run/argo` (exitcode, stdout/combined, signal), and
  `wait` **polls** them (`workflow/executor/emissary/emissary.go`, `Wait`/`isComplete`). It uses
  no inotify, which matters because file notifications do not cross nodes: a file created on the
  compute node triggers no inotify event on the login node (testbed checks I1-I3).
- `wait` reads the outputs from `/var/run/argo/outputs/artifacts/*.tgz`, written by `main`'s
  emissary, so the shared emptyDir is enough.
- The plugin already puts emptyDirs inside the job folder on the shared FS. It also mounts Secret
  and Projected volumes, so the artifact credentials are available (`GetSecret` reads the mounted
  secret).
- The virtual kubelet resolves `metadata.name`/`metadata.uid` environment variables and gets the
  service-account token through TokenRequest, so `init` and `wait` have their identity.

We did not use the Argo 4.1 init-less layout. It is beta, needs Argo 4.1 and Kubernetes'
`ImageVolume` feature gate, and the plugin has no handler for image volumes (it handles ConfigMap,
Secret, Projected, EmptyDir and HostPath).

## 5. The testbed

`../testbed` (see its README): three Lima VMs on the Mac.

- **`login`**: the Slurm sidecar, user `lisa` without sudo, `ssh -L` allowed and `ssh -R` refused.
- **`cn`**: the compute node. Its network can be switched between `normal` (reaches only the login
  node) and `dev` (internet).
- **`ulisses`**: the Kubernetes side of the FEUP prototype (kubeadm, Argo 3.7.12, Dex, interLink
  0.6.1) plus MinIO.

The software matches Deucalion where it matters: Slurm 23.11.4, Apptainer, NFSv4 between the nodes,
and the same project path. Everything is set up with Isabel's own scripts, changed only where the
testbed README lists.

The login node's isolation is always on (`guest/loginnet.sh`): it cannot open connections to
`ulisses`, while connections that `ulisses` opens (SSH) keep working. On Deucalion, `ulisses` is on
a private FEUP address (`MACHINE_HOST=10.227.208.123` in her `.env.example`). The one exception is
MinIO: it runs on `ulisses` only to save RAM, and it stands for the Global Storage, a separate host
that the login node reaches (her Azure VM). A separate VM for it is possible later. `make
test-check` verifies all of this (U1, U5-U7).

Known differences: arm64 instead of x86, Rocky 9 instead of 8, NFS instead of Lustre, and one
compute node.

## 6. Implementation: no fork, three wrappers (`setup/hpc/split-executor/`)

The sidecar runs on the login node and calls `sbatch`, `squeue` and `scancel` through configurable
paths (`SbatchPath`, `SqueuePath`, `ScancelPath`). Replacing these commands is enough; Argo and
interLink stay unmodified.

1. **`sbatch`.** Applies only to a pod with exactly one `init`, one `wait` and one `main` line in
   `job.sh`; any other job is submitted unchanged. For such a pod, it:
   - takes the `init` and `wait` lines out of `job.sh`;
   - fixes the input-artifact binds (7.1);
   - adds the local copy of `argoexec` (7.6);
   - submits the job **on hold** and prints sbatch's output;
   - starts `login.sh` in its own systemd user unit (falling back to `setsid`). `login.sh` runs
     `init`, then `scontrol release`, then `wait` together with the watchdog (7.7).

   If `init` fails, the held job is cancelled and never runs.
2. **`squeue`.**
   - While the inputs stage, the pod is reported `PD`; it stays `R` until `wait` has finished, even
     after the Slurm job has ended.
   - Then it reports the highest exit code of `init`, `main`, `wait` and the login side itself,
     never `0` unless all of them were `0`.
   - For every job, it prints `1` instead of Slurm's `1:0`, which fixes the false successes (2.2,
     item 4).
3. **`scancel`.** Also stops the login side.

Also needed:

- `CommandPrefix: ""`, so there is no data wrapper.
- `--no-eval --contain` in `SingularityDefaultOptions` (7.2, 7.3).
- The virtual kubelet's `KubernetesApiAddr`, `KubernetesApiPort` and `KubernetesApiCaCrt`
  (interLink 0.6.1), which point every offloaded container at the relay (7.4).

The testbed applies all of this with `guest/split-login.sh enable` and `guest/split-ulisses.sh api
relay`, and restores everything after the run.

Each job folder keeps:

- `job.sh.orig` (as generated) and `job.sh` (main only);
- `login.sh` and `login.out`;
- `split.log`;
- the markers `.split-released` and `.split-login-done`.

## 7. Changes made along the way, and why

### 7.1 The plugin ignores `subPath` on emptyDirs

Argo mounts each input artifact into `main` as `input-artifacts/<name>`, using `subPath`. The
plugin binds the whole `emptyDirs/<volume>` instead (`mountData`), so `main` would see a directory
where it expects a file.

`sbatch` rewrites those binds, in `main` and in `wait`'s `/mainctrfs<path>`, using the artifact
names and paths from `ARGO_TEMPLATE` in the containers' env files. To be reported upstream.

### 7.2 Apptainer evaluates every environment value twice: `--no-eval`

This was found in the first split run (`t2-20261017-031423`), where `argoexec init` panicked with
`invalid character '[' in string escape code`.

- `--env-file` is read correctly, but the values are then re-exported double-quoted inside the
  container (Apptainer `process_linux.go`, `injectEnvHandler`, "Apptainer historic behavior").
  So `$(...)`, backticks and `\` are evaluated again.
- `ARGO_TEMPLATE` is JSON that contains the user's script: `$(hostname)` ran, and the `\"` escapes
  were consumed.
- This affects any Argo pod offloaded through interLink with Apptainer, split or not.
- Fix: `--no-eval`, which gives single-quoted, OCI-compatible exports. It needs Apptainer >= 1.1 or
  SingularityCE >= 3.10; check the version on Deucalion.

The same run confirmed the split mechanics: the job was held, `init` ran on the login node in its
own unit, and when `init` failed the job was cancelled and the pod `Failed` with `init`'s exit code.
There was no false success.

### 7.3 Containers share `/tmp`: `--contain`

Singularity shares the compute node's `/tmp` between all jobs on that node, while Kubernetes gives
every container its own. Parallel steps that write `/tmp/out/file`, as Argo examples do, would
overwrite each other.

With `--contain`, each container gets a private `/tmp` in Apptainer's session directory. It is
small (64 MB by default); `--workdir` can move it to scratch.

### 7.4 The Kubernetes API from an isolated login node: the relay (`split-executor/api-relay/`)

`wait`, and sometimes `init`, call the Kubernetes API. On Deucalion, the login node most likely
cannot reach `ulisses:6443`:

- `ulisses` has a private address, and the MinIO host is public only so that both sides can reach
  it.
- The interLink tunnel is `ssh -L` from `ulisses`, so it only carries connections that start on
  `ulisses`.
- `ssh -R` is refused (check L4).
- The in-pod address (`10.96.0.1`) is unreachable from the HPC side anyway.

We considered two options:

1. **Direct access:** the login node reaches the API through a VPN or a public endpoint.
2. **Pull:** the calls are pulled by the Kubernetes side. We chose this, because it works with the
   connectivity that Deucalion is known to have.

Argo's executor only makes plain request/response calls: create and patch `WorkflowTaskResult`,
rarely a get of a ConfigMap or Secret, and no watches (`workflow/executor/taskresult.go`,
`executor.go`). So they can be pulled:

```
wait (login) --HTTPS--> split-relay login 127.0.0.1:16443  holds the request
agent (ulisses) --ssh -L--> 127.0.0.1:16444 (control)       GET /next, POST /respond/<id>
agent --HTTPS--> real API (ulisses:6443), with the pod's own token
```

The virtual kubelet points the containers at the relay (`KubernetesApiAddr` 127.0.0.1,
`KubernetesApiPort` 16443). It also gives them the relay's CA (`KubernetesApiCaCrt`, which replaces
`ca.crt` in the service-account volume), so Argo's executor trusts the relay. The API semantics are
exact (real status codes and bodies), and Argo is unchanged.

- If the agent does not answer within 120 s, the caller gets a 504.
- If the API is down, the caller gets a 502.
- A request whose caller has already given up is dropped, not sent to the API late.

In the final run, 64 calls went through the relay (44 PATCH, 20 POST).

For Deucalion: a fixed port on a shared login node can clash between users, and other users on the
node could reach the control port. A Unix socket in a private folder (`ssh -L` to a socket) would
avoid both.

### 7.5 The testbed must be as strict as Deucalion

At first, the testbed's login node could reach `ulisses`, so the relay could not be tested
honestly. The isolation (section 5) is now always on and verified by `make test-check`.

### 7.6 "Text file busy" across nodes

This was found in the first full run (`t1-20261017-153719`): every test failed with `job.sh: Text
file busy`.

- Cause: with no `CommandPrefix`, the batch script executes `job.sh` directly. `sbatch` rewrites
  `job.sh` on the login node just before submitting. On the compute node (the NFS server here), the
  freshly written file can still count as open for writing, and `exec` fails with `ETXTBSY`.
  Isabel's wrapper never hit this because it ran `bash job.sh`.
- Fix: `job.sh` is now replaced atomically, and the batch script runs `/bin/bash job.sh`.

The same happens to `argoexec`, which `init` copies into `/var/run/argo` on the login node and
`main` executes on the compute node. This hit about 1 pod in 5 in run `t1-20261017-184336`. The
compute node now makes its own copy just before `main` starts.

General rule for the split: nothing written on the login node is executed directly on the compute
node.

### 7.7 `wait` must not wait forever

`wait` learns that `main` has ended only from the exit-code file that `main`'s emissary writes. If
`main` never starts (as in 7.6), `wait` polls forever, and the pod hangs until the workflow times
out. One run hung for 20 minutes on this.

A watchdog on the login side now writes `main`'s exit code (never 0) once the Slurm job is over
without one, so the pod fails with the real cause.

### 7.8 Nothing on stderr

The sidecar treats any stderr output from `sbatch` as a failed submission. So the wrappers log to
`split.log`, and their file reads are written so that a missing file prints nothing.

### 7.9 No Python or jq on the HPC side (18 Oct)

Login nodes usually have both, but the fewer the requirements, the easier the deployment.

- **jq.** `sbatch` used jq to read the input artifacts from `ARGO_TEMPLATE`. It now uses grep and
  awk: Argo's Go encoder writes the template's fields in a fixed order (name, inputs, outputs, ...)
  and each artifact as `{"name":"...","path":"...",...}`, so the input artifacts are the name/path
  pairs before `"outputs"`. On all 55 pods of the earlier runs, the result is the same as jq's.
- **Python.** The relay was two standard-library Python scripts. It is now one static Go binary,
  `api-relay/split-relay`, used as `split-relay login` on the login node and `split-relay agent` on
  `ulisses`.
  - It keeps the same protocol and ports and uses only Go's standard library, built with CGO off.
  - `bin/` holds linux/amd64 (Deucalion) and linux/arm64 (testbed) builds; the `split-relay` script
    picks the right one. The source is in `src/`, and `build.sh` rebuilds it.
  - We tested it locally against a fake API: GET, POST and PATCH with the token passed through,
    error codes, an HTTP/2 offer (it falls back to HTTP/1.1), 20 concurrent calls, a 4 MB body,
    agent down (504) and API down (502).
  - Writing these tests revealed that the Python version sent requests to the API after their
    caller had already given up; the binary drops them (7.4).
- **openssl stays** for now: `make-certs.sh` makes the relay's CA and server certificate.

## 8. Isabel's tests as plain Argo (`tests/argo-native/`)

- `modules.yaml`: her six compute modules (simple, read, write, transform, aggregate, simulate) as
  one WorkflowTemplate with native artifacts.
- Her tests as plain DAGs that pass artifacts between steps and keep their results in the Global
  Storage.
- TC00: a single step with one input and one output artifact.
- TC08 (user isolation through her wrapper's path checks) is not ported. In standard Argo that is a
  matter of per-namespace repositories and credentials (identity; RQ4 in her thesis), not of air-gapped
  execution.
- Results are checked in MinIO and in Argo, not in the Argo UI (`checks.tsv`).

All of it runs in the testbed's single test, `make test-t1`: compute node offline
(`normal-images`), login node isolated, split executor and relay.

## 9. Results

| Run | Result | What it showed or changed |
|---|---|---|
| `t2-20261017-031423` | F | split mechanics work; `ARGO_TEMPLATE` corrupted -> `--no-eval` (7.2) |
| `t2-20261017-105227` | F | testbed bug: `singularity --help \| grep -q` under pipefail (SIGPIPE) |
| `t2-20261017-113056` | **S** | first plain artifact workflow on an offline compute node: `init` on login (input in 24 ms), `main` on cn, `wait` uploaded the result and Argo recorded the output; 54 s, about 27 s of it Slurm picking up the released job |
| `t1-20261017-151827` | **S** | TC00 with the login node isolated, API through the relay (3 calls) |
| `t1-20261017-153719` | F | every test: `job.sh: Text file busy` (7.6); the run before had hung 20 min (7.7) |
| `t1-20261017-184336` | 6/10 | `argoexec` text file busy (7.6) |
| `t1-20261018-005325` | **all pass** | see below |

Final run, `t1-20261018-005325`:

- Every check passed: 30/30, verified in MinIO and Argo. TC02 fails by design.
- `main` ran on `cn` for every pod, and `init`/`wait` ran on `lima-tb-login`.
- 64 API calls went through the relay.
- Durations were 0m30s to 3m06s per test; TC06 and TC10 include 120 s and 60 s simulations.

Evidence is in `../testbed/logs/t1-20261018-005325/`: the report, the Argo objects, the pod logs and
the job folders.

## 10. What the HPC side needs

- **On the login node:** bash, coreutils, grep, sed, awk, Slurm's commands, Apptainer (>= 1.1 for
  `--no-eval`), `systemd-run --user` (or `setsid`), and openssl for `make-certs.sh`. The
  certificates could also be made elsewhere and copied. No Python, no jq.
- **Where it lives:** everything runs as the project's own user, in its project folder. It needs no
  administrator, no site network change and no daemon beyond what interLink already runs there.
- **The SSH tunnel** from the Kubernetes side to the login node, which interLink already uses.

## 11. Open problems of this approach

Solved in the testbed: plain Argo workflows with native artifacts on a compute node without
network, reporting to Kubernetes from a login node that cannot reach it. Still to solve:

1. **Container images.** The compute node cannot pull images. The testbed pulls each image on the
   login node before the run (`normal-images`), but a scientist's workflow can name any image.
   Something on the login node has to pull, convert and cache every image a pod names before the
   job is released, for example the `sbatch` wrapper into a cache on `/projects`. It must also
   handle image size, cache cleanup, and private registries (with credentials).
2. **Architecture.** `init` copies the login node's `argoexec` into the pod, and `main` runs it on
   the compute node. Deucalion's login nodes are x86, so the ARM partitions would get the wrong
   binary. Options: only `normal-x86`, or a wrapper that supplies the compute node's `argoexec`.
   Images, too, must exist for the compute node's architecture.
3. **One account, one shared file system.**
   - Every pipeline job on Deucalion runs as the same project user, so any job can read any other
     job's folder.
   - What is exposed is worse than data. The plugin writes the artifact-store credentials
     (`secrets/<name>/accesskey`, `secretkey`) and the pod's service-account token
     (`projectedVolumeMaps/kube-api-access-*/token`) as plain files into each job folder, for as
     long as the folder exists.
   - Apptainer shows a container only the paths bound into it, so a normal `main` sees only its own
     job folder. That reduces the exposure, but it is not a security boundary: same user, and the
     site's Apptainer configuration may add default binds (to check on Deucalion).
   - Other Deucalion projects are kept out by Unix permissions; the risk is between users of the
     same platform.
   - Isabel's design has the same exposure: her TC08 isolation was a path check inside the wrapper.
   - A real fix needs separate HPC identities per platform user or trust group, which needs the
     site's cooperation. Smaller steps: credentials scoped per workflow and short-lived, and job
     folders deleted as soon as the pod ends.

   This is not one of the thesis's current problems (see section 12).
4. **All data goes through one login node.**
   - Every input and output crosses the login node, which raises the questions of bandwidth,
     per-process limits on login nodes, `/projects` quotas, and whether Deucalion's data-transfer
     nodes should do the transfers instead.
   - Intermediate artifacts make a round trip. When step B uses step A's output, `wait` uploads it
     to the Global Storage and B's `init` downloads it again, although both steps ran on the same
     shared FS. For large data this doubles the traffic for nothing. A cache on the HPC side, or a
     repository on the HPC side for intermediate artifacts, would avoid it.
   - Argo downloads every declared input before `main` starts. Nothing is streamed or read lazily,
     and data that is already on the HPC side (a growing dataset reused by every global-fit run) is
     downloaded again each time.
5. **Job folders are never cleaned up**, so data, credentials and tokens accumulate on `/projects`.
6. **Login-node lifetime.** `wait` runs on the login node for the whole job. If that node reboots,
   or the sidecar moves to another of Deucalion's login nodes, running pods lose their `wait`.
   Nothing recovers from that yet.
7. **Long queue times.** The service-account token and Argo's deadlines have to survive hours in
   the Slurm queue.
8. **Scale.** Each pod needs one `init` and one `wait` process on the login node, so 200 parallel
   steps mean 200 processes there. Slurm also adds overhead per step (about 27 s from release to
   start in the testbed).
9. **Argo features not tested:**
   - output parameters;
   - retries;
   - log archiving;
   - artifact garbage collection;
   - script templates;
   - GPU and other resource requests;
   - pods with extra containers (sidecars).
10. **Fragile coupling.**
    - The wrappers depend on the exact layout of the plugin's `job.sh` (`runInitCtn` and `runCtn`
      lines), on `squeue`'s output format, and on Argo's JSON field order (7.9). A plugin or Argo
      upgrade can break them silently.
    - The split also depends on Slurm (`--hold`, `scontrol release`); see RQ4 in section 12.
    - Upstreaming the `subPath` and `1:0` fixes and making the split a plugin feature (for
      example, an annotation `slurm-job.vk.io/split-executor`) would remove most of this.
11. **The relay on a shared login node.** Its fixed ports can clash between users, and other users
    on the node could reach the control port. A Unix socket in a private folder (`ssh -L` to a
    socket) would avoid both.
12. **Shared FS behaviour.** `main` uses `/var/run/argo` and the emptyDirs over the shared FS. That
    is fine on Lustre, but clock skew (check C1), large artifacts, and Lustre's handling of many
    small files are untested.

Next steps:

- re-run `make test-t1` after the Python and jq removal (7.9);
- the "before" table with `T1_SPLIT=off`;
- Deucalion: `normal-x86`, the Apptainer version, API reachability (`curl -k -m5
  https://<ulisses>:6443/version` from a login node), `systemd --user`, and the relay's port or
  socket;
- automatic images (problem 1);
- TC08 together with problem 3;
- reports to interLink;
- for Isabel: the partition she used, whether she ever ran with the compute nodes offline, and
  TC10;
- for the thesis: the `backoffLimit` issue and the MinIO licensing change, a sentence each.

## 12. What this means for the thesis's problems

Chapter 1 (`JoseCosta_Dissertation/body/chapter1.tex`) states four problems and five research
questions.

- **Compute nodes without network access (RQ2).** Answered "yes" in the testbed: plain Argo
  workflows with native artifacts run unchanged on an offline compute node.
  - Two qualifications. Images (problem 1) are still open. And the motivation asks for no changes
    "on the HPC side", but this approach does put something on the HPC side: wrappers, a relay and
    plugin settings, all in user space. What it avoids is changes by the *site*: no administrator,
    no network opening.
  - The motivation's text should make that distinction. It is also what separates the approach from
    CNES, whose compute nodes need the site network to reach the API and object storage.
  - The motivation also says the FEUP prototype "was tested and had its functionality validated on
    Deucalion". Given section 2.3, that sentence needs qualifying.
- **Data movement and storage (RQ3).** Answered only in part.
  - The split gives a concrete answer to "how data reaches the compute nodes": staged on the login
    node into the shared FS before the job is released.
  - It also answers "which part must be in place before processing starts": with Argo artifacts,
    all declared inputs.
  - For LISA-sized data, problem 4 is the real RQ3 work: the login-node bottleneck, intermediate
    round trips, reusing data already on the HPC side, partial or streamed access, quotas and
    cleanup.
  - The single account (problem 3) is a storage problem the motivation does not mention yet. Either
    add it here, as data protection on shared storage, or scope it out explicitly as identity.
- **Dependence on a single workload manager (RQ4).** The approach makes the dependence on Slurm
  stronger. It replaces the Slurm commands and relies on the Slurm plugin's job layout and on held
  jobs.
  - The idea itself does not depend on Slurm. It needs only "stage, then submit" (submitting after
    `init` would work without `--hold`) and a status query. So the split belongs in a scheduler-neutral
    layer (interLink's plugin interface, or a common library its plugins share), not in Slurm
    wrappers.
  - That is a concrete input for RQ4.
- **Requirements (RQ5).** The findings give candidate requirements:
  - compute nodes need no network;
  - a failure is never reported as a success (2.2, items 3 and 4);
  - workflows stay plain Argo and are portable;
  - the HPC side needs no site changes, only a short list of standard tools (section 10);
  - every result is checked in the Global Storage, not only in the Argo UI.
- **Convergence (RQ1).** The approach keeps CNES's standard workflows without CNES's network
  requirement. It also keeps FEUP's tunnel-only connectivity without FEUP's sync modules. So it is
  a candidate for the merged design. How it compares with CNES's reporting path (the HPC side
  calling the API directly) is the next comparison to make.
