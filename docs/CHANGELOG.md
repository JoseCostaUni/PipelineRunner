# Changelog and decision log

What changed in this repository, **why**, what it cost, and the evidence for it. Newest first. Each
entry names the commits, the test runs (folders under `results/`, `testbed/logs/`, and before 25 Nov 2026
`deploy/deucalion/results/` or `experiments/reverse-tunnel/results/`) and the sources that justify the
decision, so a design choice can be traced back to the problem that caused it.

Entries are kept as they were written: paths in them are those of their time. The restructure of
25 Nov 2026 (first entry) maps the old paths to the new ones, and the tag `before-restructure` holds
them (`git show before-restructure:<path>`).

Terms: **split** = interLink 0.6.1 with the split executor (Argo's `init` and `wait` on the login
node, only `main` in the Slurm job). **reverse** = interLink 0.6.3 with the reverse tunnel of its
SSH shadow (the whole pod in the Slurm job). **Testbed** = `testbed/`, a small copy of Deucalion on
three Lima VMs. Since 24 Nov 2026 `main` has only `reverse`; entries below that one describe both.

---

## 2026-11-25 (afternoon): the testbed on `proctrack/cgroup`; the image mirror reaches public.ecr.aws and ESA's GitLab

**Context.** CNES sent a stress-test pipeline (`lisa-sgs/sys/testing/mockpipelines`,
`workflows/stress-pipeline.yaml`). Its ingest and dispatch come from their runner's `common-templates`
(`lisa-sgs/sys/components/pipelinerunner`), which always runs a private image,
`gitlab.esa.int:4567/lisa-sgs/sys/sandbox/global-index/hdf5-reference-scanner:0.16.0`, and the pipeline
itself names `public.ecr.aws/docker/library/alpine:latest`. The user chose to fetch both through the
image mirror, with a token of theirs, and to rehearse on the testbed first.

**What changed.**
- **The testbed's Slurm uses `proctrack/cgroup`** (`testbed/guest/cn.sh`, and applied to the running
  VMs), as Deucalion does. Under `proctrack/linuxproc` a finished job's relay could outlive the job and
  hold the mirror's fixed address, which is how TC05 failed with the mirror (24 Nov). The testbed was
  thus unable to run any multi-pod workflow with the mirror; the user agreed to the change.
- **The mirror** (`runner/cluster/image-mirror.yaml`):
  - a rule for `public.ecr.aws` (anonymous pulls);
  - a rule for one private registry, `MIRROR_PRIVATE_REGISTRY` (default `gitlab.esa.int:4567`), with
    credentials from the Secret `image-mirror-credentials`, filled from `MIRROR_PRIVATE_USER` and
    `MIRROR_PRIVATE_TOKEN` (a personal access token with only `read_registry`). The token stays in the
    cluster and never reaches the login node; `make evidence` also checks that it is not in the evidence;
  - its images are named without the port (`gitlab.esa.int/<path>:<tag>`): behind the mirror's own
    address (`127.77.0.1:5000/<name>`) a second `host:port` cannot be part of an image name. CNES's
    templates take that prefix from their `platform-config-map` (`registry_sys`), so this stays platform
    configuration;
  - a hash of the configuration and the credentials on the pod template, so a change restarts zot by
    itself (it reads both at start). This replaces the restart `mirror on` did by comparing the
    ConfigMap.
- **`settings/testbed.env.example`:** `IMAGE_MIRROR=on`, now that the testbed meets the mirror's
  conditions. `settings/deucalion.env.example` keeps it `off` until the mirror has run on Deucalion.
- **TC13** (`tests/13-private-image/`): a plain workflow naming
  `gitlab.esa.int/lisa-sgs/sys/sandbox/global-index/hdf5-reference-scanner:0.16.0`, the scanner CNES's
  ingest runs, and asking it for its help. It shows the private image fetched with the token and run on
  the compute node. A new feature, `private-registry` (the mirror and a token), so `make test` skips it
  without them.

**Costs and open points.**
- The token is a personal one: it acts as the user, and anyone with cluster-admin on the cluster can read
  the Secret. Hence `read_registry` only, and an expiry. A deploy token of the project would be better,
  if CNES or ESA can issue one.
- The private registry's image is pulled by Singularity on the compute node, through the tunnel, like any
  other with the mirror: the same first-pull cost.

**Evidence.**
- Testbed, the property itself: a job that leaves `setsid sleep 333` behind and exits (job 504): after the
  job, no `sleep 333` is left on `cn`.
- Testbed, `make testbed-test T="00 05 12"` with the mirror (run interrupted by the end of a working
  session during TC12): TC00 passed (1m35s) and **TC05 passed** (5m56s, its three parallel steps one
  after the other on `cn`, each with its own whole node), the test that failed under
  `proctrack/linuxproc`.
