# subPath fix (the one wrapper still needed with interLink 0.6.3)

With interLink 0.6.3 and the reverse tunnel of its ssh shadow, the split executor is no longer
needed: the standard Argo executor runs on the compute node and reaches the Kubernetes API and the
Global Storage through the tunnel (`../../../experiments/reverse-tunnel/`). Of the three wrappers,
`squeue` is replaced by the plugin's own fix (0.6.3: "a job that ended in a failure state never
reports exit code 0") and `scancel` had nothing to do without the split.

One gap remains in the plugin (checked in 0.6.3, `pkg/slurm/prepare.go`, `mountData`): it ignores
`subPath` on emptyDir volumes. Argo mounts each input artifact into `main` (and `wait`, under
`/mainctrfs`) from the emptyDir `input-artifacts` with `subPath: <artifact name>`, so without this
fix the container finds a directory where it expects a file, and every workflow with an input
artifact fails.

| File | |
|---|---|
| `sbatch` | set as the plugin's `SbatchPath`; rewrites those binds in `job.sh`, then calls the real `sbatch` |
| `subpath-fix.conf.example` | copy to `subpath-fix.conf` if the real `sbatch` is not `/usr/bin/sbatch` |

The real fix is a few lines in the plugin (bind `<emptyDir>/<subPath>` when `SubPath` is set);
`upstream/` in the experiment folder has the patch to propose. Once it is merged and released, this
wrapper goes away and the plugin needs no wrapper at all.
