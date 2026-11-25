"""CNES's pipelines, unchanged: their WorkflowTemplates (their common templates, with ingest and dispatch,
and pipelines such as the stress test) and the GlobalStorage inputs their stress test reads.

Their files are ESA's, private, and this repository is public, so they are not copied here: they are
read from CNES_DIR (default ~/cnes) on the Kubernetes side. A test names the ones it uses (its
expect.yaml, 'cnes:'), and 'make test' installs them just before it submits; 'make cnes' installs them all,
for running a pipeline by hand (Argo's UI, as CNES's document does). What the platform must provide besides
(the artifact repository in their layout, the platform-config-map) is installed by 'make up'
(components/artifacts.py). docs/operations.md, "CNES's pipelines", lists all of it."""
import hashlib
import tempfile
from pathlib import Path

import numpy
import yaml

from .. import LisaError
from ..context import Context
from . import global_storage

# The stress test's inputs, in the GlobalStorage bucket <GS_GLOBAL_PREFIX>test under stress-pipeline/inputs/
# (CNES's document "StressTest Pipeline", 3.1).
STRESS_BUCKET, STRESS_PREFIX = "test", "stress-pipeline/inputs"
STRESS_INPUTS = {"idefix": 10 << 20, "asterix": 1 << 30, "obelix": 10 << 30}
STRESS_SEED = 42427
GENERATOR = "cnes-create_global_inputs_for_stresspipeline"     # object metadata: made as their script does


def generate(path: Path, size: int, chunk: int = 1 << 20) -> str:
    """One input, byte for byte as CNES's script makes it (mockpipelines,
    data/stress-pipeline/scripts/create_global_inputs_for_stresspipeline.py: numpy's legacy generator
    seeded with 42427, 1 MiB chunks of randint(0, 255)). Returns its SHA-256."""
    numpy.random.seed(STRESS_SEED)
    digest = hashlib.sha256()
    with open(path, "wb") as f:
        written = 0
        while written < size:
            n = min(chunk, size - written)
            data = bytearray(numpy.random.randint(low=0, high=255, size=(1, n), dtype=numpy.uint8))
            f.write(data)
            digest.update(data)
            written += n
    return digest.hexdigest()


def available(s) -> bool:
    """Their pipelines name public images from several registries and run a private one in every ingest:
    they need the image mirror and a registry token."""
    return s.image_mirror and bool(s.mirror_private_token)


def folder(s) -> Path:
    return Path(s.cnes_dir).expanduser()


def templates(ctx: Context, names: tuple[str, ...] = ()) -> list[dict]:
    """The WorkflowTemplates in these files of CNES_DIR (all its .yaml files without names), exactly as in
    their files but for the namespace they are installed in (ARGO_NAMESPACE), as CNES's chart installs
    them in each DCC's namespaces."""
    d = folder(ctx.settings)
    paths = [d / n for n in names] if names else sorted(d.glob("*.yaml"))
    missing = [p.name for p in paths if not p.is_file()]
    if missing or not paths:
        raise LisaError(f"CNES's files are not in {d}: {', '.join(missing) or 'no .yaml file'}. Copy them there "
                        "(docs/operations.md, \"CNES's pipelines\")")
    out = []
    for path in paths:
        for doc in yaml.safe_load_all(path.read_text()):
            if doc and doc.get("kind") == "WorkflowTemplate":
                doc["metadata"]["namespace"] = ctx.settings.namespace
                out.append(doc)
    return out


def install(ctx: Context, names: tuple[str, ...] = ()) -> None:
    if not available(ctx.settings):
        raise LisaError("CNES's pipelines need IMAGE_MIRROR=on and MIRROR_PRIVATE_TOKEN")
    installed = []
    for t in templates(ctx, names):
        ctx.cluster.apply(t)
        installed.append(t["metadata"]["name"])
    ctx.say(f"CNES's templates in {ctx.settings.namespace}: {', '.join(installed)} (from {folder(ctx.settings)})")


def provide_inputs(ctx: Context, names: tuple[str, ...]) -> None:
    """The stress test's inputs in the GlobalStorage, made as CNES's script makes them. One already there
    and made that way is kept; anything else under its name is replaced."""
    s = ctx.settings
    unknown = [n for n in names if n not in STRESS_INPUTS]
    if unknown:
        raise LisaError(f"no stress-test input {', '.join(unknown)} (there are {', '.join(STRESS_INPUTS)})")
    store = global_storage.storage(ctx)
    bucket = s.gs_global_prefix + STRESS_BUCKET
    store.create_bucket(bucket)
    for name in names:
        key, size = f"{STRESS_PREFIX}/{name}.h5", STRESS_INPUTS[name]
        if (store.metadata(key, bucket) or {}).get("generator") == GENERATOR:
            ctx.say(f"GlobalStorage: s3://{bucket}/{key} already there")
            continue
        ctx.say(f"GlobalStorage: generating {name}.h5 ({size >> 20} MiB) as CNES's script does, then uploading")
        with tempfile.TemporaryDirectory(dir=s.home.root) as tmp:
            f = Path(tmp) / f"{name}.h5"
            sha = generate(f, size)
            store.upload(f, key, bucket, metadata={"generator": GENERATOR, "sha256": sha})
        ctx.say(f"GlobalStorage: s3://{bucket}/{key} (sha256 {sha})")


def prepare(ctx: Context, templates_: tuple[str, ...], inputs: tuple[str, ...]) -> None:
    """What a test of CNES's pipelines uses (its expect.yaml, 'cnes:'), just before it runs."""
    if templates_:
        install(ctx, templates_)
    if inputs:
        provide_inputs(ctx, inputs)
