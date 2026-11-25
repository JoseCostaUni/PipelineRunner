# Approach: plain Argo workflows on HPC compute nodes without network

## 1. The problem

On Deucalion the login nodes reach the internet, but the compute nodes of the production partitions
(`normal-x86`, `normal-arm`, `large-arm`, GPU) cannot open any connection outside Deucalion. Deucalion's
staff confirmed this on 19 Nov 2026, and a probe job on `normal-x86` showed it.
- **What an Argo pod needs:** its containers must reach the Global Storage (S3) for their artifacts
  and the Kubernetes API to report back. `init` downloads the inputs, `main` runs the scientist's
  code, and `wait` uploads the outputs and reports.
- **What scientists should write:** ordinary Argo workflows with native artifacts, that would run on
  any Kubernetes cluster, without anything specific to the HPC side.

## 2. The idea: interLink 0.6.3's reverse tunnel

interLink offloads a Kubernetes pod to Slurm. A virtual kubelet on the Kubernetes side passes the
pod to a plugin on the login node (the "sidecar"), which runs it as a Slurm job with Apptainer.
interLink 0.6.3, released on 16 Nov 2026, adds a reverse tunnel to its SSH shadow (interLink PR #577).
- **What the tunnel gives:** a pod running on a compute node can open connections back into the
  cluster, to the Kubernetes API, the Global Storage, or any service it names, through the login node.
- **What the site must allow:** SSH to the login node, which interLink needs anyway, `srun --overlap`
  into one's own jobs, and `python3` and `sshd` on the compute nodes.
- **The result:** the standard Argo executor runs whole on the compute node, as on any Kubernetes node.
  Argo and interLink are not modified.

### 2.1 How one pod runs

1. **The whole pod is one Slurm job.** The plugin submits the pod as one job, with `init`, `main` and
   `wait` in it.
2. **A relay holds the pod's names.** Before the containers start, the job starts a small relay
   (`python3`). It holds a loopback address for the pod and accepts only the job's user. The names the
   pod asked for, such as the Global Storage's Service name and `kubernetes.default.svc.cluster.local`,
   are mapped to that address in the containers' `/etc/hosts`.
3. **The shadow pod reaches the job.** On Ulisses, interLink starts a shadow pod for the offloaded
   pod. The shadow logs in to the login node over SSH and finds the job with `squeue --me`. It runs
   `srun --overlap` into the job's allocation to start an `sshd` there, in user space, as the job's
   user, over `srun`'s standard input and output. Slurm carries those streams between `srun` on the
   login node and `slurmstepd` on the compute node.
4. **The return paths are opened.** Through that `sshd`, the shadow binds each forward with `ssh -R`
   as a Unix socket in the pod's folder under `SocketDirRoot`, behind the relay. It connects each one
   to the real endpoint inside the cluster.

So nothing on the compute node connects outwards, nothing is installed on the site, and the login
node's `sshd` is never asked to forward.
- **The shared file system is not a data channel.** The sockets live there only because the plugin
  creates the folder from the login node, and Unix sockets are local to one node.
- **What does go through it is the plugin's bookkeeping,** as in any interLink deployment: the job
  script, the containers' settings, each container's output and exit code, and the pod's emptyDirs.

The job's log shows `interLink: reverse tunnel ready after <n>s` in every container before it starts.

The diagrams in [`docs/diagrams/`](docs/diagrams/) show it: `deployment.svg` (what runs where),
`submission.svg` (one step, from Argo to the Slurm job and back), `communication.svg` (interLink's
calls and the reverse tunnel) and `images.svg` (where images come from).

### 2.2 What is configuration, and what is still ours

Almost everything is configuration:

- **Virtual kubelet:**
  - `Network.SSH` with `Reverse` (`NodeExec: srun`, `Sshd: userspace`), the combination that needs
    neither SSH into compute nodes nor forwarding on the site's `sshd`;
  - the SSH key as a Secret and the login node's host keys as a ConfigMap;
  - for offloaded containers, the API address `kubernetes.default.svc.cluster.local:6443`, because an
    unprivileged process cannot bind port 443.
- **Argo `workflowDefaults`:**
  - the pods' node selector and toleration for the virtual node;
  - the Slurm account and partition;
  - the annotation `interlink.eu/reverse-forwards`, which names what the tunnel carries;
  - with the image mirror, a fixed relay address (`interlink.eu/reverse-bind`) and `--exclusive`
    (section 2.3).

  The workflows themselves stay plain Argo.
- **Slurm plugin:**
  - `SocketDirRoot`;
  - `CommandPrefix: ""`;
  - `--no-eval`: Apptainer would otherwise evaluate every environment value a second time and corrupt
    Argo's `ARGO_TEMPLATE`;
  - `--contain`: each container gets its own `/tmp`, as in Kubernetes;
  - `ImagePrefix`: where images come from. Compute nodes cannot pull from the internet, so either
    images built beforehand on the login node, or the image mirror through the tunnel (section 2.3);
  - a fixed node capacity (`ResourceScriptPath`). Plugin 0.6.3 otherwise reports the free memory it
    sees, which fell below one pod's request on the testbed and left pods `Pending`.
- **Kubernetes:** the Global Storage under a Service name, because the tunnel maps names, not IP
  addresses.

One wrapper is still ours, `setup/hpc/subpath-fix/sbatch`, set as the plugin's `sbatch`:
- **The gap:** the plugin ignores `subPath` on emptyDir volumes, and Argo mounts every input artifact
  that way (the emptyDir `input-artifacts`, `subPath: <artifact name>`). Without the fix, `main` finds a
  folder where it expects a file.
- **What the wrapper does:** it rewrites those binds in the job script, then calls the real `sbatch`.
- **No configuration can avoid it.** Argo's controller hard-codes this mount, and without `subPath`
  the container would see the same wrong folder.
- **The fix belongs in the plugin.** `experiments/reverse-tunnel/upstream/` has a 9-line patch with a
  unit test. The plugin's `main` still had the gap on 24 Nov 2026, and nobody had reported it. Once a
  fix is released, no wrapper is left.

### 2.3 Any image: the image mirror

Without more, every image a pod names must be built beforehand on the login node, which has internet.
With `IMAGE_MIRROR=on`, a workflow names any image, as on any Kubernetes cluster:
- **A mirror in the cluster:** zot, which fetches each image on demand from its registry (Docker Hub,
  quay.io, ghcr.io) and keeps it.
- **Reached through the tunnel:** every pod gets a forward to it. The plugin's `ImagePrefix` is
  `docker://127.77.0.1:5000/`, so the job's Singularity pulls each image from the pod's relay and
  converts it on the compute node, once per image (`$HOME/.singularity`).
- **Platform configuration, not the workflow's:** the plugin's settings and Argo's `workflowDefaults`.
  TC12 names `busybox:1.37` and nothing else.
- **The cost of a fixed address.** Singularity pulls before the container exists, where the tunnel's
  names do not resolve. So every pod's relay takes the same address (`interlink.eu/reverse-bind`), and
  two pods must not share a node: each asks for a whole node (`--exclusive`). On Deucalion this may
  cost nothing: parallel steps already ran on separate nodes (`20261124-011219-reverse`). Slurm must
  also end each job's relay with the job (`proctrack/cgroup`); on the testbed (`proctrack/linuxproc`)
  a finished job's relay held the address for the next job on that node.
- **The clean fix is upstream:** interLink could set the image prefix to each pod's own relay address,
  which it already derives from the pod's UID. That removes the fixed address and `--exclusive`.

## 3. How it runs on Ulisses and Deucalion

Everything runs as one's own accounts (`deploy/deucalion`, steps in
[RUN_ON_ULISSES.md](RUN_ON_ULISSES.md)):
- **Ulisses:** a user with a cluster-admin kubeconfig and no sudo.
- **Deucalion:** an account that submits Slurm jobs.