- Testbed, `make testbed-test T="12 13"` with the mirror and the user's token (run `20261125-125806`):
  - **TC12 passed** (1m55s): `busybox:1.37` from Docker Hub through the mirror.
  - **TC13 failed, for a reason of the testbed's.** The token works: zot logged in to
    `gitlab.esa.int:4567` and synced the scanner image ("successfully synced image", 13:01:31), and the
    job's Singularity fetched it through the tunnel. It then stopped: `no child with platform
    linux/arm64 in index`. The image is built for `linux/amd64` only (its index, read from the mirror),
    and the testbed's compute node is an Apple Silicon VM (`aarch64`). A known constraint, not a defect
    (the user: "it really isn't a problem but a constraint"): an image must exist for the compute
    node's architecture, as for Deucalion's ARM partitions. Now in `docs/architecture.md`, known limits.
  - **A finding:** with `main`'s image unusable, the pod did not fail. It stayed Running (2/2), because
    Argo's `wait` container waits for `main`, which never started; the test would have waited for its
    30-minute timeout. Stopped by hand (`spec.shutdown: Stop`). In `docs/open-problems.md`.
  - **A mistake in TC13, found by the run:** its `expect.yaml` checked a step `scanner`, but with a
    single template as the entrypoint Argo names the pod after the workflow, so no step name can match.
    The check is gone, and `lisa test` now refuses such a test (a new check in `suite.py`, with a unit
    test).
- `make unit`: 147 passed (new: the mirror's rules, its credentials, the restart on a change; TC13 in
  the tests of the tests; step checks only on DAG or steps entrypoints).
- The image's location and tags: GitLab's API for project `lisa-sgs/sys/sandbox/global-index` (read with
  a `read_api` token the user lent for the search; `0.16.0` exists).

---

## 2026-11-25 (late morning): the restructured code on Deucalion; Deucalion meets the image mirror's conditions

**What happened.** On Ulisses, after `make results` and `make restore` with the old code:
`make setup` (with the `UV_LINK_MODE=copy` fix; interLink rebuilt into `~/lisa-runner`, a few minutes),
`make check`, `make up`, `make test`.

**Results.**
- **All 11 tests pass** with the restructured code (run `20261125-114031`; TC12 skipped without the
  mirror). Every step pod a Slurm job in `normal-x86`, on nine nodes (`cnx019`, `cnx027`, `cnx046`,
  `cnx061`, `cnx076`, `cnx151`, `cnx395`, `cnx415`, `cnx425`). Each test took within a minute of the bash
  version's run of the same morning (`20261125-013956`); the queue varies.
- **`make check` on Deucalion:** `ProctrackType proctrack/cgroup`, and partition `normal-x86`
  `OverSubscribe=EXCLUSIVE`: every job gets a whole node anyway. So the image mirror's two conditions
  hold there: a job's relay ends with the job, and its `--exclusive` costs nothing extra.

**Evidence.** On Ulisses: `~/PipelineRunner/results/20261125-114031/` (`report.md`, `where.tsv`), and the
check's output in `~/PipelineRunner/results/check-*.txt`.

---

## 2026-11-25 (morning): uv copies packages instead of cloning them (Ulisses)

**Problem.** The first `make setup` of the restructured code on Ulisses stopped before `lisa` ran: uv
could not put the build dependencies into the environment.
```
Failed to install: editables-0.6-py3-none-any.whl (editables==0.6)
Failed to clone `~/.cache/uv/archive-v0/.../editables/redirector.py` to `~/.cache/uv/builds-v0/...`
Resource temporarily unavailable (os error 11)
```
uv fills an environment by cloning or hard-linking files from its cache, and Ulisses's home file system
refuses that. The testbed (ext4) and the Mac did not, so the rehearsal could not catch it.

**What changed.** The `Makefile` exports `UV_LINK_MODE=copy` (unless already set), so uv copies the
files. Every `make` target runs uv through the Makefile, so this covers them all.

**Costs.** The environment takes its full size on disk (`.venv`, about 100 MB) instead of sharing files
with uv's cache, and the first install is a little slower.

**Evidence.** On the Mac, `UV_LINK_MODE=copy uv sync --frozen --reinstall` rebuilt the environment and
the project; `make unit`: 137 passed. On Ulisses: to be confirmed by the next `make setup`.

---

## 2026-11-25: the project restructure: `runner/`, `cli/lisa` in Python, `settings/`, a folder per test, five documents

**Problem.** The user's words: it was "super difficult to actually understand what is the pipeline
runner, what is config, what is for Ulisses". In detail:
- **No line between the runner and its tooling.** Everything that gets installed (interLink's two
  configuration files, the plugin's `SlurmConfig.yaml`, the systemd unit, Argo's `workflowDefaults`, the
  MinIO and Global Storage manifests, the artifact repository) was written by heredocs inside
  `k8s-side.sh` (937 lines) and `hpc-side.sh` (341 lines). The only way to see what the runner *is* was
  to read 1,300 lines of bash.
- **No single entry point:** two Makefiles (the root one for the testbed, `deploy/deucalion`'s for the
  real site), two scripts, and `run.py`, which called back into `k8s-side.sh`.
- **The Python was bash in Python:** `run.py` drove `argo`, `kubectl` and `mc` as commands and parsed
  their output, and one 70-line function did everything for a test.
- **Folders kept for history:** `experiments/reverse-tunnel/` (the first trial, finished),
  `setup/hpc/` (one wrapper), `tests/datasets/users/...` (10 files, 8 of them empty placeholders, 2 for
  the unported TC08).
- **Twelve Markdown files** repeating each other, already drifting: links to `APPROACH.md` and
  `CHANGELOG.md` at the root after they moved to `docs/`; a `diagrams.py` and PDFs the CHANGELOG
  mentioned and the repository did not have; `NEXT_STEPS.md` calling pushed tags local; and
  `deucalion.env.example` setting `IMAGE_MIRROR=on` while the docs said off.
- **Tests that were hard to trust:** a PASS meant whatever `checks.py` checked, and nothing showed that a
  check could fail.

**Decisions** (the user's, in the session of 25 Nov): what the runner is (below); Python for the Kubernetes side; Mermaid for the
diagrams for now (to be redrawn by hand for the thesis); the testbed left as it is ("it's for local test
only, if it works it works"), only its pointers into `deploy/deucalion` changed; the subPath patch not
proposed upstream yet; shared Argo and identity left for last; and this CHANGELOG kept whole, as the
thesis's record of the process.

**What the runner is.** Asked what they would hand CNES if they asked for it ("the whole python
solution? probably not because that is ran on ulisses"), the user agreed on this definition, now at the
top of the README: the runner is not a new program but a deployment architecture, Argo and interLink
0.6.3 configured so that each step runs as a Slurm job on an offline partition and reaches back through
the reverse tunnel. What a site gets is its configuration and one wrapper (`runner/`), the requirements
on the site, an acceptance suite (`tests/`) and the documentation. `cli/` is how we deploy it on
Ulisses as one user without root, run the suite and collect evidence; a site would deploy `runner/` its
own way (in the cluster, as Deployments: open problems, next steps).

**What changed.**
- **`runner/`: what the runner is.** Every file that gets installed, as a real file with its why in a
  comment, filled in from the settings with `${name}` placeholders: `runner/cluster/` (interLink's
  configuration and the shadows' credentials, `workflow-defaults.yaml`, `artifact-repository.yaml`,
  `global-storage/` for an endpoint outside the cluster, `image-mirror.yaml`) and `runner/hpc/`
  (`SlurmConfig.yaml`, `lisa-sidecar.service`, `resources.sh`, `subpath-fix/` with the wrapper and
  `upstream.patch`).
- **`cli/manifests/`: what the tool puts in the cluster for itself,** kept out of `runner/` because a
  site would not take them: the MinIO for trials (`GS_ENDPOINT=cluster`), the tests' namespace with
  Argo's executor role, and the probe pod of `make up`.
- **`cli/lisa`: how it is put in place, in Python** (3.11, Ulisses's own; dependencies pinned in
  `uv.lock` and brought by `uv`, which `make` fetches into `~/lisa-runner/bin` without root):
  - `adapters/`, the only code that talks to the outside: the Kubernetes API (the official client; Argo's
    Workflows as API objects, server-side apply), S3 (`boto3`), the login node over SSH (`paramiko`,
    host keys pinned on first contact and checked strictly after), HTTP, local processes;
  - `components/`, one per part of the runner (argo, offload, artifacts, global_storage, image_mirror,
    interlink, tunnel, sidecar);
  - `commands/` (lifecycle, inspect, test, evidence) and `testing/` (suite, expect, runner, report);
  - every module under about 200 lines.
- **`cli/hpc.sh`: the login node's part, still bash** (the login node has no Python), 240 lines. It no
  longer writes any configuration: `lisa` fills in the plugin's files from the settings and from what
  the login node reports (where Slurm's commands are, the CPU architecture), and copies them to
  `HPC_PROJECT_ROOT/runner`; `hpc.sh install` puts them in place.
- **The login node's layout:** `HPC_PROJECT_ROOT/{runner,sidecar,sock,images}` instead of `.interlink/`,
  `reverse-tunnel/` and `lisa-pipeline-runner_ze/`. The socket folder is shorter, so `HPC_PROJECT_ROOT`
  may now have up to 74 characters (59 before).
- **`settings/`:** `deucalion.env` and `testbed.env` (and their examples). `HPC_REPO_DIR` is gone;
  `IMAGE_MIRROR` defaults to `off` in the example too, and is called experimental there.
- **One entry point, the root `Makefile`:** `make settings/setup/check/up/test/evidence/restore` for a
  site, `make testbed-*` for the testbed, `make unit` and `make lint` for the tool itself. `up` and
  `check` copy the login node's files first, so a forgotten `make sync` can no longer leave the login
  node on old settings.
- **Tests: one folder each,** `tests/NN-name/` with `workflow.yaml` (plain Argo, unchanged but for its
  keys), `expect.yaml` (what it must produce, declared instead of coded) and `input/`. Each test reads and
  writes only under `tests/NN/` in the Global Storage (before: Isabel's `users/admin/test-NN/`,
  `users/system/test-NN/` and `t1/`). Before a run everything under `tests/` is deleted and the inputs
  uploaded.
- **Trusting a PASS:**
  - `report.md` per run: every check with what it expected and what it got, an artifact's actual
    content too, and each step pod's Slurm job, partition and compute node;
  - the terminal shows every check, not only failed ones;
  - `cli/tests/` (`make unit`, 137 tests, no cluster needed) proves that every test fails on a run that
    did nothing, on a run where Argo says Succeeded but nothing was written, on wrong content, and when a
    step ran off the virtual node, without a Slurm record or in another partition;
  - `lisa test` refuses to run a test that reads or checks keys outside its own prefix, or that checks
    one of its own inputs (it would pass without the workflow writing anything).
- **Docs:** `README.md` (what is where), `docs/architecture.md` (with Mermaid diagrams: what runs where,
  one pod's sequence, the data path, images, the tool), `docs/operations.md` (`RUN_ON_ULISSES.md`,
  `HOW_TO_RUN.md` and `deploy/deucalion/README.md` merged), `docs/results.md`, `docs/open-problems.md`
  (was `NEXT_STEPS.md`), and this CHANGELOG. The SVG diagrams are gone (in the tag).
- **Names:** `lisa-runner` instead of `deucalion-trial` (label `app.kubernetes.io/managed-by`), `lisa-*`
  instead of `trial-*` (`lisa-hpc-ssh-key`, `lisa-hpc-known-hosts`, `lisa-probe`), `~/lisa-runner`
  instead of `~/lisa-trial`. The split mode's leftovers (`SPLIT_ENV`, `REVERSE_IL_VERSION`,
  `split-gs-creds`, the `split-trial` label) are gone.
- **`Ulisses tutorials.pdf`** (Isabel's access guide) removed from the repository by the user.
- **Fixed on the way:** `tunnel off` deleted every Service labelled as ours in the namespace, which with an
  external Global Storage included the image mirror's; now only the Global Storage's Service and
  EndpointSlice, by name.

**Old path → new path.**

| Before | Now |
|---|---|
| `deploy/deucalion/k8s-side.sh` | `cli/lisa/` (Python), with the configuration it wrote in `runner/cluster/` |
| `deploy/deucalion/hpc-side.sh` | `cli/hpc.sh`, with the configuration it wrote in `runner/hpc/` |
| `deploy/deucalion/Makefile`, root `Makefile` | root `Makefile` (`make <target>`, `make testbed-<target>`) |
| `deploy/deucalion/{deucalion,testbed}.env.example` | `settings/` |
| `deploy/deucalion/image-mirror.yaml` | `runner/cluster/image-mirror.yaml` |
| the MinIO, the namespace role and the probe pod, as heredocs in `k8s-side.sh` | `cli/manifests/` |
| `deploy/deucalion/results/` | `results/` |
| `setup/hpc/subpath-fix/` | `runner/hpc/subpath-fix/` |
| `experiments/reverse-tunnel/upstream/0001-...patch` | `runner/hpc/subpath-fix/upstream.patch` |
| `experiments/reverse-tunnel/` (README, local results) | tag `before-restructure`; the results in `~/Documents/Dissertation/evidence/reverse-tunnel-experiment/` |
| `tests/argo-native/NN-name.yaml`, `checks.py`, `run.py` | `tests/NN-name/{workflow,expect}.yaml`, `cli/lisa/testing/` |
| `tests/datasets/users/...` | `tests/NN-name/input/` |
| `RUN_ON_ULISSES.md`, `HOW_TO_RUN.md`, `deploy/deucalion/README.md` | `docs/operations.md` |
| `docs/APPROACH.md` | `docs/architecture.md`, `docs/results.md` |
| `docs/NEXT_STEPS.md` | `docs/open-problems.md` |
| `~/lisa-trial` (Ulisses) | `~/lisa-runner` |

**Costs and open points.**
- **More lines in all:** 2,570 lines of Python (the tool) and 240 of bash (`hpc.sh`), plus the
  templates and 306 lines of the tool's own tests, against 1,624 lines of bash and Python before
  (`k8s-side.sh`, `hpc-side.sh`, `run.py`, `checks.py`). In exchange, each part can be read on its own,
  and the tool has tests of its own.
- **Dependencies:** `kubernetes`, `boto3`, `paramiko`, `PyYAML` and `uv`, fetched from PyPI and GitHub
  (Ulisses reaches both). Before: the standard library, `kubectl`, `jq`, `argo` and `mc`.
- **A one-time move on Ulisses and Deucalion** (`docs/operations.md`, section 5): restore with the old
  code, then set up again. interLink is rebuilt into `~/lisa-runner`. `lisa` refuses to start while the
  old version's state says it is on.
- **Not yet run on Deucalion** at the time of this entry; the bash version's full run of the same day is
  in the evidence below. The testbed rehearsal ran before the three manifests moved to `cli/manifests/`:
  that move changed only paths, which the unit tests check (every template the code names exists and
  fills in), but it has not been run against a cluster since.
- **The layout is a working base, not the final one.** The user, on committing it: "I'm still not the
  biggest fan of the folder structure but if it works we can work upwards". Later changes to the layout
  get their own entries here.

**Evidence.**
- `make unit`: 137 passed; `make lint`: ruff clean.
- Deucalion, the same day, with the bash scripts (`before-restructure`), run `20261125-013956`: all 11
  tests pass (TC12 skipped without the mirror), 22 step pods, all Slurm jobs in `normal-x86` on
  `cnx017`, `cnx066`, `cnx067`, `cnx074` and `cnx331`. The first Deucalion run of the full suite, and of
  TC11 on a real offline node. Evidence collected on Ulisses in
  `~/PipelineRunner/deploy/deucalion/results/20261125-013956/`.
- Testbed, the restructured code, as the trial user without root: `make testbed-init` (setup) and
  `make testbed-test T="00 11"`, run `20261125-022949`: TC00 3/3, TC11 3/3 (Slurm jobs 499 and 500,
  partition `arm`, node `cn`). Then, on the same testbed: `make testbed A=status`, `A=evidence` (the
  binaries' `vcs.revision` is the tag's commit `6b0203b0`; the plugin's sha256 matches the release's
  published checksum), `A=check` (every check PASS; the probe shows the compute node offline, and
  `srun --overlap` works), and `A=restore` (the virtual node, the credentials and every copy deleted,
  `workflowDefaults` and `artifact-repositories` put back).

---

## 2026-11-24 (late night): any image, through an image mirror in the cluster; the diagrams

**Problem.** The biggest limit left (APPROACH.md, section 5): compute nodes cannot pull images, so
every image a pod names had to be listed in `IMAGES` and built beforehand on the login node. A
workflow could not name any image it likes.

**Options considered.**
- **Pull on demand on the login node,** from our `sbatch` wrapper. Rejected: it grows the one wrapper
  we want to remove. This belongs in the plugin: a pull at submission with an image cache and a pull
  policy, the job held (`sbatch --hold`) until the pull ends. Proposed in NEXT_STEPS.md.
- **Pull through the tunnel,** from a mirror in the cluster. Chosen: it needs no change to interLink
  or the plugin, only their configuration.

**What we found first.** interLink resolves the tunnel's names only inside the containers (it binds a
hosts file into them). Singularity pulls a `docker://` image before the container exists, in the
job's shell, where those names do not resolve. The relay's address is derived per pod from its UID
(`reverseBindAddress` in interLink's `shadow_ssh_reverse.go`), so it is not known in advance either.
interLink's annotation `interlink.eu/reverse-bind` fixes it; the plugin's `ImagePrefix` (or the
per-pod annotation `slurm-job.vk.io/image-root`) then names the mirror as `docker://<address>:5000/`.
The tunnel is ready before Singularity starts: the job's pre-exec waits for it.

**First design, then changed.** The first version had each workflow opt in with three pod
annotations (run `20261124-214141`). As the user pointed out, that defeats the purpose: the scientist
would have to change the workflow. So it became platform configuration:
- **The plugin** (`hpc-side.sh install`): `ImagePrefix: docker://127.77.0.1:5000/` and `--no-https`.
- **Argo's `workflowDefaults`** (`offload on`): every pod's relay at `127.77.0.1`, and `--exclusive`
  in the Slurm flags, so that two pods never share a node and its address.
- **The mirror:** zot (`deploy/deucalion/image-mirror.yaml`), started by `make up`. One rule per
  registry (`quay.io/…`, `ghcr.io/…`, `docker.io/…`), and a last one for bare names, which go to Docker
  Hub as Kubernetes reads them (`alpine:3.20` is `library/alpine`). So workflows keep their image names.
- **Setting:** `IMAGE_MIRROR=on|off` (default `off`; `on` in `deucalion.env.example`). With `on`,
  `hpc images` builds nothing. `make mirror` / `make mirror-off`; `make restore` leaves the mirror.
- **TC12:** a plain workflow naming `busybox:1.37`, which nobody built. `make test` (all) skips it
  without the mirror (`checks.NEEDS`, `run.py --feature`).
- **Checks:** `mirror on` must fetch Argo's executor image and `alpine:3.20`; `make check` looks for
  `--no-https`, shows the partition's `OverSubscribe`, and the compute-node probe shows the CPUs and
  the process limit in a job (Singularity's `mksquashfs` may start one thread per CPU).

**What the testbed showed.** With the mirror as default (`20261124-215423`), TC00 and TC12 passed
with the image caches emptied first: the mirror served `alpine` and `busybox` from Docker Hub and the
executor from quay.io, and the jobs converted them (`Creating SIF file`). TC05 failed: one of its
three steps found `127.77.0.1:9000` taken. `--exclusive` worked (Slurm ran the three jobs one after
the other), but the step started on the node right after the previous job ended, and that job's relay
was still there. The testbed's Slurm tracks processes with `proctrack/linuxproc`, which loses the
relay: the job starts it in the background, and it is reparented when the job's shell ends.
`proctrack/cgroup` ends everything in the job's cgroup. So `make check` now fails with the mirror on
unless `ProctrackType` is `proctrack/cgroup`, and the testbed keeps `IMAGE_MIRROR=off`.

**Costs.**
- Every pod asks for a whole node. Deucalion's parallel steps already landed on separate nodes
  (`20261124-011219-reverse`: TC05 on `cnx043`, `cnx427`, `cnx497` at once), which suggests whole
  nodes anyway, but this is not confirmed (`make check` shows `OverSubscribe`).
- It depends on Slurm's process tracking (above). Deucalion's is not known yet.
- Each new image is converted on the compute node, inside the job, once (`$HOME/.singularity`).
- The mirror keeps its images in an `emptyDir`; Docker Hub limits anonymous pulls, and the mirror
  fetches each image only once.
- Not yet run on Deucalion.

**What would remove the fixed address** (and `--exclusive` and the process-tracking requirement):
interLink setting the image prefix to each pod's own relay address, which it already computes. A
small change in the virtual kubelet; to propose (NEXT_STEPS.md).

**Evidence.**
- `20261124-212245`: TC12 by hand (opt-in annotations), the mirror applied by hand: relay at
  `127.77.0.1`, `Creating SIF file`, the mirror's log serving the executor and `busybox`.
- `20261124-214141`: `make test TESTS="00 05 12"`, the mirror started by `make up`, opt-in TC12: 3/3.
- `20261124-215423`: the mirror as default: TC00 and TC12 pass, TC05 fails as described.
- `20261125-010233`: `IMAGE_MIRROR=off` again (images built beforehand): TC00 passes, so the default
  path is unchanged. An earlier attempt (`20261124-220655`) failed while the Mac slept: the VMs' clocks
  jumped (`Clock change detected` at 22:25 and 22:40, Munge's `Expired credential`), and `init`
  failed (status 64). Not a fault of the change; worth knowing for long testbed runs.

**Also in this change.**
- **`docs/diagrams/`:** four diagrams in the style of Isabel's deployment views (her Fig. 6.1, 6.2):
  deployment, submission (numbered), communication (the tunnel and interLink's calls), images. Drawn
  by `diagrams.py` (standard library), with a PDF of each for LaTeX.
- **`run.py`:** a command whose output is not JSON no longer stops the run (found with stand-in
  commands).

---

## 2026-11-24 (night): the tests are run and checked in Python, and check where each step ran

**Decision.** The loop that submits the test workflows, records them and checks their results moves
from `k8s-side.sh` to Python: `tests/argo-native/run.py`, with the checks in
`tests/argo-native/checks.py` instead of `checks.tsv`. The tests themselves stay plain Argo
workflows.
- **Why:**
  - The loop was about 65 lines of bash that parsed JSON with `jq` and TSV with `awk`. A bug of
    that kind had already slipped into a run's summary: in `20261124-014246-reverse` the columns were
    shifted ("Slurm partitions: cn; compute nodes: COMPLETED").
  - A check could only be one of three fixed kinds, read from a table. In Python a check is a
    function of the test's result, so it can look at anything the run recorded.
  - It also takes about 50 lines out of `k8s-side.sh`, which the cleanup of the scripts asks for
    (NEXT_STEPS.md).
- **Why the standard library only, and not pytest:** Ulisses has `python3` but we cannot install
  packages system-wide, and the run must keep working with nothing but `make test`. `run.py` and
  `checks.py` need Python 3.6 or newer, and `argo`, `kubectl` and `mc` do the talking, as before.
- **Why bash still starts it:** the checks before a run (both sides up, the artifact repository,
  offload with the tunnel), `reset-data` and the configuration snapshot use the script's own
  functions and settings. `test` does those, then hands over with `exec python3 run.py`. `run.py`
  calls back two commands of the script: `slurm-jobs` (Slurm's record, over SSH to the login node)
  and `diag`.

**What changed:**
- **A new check in every test** (`EVERY_TEST`): each step pod was on the virtual node, and Slurm has
  a job for it in `SLURM_PARTITION`. Before, `where.tsv` only recorded this. Now a test fails if a
  step ran on Ulisses, or if Argo says `Succeeded` but Slurm never ran the job. TC00 has 3 checks
  instead of 2, and so on.
- **`make test` fails unless every test passed.** Before, it always ended with status 0.
- **A test without checks of its own fails**, as before; so does a missing workflow file or a failed
  submission, which before were skipped without a line in the summary.
- **Ctrl-C** stops the workflow that was running (`argo stop`) and exits with 130. Before, it was
  left running until `make clean`.
- **`summary.txt`** gets a line `passed: <n> of <m> tests` before the `where:` line, which stays
  last. Every other file of a run keeps its name and format, so `make evidence` is unchanged.
- **`make check`** looks for `python3` on Ulisses.

**Costs.**
- Two languages on Ulisses instead of one. The login node still has no Python, so `hpc-side.sh`
  stays bash.
- `run.py` is 212 lines and `checks.py` 104, against about 65 lines of bash and a 37-line table.
  Most of the difference is comments and the new check.
- The new where check depends on `squeue`/`sacct` answering over SSH right after the workflow ends.
  It did in every testbed run since `where.tsv` exists (`20261124-014246-reverse` on), and Deucalion
  keeps accounting (`sacct` works there). A site without accounting would fail it once `squeue`
  forgets the job.

**Evidence.**
- Offline, with stand-in `argo`, `kubectl` and `mc` commands: a passing test, a failed object check,
  a pod off the virtual node, a pod in another partition, a missing workflow file, the exit status,
  and Ctrl-C (workflow stopped, status 130).
- Testbed, as the trial user, run `20261124-204746` (root `make test TESTS="00 02 11"`): TC00 3/3,
  TC02 4/4 (ends `Failed` on purpose; its failing step is Slurm job 479, `FAILED`, and still passes
  the where check), TC11 3/3, `passed: 3 of 3 tests`, `make` exit status 0. Four step pods, Slurm
  jobs 478 to 481 on partition `arm`, node `cn`. Then `make check` (`found python3`), `make evidence`
  on that run, and `make restore`.

---

## 2026-11-24 (evening): `main` keeps only interLink 0.6.3 and the reverse tunnel; two tags

**Decision.** We go with interLink 0.6.3 and its reverse tunnel. It is the only approach left on
`main`; the split executor lives on in a tag.
- **Why now:** it has run on Deucalion's `normal-x86` (TC00 to TC05, `20261124-011219-reverse`). The
  evidence shows that every step ran on the compute nodes behind the tunnel (entries below).
- **Why not keep both:** keeping `split` working beside it cost about half of every script.
  - `mode`/`enable`/`disable` with backups and a mode file on each side;
  - three wrappers and a relay;
  - two interLink and two plugin versions;
  - a second testbed runner and tests T0/T1.

  Every change had to be made and tested twice. The thesis can compare the two from the tags and from
  the results already recorded, without `main` carrying both.

**Tags** (annotated, local until pushed with `git push origin main --tags`):

| Tag | Commit | What |
|---|---|---|
| `split-interlink-0.6.1` | `108d868` | the last commit with both modes. The first state with `split` only is `9f3cbb2` |
| `reverse-interlink-0.6.3` | this commit | `reverse` only |

**What was removed from `main`** (all of it is in `split-interlink-0.6.1`):
- **The split executor:** `setup/hpc/split-executor/` (the `sbatch`, `squeue` and `scancel`
  wrappers, and the API relay with its binaries).
- **Isabel's original setup and tests, as copied into this fork:**
  - `setup/kubernetes/`, `setup/global_storage/`, and `setup/hpc/{1-bridge,2-data,main,cleanup}.sh`
    with their README and `.env.example`;
  - `tests/workflows/`;
  - `docs/img/` (her diagrams).

  The testbed never used these copies: it installs `ulisses` from her own repository (`LPR_DIR`).
  The tests in `tests/argo-native/` are their plain-Argo versions.
- **The testbed's own tests and runners:**
  - T0 (her workflows, three network modes) and T1 (the split executor): `cmd_t0`, `cmd_t1` and
    `guest/t0-*.sh`, `guest/t1-*.sh`, `guest/split-*.sh`;
  - `testbed/makefile`, which the root `Makefile` had replaced;
  - the experiment's runner, `experiments/reverse-tunnel/run.sh` and `guest/`. It worked by switching
    the testbed's installation of Isabel's prototype (0.6.1) to 0.6.3 with drop-ins and backups, and
    it called T1's scripts.
- **From `deploy/deucalion`:**
  - the `split` mode and the settings it needed (`SPLIT_API`, `RELAY_API_PORT`, `RELAY_CTL_PORT`,
    `SPLIT_IL_VERSION`);
  - the mode switching itself: `mode`, `api reverse|split|off`, `hpc enable|disable`, the
    `SlurmConfig.yaml.pre-*` backups and the systemd drop-in that ran plugin 0.6.3;
  - `relay-health` and `relay-log`.

In all, 78 files changed: 6396 lines deleted and 1077 added, most of the added lines in the docs.
- `k8s-side.sh`: 1011 to 930 lines, with the new `up`/`down` and evidence code.
- `hpc-side.sh`: 490 to 315.
- `testbed/testbed`: 893 to 590.

**What changed in how it runs:**
- **`make up` / `make down`** replace `make reverse` / `make split`.
  - `up` runs offload off, `hpc install`, `hpc images`, `install` (if missing), `tunnel on`,
    `artifacts` and offload on. Every step can be repeated.
  - `down` runs offload off, then `tunnel off`, which is the old `api off`.
  - `restore` is unchanged in effect.
- **`hpc-side.sh install` writes the plugin's whole configuration from the settings every time**, and
  the user unit runs plugin `IL_VERSION` directly.
  - It restarts the sidecar only if the configuration, the unit or the binary changed (compared with
    `cmp`).
  - It removes the old drop-in folder, so a login node set up before today comes over cleanly.
  - *Why:* with one mode there is nothing to switch, so no backup to restore. Writing the whole file
    from the settings also means a change in `deucalion.env` always reaches the sidecar.
  - *Cost:* a `SlurmConfig.yaml` edited by hand on the login node is overwritten.
- **State.** Each side is now just `on` or `off`. Ulisses is `on` while `~/lisa-trial/state/mode`
  exists (it holds `up <version>`); the login node is `on` while the sidecar runs with its
  configuration. `make test` refuses to run unless both are on and offload asks for the tunnel.
- **Settings:**
  - `IL_VERSION=0.6.3`. An old `deucalion.env` still works: `REVERSE_IL_VERSION` is read when
    `IL_VERSION` is missing, and the split settings are ignored.
  - New `EXTRA_FORWARDS`, for services besides the Global Storage and the API that every pod may
    reach through the tunnel, e.g. a message bus.
  - The variable naming the settings file is `TRIAL_ENV`, with `SPLIT_ENV` still read.
- **Names:**
  - test workflows carry `lisa-test=true` (was `split-trial=true`; `clean` deletes both);
  - the Global Storage keys' Secret is `lisa-gs-creds` (`artifacts` deletes the old `split-gs-creds`);
  - result folders are `results/<time>/`, without the mode suffix.
- **Testbed: the same scripts as Deucalion.**
  - `make init` and `make test` at the repository root now run `deploy/deucalion` on the testbed,
    as a user without root, through the new `testbed trial` command. Its `setup` creates the user
    with `guest/trial-user.sh`, copies the repository without settings files, results or git, and
    runs `make setup`; `trial make <target>` runs any target.
  - `make trial T=<target>` exposes it.
  - *Why:* before, the testbed ran 0.6.3 through the experiment's own runner, a second
    implementation of the same configuration that had already drifted from `deploy/deucalion`. Now a
    rehearsal on the testbed is a run of exactly what goes to Deucalion.
  - *Cost:* the testbed no longer tests Isabel's prototype itself. Her installation stays only as the
    base cluster, as on Ulisses.

**Fixed along the way.** `k8s-side.sh sync` reported "copy of the settings failed" whenever the
Global Storage was outside the cluster, although the settings had been written.
- **Cause:** the group that writes them ended with `[ "$GS_IN_CLUSTER" = true ] && printf ...`, which
  returns 1 when the test is false, and `pipefail` made that the pipeline's status.
- **Since when:** 23 Nov (`4903ab5`, the in-cluster MinIO), so the tag has it too. Every run since
  then used `GS_ENDPOINT=cluster`, which hid it. It would have stopped `make setup` on Deucalion with
  Isabel's MinIO.
- **Found by:** the testbed's `make init`, whose `testbed.env` points at the testbed's MinIO outside
  the cluster. Now an `if`.

**What it costs:**
- **No fallback on `main`.** If a site forbids `srun --overlap`, or has no `python3` or `sshd` on its
  compute nodes, the reverse tunnel cannot run there. The split executor needed only SSH to the login
  node; it is in the tag and would have to be brought back.
- **No faster option on `main`.** `split` took about 30 s for a short step on the testbed, against
  about 1.5 min with the tunnel.
- **T0 cannot be rerun from `main`.** T0 showed why Isabel's design cannot move data on an offline
  node; it can still be rerun from the tag.

**Evidence** (testbed):
- **Run `20261124-172438`,** as the trial user, with `GS_ENDPOINT=cluster`: `make sync`, `setup`,
  `check`, `up`, `test T="00 11"`, `evidence`, `restore` and `minio-off`, all with the new scripts.
  - TC00 passed in 1m47s and TC11 in 2m08s, 2/2 checks each, on node `cn`, partition `arm`.
  - `logs.txt`: "reverse tunnel ready after 80s" (84 s for TC11) in `init`, `main` and `wait`.
  - `make evidence`: `vcs.revision=6b0203b0e92b…` for both interLink binaries, and the plugin's sha256
    equal to the one published with release 0.6.3 (`interlink-sidecar-slurm_Linux_arm64`).
  - After `restore`, only Isabel's `interlink-node` was left. The five job folders of the trial were
    empty (plugin 0.6.3's DeletePod panic: entry "a Global Storage inside the cluster", 24 Nov).
- **Root entry point, run `20261124-173403`:** `make init`, `make test TESTS=00` and
  `make trial T=restore`, from the repository root.
  - The settings were the VM's old `testbed.env` from 23 Nov: the testbed's MinIO outside the
    cluster, and the split settings still in the file.
  - `make init` first stopped at `sync` (the bug above); with the fix, setup and `up` went through.
  - TC00 passed in 1m36s, 2/2 checks, on `cn`.
  - `restore` ended with Ulisses `off`, the sidecar inactive, the virtual node and the SSH key's
    copies deleted, and the saved artifact repository put back.
  - So the new root targets work, old settings files still work, and the `sync` fix holds for a
    Global Storage outside the cluster.

---

## 2026-11-24 (later): container logs from the virtual node; evidence of the first Deucalion run

**Context.** In the first Deucalion run every `logs.txt` held only an error:
`Get "https://10.227.63.27:5830/containerLogs/...": remote error: tls: internal error`.
- **Cause:** the virtual kubelet asks for its serving certificate with a CSR (signer
  `kubernetes.io/kubelet-serving`) and "will wait indefinitely for approval" (its log).
- **Why nothing approves it:** a kubeadm cluster does not approve such requests by itself.
  `kubectl get csr` showed it `Pending` for 15 h on Ulisses, and likewise on the testbed.
- **Consequence:** the API server could not fetch any container's log from the virtual node, so
  `kubectl logs` and `argo logs` failed. Isabel's units had the same behaviour.

**What changed** (`deploy/deucalion/k8s-side.sh`):
- **After the virtual kubelet starts, `mode` approves its CSR.** Only a request named `vk-<node>-`,
  for the kubelet-serving signer, made by the identity of the kubeconfig in use
  (`kubectl auth whoami`), and not yet decided. `restore` deletes our node's CSRs.
- **The runner fetches each step's log with `kubectl logs --all-containers --prefix`.** *Why not
  `argo logs`:* it asks for timestamps, which the virtual kubelet does not give, and reports every
  line as a parse error. The first try after the fix showed that.

**Evidence of the CSR fix (testbed).** The request was `Approved,Issued`. Container logs came back
instead of the TLS error (`20261124-162209-reverse`), and `restore` left no CSR of the node.

With `kubectl logs`, run `20261124-162554-reverse` (TC00 and TC11 pass) has every container's own
output in `logs.txt`:
- in each of `init`, `main` and `wait`: `interLink: reverse tunnel ready after 68s` (72 s for
  TC11);
- TC00's step: `[t1] main on lima-tb-cn`;
- TC11's step: `node: lima-tb-cn` and `internet: blocked`.

So from now on each run's own logs show that every container ran on the compute node behind the
tunnel.

**Evidence of the first Deucalion run.** Run `20261124-011219-reverse` was collected with
`make evidence` (on 24 Nov, from a temporary copy of the scripts on Ulisses). A copy is kept
outside this repository, in `Dissertation/evidence/deucalion/`. The bundle's secret scan was clean.
- **interLink 0.6.3:** its binaries' `vcs.revision` is `6b0203b0e92b…`, the commit of the tag
  `0.6.3`. The virtual kubelet config has `Network.EnableTunnel: true`, `ShadowMode: ssh`, and
  `Reverse` enabled with `NodeExec: srun`, `Sshd: userspace` and login host `ln01`.
- **Slurm plugin:** the sha256 of the 0.6.1 and 0.6.3 binaries on `ln01` equal the checksums
  published with those releases. SingularityCE 4.3.2, Slurm 23.11.8.
- **The tunnel, for TC00's pod** (UID `b3b3151b…`):
  - the virtual kubelet logged "shadow infrastructure for `lisa-jcosta/native-00-artifacts-m766l`";
  - the sidecar created its socket folder `reverse-tunnel/sock/b3b3151bf5bd`;
  - Slurm ran it as job 2265675 on `cnx043`, `normal-x86`.
- **Every step of TC00 to TC06** appears in Slurm's record with its partition and node (entry
  below).

The job folders, with each job's own output (`job.out`, "reverse tunnel ready"), were already
deleted by `clean`. And no `logs.txt` had content, because of the certificate problem above.

---

## 2026-11-24 (later): `make evidence`; interLink's logs made private

**Why.** We needed to show which versions ran, with which configuration, and that `reverse`
really used the tunnel, from records rather than from memory. The obvious answer was to copy
interLink's logs, but a scan of the testbed's logs (`/tmp` scripts, 24 Nov) found:
- **`il-api.log`:** the Global Storage secret keys, base64-encoded, 5 and 6 times for the two keys
  used. With verbose logging, interLink logs the Secrets it passes to the sidecar.
- **`il-vk.log` and `il-api.log`:** 12 service-account tokens (JWTs) each.
- **Not found:** the SSH private key (base64 of `BEGIN OPENSSH PRIVATE KEY`) in either log, and in
  the sidecar's log on the login node, no key value (plain or base64) and no token.
- **Exposure:** the logs were `-rw-rw-r--` in a `drwxr-xr-x` `~/lisa-trial`. Only the home
  folder's mode (`drwx------` on Ulisses and on the testbed) kept other users out.

**What changed** (`deploy/deucalion/`):
- **`k8s-side.sh` runs with `umask 077`,** and makes `TRIAL_HOME` and its logs private
  (`700`/`600`) on every call.
- **`make evidence [RUN=<run>]`** (`k8s-side.sh evidence`, `hpc-side.sh evidence`) collects into
  `results/<run>/evidence/`:
  - the configuration of both sides;
  - versions: sha256 of every binary, Go's build info (module, `vcs.revision`) next to the tag's
    commit from GitHub, and the plugin's sha256 next to the release's published `checksums.txt`;
  - Slurm's record of the jobs (`sacct`, else `squeue`);
  - the lines of interLink's and the sidecar's logs in the run's time window (UTC).

  Every Secret's `data` and every token is blanked. The folder is then searched for the Global
  Storage keys (plain and base64) and for tokens, and deleted if anything is found.
- **`make test` snapshots both sides' configuration into `results/<run>/config/` when a run
  starts.** *Why:* `evidence` collected after `restore` sees the plain configuration again, not
  the one the run used.

**Evidence (testbed, run `20261124-014246-reverse`).**
- **interLink:** the binaries' `vcs.revision` equals the tag's commit (0.6.1 `b49984c0…`, 0.6.3
  `6b0203b0…`, the latter built here).
- **Slurm plugin:** the binaries' sha256 equal the published checksums of releases 0.6.1 and 0.6.3.
- **Reverse tunnel:** the virtual kubelet config has `Network.EnableTunnel: true`,
  `ShadowMode: ssh`, `Reverse.Enabled: true`, `NodeExec: srun`, `Sshd: userspace`, and its log of
  the run names the shadow pods 44 times.
- **Secret scan of the bundle:** no key (plain or base64), no token.

---

## 2026-11-24 (later): evidence of where every step runs (`where.tsv`, TC11)

**Why.** The claim is "plain Argo workflows run on offline compute nodes". Up to now that rested on
two facts kept apart: `probe-compute` showed that a node of the partition reaches nothing, and the
tests passed. Nothing tied a test's steps to the nodes they ran on, or showed from inside a step's
container that it has no network.

**Evidence for run `20261124-011219-reverse` on Deucalion, gathered by hand.**
- **Pods to jobs:** each step pod became a Slurm job named after the pod's UID. Slurm accounting
  (`sacct`) is enabled on Deucalion, and interLink's logs on Ulisses map UIDs to pod names.
- **All on `normal-x86`:**
  - TC00 on `cnx036` and `cnx043`;
  - TC01, TC03 and TC04 on `cnx043`;
  - TC02 on `cnx043` and `cnx427`; the step that reads a missing file is the job in state `FAILED`,
    as the test intends;
  - TC05's three parallel writes started within 9 s of each other on `cnx043`, `cnx427` and
    `cnx497`, so steps of one workflow already run in parallel on several nodes, and its aggregation
    ran on `cnx043`;
  - TC06 started on `cnx043` and was `CANCELLED` by `make clean`.
- **No network on that partition:** a node of the same partition reached nothing
  (`probe-compute`, `cnx420`).

**What changed.**
- **`where.tsv` in every run folder.** After each test, `make test` records the test's pods (name,
  UID, Kubernetes node) and asks Slurm for the jobs named after those UIDs: `squeue -t all`, which
  keeps finished jobs for a few minutes, then `sacct` where accounting exists. The result is one row
  per step pod with the Slurm job, partition, compute node and state. `summary.txt` ends with the
  partitions and nodes.
- **TC11 (`tests/argo-native/11-no-internet.yaml`).**
  - The step records its node, then tries TCP connections to `1.1.1.1:443`, `8.8.8.8:53`,
    `9.9.9.9:443`, `quay.io:443` and `github.com:443` from inside its container, and records
    whether DNS resolves.
  - The record goes to the Global Storage as an output artifact, and the test passes only if no
    connection opened.
  - *Why TCP connections:* the first version used `wget` and reported "not reachable" in a testbed
    pod that does have internet. The pod reached `1.1.1.1`, but `wget` then failed on a redirect to
    a name that pod could not resolve. `nc -z -w 5` tests the connection itself: in that pod it
    opened to all three IP addresses (`internet: OPEN`), and it failed after 5 s to an unroutable
    address.

**Evidence (testbed, `reverse`, `20261124-014246-reverse`).**
- TC00 and TC11 passed.
- TC11's record in the Global Storage: node `lima-tb-cn`, DNS cannot resolve, nothing reachable,
  `internet: blocked`.
- `where.tsv` showed both steps as Slurm jobs 469 and 470 on partition `arm`, node `cn`, found
  through `squeue` (the testbed has no accounting).
- The summary line read the wrong columns; fixed after the run.

**Still ours in `reverse`: the subPath fix.** Checked on 24 Nov:
- the Slurm plugin's latest release is still 0.6.3;
- `main` (last commit `c96b4291`, 21 Nov) still binds a whole emptyDir and ignores `subPath`. Its
  only `subPath` handling, from #61 (June 2025), is for ConfigMaps and Secrets;
- no open issue or PR covers emptyDirs.

So the patch in `experiments/reverse-tunnel/upstream/` (9 lines and a unit test) is still needed
upstream.

---

## 2026-11-24: first plain Argo workflows on Deucalion; Ctrl-C stops `make test`

**Result.** The first runs on the real site, in `reverse` mode (interLink 0.6.3), on `normal-x86`:
- **Setup:** the jobs went from Ulisses to the login node `ln01` as `jcosta.up`. The images were
  built with the method of the entry below, and the Global Storage was the MinIO inside the
  cluster.
- **TC00 passed** (`20261124-010849-reverse`, 2 min 09 s).
- **A full run then passed TC00 to TC03** (`20261124-011219-reverse`): 2 min 16 s, 2 min 58 s,
  3 min 05 s (TC02 ends `Failed` on purpose) and 2 min 07 s. It was then interrupted.

Each time includes the queue of `normal-x86`.

**Bug: Ctrl-C did not stop `make test`.**
- **Cause:** the runner waits for each workflow with `timeout 1800 argo wait`. Without
  `--foreground`, GNU `timeout` runs in its own process group, which the terminal's SIGINT does not
  reach.
- **Effect:** bash got the signal, but there was no trap and its child did not die of SIGINT, so it
  went on to the next test.
- **Fix:** `timeout --foreground` and a trap that stops the run and says what is still running.
  Evidence, from a replica of the loop with job control (as in a terminal), with `sleep` standing in
  for `argo wait`:
  - without `--foreground`, the trap fired only after the current wait ended (19 s);
  - with it, at once (0 s, exit code 130).
- An interrupted run leaves the workflow already submitted running on the HPC side. `make clean`
  deletes it, and interLink then cancels its Slurm job.

---

## 2026-11-24 (later): images built without `singularity pull` on the login node

**Context.** The first `make reverse` on Deucalion stopped in `hpc images`. `singularity pull`
failed with `mksquashfs: FATAL ERROR: Failed to create thread`. Measured on `ln01`:
- 256 CPUs;
- `pids.max = 150` in the user's cgroup (`user.slice/user-<uid>.slice`);
- `mksquashfs procs = 0` in `/etc/singularity/singularity.conf`, so one thread per CPU.

So `mksquashfs` asks for 256 threads where 150 are allowed. `taskset` doesn't help: this
`mksquashfs` (4.3, 2014) counts every CPU on the machine.

**Alternatives measured on `ln01`** (scripts run as `jcosta.up`, results in this entry):
- **Unpacked sandbox written straight to `/home`:** works (alpine runs), but took 4 min 14 s for
  alpine. NFS is slow at creating many small files. The same sandbox takes 1 s to build in the
  local `/tmp`, and copying its 545 files to `/home` took 39 s.
- **Sandbox in the local `/tmp`, then our own `mksquashfs -processors 4` into one file on `/home`:**
  alpine took 2 s (3.4 MB), argoexec 11 s (64 MB, 1415 files).
  - Both run with `singularity exec --contain --no-eval`, as the plugin runs them. A plain
    squashfs file is an image format singularity accepts, like a SIF.

**What changed.** `hpc-side.sh images` uses the second method whenever `mksquashfs` is on the
`PATH`, and falls back to `singularity pull` otherwise. The temporary files, including
singularity's cache, live in a folder under the local `/tmp` that is removed afterwards.

**Risk for `split` on Deucalion.** The same 150-process limit covers everything the user runs on
the login node:
- the sidecar;
- the relay;
- in `split`, `init` and `wait` of every running pod, each a singularity process with Go threads.

Several parallel steps may hit it. Not measured yet.

**Evidence (testbed).** The image folder was emptied first, so that `make reverse` had to rebuild
the images with the new method (`/sbin/mksquashfs` is on the `PATH` there):
- **Images:** alpine and argoexec came out as single files, 3.9 MB and 61 MB. `file` identifies
  them as `Squashfs filesystem ... version 4.0`. Nothing was left in `/tmp`.
- **TC00 passed with the plugin running these images** (`20261124-005749-reverse`, 1 min 31 s),
  against the MinIO inside the cluster.

---

## 2026-11-24: a Global Storage inside the cluster; `sync` sends only what the login node needs

**Context.** Isabel's MinIO did not answer from anywhere (entry below), which blocks both modes. The
site checks showed that Deucalion has everything `reverse` needs. In `reverse` only Ulisses has to
reach the Global Storage, since the jobs reach it through the tunnel.

**What changed** (`deploy/deucalion/`):
- **`GS_ENDPOINT=cluster` and `k8s-side.sh minio on|off`** (`make minio`, and `make setup` when
  that setting is on):
  - a MinIO Deployment `lisa-minio` in `ARGO_NAMESPACE` behind the Service `GS_SERVICE`;
  - its root credentials are `GS_ACCESS_KEY`/`GS_SECRET_KEY`, kept in a Secret;
  - its data is in an `emptyDir` of at most 20 Gi;
  - the image is `pgsty/minio` at a fixed release.

  Design choices:
  - Ulisses reaches it at the Service's cluster IP, resolved at every run, and the jobs of
    `reverse` under the Service's name through the tunnel, as for an external endpoint.
  - The selector-less Service that `gs_service` would create is skipped, because the MinIO's own
    Service already has that name.
  - `check` now fails `split` with this setting, since the login node cannot reach the cluster.

  *Why these choices:*
  - The `pgsty` fork is used because MinIO stopped publishing free images in October 2025. The
    testbed already ran it with the same arguments (`server /data --console-address :9001`).
  - The data goes in an `emptyDir` because the cluster has no StorageClass, and the tests put back
    their own data before every run anyway.
  - Nothing is exposed outside the cluster.

  *Cost:* the Global Storage now lives on the same machine as Kubernetes, unlike the architecture
  it stands in for. Its data disappears when the pod restarts. It's a stand-in for testing
  `reverse`, not a design decision about where LISA's data lives.
- **`sync` copies only `deploy/deucalion` and `setup/hpc` (29 files), and no settings file except
  its own stripped copy.**
  - On Ulisses, the runbook's `mv deucalion.env deucalion.env.old` had created a second settings
    file, with the keys. `sync` copied it to the login node because it excluded only the current
    file by name.
  - All `*.env*` files are now excluded, and any left over on the login node are removed.
- **`hpc-side.sh check` fails on a full file system** (the entry below has the evidence).
- **`minio on` waits until the Service answers.** In the first try, the pod was ready but its
  Service refused connections for a moment, because kube-proxy had not routed it yet. The
  following `mc` step failed on that.
- **`clean` waits until no pod is left on the virtual node.** *Why:* `make restore` and
  `make clean split` stop interLink right after `clean`. In the first try that came before interLink
  had deleted the pod, and its job folder, with keys and tokens, stayed on the login node.

**Evidence** (testbed, as the non-root user, `GS_ENDPOINT=cluster`, `testbed-cluster.env`):
- **First try:** `make minio`, `sync`, `reverse` and TC00 passed (`20261123-234554-reverse`,
  1 min 43 s). `check` failed `split` with the intended message. `restore` and `minio-off` cleaned
  up, but one job folder was left, which led to the `clean` change.
- **Second try**, with both fixes: the MinIO answered at once, and TC00 passed
  (`20261123-234928-reverse`, 1 min 49 s). `clean` reported no pod left.
- **An empty job folder still remained.** The Slurm plugin 0.6.3's DeletePod handler panics: a nil
  pointer in `deleteContainer`, at `prepare.go:1482` in the release binary, once per delete call.
  - Go's HTTP server recovers the panic per request, so the sidecar keeps running and the pod is
    deleted. The folder's contents (keys, tokens) were gone; only the empty directory stayed.
  - The tag `0.6.3`'s source has a guard for exactly this case. Its `deleteContainer` says that
    "dereferencing the nil `*JidStruct` panics the whole request handler", and it sits at line
    1829, not 1482. So the published binary appears to be built from an earlier commit than the
    tag. That is an inference from the line numbers.
  - *Open:* build the plugin from its tag, as is done for interLink, and report the mismatch
    upstream.

---

## 2026-11-23 (later): first `make setup` on Ulisses; fail fast instead of hanging

**What happened** on the first run on Ulisses:
- **Ulisses side:** `make setup` installed Argo, fetched `argo` and `mc`, and built interLink 0.6.3.
- **Sidecar:** did not start, because `deucalion.env` had `HPC_PROJECT_ROOT=HPC_PROJECT_ROOT=/projects/...`. The value was therefore a relative path: `sync` copied the repository into a folder literally named `HPC_PROJECT_ROOT=` in the home of `jcosta.up`, and the sidecar's unit had a relative `ExecStart`, which systemd refuses.
- **Linger:** Deucalion does not allow it (`loginctl enable-linger` is refused), as anticipated.
- **`make check` hung.** Isabel's MinIO (`68.221.216.246:9000`) did not answer from Ulisses or from the login node (HTTP 000 from both). `mc alias set` keeps retrying for minutes when nothing answers.

**What changed** (`deploy/deucalion/`):
- **`gs()` checks the endpoint first.** It asks the endpoint's health URL with `curl -m 8` and gives `mc alias set` 30 s. `check` reports a `FAIL` with the cause, and `artifacts`, `reset-data` and `test` stop instead of hanging. *Why:* a hang gives no information; the first run on the real site lost time to it.
- **`HPC_PROJECT_ROOT` must be an absolute path:**
  - `check` fails on it;
  - `sync` and `hpc-side.sh install` refuse it.

  *Why:* a relative value silently scatters files into the login node's home folder.

**Evidence.**
- **Testbed, bad settings** (`GS_ENDPOINT` pointing at a dead address and `HPC_PROJECT_ROOT=HPC_PROJECT_ROOT=/x`): `check`, `sync` and `reset-data` all stopped with those messages within 18 s in total.
- **Testbed, correct settings:** `reset-data` and the bucket check still pass.

**Open:** the Global Storage is unreachable. Nothing can run until Isabel's MinIO answers again (or another reachable S3 endpoint is configured).

**First `make check` on the real site** (`results/check-*.txt` and `results/probe-compute.txt` on Ulisses). Evidence for the assumptions both modes make:

- **Ulisses:** everything passes with the account `jcosta` and no sudo: cluster-admin, Argo installed, both interLink versions, SSH to the login node, the API certificate valid for 10.227.63.27 and for `kubernetes.default.svc.cluster.local`.
- **Login node (`ln01`), as `jcosta.up`:**
  - the sidecar runs as a user service; linger is not allowed;
  - SingularityCE 4.3.2 has `--no-eval` and `--contain`;
  - `sbatch --hold` is accepted;
  - `squeue --me` works;
  - the Kubernetes API is not reachable from the login node, so `split` needs the relay.
- **Compute node** (`cnx412`, `normal-x86`):
  - every URL fails, including the Global Storage and the API: no outbound connections;
  - it can resolve names (`quay.io`), so DNS works but connections don't;
  - the shared folder is visible;
  - `python3` is 3.6.8, the minimum the reverse tunnel's job relay needs;
  - `/usr/sbin/sshd` exists;
  - `srun --overlap` into the job works.

  **So everything `reverse` needs from the site is there.**
- **`/projects` is full:** 9.8T of 9.8T used, the HPCvLAB group alone 8.1T. `/home` (NFS) has room: a 20 GB quota per user, and 22T free in total.
  - *Change:* `hpc-side.sh check` now fails when less than 1 GB is free under `HPC_PROJECT_ROOT`. Before, it printed the free space as `INFO`, and `0 free of 9.8T` was easy to miss.
  - *Decision:* `HPC_PROJECT_ROOT` moves to `/home/jcosta.up/lisa`. It is private, unlike the shared folder, which also keeps the job folders' keys and tokens away from the group.

---

## 2026-11-23: run the trial with your own accounts, no root

**Context.** The first attempt on Ulisses (18 Nov) could not start: the scripts assumed root on
Ulisses, but the account `jcosta` has no sudo. In the 19 Nov meeting Isabel explained that she had
taken her cluster down: it still had old IPs and was broken (transcript 00:04:42–00:06:09). Her
email afterwards: a new bare Kubernetes cluster on Ulisses, without Argo or interLink, with
cluster-admin for José and Gustavo through ServiceAccounts, "so that you can install and configure
those components according to the tests you want to run … without needing sudo access". Checked on
23 Nov: Kubernetes 1.35, a single node `ulisses` (x86_64, Debian 12) without the control-plane
taint, `kubectl auth can-i '*' '*'` = yes. There was no Argo, no interLink and no MinIO, and no
`go`, `argo` or `mc`. The real kubelet uses port 10250. Linger is off for `jcosta`, and enabling
it needs root.

**What changed** (`deploy/deucalion/`):

- **interLink on Ulisses runs as your own processes instead of root's systemd units.**
  - Three processes: the SSH tunnel to the sidecar, the interLink API and the virtual kubelet.
    Each runs in its own session (`setsid`) and is restarted 5 s after it exits.
  - Everything lives in `TRIAL_HOME` (default `~/lisa-trial`): binaries per version, generated
    configs, logs, PID files, saved state.
  - *Why:* no sudo, and Isabel's units no longer exist. systemd user services were rejected
    because, without linger, they stop when the last session ends.
- **Configs are generated, not patched.**
  - Each mode writes `InterLinkConfig.yaml` and `VirtualKubeletConfig.yaml` from the settings,
    starting from Isabel's (`setup/kubernetes/3-bridge.sh`) with our paths.
  - Removed: the systemd drop-ins, the `.pre-split`/`.pre-reverse` backups of the virtual kubelet's
    config, and `/var/lib/split-executor`.
  - *Why:* with our own installation there is nobody else's configuration to preserve, so a
    backup-and-restore scheme only adds failure modes.
- **One virtual node, namespace and set of ports per person.** `INTERLINK_NODE_NAME`,
  `ARGO_NAMESPACE`, `TUNNEL_PORT`, `VK_PORT` and the shadow's credential namespace (the node's
  name) are settings. *Why:* the cluster is shared with Gustavo.
- **The virtual kubelet listens on `VK_PORT` (5830) and gets `POD_IP`.**
  - Its default is 5820 (`KUBELET_PORT` in interLink's `cmd/virtual-kubelet/main.go`), and 10250 is
    the real kubelet's.
  - `POD_IP` is the address the API server uses to reach it for logs. Isabel's units set neither,
    so the node had no InternalIP.
- **`k8s-side.sh argo` installs Argo `ARGO_VERSION` (v3.7.12) in namespace `argo`**, only if the
  cluster has none.
  - It prepares `ARGO_NAMESPACE` with Isabel's `argo-workflow-role` for its `default` service
    account (`setup/kubernetes/2-argo.sh`). Argo's executor needs that role to write
    `workflowtaskresults`.
  - Isabel's Dex/SSO setup is left out: the tests use the CLI, not the web UI.
- **`k8s-side.sh install` puts both interLink versions in `TRIAL_HOME`.**
  - 0.6.1 from its release binaries (x86_64 and arm64 exist).
  - 0.6.3 built from its tag with the Go version its `go.mod` names, downloaded into
    `TRIAL_HOME`. The 0.6.3 release has no binaries; checked again on 23 Nov through the GitHub
    API.
  - The shadow image is no longer pre-pulled with `crictl`, which needs root. The kubelet pulls it
    for the probe pod.
- **`k8s-side.sh tools` fetches `argo` and `mc` into `TRIAL_HOME/bin`.** The script puts that folder
  first in its own `PATH`. Moved out of the Makefile.
- **The kubeconfig drives the Ulisses side.** `K8S_API_HOST`/`K8S_API_PORT` default to its server,
  and the cluster CA (for the relay agent and the address check) comes from it, not from
  `/etc/kubernetes/pki`. *Why:* a non-root user may not read `/etc/kubernetes`, and the kubeconfig
  is what Isabel provides.
- **Deucalion: our own sidecar** (`hpc-side.sh install`, `uninstall`).
  - The Slurm plugin 0.6.1 runs as the user service `SIDECAR_UNIT` (`lisa-sidecar`) on
    `SIDECAR_PORT` (4100). Linger is enabled if the site allows it.
  - Its `SlurmConfig.yaml` is Isabel's (`setup/hpc/1-bridge.sh`) without her data wrapper
    (`CommandPrefix`) and without the bind of her system data. Both belonged to her prototype only,
    and the bind would fail where that folder doesn't exist.
  - *Why:* her sidecar runs under her account, and a login node is shared: another sidecar may
    already use the unit name `interlink-sidecar` and port 4000.
  - `enable`/`disable` keep working as before, now on top of this base configuration.
- **`k8s-side.sh sync` copies the repository to the login node, then the settings without
  `GS_ACCESS_KEY`/`GS_SECRET_KEY`.** *Why:* `hpc-side.sh` never uses them, and Isabel suggested
  putting the files in the HPCvLAB shared folder (meeting, 00:07:17), which others can read.
- **`restore` now ends with nothing of ours running.**
  - It switches offload off, disables the login node's mode, stops and removes the sidecar service
    (`hpc-side.sh uninstall`), stops interLink here and deletes the virtual node.
  - Argo and `TRIAL_HOME` stay, because they're expensive to recreate and harmless.
- **`k8s-side.sh check` tests the new assumptions:**
  - settings that are empty;
  - cluster-admin;
  - ports in use;
  - a node of the same name that our virtual kubelet doesn't run;
  - the API server's certificate, read with `openssl s_client` instead of
    `/etc/kubernetes/pki/apiserver.crt`.
- **The Makefile is a thin wrapper:** every target calls `k8s-side.sh`. New targets: `setup` (once)
  and `sync`. `results` writes `~/results.tgz`, since no sudo is involved any more.

**Costs and open points.**

- **Reboots.** The processes on Ulisses don't survive a reboot: run `make reverse` or `make split`
  again.
- **Sessions on the login node.** Without linger there, the sidecar runs only while you have a
  session. The tunnel from Ulisses is one, and an enabled unit starts again with the next session.
- **Shared Argo.** Argo's `workflowDefaults` are global, so coordinate offload with anyone else
  using the same Argo.
- **Shared folder.** If `HPC_PROJECT_ROOT` is in the HPCvLAB shared folder, job folders (artifact
  keys, service-account tokens) are readable by the folder's members while a pod runs.

**Evidence.** Rehearsed on the testbed on 23 Nov, next to the testbed's own root installation,
which stayed untouched: its node `interlink-node` stayed Ready and its units active. The user had
no root on tb-ulisses but a cluster-admin ServiceAccount token, like `jcosta` on Ulisses
(`testbed/guest/trial-user.sh`), and ran as `lisa` on tb-login.

- **`make setup`**: 1 min 35 s, including the 0.6.3 build. Argo was already there and was not
  touched.
- **`make check`**: everything passed on both sides and on the compute node (Python 3.9, sshd,
  `srun --overlap`).
- **`make reverse`**: 1 min 23 s. The virtual node `interlink-jcosta` was Ready next to the
  testbed's own, and the probe pod reached the login node's sshd.
- **Tests:** TC00 passed (`20261123-225317-reverse`, 1 min 22 s). A full run then passed TC00 to
  TC03 (`20261123-225447-reverse`) before it was stopped on purpose, to move on to Ulisses.
- **`make restore`** left nothing running:
  - offload off;
  - login node in mode `none`, the sidecar stopped and its service removed, no job folders;
  - interLink stopped, the virtual node and the shadow credentials deleted.

`split` was not rehearsed with these scripts. Its parts that changed are the relay processes on
Ulisses and the generated virtual kubelet config for the relay.

The rehearsal found two bugs, fixed before the commit:
1. The login node no longer received the API address, now that it comes from the kubeconfig.
   `sync` now appends it.
2. A missing mode file printed an error.

---

## 2026-11-19: meeting with Deucalion (António Sousa); not a code change

Recorded because it changes what the code must assume. Sources: `transcript.shareable.txt`,
Gustavo's summary and Isabel's options document (*Conectividade dos nós de computação no
Deucalion*), all outside this repository.

- **Production partitions have no outbound connections at all** (`normal-x86`, `normal-arm`,
  `large-arm`, GPU). Only `dev-x86` and `dev-arm` have internet (00:45:51).
- **António's first choice is a per-user `ssh -R`**, to be tested by his team. A firewall exception
  is the last resort (00:46:07–00:51:05).
- **`ssh -L` into a running job's node through the login node works** (00:52:48–00:55:30).
- **There are no transfer nodes**, and the outbound IPs are stable (00:58:34–00:59:29).
- **Isabel's concerns about `split`** (00:04:42, 00:34:42): the `sbatch` rewrite, the pre-pulled
  images and the exchange through the shared file system. Her preferred option is a relay on the
  login node combined with `ssh -R` or an exposed API.
- **Her document doesn't cover `reverse`.** It notes that interLink's SSH mode (PR 550) goes from
  the cluster to the compute node only and doesn't consider 0.6.3's reverse tunnel (PR #577). That
  tunnel is what `reverse` uses, and it needs no forwarding on the site's sshd.
- **The split of work between José's and Gustavo's theses is not defined yet** (00:40:57).

---

## 2026-11-18: runbook, Makefile; first attempt on Ulisses (blocked)

Commits `9cf4854`, `cd1cd25`, `ce382d0`.

- **`RUN_ON_ULISSES.md`**: the commands for the trial in one file. **`DIFFERENCES.md`**: a short
  comparison with Isabel's prototype. It was removed again in `cd1cd25`, together with adding
  Isabel's Ulisses access guide (`Ulisses tutorials.pdf`).
- **`k8s-side.sh check` verifies that the API server's certificate is valid for `K8S_API_HOST`.**
  *Why:* the access guide gives Ulisses as 10.227.63.27, while Isabel's `.env` had 10.227.208.123.
  `split` gives that address to offloaded containers and to the relay agent, so a wrong value fails
  late and obscurely. Tested on the testbed with a right and a wrong address.
- **Makefile** (`deploy/deucalion/Makefile`): one target per step. `make tools` fetched `argo` and
  `mc`, which Ulisses lacked.
  - `mc` comes from the pgsty fork, because `dl.min.io` answers HTTP 410: MinIO stopped
    distributing it. Isabel's `setup/hpc/2-data.sh` still downloads from that dead link.
- **The attempt on Ulisses failed** (no code change). `jcosta` has no sudo, and the scripts needed
  root:
  - Isabel's interLink units;
  - her root-only kubeconfig;
  - her Deucalion key in `/root/.ssh`.

  Moving the state folder to `$HOME` would only have moved the failure. That led to the 23 Nov
  rework above.
- **Deucalion login:** `Permission denied (publickey)` for a freshly uploaded key. Isabel: new keys
  take hours to be accepted (meeting, 00:03:45).
  - The portal only accepts RSA 4096 or Ed25519 keys. A 3072-bit RSA key, `ssh-keygen`'s default,
    is rejected.
  - Pasting a key with a trailing newline or comment was also rejected.

---

## 2026-11-17: `main` gets both modes, switched with one command

Commits `a15feaa`, `387ed49`, `082e994` (and `54d0db8` on the experiment branch).

- **`deploy/deucalion` runs either mode over Isabel's deployment.** `k8s-side.sh mode split|reverse`
  switches both sides in order: offload off, the login node, interLink, the artifact repository,
  offload on. *Why:* to test both modes in one session on Deucalion and compare them with the same
  tests.
  - interLink 0.6.3 ran through systemd drop-ins next to Isabel's units, and her configuration
    files were backed up, so her deployment stayed untouched and could be restored. Superseded on
    23 Nov.
- **Fix: Argo's `workflowDefaults` were not restored exactly.** Each offload on/off cycle added a
  newline; 19 had accumulated on the testbed. They are now saved as JSON, so "absent" and any value
  come back exactly.
- **Fix: `enable reverse` made its backup before the steps that can fail.** A failed attempt then
  left the login node looking switched on. The backup now comes last.
- **The testbed moved into this repository** (`testbed/`, `54d0db8`). Its paths were fixed in
  `387ed49`.
- **Experiment fixes before `reverse` passed** (`54d0db8`, runs `20261117-011154`, `-022804`,
  `-024031` in `experiments/reverse-tunnel/results/`):
  1. **The plugin refused a `SocketDirRoot` under `.interlink`:** no path element may start with a
     dot. The socket folder moved to `reverse-tunnel/sock`.
  2. **Pods stayed `Pending` for lack of capacity.** Plugin 0.6.3 reports the free memory it sees as
     the node's capacity, which fell to 200Mi, below one pod's request; TC05 stopped after 20
     minutes. A fixed capacity is now reported through `ResourceScriptPath`.
  3. **TC09 and TC10 failed.** The subPath fix now reads `ARGO_TEMPLATE` from whichever container's
     env file has it (`main`'s doesn't), and always hands Slurm a new `job.sh`. That avoids "Text
     file busy" when the compute node is also the NFS server.
- **Evidence:** `20261117-215316-reverse` (10/10 tests, 30/30 checks) and `20261117-222712-split`
  (10/10, 30/30), switched with one command each. Then TC00 and TC04 passed again after switching
  back (`20261117-224236-reverse`). Times per test are in `APPROACH.md`, section 7.3. Short steps
  take about 30 s in `split` and about 1.5 min in `reverse`, mostly waiting for the tunnel.
  - After `restore`, both configuration files were byte-identical to the originals (md5 compared).

---

## 2026-11-16: repository created; HPC side without Python; reverse-tunnel experiment

Commits `d508289`/`9345ad2` (first commit), `913c973`, `9f3cbb2`, `291733a`, `10ddb0f`.

- **This repository starts** as a fork of Isabel Moutinho's FEUP prototype: the split executor
  (`setup/hpc/split-executor/`), the API relay, the plain-Argo tests (`tests/argo-native/`), the
  Deucalion trial scripts and the documentation (`APPROACH.md`, `HOW_TO_RUN.md`).
- **The HPC side stopped needing Python and jq.** *Why:* nothing guarantees them on a login node,
  and every requirement is one more thing to ask the site for. Evidence: run `20261116-220707`, all
  tests passed through the Deucalion scripts with the testbed's settings.
- **The reverse-tunnel experiment** (`experiments/reverse-tunnel/`). *Why:* CNES doesn't want to
  maintain wrapper scripts.
  - interLink 0.6.3, released that day, adds a reverse tunnel to its SSH shadow (PR #577).
  - Plugin 0.6.3 adds a per-job socket folder (#166) and stops reporting failed jobs as successful
    (#169), the bug the `squeue` wrapper worked around.
  - One wrapper remains, `setup/hpc/subpath-fix/sbatch`, because the plugin still ignores `subPath`
    on emptyDir volumes, which Argo uses for every input artifact. The plugin patch to propose
    upstream is in `experiments/reverse-tunnel/upstream/`.

---

## Before this repository (October to mid-November 2026)

Recorded in `APPROACH.md`, sections 2 to 6, and in `testbed/logs/`.

- **The split executor.** *Why:* Deucalion's compute nodes have no network, while Argo's `init` and
  `wait` must reach the Global Storage and the Kubernetes API. Those two containers run on the
  login node, which has network, and only `main` runs in the Slurm job. They talk through the
  shared file system.
  - Three wrappers replace the `sbatch`, `squeue` and `scancel` that the sidecar calls. That is the
    only place the split can happen without forking Argo or interLink.
- **The API relay** (`split-relay`). *Why:* the login node cannot open connections to Ulisses,
  which is on a private FEUP network. The relay reverses the direction: Ulisses pulls the held API
  calls through an `ssh -L` tunnel it opens itself.
  - This works because Argo's executor makes only plain request-and-response calls, with no
    watches.
- **Plugin settings, each traced to a failure on the testbed:**
  - **`--no-eval`:** Apptainer otherwise evaluates environment values twice and corrupts
    `ARGO_TEMPLATE`.
  - **`--contain`:** each container gets its own `/tmp`, as in Kubernetes.
  - **`CommandPrefix: ""`:** switches Isabel's data wrapper off.
  - **`ImagePrefix`:** points at images pulled beforehand on the login node, because compute nodes
    cannot pull.
- **Offload through Argo's `workflowDefaults`.** *Why:* the workflows stay plain Argo and say
  nothing about the HPC side.
- **Evidence:** run `t1-20261018-005325` (18 Oct 2026), all tests passed with 30 of 30 checks on the
  testbed (`make test-t1`).
