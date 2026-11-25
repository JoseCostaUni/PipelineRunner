# Open problems, and what to do next

Where the work stands, for the next working session. Updated 25 Nov 2026. The why of every past change
is in the [CHANGELOG](CHANGELOG.md).

## Where it stands

- **It works on Deucalion.** Plain Argo workflows ran on `normal-x86`, an offline partition, from
  Ulisses, as our own accounts: TC00 to TC05 passed (run `20261124-011219-reverse`; [results](results.md)).
- **Since that run, tested on the testbed only:** container logs, `where.tsv`, TC11, `make evidence`, the
  tests' checks of where each step ran, the image mirror, and the restructure of 25 Nov (`runner/`,
  `cli/lisa` in Python, `settings/`, one folder per test, these docs).
- **The restructured code has run on Deucalion:** all 11 tests passed (`20261125-114031`), as with the
  bash version the same morning.
- **Deucalion meets the image mirror's conditions:** `proctrack/cgroup`, and `normal-x86` gives whole
  nodes anyway (`OverSubscribe=EXCLUSIVE`), so the mirror's `--exclusive` costs nothing there.

## Next steps, in order

1. **The full suite on Deucalion with the image mirror.** TC00, TC05, TC12 and TC13 have passed with it
   (`20261125-132221`, `20261125-150457`); the rest have only run with images built beforehand. Then
   decide whether the mirror becomes the default in `settings/deucalion.env.example`.
2. **CNES's stress pipeline** (`mockpipelines/workflows/stress-pipeline.yaml`): TC20, branch
   `test/cnes-stress-test-pipeline`, ready for Deucalion (operations, section 4). It needs their
   `common-templates` (ingest and dispatch, in `lisa-sgs/sys/components/pipelinerunner`), their
   `artifact-repositories` keys and a `platform-config-map`, a GlobalStorage beside the LocalStorage
   (two bucket prefixes of our MinIO, as their single-node setup does), and the private image
   `gitlab.esa.int:4567/lisa-sgs/sys/sandbox/global-index/hdf5-reference-scanner:0.16.0`, which the
   mirror fetches with a `read_registry` token (`MIRROR_PRIVATE_*`). Testbed first, small parameters.
3. **The subPath wrapper,** the last piece of our code on the site. The patch is ready with a unit test
   (`runner/hpc/subpath-fix/upstream.patch`); the plugin's `main` still had the gap on 24 Nov 2026, and
   nobody had reported it. (a) An issue and a PR on `interlink-hq/interlink-slurm-plugin`, the right end
   state, citable in the thesis; (b) the plugin built from tag 0.6.3 with the patch, which removes the
   wrapper now but makes us maintain a build. Not now (decided 25 Nov).
4. **A per-pod image prefix, proposed to interLink.** With the mirror, every pod's relay takes one fixed
   address, hence `--exclusive` and the `proctrack/cgroup` requirement. interLink already derives a relay
   address per pod from its UID (`reverseBindAddress`): an annotation such as
   `interlink.eu/reverse-image-mirror: host:port` could add the forward and set
   `slurm-job.vk.io/image-root` to `docker://<that pod's address>:<port>/`. The alternative, in the
   plugin: pull on the login node at submission (an image cache, a pull policy, the job held until the
   pull ends).
5. **The plugin's DeletePod panic,** reported upstream or built from the tag. The 0.6.3 release binary
   panics on every pod deletion (a nil `*JidStruct`), which the tag's source already guards: the binary
   does not match its tag, and an empty job folder is left per pod.
6. **What the thesis needs measured:**
   - the tunnel's start-up on Deucalion (68 to 84 s per pod on the testbed), apart from the queue wait
     (`logs.txt`, `where.tsv`, `sacct`);
   - the throughput of the `srun` carrier with large artifacts (100 MB, 1 GB): a new test like TC03;
   - parallel pods against the login node's 150-process limit: each running pod holds an SSH session and
     an `srun` there. TC05's three parallel steps worked; find where it breaks.
