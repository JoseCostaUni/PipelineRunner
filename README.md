# LISA Pipeline Runner

Plain Argo workflows, with native artifacts, running on HPC compute nodes that have no network. A
fork of Isabel Moutinho's FEUP prototype, for Deucalion through Ulisses.

**What the runner is.** Not a new program: a deployment architecture. Argo Workflows and interLink
0.6.3 (with its Slurm plugin) are configured so that each workflow step runs as a Slurm job on an
offline HPC partition and reaches the cluster back through interLink's reverse tunnel. The workflows
stay plain Argo, and neither tool is modified. Handing it to a site means handing over:
1. **the configuration** of both sides, and the one wrapper the Slurm plugin still needs (`runner/`);
2. **what the site must allow**: SSH to the login node, `srun --overlap`, `python3` and `sshd` on the
   compute nodes, Apptainer 1.1 or newer (what `make check` verifies);
3. **an acceptance suite** that proves a deployment works, and where each step ran (`tests/`);
4. **the documentation** (`docs/`).

`cli/` is not the runner. It is how we put the runner in place on Ulisses, as one user without root on
a shared cluster, how we run the acceptance suite, and how we collect the evidence for the thesis.

- **How:** interLink 0.6.3 offloads each Argo pod to Slurm. The reverse tunnel of its SSH shadow lets
  the whole pod (`init`, `main`, `wait`) run in one Slurm job on the compute node, and reach the Global
  Storage and the Kubernetes API back through the login node.
- **The one wrapper:** for a gap in the Slurm plugin (`subPath` on emptyDirs); a patch for the plugin is
  ready, after which nothing of ours runs on the site.
- **As whom:** your own accounts. A cluster-admin kubeconfig and no sudo on Ulisses, and a Slurm
  account on Deucalion.

Every test passed on Deucalion's offline `normal-x86` partition from Ulisses on 25 Nov 2026 ([results](docs/results.md)).

## What is where

```
runner/      WHAT the runner is: the files that get installed, nothing else
  cluster/     on the Kubernetes side: interLink's configuration and the tunnel's credentials, Argo's
               workflowDefaults (offload), the artifact repository, the Global Storage's Service name,
               the image mirror (optional)
  hpc/         on the login node: the Slurm plugin's configuration, its user service, the subPath fix
settings/    the values for one site: deucalion.env (Ulisses -> Deucalion), testbed.env
cli/         HOW it is put in place and tested
  lisa/        Python, runs on the Kubernetes side: fills in runner/ from the settings, applies it,
               starts interLink, runs and checks the tests, collects evidence
  hpc.sh       bash, runs on the login node (it has no Python): installs the sidecar, builds images, probes
  manifests/   what the tool puts in the cluster for itself: a MinIO for trials, the tests' namespace, a probe
tests/       the test workflows, one folder each: workflow.yaml (plain Argo), expect.yaml, input/
testbed/     a small copy of Deucalion on three Lima VMs, to rehearse locally
docs/        architecture, operations, results, open problems, and the CHANGELOG (the why of each change)
Makefile     the one entry point: `make` lists the targets
```

## Running it

On Ulisses, in this repository ([docs/operations.md](docs/operations.md) has every step and what it
changes):

```sh
make settings && vi settings/deucalion.env    # once
make setup && make check                      # once; fix every FAIL
make up && make test                          # then: make evidence
make restore                                  # everything off
```

On the Mac, the same on the testbed: `make testbed-init`, then `make testbed-test T="00 11"`.

## Read next

- [docs/architecture.md](docs/architecture.md): how it works, drawn, and its limits.
- [docs/operations.md](docs/operations.md): running it, on Ulisses and on the testbed, and what to do when something fails.
- [docs/results.md](docs/results.md): the runs so far, and the comparison with the earlier approach.
- [docs/open-problems.md](docs/open-problems.md): what is left to do.
- [docs/CHANGELOG.md](docs/CHANGELOG.md): every change, and why.

## Versions in git

| Tag | What it holds |
|---|---|
| `split-interlink-0.6.1` | The earlier approach, the split executor (interLink 0.6.1), beside the reverse tunnel; Isabel's original setup and tests as copied here |
| `reverse-interlink-0.6.3` | The reverse tunnel only, with the bash deploy scripts (`deploy/deucalion`) |
| `before-restructure` | The last commit before the restructure into `runner/`, `cli/`, `settings/` and `tests/NN-name/` |

`git show <tag>:<path>` shows an old file without leaving `main`.

## Credentials

No real keys are in this repository. The Global Storage keys live in `settings/<site>.env`, which git
ignores. They never go to the login node. `make evidence` blanks every secret in what it collects, then
checks that none is left.
