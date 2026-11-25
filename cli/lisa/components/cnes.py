"""CNES's pipelines, unchanged: their WorkflowTemplates (CNES_TEMPLATES: their common templates, with ingest
and dispatch, and pipelines such as the stress test), the platform-config-map they read
(runner/cluster/platform-config-map.yaml), and the GlobalStorage inputs their stress test expects.

Their files stay in their repositories (ESA's GitLab, private): CNES_TEMPLATES names local clones of them,
so nothing of theirs is copied into this one. Their pipelines need the image mirror (they name public
images from several registries) and a registry token (their ingest always runs a private image)."""
import hashlib
import tempfile
from pathlib import Path

import numpy
import yaml

from .. import LisaError
from ..context import Context
from ..paths import REPO
from ..templates import render_one
from . import global_storage

# The stress test's inputs, in the GlobalStorage bucket <GS_GLOBAL_PREFIX>test under stress-pipeline/inputs/
# (CNES's document "StressTest Pipeline", 3.1). CNES_STRESS_INPUTS chooses which 'make up' provides.
STRESS_BUCKET, STRESS_PREFIX = "test", "stress-pipeline/inputs"
STRESS_INPUTS = {"idefix": 10 << 20, "asterix": 1 << 30, "obelix": 10 << 30}
STRESS_SEED = 42427


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
    return bool(s.cnes_templates) and s.image_mirror and bool(s.mirror_private_token)


def templates(ctx: Context) -> list[dict]:
    """The WorkflowTemplates in CNES_TEMPLATES, exactly as in their files but for the namespace they are
    installed in (ARGO_NAMESPACE), as CNES's chart installs them in each DCC's namespaces."""
    out = []
    for name in ctx.settings.cnes_templates:
        path = Path(name) if Path(name).is_absolute() else REPO / name
        if not path.is_file():
            raise LisaError(f"CNES_TEMPLATES names {path}, which is not there: clone CNES's repositories "
                            "next to this one (docs/operations.md)")
        for doc in yaml.safe_load_all(path.read_text()):
            if not doc or doc.get("kind") != "WorkflowTemplate":
                continue
            doc["metadata"]["namespace"] = ctx.settings.namespace
            out.append(doc)
    return out


def on(ctx: Context) -> None:
    s, c = ctx.settings, ctx.cluster
    if not available(s):
        raise LisaError("CNES's pipelines need CNES_TEMPLATES, IMAGE_MIRROR=on and MIRROR_PRIVATE_TOKEN")
    c.apply(render_one("runner/cluster/platform-config-map.yaml", namespace=s.namespace,
                       registry_sys=f"{s.mirror_private_name}/"))
    names = []
    for t in templates(ctx):
        c.apply(t)
        names.append(t["metadata"]["name"])
    ctx.say(f"CNES's templates in {s.namespace}: {', '.join(names)}; platform-config-map: images of "
            f"{s.mirror_private_name}/ through the mirror")
    store = global_storage.storage(ctx)
    bucket = s.gs_global_prefix + STRESS_BUCKET
    store.create_bucket(bucket)
    for name in s.cnes_stress_inputs:
        if name not in STRESS_INPUTS:
            raise LisaError(f"CNES_STRESS_INPUTS: no input '{name}' (there are {', '.join(STRESS_INPUTS)})")
        key, size = f"{STRESS_PREFIX}/{name}.h5", STRESS_INPUTS[name]
        if store.exists(key, bucket):
            ctx.say(f"GlobalStorage: s3://{bucket}/{key} already there")
            continue
        ctx.say(f"GlobalStorage: generating {name}.h5 ({size >> 20} MiB) as CNES's script does, then uploading")
        with tempfile.TemporaryDirectory(dir=s.home.root) as tmp:
            f = Path(tmp) / f"{name}.h5"
            sha = generate(f, size)
            store.upload(f, key, bucket)
        ctx.say(f"GlobalStorage: s3://{bucket}/{key} (sha256 {sha})")
