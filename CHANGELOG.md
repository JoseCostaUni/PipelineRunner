# Changelog and decision log

What changed in this repository, **why**, what it cost, and the evidence for it. Newest first. Each
entry names the commits, the test runs (folders under `deploy/deucalion/results/`, `testbed/logs/` or
`experiments/reverse-tunnel/results/`) and the sources that justify the decision, so a design choice
can be traced back to the problem that caused it.

Terms: **split** = interLink 0.6.1 with the split executor (Argo's `init` and `wait` on the login
node, only `main` in the Slurm job). **reverse** = interLink 0.6.3 with the reverse tunnel of its
SSH shadow (the whole pod in the Slurm job). **Testbed** = `testbed/`, a small copy of Deucalion on
three Lima VMs.

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