What runs where:

- **Ulisses: interLink** (API and virtual kubelet) and the SSH tunnel to the sidecar.
  - They run as the user's own processes in `~/lisa-trial`, each restarted if it exits. They are not
    systemd services, which without root would stop at logout.
  - Each person has their own virtual node, namespace and ports.
  - Argo is installed once.
  - After the virtual kubelet starts, its serving certificate request is approved, which nothing on a
    kubeadm cluster does by itself. Without it, the API server cannot read any container's log from
    the virtual node.
- **Deucalion: the Slurm plugin 0.6.3** runs as the user service `lisa-sidecar`, with a configuration
  written from the settings.
  - Images are unpacked in the login node's local `/tmp` and packed with our own
    `mksquashfs -processors 4`. Singularity's `pull` cannot build images there: its `mksquashfs`
    starts one thread per CPU (256), and a user may run 150.
- **The Global Storage** is either an S3 endpoint that Ulisses reaches, or a MinIO inside the cluster
  (`GS_ENDPOINT=cluster`). The jobs reach it through the tunnel either way.

**Evidence of each run:**
- `results/<run>/where.tsv` lists every step pod's Slurm job, partition and compute node. Every test
  also checks it: a step pod that was not on the virtual node, or that Slurm has no job for, fails it.
- `logs.txt` holds every container's own output.
- TC11 records, from inside a step's container, that no connection to the internet opens.
- `make evidence` adds the versions (binaries' build commits, release checksums), the configuration
  and the logs, with secrets blanked and checked.

## 4. Results

The tests are TC00 (one step with an input and an output artifact), Isabel's tests TC01 to TC10
rewritten as plain Argo workflows (`tests/argo-native/`; TC08 not ported), and TC11 (no internet from
inside a step). Every result is checked in Argo and in the Global Storage
(`tests/argo-native/checks.py`).

| Run | Where | Result |
|---|---|---|
| `20261117-011154`, `-022804`, `-024031` | testbed, `experiments/reverse-tunnel` | All tests pass across the three runs of the first experiment, after its fixes (its README) |
| `20261117-215316-reverse` | testbed, Deucalion scripts | All tests pass in one run, 30 of 30 checks |
| `20261124-011219-reverse` | **Deucalion**, `normal-x86` | TC00 to TC05 pass (stopped by hand during TC06). Every step was a Slurm job on `cnx036`, `cnx043`, `cnx427` or `cnx497`, and TC05's three parallel writes ran at the same time on three nodes. Evidence in `CHANGELOG.md` |
| `20261124-162554-reverse` | testbed, as a user without root | TC00 and TC11 pass. Every container logs `reverse tunnel ready after 68s` (72 s for TC11), and TC11 records `internet: blocked` |
| `20261124-172438` | testbed, as a user without root, after `main` kept only 0.6.3 | TC00 and TC11 pass. The whole flow (`setup`, `check`, `up`, `test`, `evidence`, `restore`) ran with the new scripts |

**Time.** Each pod waits for its tunnel before its containers start: the shadow pod starts, logs in,
waits for the job to run and starts the `sshd` in it. That took 68 to 80 s per pod on the testbed.
- **Testbed:** short tests take about 1.5 minutes, against about 30 s with the earlier split executor
  (section 6).
- **Deucalion:** short tests took 2 to 3 minutes, including the queue of `normal-x86`.

## 5. Known limits

- **Every pod pays for its tunnel before it starts** (about a minute).
- **Throughput not measured.** All data passes through Slurm's I/O forwarding and SSH, and that path
  hasn't been measured with large artifacts.
- **The SSH key sits in Kubernetes.** The shadow logs in with an SSH private key kept in a Secret,
  which interLink copies into every shadow namespace. interLink's documentation advises a key for the
  tunnel only, restricted on the site. `restore` deletes the Secret and its copies.
- **Site requirements:** `srun --overlap`, `python3` (3.6 or newer; Deucalion has 3.6.8) and `sshd`
  on the compute nodes.
- **The 150-process limit.** Each running pod keeps an SSH session and an `srun` on the login node,
  where a user may run 150 processes and threads in all, the sidecar included.
- **HTTPS would need a matching certificate.** The Global Storage is reached through a Service name,
  so over HTTPS its certificate would have to be valid for that name (MinIO in plain HTTP here).
- **Images.** With `IMAGE_MIRROR=off`, they must be listed and built beforehand on the login node.
  With the image mirror any image works, but each pod asks for a whole node, and each new image is
  converted on the compute node (section 2.3). The mirror has run on the testbed only.
- **One account per deployment.** All jobs share one Deucalion account, and job folders hold the pods'
  artifact keys and service-account tokens while they run.
- **Argo's `workflowDefaults` are global.** While offload is on, every workflow of that Argo goes to
  Deucalion.
- **The Slurm plugin's 0.6.3 release binary** panics on every pod deletion (a nil pointer that the
  tag's source already guards). The pod is deleted, but an empty job folder stays.

## 6. How it worked before: the split executor (interLink 0.6.1)

Until 24 Nov 2026 this repository also had a second mode, `split`, on interLink 0.6.1. Its code is in
the tag `split-interlink-0.6.1`.

**The idea.** In an Argo pod only `init` and `wait` need the network, and they talk to `main` only
through files. So the split executor ran `init` and `wait` on the login node and only `main` in the
Slurm job, coordinating through the shared file system.
- **Three wrappers** replaced the plugin's `sbatch`, `squeue` and `scancel`. The `sbatch` wrapper kept
  only `main` in a held job and ran `init` and `wait` on the login node. The `squeue` wrapper reported
  the pod's real result.
- **A relay** let `init` and `wait` reach the Kubernetes API, since the login node cannot connect to
  Ulisses. Ulisses pulled their API calls through an `ssh -L` tunnel it opened itself.

It passed all tests on the testbed, 30 of 30 checks (`t1-20261018-005325`, `20261117-222712-split`).

**Why it was dropped:**
- **More code to maintain:** three wrappers and a relay, against one wrapper that is meant to go
  upstream. CNES does not want to maintain wrapper scripts.
- **Fragile:** the wrappers depended on the exact job script of interLink 0.6.1, on `squeue`'s output
  format and on Slurm's `--hold`. Plugin 0.6.3 also fixes the false successes the `squeue` wrapper
  worked around (#169).
- **`main` had no network,** so it could not use a message bus during execution. The reverse tunnel
  can carry any service the pod names.
- **Shared file system and login node:** `init` and `wait` coordinated with `main` through files,
  which Isabel found confusing, and lived on the login node for the whole job. On Deucalion that
  counts against the 150-process limit.
- **Its strengths:** it was faster (about 30 s for a short step), and it needed nothing from the site
  but SSH to the login node.

| | split executor (before) | reverse tunnel (now) |
|---|---|---|
| interLink | 0.6.1 | 0.6.3 |
| Code we maintain | 3 wrappers + relay | 1 wrapper (subPath), until upstream |
| Where `init` and `wait` run | login node | compute node, in the job |
| What the site must allow | SSH to the login node | SSH to the login node, `srun --overlap`, `python3` and `sshd` on the compute nodes |
| Data path | login node ↔ Global Storage | compute node ↔ Slurm ↔ login node ↔ shadow pod ↔ Global Storage |
| Time per short step (testbed) | about 30 s | about 1.5 min, mostly the tunnel |
| `main` reaches services | no | yes, any service named in the forwards |
