"""CNES's pipelines, unchanged: their WorkflowTemplates (CNES_TEMPLATES: their common templates, with ingest
and dispatch, and pipelines such as the stress test), the platform-config-map they read
(runner/cluster/platform-config-map.yaml), and the GlobalStorage inputs their stress test expects.

Their files stay in their repositories (ESA's GitLab, private): CNES_TEMPLATES names local clones of them,
so nothing of theirs is copied into this one. Their pipelines need the image mirror (they name public
images from several registries) and a registry token (their ingest always runs a private image)."""
import os
import tempfile
from pathlib import Path

import yaml

from .. import LisaError
from ..context import Context
from ..paths import REPO
from ..templates import render_one
from . import global_storage

# The stress test's smallest input, in the GlobalStorage bucket <GS_GLOBAL_PREFIX>test (CNES's docs:
# idefix.h5, 10 MB, random bytes; their script also makes asterix.h5, 1 GB, and obelix.h5, 10 GB).
STRESS_INPUT = ("test", "stress-pipeline/inputs/idefix.h5", 10 * 1024 * 1024)


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
    bucket, key, size = STRESS_INPUT
    bucket = s.gs_global_prefix + bucket
    store.create_bucket(bucket)
    if not store.exists(key, bucket):
        with tempfile.NamedTemporaryFile() as f:
            for _ in range(size // (1 << 20)):
                f.write(os.urandom(1 << 20))
            f.flush()
            store.upload(Path(f.name), key, bucket)
    ctx.say(f"GlobalStorage: s3://{bucket}/{key} ({size >> 20} MiB) for the stress test")
