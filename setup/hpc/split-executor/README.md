# Split executor (proof of concept)

Runs Argo's `init` and `wait` containers on the HPC **login node** and only `main` on the compute
node, so standard Argo workflows with native artifacts work on compute nodes without network.
See `../../../APPROACH.md`.

No change to Argo or to interLink: three wrappers replace the Slurm commands the interLink Slurm
sidecar (0.6.1) calls, which it runs on the login node.

| File | SlurmConfig key | Does |
|---|---|---|
| `sbatch` | `SbatchPath` | splits job.sh, submits `main` on hold, starts `login.sh` (init -> release -> wait) |
| `squeue` | `SqueuePath` | keeps the pod running until `wait` is done; exit code `1:0` -> `1` |
| `scancel` | `ScancelPath` | also stops the login side |
| `split.conf` | | paths of the real Slurm commands |

Also needed: `--no-eval` in `SingularityDefaultOptions` (otherwise Apptainer evaluates every env
value a second time and corrupts Argo's `ARGO_TEMPLATE`), `CommandPrefix: ""` (no data wrapper),
and the virtual kubelet's
`KubernetesApiAddr`/`KubernetesApiPort` set to an API address the login node can reach (for `wait`).

Per job, in the job folder: `job.sh.orig` (as generated), `job.sh` (main only), `login.sh`,
`login.out`, `split.log`, and the markers `.split-released` and `.split-login-done`.

`api-relay/`: for a login node that cannot reach the Kubernetes API. `split-relay` runs the static
binary for the machine (`bin/split-relay-linux-{amd64,arm64}`, Go standard library, source in
`src/`, rebuilt by `build.sh`): `split-relay login` on the login node (HTTPS for `init`/`wait` +
control port), `split-relay agent` on the Kubernetes side (pulls through an `ssh -L` tunnel it
opens). `make-certs.sh` (openssl) makes the relay's CA, given to the pods by the virtual kubelet's
`KubernetesApiCaCrt`. See `../../../APPROACH.md`.

On the login node: bash, coreutils, grep, sed, awk, Slurm, Apptainer, `systemd-run --user` (or
`setsid`), openssl. No Python, no jq.
