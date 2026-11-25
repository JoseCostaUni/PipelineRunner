# Results

The tests are TC00 (one step with an input and an output artifact), Isabel Moutinho's tests TC01 to TC10
rewritten as plain Argo workflows (TC08, user isolation, not ported), TC11 (no internet from inside a
step), TC12 (an image nobody built, with the image mirror) and TC13 (an image from ESA's private
registry, through the mirror with a registry token). Each is checked in Argo and in the Global
Storage, and for where it ran: every step pod a Slurm job in the partition.

The evidence of each run is in its folder (run IDs below): `results/` on the machine that ran it, and
copies under `~/Documents/Dissertation/evidence/`. The CHANGELOG entry of the same date says what each run
was for.

## Runs

| Run | Where | Version | Result |
|---|---|---|---|
| `20261117-011154`, `-022804`, `-024031` | testbed | first trial of interLink 0.6.3 | All tests pass across the three runs, after the experiment's fixes (`evidence/reverse-tunnel-experiment/`) |
| `20261117-215316-reverse` | testbed | bash scripts, both modes | All tests pass in one run, 30 of 30 checks |
| `20261124-011219-reverse` | **Deucalion**, `normal-x86` | bash scripts, both modes | TC00 to TC05 pass (stopped by hand during TC06). Every step a Slurm job on `cnx036`, `cnx043`, `cnx427` or `cnx497`; TC05's three parallel writes ran at the same time on three nodes |
| `20261124-162554-reverse` | testbed, user without root | bash scripts | TC00 and TC11 pass; every container logs `reverse tunnel ready after 68s` (72 s for TC11); TC11 records `internet: blocked` |
| `20261124-172438` | testbed, user without root | bash, 0.6.3 only | TC00 and TC11 pass; the whole flow (`setup`, `check`, `up`, `test`, `evidence`, `restore`) |
| `20261124-204746` | testbed | Python test runner | TC00 3/3, TC02 4/4 (fails on purpose, as expected), TC11 3/3 |
| `20261124-215423` | testbed | image mirror on | TC00 and TC12 pass; TC05 fails: a finished job's relay held the fixed address (`proctrack/linuxproc`) |
| `20261125-010233` | testbed | image mirror off again | TC00 passes |
| `20261125-013956` | **Deucalion**, `normal-x86` | bash scripts (`before-restructure`), mirror off | **All 11 tests pass** (TC00 to TC11; TC12 skipped without the mirror). 22 step pods, every one a Slurm job in `normal-x86`, on `cnx017`, `cnx066`, `cnx067`, `cnx074`, `cnx331`. TC11 passes on a real offline node. Evidence collected (`make evidence`) |
| `20261125-022949` | testbed, user without root | restructured (`cli/lisa`) | TC00 and TC11 pass; then `status`, `evidence`, `check` and `restore` |
| `20261125-114031` | **Deucalion**, `normal-x86` | restructured (`cli/lisa`), mirror off | **All 11 tests pass** (TC12 skipped without the mirror). Every step pod a Slurm job in `normal-x86`, on `cnx019`, `cnx027`, `cnx046`, `cnx061`, `cnx076`, `cnx151`, `cnx395`, `cnx415`, `cnx425`. Times close to the bash version's run above (each test within a minute of it; the queue varies) |
| `20261125-125806` and the run before it | testbed, `proctrack/cgroup` | image mirror on, with a registry token | TC00, **TC05** (failed under `proctrack/linuxproc`) and TC12 pass. TC13 fails on the testbed's architecture: ESA's scanner image was fetched with the token, but exists for `linux/amd64` only, and the testbed's compute node is `aarch64` |
| `20261125-132221` | **Deucalion**, `normal-x86` | image mirror on, with a registry token | **TC00, TC05 and TC12 pass with the mirror** (`cnx019`, `cnx148`, `cnx423`). TC13: ESA's image fetched with the token, then the job ran out of memory converting it (`ReqMem 256M`, `OUT_OF_MEMORY`), and hung until the 30-minute timeout. Fixed in the evening: with the mirror every job asks for its node's whole memory |
| `20261125-150457` | **Deucalion**, `normal-x86` | image mirror on, a registry token, jobs with their node's whole memory | **TC13 passes** (2m50s, `cnx080`): ESA's private scanner image, fetched by the mirror with the token, converted and run on the compute node |

## Time

Each pod waits for its tunnel before its containers start: the shadow pod starts, logs in, waits for the
job to run and starts the `sshd` in it. That took 68 to 84 s per pod on the testbed.
- **Testbed:** short tests take about 1.5 minutes.
- **Deucalion:** short tests took 2 to 3 minutes, including the queue of `normal-x86`. In the full run
  `20261125-013956`: one-step tests 2m08s to 2m38s; TC05 (three parallel steps, then one) 4m40s; TC06
  (120 s of CPU) 4m17s; TC09 and TC07 (chains of two and three steps) 4m55s and 6m42s; TC10 (five steps)
  10m20s. Steps in sequence add up: each pays its own queue wait and tunnel.

Not measured yet: the tunnel's start-up on Deucalion apart from the queue, throughput with large
artifacts, and how many pods run at once before the login node's process limit
([open problems](open-problems.md)).

## Against the earlier approach: the split executor

Until 24 Nov 2026 the default was the split executor on interLink 0.6.1 (tag `split-interlink-0.6.1`):
`init` and `wait`, the only containers that need the network, ran on the login node, and only `main` in
the Slurm job, coordinating through the shared file system. Three wrappers replaced the plugin's
`sbatch`, `squeue` and `scancel`, and a relay let the login node reach the Kubernetes API. It passed all
tests on the testbed, 30 of 30 checks (`t1-20261018-005325`, `20261117-222712-split`). Why it was dropped
is in the CHANGELOG (24 Nov 2026).

| | split executor (before) | reverse tunnel (now) |
|---|---|---|
| interLink | 0.6.1 | 0.6.3 |
| Code we maintain on the site | 3 wrappers + a relay, tied to 0.6.1's job script | 1 wrapper (subPath), with a patch ready upstream |
| Where `init` and `wait` run | login node | compute node, in the job |
| What the site must allow | SSH to the login node | SSH to the login node, `srun --overlap`, `python3` and `sshd` on the compute nodes |
| Data path | login node ↔ Global Storage | compute node ↔ Slurm ↔ login node ↔ shadow pod ↔ Global Storage |
| Time per short step (testbed) | about 30 s | about 1.5 min, mostly the tunnel |
| `main` reaches services | no | yes, any service named in the forwards |
