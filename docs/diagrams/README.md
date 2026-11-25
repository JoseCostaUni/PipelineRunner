# Diagrams

Drawn in [Excalidraw](https://excalidraw.com), to edit by hand. Each one is kept twice:

- `<name>.excalidraw`: the scene, the source (JSON, so its changes show in a diff);
- `<name>.png`: the picture for documents and slides, **with the scene embedded**: dropping the PNG on
  excalidraw.com opens it for editing too.

To change one: open it at excalidraw.com (*Open*, or drag the file in), edit, then *Save to disk* (the
`.excalidraw`) and *Export image* as PNG with *Embed scene* on and scale 2x (the `.png`). Keep both in step.

| Diagram | Shows | Used in |
|---|---|---|
| `architecture` | what runs where: Ulisses, Deucalion's login node, a compute node, the tunnel | [architecture](../architecture.md) |
| `data-lifecycle` | CNES's data lifecycle as it runs today, and the proposal for large data | [open problems](../open-problems.md) |
| `tc21-time` | where TC21's 27 minutes went, pod by pod (run `20261125-165404`) | [results](../results.md) |

The numbers in `tc21-time` come from that run's `TC21/workflow.json` (each pod's start and end) and
`TC21/logs.txt` ("reverse tunnel ready after N s", and the transfers' own logs).
