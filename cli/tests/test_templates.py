"""Every template (runner/ and cli/manifests/) fills in, and the YAML ones are valid YAML once filled in."""
import re
from string import Template

import pytest
import yaml

from lisa import LisaError
from lisa.paths import REPO, RUNNER
from lisa.templates import render_one, render_text, render_yaml

# The files lisa fills in (the scripts under runner/hpc are copied as they are).
MANIFESTS = REPO / "cli" / "manifests"
TEMPLATES = sorted(p for d in (RUNNER, MANIFESTS) for p in d.rglob("*") if p.suffix in (".yaml", ".service"))


@pytest.mark.parametrize("path", TEMPLATES, ids=lambda p: str(p.relative_to(REPO)))
def test_every_template_fills_in(path):
    names = Template(path.read_text()).get_identifiers()
    rel = str(path.relative_to(REPO))
    text = render_text(rel, **{n: "1000" for n in names})
    assert "${" not in text
    if path.suffix == ".yaml":
        assert list(yaml.safe_load_all(text))


def test_a_missing_value_is_an_error():
    with pytest.raises(LisaError, match="needs a value"):
        render_text("runner/cluster/workflow-defaults.yaml", node="n")


def test_namespaced_objects_name_their_namespace():
    """The cluster files are applied through the API, which needs the namespace in each object."""
    for path in sorted([*(RUNNER / "cluster").rglob("*.yaml"), *MANIFESTS.glob("*.yaml")]):
        rel = str(path.relative_to(REPO))
        if "Config" in rel or rel.endswith("workflow-defaults.yaml"):
            continue                    # interLink's own configuration, and a value inside Argo's ConfigMap
        names = Template(path.read_text()).get_identifiers()
        for obj in render_yaml(rel, **{n: "ns" for n in names}):
            assert obj["metadata"].get("namespace") == "ns", f"{rel}: {obj['kind']} without a namespace"
            assert obj["metadata"]["labels"]["app.kubernetes.io/managed-by"] == "lisa-runner"


def test_workflow_defaults_send_pods_to_the_virtual_node():
    d = render_one("runner/cluster/workflow-defaults.yaml", node="vn", account="acc", partition="p", forwards="a:1 b:2")
    spec = d["spec"]
    assert spec["nodeSelector"] == {"kubernetes.io/hostname": "vn"}
    assert spec["podMetadata"]["annotations"] == {"slurm-job.vk.io/flags": "--account=acc --partition=p",
                                                  "interlink.eu/reverse-forwards": "a:1 b:2"}


def test_the_sidecar_uses_the_subpath_fix_and_the_socket_folder():
    names = Template((RUNNER / "hpc/SlurmConfig.yaml").read_text()).get_identifiers()
    c = render_one("runner/hpc/SlurmConfig.yaml", **{n: f"<{n}>" for n in names})
    assert c["SbatchPath"] == "<sidecar>/subpath-fix/sbatch"
    assert c["SocketDirRoot"] == "<sockets>"
    assert c["SingularityDefaultOptions"] == ["--no-eval", "--contain"]
    assert re.fullmatch(r"<\w+>", c["ImagePrefix"])


def test_every_template_the_code_names_exists():
    """The paths are only used when a command runs against a cluster: a typo would show up only there."""
    code = "".join(p.read_text() for p in (REPO / "cli" / "lisa").rglob("*.py"))
    named = set(re.findall(r'render_(?:text|yaml|one)\(\s*"([^"]+)"', code))
    assert len(named) >= 10
    assert [n for n in named if not (REPO / n).is_file()] == []