7. **Package the Kubernetes side as a site would deploy it.** The runner is `runner/` (README). On Ulisses
   we put it in place as one user: interLink's API, virtual kubelet and SSH tunnel run as our own
   processes, which stop when Ulisses reboots. A site like CNES would rather install it as everything
   else: interLink running in the cluster as Deployments, with the tunnel to the sidecar as a container
   beside it, the configuration as a Helm chart or Kustomize overlay rendered from `runner/cluster/`.
   With cluster-admin this can run on Ulisses too. Check first whether interLink's own Helm chart
   carries 0.6.3's reverse-tunnel settings.
8. **A message bus through the tunnel** (offered, not built): NATS in `ARGO_NAMESPACE`,
   `EXTRA_FORWARDS="nats.<namespace>.svc.cluster.local:4222"`, and a test where `main` publishes while it
   runs. The capability the split executor could not give.

## Open issues

- **A pod whose image cannot be used does not fail.** When Singularity cannot fetch or convert `main`'s
  image in the job, the pod stays Running: Argo's `wait` container waits for `main`, which never
  started (TC13 on the testbed, 25 Nov). It only ends at the workflow's deadline. Options: an
  `activeDeadlineSeconds` in the offload's `workflowDefaults`, or the plugin reporting a container that
  never started; report it upstream to the Slurm plugin.

- **Shared Argo with Gustavo** (to tackle last). `workflowDefaults` are global, so while our offload is
  on every workflow of that Argo goes to Deucalion. Options: an Argo `instanceID` per person with our own
  controller (the cleanest), a namespaced controller for `lisa-jcosta`, or agreed times. Argo's CRDs are
  cluster-wide: talk to Gustavo first.
- **Identity, RQ4** (to tackle last). All jobs run as one Deucalion account, and job folders hold
  artifact keys and service-account tokens while a pod runs. TC08 (user isolation) is not ported.
- **The SSH key in Kubernetes.** The shadow logs in with a private key kept in a Secret, copied into every
  shadow namespace. Use a key for this only, and ask whether Deucalion can restrict it
  (`authorized_keys` options).
- **The thesis split with Gustavo** was left undefined at the 19 Nov meeting. This work is the
  architecture (plain Argo through interLink's reverse tunnel), with a measured comparison against the
  split executor. Agree on it explicitly.
- **Isabel's options document** (19 Nov) says interLink's SSH mode does not solve the return path. It
  predates 0.6.3's reverse tunnel, which does: worth showing Isabel the Deucalion evidence.
- **The Global Storage.** Isabel's MinIO (`68.221.216.246:9000`) was down on 23 Nov. Ours keeps its data
  in an `emptyDir`, lost when the pod restarts: for more than trials it needs a PersistentVolumeClaim, or
  hers.
- **The virtual kubelet's certificate request** is approved by us. Check whether Ulisses gets an
  approver, which would make this unnecessary.
- **Tests in parallel.** They run one after the other. They write to separate key prefixes, so they
  could run at once, but cap the number: each running pod holds an SSH session and an `srun` on the login
  node.
- **ARM partitions** were not tried: images are built on the x86 login nodes, so an ARM run needs ARM
  images built elsewhere (or the mirror) and the plugin's arm64 binary.
- **Housekeeping on Deucalion:** the old copy in `/projects/F202500007HPCVLABUPORTO/jcosta.up` (53 MB),
  the old folders of the bash scripts under `/home/jcosta.up/lisa`, and later `/home/jcosta.up/lisa`
  itself.

## Habits that worked

- **Every change gets a CHANGELOG entry** (newest first): what, why, what it cost, and the evidence (run
  folders, commits, sources).
- **Rehearse on the testbed before Deucalion:** `make testbed-init`, `make testbed-test T="00 11"`,
  `make testbed A=restore`. It runs exactly the Ulisses flow, as a user without root.
- **`make unit` before committing:** the tool's own tests, including that no test can pass on a run that
  did not do its work.
- **Gotchas:** `pkill -f <pattern>` kills your own shell if the pattern is in its command line; on the
  testbed, root cannot write in `lisa`'s NFS home (use `sudo -u lisa`); a Mac that sleeps during a
  testbed run makes the VMs' clocks jump and Munge refuse credentials.
