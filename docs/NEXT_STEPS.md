# Where this stands, and what to do next

A handoff for the next working session. It was written on 24 Nov 2026, when `main` became
interLink 0.6.3 with the reverse tunnel only (tag `reverse-interlink-0.6.3`). Read it with
[CHANGELOG.md](CHANGELOG.md), which has the why of every change, and [APPROACH.md](APPROACH.md).

## 1. Where it stands

- **It works on Deucalion.** Plain Argo workflows ran on `normal-x86`, an offline partition, from
  Ulisses, as our own accounts.
  - TC00 to TC05 passed (run `20261124-011219-reverse`), and the run was stopped by hand during TC06.
  - Its evidence shows interLink 0.6.3 by build commit, the plugin by release checksum, the tunnel
    for each pod, and Slurm's record of each step on nodes `cnx036`, `cnx043`, `cnx427` and
    `cnx497`.
- **Fixed since that run, tested on the testbed only:**
  - container logs (the virtual kubelet's certificate request is now approved);
  - `where.tsv` per run;
  - TC11 (no internet from inside a step);
  - `make evidence`;
  - the `main` cleanup;
  - the tests' runner and checks in Python (`tests/argo-native/run.py`, `checks.py`), with a new check
    in every test that each step pod is a Slurm job in the partition;
  - the image mirror (`IMAGE_MIRROR=on`): any image, pulled in the job from a mirror in the cluster
    through the tunnel, with no change to the workflows (TC12);
  - the diagrams (`docs/diagrams/`).

  The last testbed runs passed: `20261124-172438`, with the in-cluster MinIO, and the root
  `make init` / `make test`.
- **Git:**
  - `main` holds only the reverse tunnel, and the split executor is in the tag
    `split-interlink-0.6.1`;
  - both tags and `main` are **local until pushed**: `git push origin main --tags`;
  - Ulisses must then `git pull` and run `make sync`.

## 2. Machines and accounts

| What | Where |
|---|---|
| Ulisses | `ssh ulisses` from the Mac with the FEUP VPN on (`jcosta@10.227.63.27`, key `~/.ssh/id_ed25519_work_key`). No sudo, cluster-admin kubeconfig from Isabel. Repository in `~/PipelineRunner`, interLink in `~/lisa-trial` |
| Deucalion | `jcosta.up@ln01.deucalion.macc.fccn.pt`, from Ulisses with `~/.ssh/id_ed25519` (from the Mac: `~/.ssh/id_ed25519_deucalion`). Slurm account `F202500007HPCVLABUPORTOX`, partition `normal-x86`. `HPC_PROJECT_ROOT=/home/jcosta.up/lisa` |
| Settings | `deploy/deucalion/deucalion.env` on Ulisses (not in git: it holds the MinIO keys). `GS_ENDPOINT=cluster` |
| Testbed | Lima VMs `tb-cn`, `tb-login`, `tb-ulisses` on the Mac. `make init` / `make test` at the repository root; the trial user is `jcosta` on `tb-ulisses` |
| Evidence of the Deucalion run | `~/Documents/Dissertation/evidence/deucalion/20261124-011219-reverse/` on the Mac; results on Ulisses in `~/PipelineRunner/deploy/deucalion/results/` |

**Limits to remember on Deucalion:**
- 150 processes and threads per user on the login node;
- no linger, so the sidecar lives as long as a session, which the tunnel from Ulisses is;
- `/projects` was full;
- `sacct` works;
- compute nodes have `python3` 3.6.8 and `sshd`, and `srun --overlap` works.

**What may still be running:** after the 24 Nov runs, check before anything else with `make status` on
Ulisses. `make restore` switches everything off; `make minio-off` also removes the MinIO.

## 3. Next steps, in order

1. **Push and update Ulisses.**
   - Push: `git push origin main --tags` from the Mac.
   - On Ulisses: `git pull`, `make sync`, then `make up`.
   - `hpc install` removes the old systemd drop-in and rewrites the plugin's configuration by
     itself. An old `deucalion.env` keeps working.
2. **The full test suite on Deucalion, with the new evidence.** `make up`, `make test` (all, TC00 to
   TC11), `make evidence`, `make results`. This is the first Deucalion run with:
   - container logs: "reverse tunnel ready" in every container, and "main on cnx…";
   - `where.tsv`;
   - TC11 on a real offline node;
   - the Python runner, and its check that every step is a Slurm job in `normal-x86`;
   - the image mirror: add `IMAGE_MIRROR=on` to `deucalion.env`, `make sync`, then `make check`. It
     must pass `ProctrackType proctrack/cgroup` (otherwise a finished job's relay can hold the fixed
     address, as on the testbed: keep `IMAGE_MIRROR=off`) and `--no-https`; look at the partition's
     `OverSubscribe` and the probe's `processes` line. Then `make up`, `make test T=12`, then all;
   - an evidence bundle made by the scripts on `main`.

   Copy it to `~/Documents/Dissertation/evidence/deucalion/`.
3. **Decide on the subPath wrapper**, the last piece of our code on the HPC side (`setup/hpc/subpath-fix`).
   The patch is ready, with a unit test: `experiments/reverse-tunnel/upstream/`. Upstream `main` still
   had the gap on 24 Nov 2026, and nobody had reported it. Options:
   - **(a)** Open an issue and a PR on `interlink-hq/interlink-slurm-plugin`. This is the right end
     state, and it can be cited in the thesis.
   - **(b)** Build the plugin from tag 0.6.3 with the patch ourselves. That removes the wrapper now,
     but makes us maintain a build.
   - (a) and (b) can be done together.

   Argo can't be configured around it: the controller hard-codes the `subPath` mount of input
   artifacts.
4. **Propose the per-pod image prefix to interLink.** With the image mirror, every pod's relay takes
   one fixed address, so each pod asks for a whole node (`--exclusive`). interLink already derives a
   relay address per pod from its UID (`reverseBindAddress`), and the testbed showed a second cost: on
   `proctrack/linuxproc` a finished job's relay held the address for the next job. A small change in the virtual kubelet,
   e.g. an annotation `interlink.eu/reverse-image-mirror: host:port`, could add the forward and set
   `slurm-job.vk.io/image-root` to `docker://<that pod's address>:<port>/`. That removes the fixed
   address and `--exclusive`. The alternative, in the plugin: pull on the login node at submission
   (`ImageCacheDir`, a pull policy, `sbatch --hold` until the pull ends).
5. **Report the plugin's DeletePod panic upstream,** or build from the tag. The 0.6.3 release binary
   panics on every pod deletion (a nil `*JidStruct`), which the tag's source already guards. The binary
   doesn't match its tag, and an empty job folder is left per pod.
6. **Measure what the thesis needs:**
   - **Tunnel start-up:** 68 to 84 s per pod on the testbed. Measure it on Deucalion from
     `logs.txt`, and split it from the queue wait with `where.tsv`/`sacct`.
   - **Throughput of the `srun` carrier** with large artifacts (100 MB, 1 GB), not measured yet: a new
     test like TC03 with a bigger file.
   - **Parallel pods against the 150-process limit:** each running pod holds an SSH session and an
     `srun` on the login node. TC05's three parallel steps worked. Find where it breaks.
7. **A message bus through the tunnel** (offered, not built). Deploy NATS in `ARGO_NAMESPACE` and set
   `EXTRA_FORWARDS="nats.<namespace>.svc.cluster.local:4222"`. Then a test where `main` publishes
   during execution. This is the capability the split executor could not give.

## 4. Open issues and improvements

- **Global Storage.**
  - Isabel's MinIO (`68.221.216.246:9000`) was down on 23 Nov. Ask her whether it comes back.
  - Our in-cluster MinIO keeps its data in an `emptyDir`, lost when the pod restarts. For more than
    trials, it needs a PersistentVolumeClaim, or Isabel's MinIO.
- **Shared Argo with Gustavo.** Argo's `workflowDefaults` are global, so while our offload is on,
  every workflow on that Argo goes to Deucalion. Options:
  - an Argo `instanceID` per person, with our own controller;
  - a namespaced controller (`--namespaced`) for `lisa-jcosta`;
  - agreeing on times with him.

  The instanceID is the cleanest. Talk to Gustavo first: Argo's CRDs are cluster-wide.
- **The thesis split with Gustavo** was left undefined at the 19 Nov meeting. Paulo asked what
  differs between the two theses. Isabel suggested one takes the connectivity analysis and the other
  the architecture change. This work is the architecture (plain Argo through interLink's reverse
  tunnel), with a measured comparison against the split executor. Agree on it explicitly.
- **Isabel's options document** (19 Nov) says interLink's SSH mode doesn't solve the return path. It
  predates 0.6.3's reverse tunnel, which does. Worth showing her the Deucalion evidence.
- **The SSH key in Kubernetes.** The shadow logs in with a private key kept in a Secret, which interLink
  copies into every shadow namespace. Use a key for this only, and ask whether Deucalion can restrict
  it (`authorized_keys` options).
- **Identity (RQ4).** All jobs run as one Deucalion account, and job folders hold artifact keys and
  service-account tokens while a pod runs. TC08 (user isolation) is not ported. This belongs with the
  identity question.
- **The certificate request of the virtual kubelet.** We approve it ourselves (`approve_csr`). Check
  whether Ulisses gets an approver, which would make this step unnecessary.
- **Scripts.** `k8s-side.sh` is still 884 lines; the test loop has moved to Python
  (`tests/argo-native/run.py`). Split the rest by concern (install, tunnel, artifacts and offload,
  evidence), keeping the Makefile targets. `evidence` is the next candidate for Python. Rehearse on the testbed after (`make init`,
  `make test`, `make trial T=restore`).
- **Tests in parallel.** `run.py` runs them one after the other. They write to different keys, so a
  thread per test would work, but each running pod holds an SSH session and an `srun` on the login
  node (the 150-process limit): cap the number at once.
- **ARM partitions** were not tried. Images are built on the x86 login nodes. An ARM run needs ARM
  images built elsewhere, and the plugin's arm64 binary.
- **Housekeeping on Deucalion:**
  - delete the old copy in `/projects/F202500007HPCVLABUPORTO/jcosta.up` (53 MB, from before
    `/home` was used);
  - delete `/home/jcosta.up/lisa` after the last run, if it is no longer needed.
- **`Ulisses tutorials.pdf`** is tracked in this repository. If the GitHub repository is public,
  consider whether it should be.

## 5. Habits that worked

- **Every change gets a `CHANGELOG.md` entry** (newest first): what, why, what it cost, and the
  evidence (run folders, commits, sources).
- **Rehearse on the testbed before Deucalion:** `make init`, `make test TESTS=00`,
  `make trial T=restore`. The testbed runs exactly the Deucalion scripts, as a user without root.
- **Gotchas from these sessions:**
  - `sudo -i bash -c '...'` mangles `$VAR`, so copy a script into the VM and run it;
  - `pkill -f <pattern>` kills your own shell if the pattern is in its command line;
  - on the testbed, root can't write in `lisa`'s NFS home: use `sudo -u lisa`;
  - a `[ test ] && cmd` at the end of a piped `{ }` group fails the pipeline under `pipefail`.
