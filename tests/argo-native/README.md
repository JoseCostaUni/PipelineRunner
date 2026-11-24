# Isabel Moutinho's tests as plain Argo workflows

Her tests need her sync modules and resource templates (`tests/workflows/` in her repository, and in
the tag `split-interlink-0.6.1` of this one). These are the same tests written the way a scientist
writes any Argo workflow: container templates (`modules.yaml`, a WorkflowTemplate with her six compute
modules) and **native artifacts** from and to the default artifact repository. Nothing in them refers
to the HPC side; the platform sends them there (`../../deploy/deucalion`, `make test`).

| Test | Hers | Here |
|---|---|---|
| TC00 | (new) | one step with a native input and output artifact |
| TC01 | one step | same |
| TC02 | sync, read existing + read missing | read existing + read missing input artifact (the second fails) |
| TC03 | sync, write, sync back | write, output artifact kept in the Global Storage |
| TC04 | sync, transform, sync back | transform, input and output artifacts |
| TC05 | sync, 3 writes, aggregate, sync back | 3 parallel writes, aggregate of the key prefix |
| TC06 | sync, 300 s simulation (her duration was ignored), sync back | 120 s simulation |
| TC07 | write, sync, transform, sync, aggregate, sync | write -> transform (artifact passing), each output kept as checkpoint, aggregate |
| TC08 | user isolation (wrapper path checks) | **not ported**: see below |
| TC09 | write, sync back, read | write -> read (artifact passing) |
| TC10 | system CronWorkflow, full flow | the same DAG as a plain Workflow |
| TC11 | (new) | records the compute node and tries TCP connections to the internet (IPs and names) from inside the container; passes only if none opens. The record (`users/admin/test-11/network.txt`) stays in the Global Storage as evidence |

TC08 tested her wrapper's per-user path checks (`/users/$ARGO_USER`). Standard Argo has no such
check: isolation comes from who may use which artifact repository and credentials (per namespace),
which is a question of identity (her RQ4), not of air-gapped execution (RQ2). Left for later.

Test data: `../datasets/users/` in the bucket `argo-artifacts` under `users/`. `checks.tsv` lists
what every test must produce, checked in the Global Storage itself.
